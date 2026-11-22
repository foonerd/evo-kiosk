// Copyright (c) 2026 Just a Nerd
// SPDX-License-Identifier: BUSL-1.1

//! evo-kiosk-browser — on-device WebKit kiosk shell.
//!
//! GTK 4 + webkit2gtk 6.0, maximize (not fullscreen) for OSK layer-shell,
//! mint on `/run/evo/kiosk.sock`, inject bearer into `localStorage.evoBearer`,
//! navigate to local UI. See docs/KIOSK.md.
//!
//! Environment:
//!   KIOSK_URL              URL to load (default http://127.0.0.1/)
//!   KIOSK_ZOOM             WebKit zoom level float (default 1.0)
//!   EVO_KIOSK_SOCK         mint socket (default /run/evo/kiosk.sock)
//!   EVO_KIOSK_MINT_REASON  audit reason (default kiosk-boot)
//!
//! CLI: evo-kiosk-browser [URL]

use std::cell::RefCell;
use std::env;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use evo_kiosk_browser::{
    kiosk_sock_path, local_storage_inject_script, mint_with_retry, navigation_allowed,
    parse_allowed_origin, probe_bearer, renew_at_ms, BearerState, MintedSession, WatchAction,
    BEARER,
};
use gio::prelude::*;
use gio::ApplicationFlags;
use glib::ControlFlow;
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow};
use webkit6::prelude::*;
use webkit6::{
    NavigationPolicyDecision, PolicyDecisionType, UserContentInjectedFrames, UserContentManager,
    UserScript, UserScriptInjectionTime, WebView,
};

const APP_ID: &str = "org.evoframework.kiosk";
const DEFAULT_URL: &str = "http://127.0.0.1/";
const FALLBACK_WIDTH: i32 = 1280;
const FALLBACK_HEIGHT: i32 = 720;
const RELOAD_DELAY_MS: u64 = 1000;
const MAXIMIZE_RETRY_MS: u64 = 200;
const MINT_ATTEMPTS: u32 = 8;
const MINT_INITIAL_BACKOFF_MS: u64 = 250;
/// How often the panel asks the steward whether it still honours the
/// bearer it presents. Loopback and one short-lived request, so a
/// refused bearer is noticed in seconds, not at the daily renewal.
const BEARER_WATCH_SECS: u32 = 15;

/// Generation of the renewal timer; see `schedule_renew`.
static RENEW_EPOCH: AtomicU64 = AtomicU64::new(0);

