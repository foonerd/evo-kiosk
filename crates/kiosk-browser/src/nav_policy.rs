// Copyright (c) 2026 Just a Nerd
// SPDX-License-Identifier: BUSL-1.1

//! Kiosk navigation-policy helpers.
//!
//! The kiosk browser owns a `NavigationAction` policy that pins the
//! WebView to the operator-supplied initial URL's origin. A rogue
//! link, a misconfigured SPA, or a tag corruption cannot navigate
//! the kiosk to an external URL and pin the operator glass off-brand.
//!
//! `data:` URIs are refused unconditionally — any code path that
//! previously loaded an internally-generated `data:` failure page
//! now uses `WebView::load_html`, which reaches the WebView without
//! a `data:`-URL navigation. `about:blank` is the only `about:*`
//! form allowed (WebKit uses it as the base URI for `load_html`
//! and as a bootstrap surface); other `about:*` forms (about:crash,
//! about:memory, about:config, about:blank#specific) are refused.
//!
//! Kept in a stdlib-plus-`url` module (no GTK/WebKit link) so host
//! CI can exercise the policy without kiosk display packages.

use url::Url;

/// Return the operator-configured origin (`scheme://host:port`, port
/// always explicit) the kiosk is allowed to navigate within, if the
/// initial URL parses as `http` or `https`. Any other scheme returns
/// `None`; the caller's navigation policy then only permits
/// `about:blank`.
///
/// The port is materialised (defaulting to 80 / 443) so a target URL
/// that omits the port matches an initial URL that supplies it
/// (`http://127.0.0.1/` vs `http://127.0.0.1:80/`).
pub fn parse_allowed_origin(initial_url: &str) -> Option<String> {
    let parsed = Url::parse(initial_url).ok()?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return None;
    }
    let host = parsed.host_str()?;
    let scheme = parsed.scheme();
    let default_port = if scheme == "https" { 443 } else { 80 };
    let port = parsed.port().unwrap_or(default_port);
    Some(format!("{scheme}://{host}:{port}"))
}