fn log_line(msg: &str) {
    // Never include the bearer. systemd journal greps align with
    // [kiosk-launch] / [kiosk-session] / [kiosk-browser].
    // eprintln (stderr) rather than println (stdout): systemd
    // captures both via StandardOutput/StandardError=journal, but
    // stdout is block-buffered when connected to a pipe (which
    // systemd is), so single-line events like "calibrate-trigger
    // fired" would sit in a ~8 KiB buffer until enough noise
    // flushed them. stderr is line-buffered, so log lines land
    // in the journal immediately — what an operator watching
    // `journalctl -fu evo-kiosk.service` expects.
    eprintln!("[kiosk-browser] {msg}");
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn resolve_url(argv: &[String]) -> String {
    if argv.len() >= 2 && !argv[1].is_empty() {
        return argv[1].clone();
    }
    env::var("KIOSK_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_URL.to_string())
}

fn resolve_zoom() -> f64 {
    let raw = match env::var("KIOSK_ZOOM") {
        Ok(v) => v,
        Err(_) => return 1.0,
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("auto") {
        return 1.0;
    }
    match trimmed.parse::<f64>() {
        Ok(v) if v.is_finite() && v > 0.0 => v.clamp(0.25, 5.0),
        _ => {
            log_line(&format!(
                "KIOSK_ZOOM='{raw}' not a positive float; using 1.0"
            ));
            1.0
        }
    }
}

fn mint_reason() -> String {
    env::var("EVO_KIOSK_MINT_REASON")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "kiosk-boot".to_string())
}

fn mint_session(reason: &str) -> Result<MintedSession, String> {
    let sock = kiosk_sock_path();
    log_line(&format!("minting via {} reason={reason}", sock.display()));
    mint_with_retry(
        &sock,
        reason,
        MINT_ATTEMPTS,
        Duration::from_millis(MINT_INITIAL_BACKOFF_MS),
    )
    .map_err(|e| {
        // MintError Display never includes the bearer.
        format!("{e}")
    })
}

/// Glass presence probe. The UI's `kioskMode()` treats
/// `window.webkit.messageHandlers.evo_set_display_rotation` as
/// "this is the on-device browser". Display and touch writes now
/// go through `system.kiosk` verbs, so this slot must stay
/// registered and must not write overlays. The two touch writer
/// names are not registered: a script that still posts them
/// fails closed instead of skipping the household gate.
fn install_kiosk_glass_probe(ucm: &UserContentManager) {
    ucm.register_script_message_handler("evo_set_display_rotation", None);
    ucm.connect_script_message_received(Some("evo_set_display_rotation"), |_ucm, _value| {
        log_line(
            "settings: evo_set_display_rotation is a presence probe; \
             display writes go through system.kiosk",
        );
    });
}

/// Polling window for the `calibrate_trigger` overlay file. 500 ms
/// gives a "walked to the laptop, clicked the button, walked back
/// to the player" latency well inside the operator's tolerance and
/// costs one `stat(2)` every half-second — cheaper than an
/// inotify watcher on the browser side, which would add a
/// dependency for a single feature.
const CALIBRATE_TRIGGER_POLL_MS: u64 = 500;

/// Absolute path to the trigger file the system.kiosk plugin's
/// `launch_touch_calibration` verb writes. Matches the constant
/// the plugin uses on the write side; a drift here would break
/// the remote-triggered wizard silently.
const CALIBRATE_TRIGGER_PATH: &str = "/var/lib/evo/settings/kiosk/calibrate_trigger";

/// Install the `calibrate_trigger` watcher. Every
/// [`CALIBRATE_TRIGGER_POLL_MS`], stat the trigger file. On
/// mtime change (or first appearance), evaluate a JS snippet in
/// the loaded page that dispatches
/// `CustomEvent('evo:touch-calibration-launch')` on `window`.
///
/// The local UI (Evo UI running in this browser) listens for
/// the event and opens the four-corner wizard on-glass. Same
/// wizard the on-glass "Calibrate touch" button opens; the
/// operator walks to the device to tap the corners.
///
/// Pairs with the plugin verb
/// `system.kiosk.launch_touch_calibration` which writes
/// [`CALIBRATE_TRIGGER_PATH`] with a wall-clock ms token. The
/// verb's response is fire-and-forget from the operator's
/// remote-browser perspective — the visible confirmation is the
/// wizard appearing on the player's glass, mediated by this
/// watcher.
///
/// First-tick behaviour: whatever mtime the file has at browser
/// start is treated as "already-seen". A calibrate_trigger file
/// created before the browser started does NOT re-fire the
/// event on next boot — otherwise the wizard would open every
/// time the kiosk restarts if the operator ever triggered it
/// once, which is not the intent.
fn install_calibrate_trigger_watcher(webview: &WebView) {
    let webview = webview.clone();
    let last_mtime = Rc::new(RefCell::new(current_trigger_mtime()));
    log_line(&format!(
        "calibrate-trigger watcher: polling {CALIBRATE_TRIGGER_PATH} every {CALIBRATE_TRIGGER_POLL_MS}ms"
    ));
    glib::timeout_add_local(
        Duration::from_millis(CALIBRATE_TRIGGER_POLL_MS),
        move || {
            let now_mtime = current_trigger_mtime();
            let prior = *last_mtime.borrow();
            // Trigger on any change from the prior observation
            // — file creation (None → Some), file re-write (Some
            // → Some' with different value), and file removal
            // (Some → None). Only the first two are meaningful
            // for the wizard-launch semantics; treating a
            // deletion as a launch would fire spuriously on
            // operator settings-directory hygiene. Gate on
            // Some(_) so deletions are absorbed silently.
            if now_mtime != prior && now_mtime.is_some() {
                log_line("calibrate-trigger fired; dispatching evo:touch-calibration-launch");
                let script = "(() => { \
                     window.evoTouchCalibrationLaunch = { launched_at_ms: Date.now() }; \
                     window.dispatchEvent(new CustomEvent('evo:touch-calibration-launch', \
                         {detail: window.evoTouchCalibrationLaunch})); \
                 })();";
                webview.evaluate_javascript(script, None, None, None::<&gio::Cancellable>, |_| {});
            }
            *last_mtime.borrow_mut() = now_mtime;
            ControlFlow::Continue
        },
    );
}

/// Read `mtime` on the trigger file. Returns `None` if the file
/// does not exist yet (fresh install, operator has never
/// triggered the wizard from a remote browser). Returns `None`
/// on any I/O error too — the watcher just waits for the next
/// tick rather than surfacing the transient noise.
fn current_trigger_mtime() -> Option<SystemTime> {
    std::fs::metadata(CALIBRATE_TRIGGER_PATH)
        .and_then(|m| m.modified())
        .ok()
}

/// Hold `session` as the bearer this panel presents and write it into
/// every page load from here on. The page script is built from the held
/// bearer and from nothing else, so a bearer that has been dropped is
/// never written again.
fn install_bearer_script(ucm: &UserContentManager, session: &MintedSession) {
    ucm.remove_all_scripts();
    let script = {
        let mut held = BEARER.lock().unwrap_or_else(|p| p.into_inner());
        held.install(session);
        held.script()
    };
    if let Some(source) = script {
        ucm.add_script(&UserScript::new(
            &source,
            UserContentInjectedFrames::AllFrames,
            UserScriptInjectionTime::Start,
            &[],
            &[],
        ));
    }
}

/// Stop writing the bearer into pages. Run the moment the steward
/// refuses it, before a replacement is minted, so no load in between
/// is handed the dead one.
fn drop_bearer_script(ucm: &UserContentManager) {
    ucm.remove_all_scripts();
}

/// `host`, `port` of a plain-http kiosk URL: where the steward answers
/// the bearer probe. An https URL is left to the daily renewal.
fn probe_target(url: &str) -> Option<(String, u16)> {
    let parsed = url::Url::parse(url).ok()?;
    if parsed.scheme() != "http" {
        return None;
    }
    Some((
        parsed.host_str()?.to_string(),
        parsed.port_or_known_default()?,
    ))
}

/// Watch the bearer. Every few seconds the steward is asked whether it
/// still honours the bearer held. A refusal drops it and mints a fresh
/// one on the local socket, loaded without a unit restart; an outage
/// changes nothing, since a down steward says nothing about the bearer.
fn start_bearer_watch(webview: &WebView, ucm: &UserContentManager, url: &str, reason: &str) {
    let Some((host, port)) = probe_target(url) else {
        log_line("bearer watch off: kiosk url is not plain http");
        return;
    };
    let webview = webview.clone();
    let ucm = ucm.clone();
    let url = url.to_string();
    let reason = reason.to_string();
    let busy = Rc::new(std::cell::Cell::new(false));
    glib::timeout_add_seconds_local(BEARER_WATCH_SECS, move || {
        if busy.replace(true) {
            return ControlFlow::Continue;
        }
        let held = BEARER
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .token()
            .map(str::to_string);
        let (webview, ucm, url, reason, host, busy) = (
            webview.clone(),
            ucm.clone(),
            url.clone(),
            reason.clone(),
            host.clone(),
            busy.clone(),
        );
        glib::spawn_future_local(async move {
            let state = match held {
                Some(token) => gio::spawn_blocking(move || probe_bearer(&host, port, &token))
                    .await
                    .unwrap_or(BearerState::Unknown),
                None => BearerState::Unknown,
            };
            let (action, dead_id) = {
                let mut held = BEARER.lock().unwrap_or_else(|p| p.into_inner());
                let id = held.token_id().map(str::to_string);
                (held.on_probe(state), id)
            };
            if action == WatchAction::Remint {
                match dead_id {
                    Some(id) if state == BearerState::Refused => {
                        log_line(&format!(
                            "bearer refused by the steward (token_id={id}); reminting"
                        ));
                    }
                    _ => log_line("no bearer held; reminting"),
                }
                drop_bearer_script(&ucm);
                match mint_session(&reason) {
                    Ok(next) => {
                        log_line(&format!("bearer remint ok token_id={}", next.token_id));
                        install_bearer_script(&ucm, &next);
                        webview.load_uri(&url);
                        schedule_renew(&webview, &ucm, &url, &next, &reason);
                    }
                    Err(e) => log_line(&format!("bearer remint failed: {e}; retrying")),
                }
            }
            busy.set(false);
        });
        ControlFlow::Continue
    });
}

fn mint_failure_html(detail: &str) -> String {
    // HTML body loaded via WebView::load_html — reaches the WebView
    // without a data:-URL navigation, so the nav-policy allowlist can
    // refuse all data: URIs without also killing this operator page.
    let safe = detail
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;");
    format!(
        "<!doctype html><html><head><meta charset=utf-8>\
         <title>evo kiosk</title>\
         <style>body{{margin:0;background:#111;color:#eee;font:20px/1.4 system-ui,sans-serif;\
         display:flex;min-height:100vh;align-items:center;justify-content:center;padding:2rem;}}\
         main{{max-width:36rem}}h1{{font-size:1.4rem;margin:0 0 .75rem}}\
         p{{margin:.5rem 0;opacity:.85}}code{{opacity:.7;font-size:.85rem}}</style></head>\
         <body><main><h1>Display session unavailable</h1>\
         <p>The kiosk shell could not obtain a local session from the steward.</p>\
         <p>Check that evo is running, this user is allowlisted for kiosk mint, \
         and a display is attached. The unit will retry automatically.</p>\
         <p><code>{safe}</code></p></main></body></html>"
    )
}

fn schedule_renew(
    webview: &WebView,
    ucm: &UserContentManager,
    url: &str,
    session: &MintedSession,
    reason: &str,
) {
    // One renewal timer at a time: a remint from any path supersedes the
    // one before it, so timers do not pile up.
    let epoch = RENEW_EPOCH.fetch_add(1, Ordering::SeqCst) + 1;
    let renew_at = renew_at_ms(session.expires_at_ms, now_ms());
    let delay_ms = renew_at.saturating_sub(now_ms()).max(1_000);
    log_line(&format!(
        "scheduling silent remint in {}s (token_id={})",
        delay_ms / 1000,
        session.token_id
    ));

    let webview = webview.clone();
    let ucm = ucm.clone();
    let url = url.to_string();
    let reason = reason.to_string();
    glib::timeout_add_local(Duration::from_millis(delay_ms), move || {
        if RENEW_EPOCH.load(Ordering::SeqCst) != epoch {
            return ControlFlow::Break;
        }
        match mint_session(&reason) {
            Ok(next) => {
                log_line(&format!("silent remint ok token_id={}", next.token_id));
                install_bearer_script(&ucm, &next);
                // Re-inject on next navigation; also run immediately for the live page.
                let js = local_storage_inject_script(&next.token);
                webview.evaluate_javascript(&js, None, None, None::<&gio::Cancellable>, |_| {});
                schedule_renew(&webview, &ucm, &url, &next, &reason);
            }
            Err(e) => {
                log_line(&format!("silent remint failed: {e}; retrying in 30s"));
                let webview = webview.clone();
                let ucm = ucm.clone();
                let url = url.clone();
                let reason = reason.clone();
                glib::timeout_add_local(Duration::from_secs(30), move || {
                    if RENEW_EPOCH.load(Ordering::SeqCst) != epoch {
                        return ControlFlow::Break;
                    }
                    match mint_session(&reason) {
                        Ok(next) => {
                            install_bearer_script(&ucm, &next);
                            webview.load_uri(&url);
                            schedule_renew(&webview, &ucm, &url, &next, &reason);
                        }
                        Err(e2) => {
                            log_line(&format!("remint still failing: {e2}"));
                            webview.load_html(&mint_failure_html(&e2), None);
                        }
                    }
                    ControlFlow::Break
                });
            }
        }
        ControlFlow::Break
    });
}

fn build_ui(app: &Application, url: &str, zoom: f64, reason: &str) {
    let window = ApplicationWindow::builder()
        .application(app)
        .decorated(false)
        .title("evo")
        .default_width(FALLBACK_WIDTH)
        .default_height(FALLBACK_HEIGHT)
        .build();

    let ucm = UserContentManager::new();

    let webview = WebView::builder()
        .user_content_manager(&ucm)
        .hexpand(true)
        .vexpand(true)
        .focusable(true)
        .build();

    // Presence probe only. Overlay writes go through system.kiosk.
    // Remote launch of the on-glass wizard is the trigger-file
    // watcher below, not a WebKit write handler.
    install_kiosk_glass_probe(&ucm);
    install_calibrate_trigger_watcher(&webview);

    if (zoom - 1.0).abs() > f64::EPSILON {
        log_line(&format!("set_zoom_level({zoom})"));
        webview.set_zoom_level(zoom);
    }

    // Initial mint before first navigation so Start-time user script applies.
    match mint_session(reason) {
        Ok(session) => {
            log_line(&format!(
                "mint ok token_id={} expires_at_ms={}",
                session.token_id, session.expires_at_ms
            ));
            install_bearer_script(&ucm, &session);
            schedule_renew(&webview, &ucm, url, &session, reason);
            webview.load_uri(url);
        }
        Err(e) => {
            log_line(&format!("mint failed: {e}"));
            webview.load_html(&mint_failure_html(&e), None);
        }
    };

    start_bearer_watch(&webview, &ucm, url, reason);

    // Navigation policy: allow the operator-supplied kiosk URL's
    // origin (scheme + host + port) plus the internally-generated
    // `data:` failure page. Refuse everything else. A rogue link in
    // the local SPA (or a tag corruption) cannot navigate the kiosk
    // to an external URL and pin the operator glass off-brand.
    let allowed_origin = parse_allowed_origin(url);
    log_line(&format!(
        "navigation policy: allowed_origin={} data-urls=refused about-blank=allowed",
        allowed_origin
            .as_deref()
            .unwrap_or("<none — about:blank only>")
    ));
    let allowed_origin_for_decision = allowed_origin.clone();
    webview.connect_decide_policy(move |_webview, decision, dtype| match dtype {
        PolicyDecisionType::NewWindowAction => {
            log_line("blocked new window (popup / target=_blank / window.open)");
            decision.ignore();
            true
        }
        PolicyDecisionType::NavigationAction => {
            if let Some(nav) = decision.downcast_ref::<NavigationPolicyDecision>() {
                let target = nav
                    .navigation_action()
                    .and_then(|mut a| a.request())
                    .and_then(|r| r.uri())
                    .map(|s| s.to_string())
                    .unwrap_or_default();
                if navigation_allowed(&target, allowed_origin_for_decision.as_deref()) {
                    return false;
                }
                log_line(&format!(
                    "blocked navigation to {target:?}: outside allowed origin"
                ));
                decision.ignore();
                return true;
            }
            false
        }
        _ => false,
    });

    webview.connect_context_menu(|_webview, _menu, _hit| true);

    let webview_for_terminate = webview.clone();
    let ucm_for_terminate = ucm.clone();
    let url_for_terminate = url.to_string();
    let reason_for_terminate = reason.to_string();
    // Track in-flight remint so we do not pile up timers on crash storms.
    let reminting = Rc::new(RefCell::new(false));
    webview.connect_web_process_terminated(move |_webview, reason_term| {
        log_line(&format!(
            "WebProcess terminated ({reason_term:?}); remint+reload in {RELOAD_DELAY_MS}ms"
        ));
        if *reminting.borrow() {
            return;
        }
        *reminting.borrow_mut() = true;
        let webview = webview_for_terminate.clone();
        let ucm = ucm_for_terminate.clone();
        let url = url_for_terminate.clone();
        let reason = reason_for_terminate.clone();
        let reminting = reminting.clone();
        glib::timeout_add_local(Duration::from_millis(RELOAD_DELAY_MS), move || {
            match mint_session(&reason) {
                Ok(session) => {
                    install_bearer_script(&ucm, &session);
                    webview.load_uri(&url);
                    schedule_renew(&webview, &ucm, &url, &session, &reason);
                }
                Err(e) => {
                    log_line(&format!("remint after WebProcess death failed: {e}"));
                    webview.load_html(&mint_failure_html(&e), None);
                }
            }
            *reminting.borrow_mut() = false;
            ControlFlow::Break
        });
    });

    window.set_child(Some(&webview));

    let window_for_notify = window.clone();
    window.connect_maximized_notify(move |w| {
        if !w.is_maximized() {
            log_line("window unmaximized; re-requesting");
            let w2 = window_for_notify.clone();
            glib::timeout_add_local(Duration::from_millis(MAXIMIZE_RETRY_MS), move || {
                w2.maximize();
                ControlFlow::Break
            });
        }
    });

    window.present();

    let window_for_maximize = window.clone();
    glib::idle_add_local_once(move || {
        log_line("requesting maximize");
        window_for_maximize.maximize();
    });

    let webview_for_focus = webview.clone();
    glib::idle_add_local_once(move || {
        log_line("granting GTK focus to WebView");
        webview_for_focus.grab_focus();
    });
}

fn main() -> glib::ExitCode {
    let argv: Vec<String> = env::args().collect();
    let url = resolve_url(&argv);
    let zoom = resolve_zoom();
    let reason = mint_reason();
    log_line(&format!("starting; url={url} zoom={zoom} reason={reason}"));

    // NON_UNIQUE: systemd guarantees single-instance; D-Bus app registration
    // is unreliable in the PAM-login session context.
    let app = Application::builder()
        .application_id(APP_ID)
        .flags(ApplicationFlags::NON_UNIQUE)
        .build();

    let url_for_activate = url.clone();
    let reason_for_activate = reason.clone();
    app.connect_activate(move |app| {
        build_ui(app, &url_for_activate, zoom, &reason_for_activate);
    });

    let argv0 = argv
        .first()
        .cloned()
        .unwrap_or_else(|| "evo-kiosk-browser".to_string());
    app.run_with_args(&[argv0])
}