/// Decide whether `target` may be navigated to under the current
/// origin allowlist.
///
/// - `about:blank` passes unconditionally — WebKit reports this as
///   the URI when `WebView::load_html` is used, and as the base
///   surface it briefly loads during bootstrap.
/// - Every other `about:*` form (`about:crash`, `about:config`,
///   `about:memory`, `about:blank#`, `about:` with query strings) is
///   refused — the operator kiosk has no legitimate reason to reach
///   those, and unconditional pass would leak an attack surface an
///   XSS or content-injection could exploit.
/// - `data:` URIs are refused unconditionally — the mint-failure
///   page uses `WebView::load_html` now, so no internal code path
///   needs `data:`.
/// - Any http/https URL must match the allowed origin exactly
///   (scheme + host + port, port defaulted to 80 / 443).
/// - Malformed URLs are refused.
/// - When no allowed origin is set (initial URL was not http-family),
///   only `about:blank` passes.
pub fn navigation_allowed(target: &str, allowed_origin: Option<&str>) -> bool {
    if target == "about:blank" {
        return true;
    }
    if target.starts_with("data:") || target.starts_with("about:") {
        return false;
    }
    let Some(allowed) = allowed_origin else {
        return false;
    };
    let Ok(parsed) = Url::parse(target) else {
        return false;
    };
    let Some(host) = parsed.host_str() else {
        return false;
    };
    let scheme = parsed.scheme();
    let default_port = if scheme == "https" { 443 } else { 80 };
    let port = parsed.port().unwrap_or(default_port);
    let candidate = format!("{scheme}://{host}:{port}");
    candidate == allowed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_allowed_origin_defaults_port_80() {
        assert_eq!(
            parse_allowed_origin("http://127.0.0.1/").as_deref(),
            Some("http://127.0.0.1:80")
        );
    }

    #[test]
    fn parse_allowed_origin_defaults_port_443() {
        assert_eq!(
            parse_allowed_origin("https://kiosk.local/").as_deref(),
            Some("https://kiosk.local:443")
        );
    }

    #[test]
    fn parse_allowed_origin_preserves_explicit_port() {
        assert_eq!(
            parse_allowed_origin("http://127.0.0.1:8443/ui/").as_deref(),
            Some("http://127.0.0.1:8443")
        );
    }

    #[test]
    fn parse_allowed_origin_refuses_non_http() {
        assert_eq!(parse_allowed_origin("file:///opt/ui/index.html"), None);
        assert_eq!(parse_allowed_origin("data:text/html,<h1>x</h1>"), None);
        assert_eq!(parse_allowed_origin("about:blank"), None);
    }

    #[test]
    fn navigation_allowed_matches_same_origin_default_port() {
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(navigation_allowed(
            "http://127.0.0.1/library",
            allowed.as_deref()
        ));
        assert!(navigation_allowed(
            "http://127.0.0.1:80/queue",
            allowed.as_deref()
        ));
    }

    #[test]
    fn navigation_allowed_refuses_other_host() {
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(!navigation_allowed(
            "http://192.0.2.10/library",
            allowed.as_deref()
        ));
    }

    #[test]
    fn navigation_allowed_refuses_other_port() {
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(!navigation_allowed(
            "http://127.0.0.1:8443/library",
            allowed.as_deref()
        ));
    }

    #[test]
    fn navigation_allowed_refuses_other_scheme() {
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(!navigation_allowed(
            "https://127.0.0.1/library",
            allowed.as_deref()
        ));
    }

    #[test]
    fn navigation_allowed_about_blank_always_passes() {
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        // With an origin configured — WebKit reports about:blank
        // during load_html and bootstrap; must pass.
        assert!(navigation_allowed("about:blank", allowed.as_deref()));
        // With no origin configured — same policy.
        assert!(navigation_allowed("about:blank", None));
    }

    #[test]
    fn navigation_allowed_refuses_data_urls() {
        // The mint-failure page migrated to WebView::load_html so no
        // internal code path needs data: URIs. Refuse them wholesale.
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(!navigation_allowed(
            "data:text/html,<h1>x</h1>",
            allowed.as_deref()
        ));
        assert!(!navigation_allowed(
            "data:text/html,<script>alert(1)</script>",
            allowed.as_deref()
        ));
        assert!(!navigation_allowed("data:text/html,<h1>x</h1>", None));
    }

    #[test]
    fn navigation_allowed_refuses_non_blank_about_forms() {
        // about:crash / about:config / about:memory are legitimate
        // WebKit surfaces but have no place in the operator kiosk;
        // XSS or content-injection reaching one is an escape.
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(!navigation_allowed("about:crash", allowed.as_deref()));
        assert!(!navigation_allowed("about:config", allowed.as_deref()));
        assert!(!navigation_allowed("about:memory", allowed.as_deref()));
        // Fragments and query strings on about:blank are also refused —
        // the equality check keeps this tight.
        assert!(!navigation_allowed("about:blank#x", allowed.as_deref()));
        assert!(!navigation_allowed("about:blank?y=1", allowed.as_deref()));
    }

    #[test]
    fn navigation_allowed_refuses_when_no_origin_configured() {
        // Initial URL that produced no allowed origin blocks every
        // non-about-blank URL.
        assert!(!navigation_allowed("http://127.0.0.1/", None));
        assert!(!navigation_allowed("https://example.com/", None));
        assert!(!navigation_allowed("data:text/html,x", None));
        assert!(!navigation_allowed("about:crash", None));
    }

    #[test]
    fn navigation_allowed_refuses_malformed_url() {
        let allowed = parse_allowed_origin("http://127.0.0.1/");
        assert!(!navigation_allowed("not a url", allowed.as_deref()));
        assert!(!navigation_allowed("http://", allowed.as_deref()));
    }
}
