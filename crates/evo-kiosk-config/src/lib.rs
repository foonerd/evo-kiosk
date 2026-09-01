// Copyright (c) 2026 Just a Nerd
// SPDX-License-Identifier: BUSL-1.1

//! Kiosk operator-settings write path — display rotation + touch
//! calibration.
//!
//! Owned by the kiosk-browser process per the ownership boundary
//! in the accepted kiosk design: compositor session,
//! launch/preflight/session scripts, kiosk browser binary,
//! systemd units, and install/deploy live in this workspace.
//! Framework core owns only the `/run/evo/kiosk.sock` mint
//! semantics; it never reads or writes kiosk operator settings.
//!
//! Writes the four per-setting overlay files under
//! `/var/lib/evo/settings/kiosk/` that the on-device kiosk stack
//! reads:
//!
//!   display_rotation  "0" | "90" | "180" | "270"
//!   touch_rotation    "0" | "90" | "180" | "270"
//!   touch_hflip       "true" | "false"
//!   touch_vflip       "true" | "false"
//!
//! Kiosk-side machinery owns the read + apply path:
//!   - `evo-kiosk-launch` reads on session start
//!   - `evo-kiosk-watch-settings` re-applies display rotation on
//!     overlay writes (inotify-backed)
//!   - `evo-kiosk-touch-calibrate.path` (systemd path unit)
//!     re-applies touch calibration on the same writes
//!
//! Wizard math also lives here: given four operator taps at
//! known-position on-screen targets, derive the (rotation,
//! hflip, vflip) triple that best aligns the actual touch
//! reports with the intended target positions. Brute-force over
//! all 16 combinations, minimising sum-of-squared-distance. The
//! candidate space is small enough that a closed-form
//! least-squares solve buys no accuracy on real hardware — the
//! touch panel is one of the 16 combinations by construction of
//! the compositor + libinput chain.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Serialize;
use thiserror::Error;

/// Distribution-conventional overlay directory. Matches the
/// hard-coded path in `evo-kiosk-launch` /
/// `evo-kiosk-watch-settings` / `evo-kiosk-touch-calibrate`;
/// changing it requires updating every consumer together.
pub const OVERLAY_DIR: &str = "/var/lib/evo/settings/kiosk";

// ------------------------------ defaults ------------------------------
//
// One authoritative default per operator setting. Reader helpers and
// apply-time scripts share these — keep them aligned when either side
// changes so a UI showing "current" state matches what the applier
// would produce with the same absent-overlay input.

/// Default rotation for both the display and touch axes. Matches
/// `evo-kiosk-touch-calibrate` (rotation defaults to 0) and
/// `evo-kiosk-launch` (WLR_ROT defaults to `normal` which is 0°).
pub const DEFAULT_ROTATION: &str = "0";

/// Default touch hflip / vflip. Matches `evo-kiosk-touch-calibrate`
/// which defaults each flip axis to `false` when the overlay is
/// absent.
pub const DEFAULT_TOUCH_FLIP: bool = false;

/// Default brightness percent. Matches the seed in
/// `scripts/install/install.sh` (`brightness = 80`
/// in `/etc/evo/kiosk.toml`); the apply script leaves brightness
/// alone when no overlay is present, so this default is the
/// "operator-visible expected value" for the UI — not necessarily
/// what the panel currently emits.
pub const DEFAULT_BRIGHTNESS_PERCENT: u8 = 80;

/// Default idle-sleep timeout in seconds. Matches
/// `evo-kiosk-watch-settings::apply_sleep` which reads
/// `sleep_timeout_seconds` with `"120"` as its overlay fallback.
pub const DEFAULT_SLEEP_TIMEOUT_SECONDS: u32 = 120;

/// Default sleep-inhibit-while-playing toggle. Matches
/// `evo-kiosk-watch-settings::apply_sleep` which reads
/// `sleep_inhibit_while_playing` with `"true"` as its overlay
/// fallback (and matches the seed in `/etc/evo/kiosk.toml`).
pub const DEFAULT_SLEEP_INHIBIT_WHILE_PLAYING: bool = true;

/// Default sleep-inhibit-active mirror. Matches the `false` seed
/// the plugin writes at load before its MPD subscription lands.
pub const DEFAULT_SLEEP_INHIBIT_ACTIVE: bool = false;

/// Default kiosk-enabled mirror. Matches the kiosk unit's default-
/// on-non-headless posture — an absent overlay means the operator
/// has not explicitly disabled the unit, so the running state is
/// "enabled" (the unit's own `[Install] WantedBy=multi-user.target`
/// takes effect).
pub const DEFAULT_KIOSK_ENABLED: bool = true;

/// Normalise the operator-facing rotation string to one of the
/// four canonical values `"0"`, `"90"`, `"180"`, `"270"`.
/// Accepts `"normal"` as an alias for `"0"` (mirrors what the
/// kiosk launch script does when it reads the overlay). Returns
/// `None` for any other input.
pub fn normalise_rotation(raw: &str) -> Option<&'static str> {
    match raw.trim() {
        "0" | "normal" => Some("0"),
        "90" => Some("90"),
        "180" => Some("180"),
        "270" => Some("270"),
        _ => None,
    }
}

/// Errors emitted by the settings write path.
#[derive(Debug, Error)]
pub enum KioskConfigError {
    /// The rotation value did not match `normalise_rotation`.
    #[error("invalid rotation '{0}'; expected 0 | 90 | 180 | 270")]
    InvalidRotation(String),
    /// I/O failure while writing the overlay file.
    #[error("overlay write failed: {0}")]
    Io(#[from] std::io::Error),
    /// Sample-set shape violation from the wizard path.
    #[error("wizard requires exactly 4 samples; received {0}")]
    SampleCountMismatch(usize),
    /// One of the sample coordinates is outside [0, 1] — the UI
    /// should never send these; a bounds check surfaces UI bugs.
    #[error("sample coord {0} outside [0, 1]")]
    SampleOutOfRange(f64),
}

/// Atomic write of a small text overlay: write to `<path>.tmp`,
/// fsync, rename over `<path>`. POSIX guarantees the rename is
/// atomic within the same filesystem, so a concurrent reader
/// (the systemd path unit / the launch script / the watcher)
/// sees either the old bytes or the new bytes, never a
/// truncated in-flight write.
fn write_overlay_atomic(path: &Path, contents: &str) -> Result<(), KioskConfigError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp_path: PathBuf = {
        let mut p = path.as_os_str().to_owned();
        p.push(".tmp");
        PathBuf::from(p)
    };
    {
        let mut f = std::fs::File::create(&tmp_path)?;
        f.write_all(contents.as_bytes())?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp_path, path)?;
    Ok(())
}

/// Persist `display_rotation` to its overlay file. Returns the
/// normalised value on success so the caller can echo it back
/// to the UI.
pub fn set_display_rotation(rotation: &str) -> Result<&'static str, KioskConfigError> {
    let normalised = normalise_rotation(rotation)
        .ok_or_else(|| KioskConfigError::InvalidRotation(rotation.to_string()))?;
    let path = Path::new(OVERLAY_DIR).join("display_rotation");
    write_overlay_atomic(&path, normalised)?;
    Ok(normalised)
}

/// Persist `brightness` as a 0..=100 percent overlay. Callers
/// clamp to their own operator-facing minimum (recommended
/// floor: 5 % — 0 % blacks the screen and hides the "raise
/// brightness" control). Returns the persisted percent.
pub fn set_brightness(percent: u8) -> Result<u8, KioskConfigError> {
    if percent > 100 {
        return Err(KioskConfigError::InvalidRotation(format!(
            "brightness percent {percent} out of 0..=100"
        )));
    }
    let path = Path::new(OVERLAY_DIR).join("brightness");
    write_overlay_atomic(&path, &percent.to_string())?;
    Ok(percent)
}

/// Persist `sleep_timeout_seconds`. `0` means "disabled — never
/// sleep." Values under 5 s are refused (the screen would sleep
/// almost immediately after any operator gesture and be
/// pathological). Returns the persisted value.
pub fn set_sleep_timeout(seconds: u32) -> Result<u32, KioskConfigError> {
    if seconds != 0 && seconds < 5 {
        return Err(KioskConfigError::InvalidRotation(format!(
            "sleep_timeout_seconds {seconds}: minimum non-zero value is 5"
        )));
    }
    let path = Path::new(OVERLAY_DIR).join("sleep_timeout_seconds");
    write_overlay_atomic(&path, &seconds.to_string())?;
    Ok(seconds)
}

/// Persist `sleep_inhibit_while_playing` (bool). When `true`,
/// the kiosk-side apply merges with the `sleep_inhibit_active`
/// signal (written by the plugin's MPD subscription) to
/// override the base timeout while audio is playing. Returns
/// the persisted flag.
pub fn set_sleep_inhibit_while_playing(enabled: bool) -> Result<bool, KioskConfigError> {
    let path = Path::new(OVERLAY_DIR).join("sleep_inhibit_while_playing");
    write_overlay_atomic(&path, if enabled { "true" } else { "false" })?;
    Ok(enabled)
}

/// Persist `sleep_inhibit_active` (bool). Written by the
/// plugin's MPD-state subscriber on every playback transition
/// (playing ⇒ true; paused/stopped ⇒ false). Kiosk-side apply
/// consults this alongside `sleep_inhibit_while_playing` to
/// decide whether the base timeout is currently in force.
/// Separate from the operator toggle so the operator's
/// preference persists across playback transitions without
/// stomping.
pub fn set_sleep_inhibit_active(active: bool) -> Result<bool, KioskConfigError> {
    let path = Path::new(OVERLAY_DIR).join("sleep_inhibit_active");
    write_overlay_atomic(&path, if active { "true" } else { "false" })?;
    Ok(active)
}

/// Persist `kiosk_enabled` (bool) as a UI-visible mirror of the
/// systemd unit state. The plugin's `set_enabled` verb writes
/// this alongside invoking `systemctl enable|disable --now
/// evo-kiosk.service`; the overlay is the fast-read source for
/// the UI's current-state display so it does not have to poll
/// systemd on every settings-page render.
pub fn set_kiosk_enabled(enabled: bool) -> Result<bool, KioskConfigError> {
    let path = Path::new(OVERLAY_DIR).join("kiosk_enabled");
    write_overlay_atomic(&path, if enabled { "true" } else { "false" })?;
    Ok(enabled)
}

/// Persist the touch calibration triple. Writes proceed in
/// `touch_rotation` → `touch_hflip` → `touch_vflip` order so the
/// systemd path unit that watches these three files coalesces
/// the burst into a single service run (the tens-of-milliseconds
/// window between the first and last write is well under
/// systemd's default settle time). Returns the applied values on
/// success.
pub fn set_touch_calibration(
    rotation: &str,
    hflip: bool,
    vflip: bool,
) -> Result<(&'static str, bool, bool), KioskConfigError> {
    let normalised = normalise_rotation(rotation)
        .ok_or_else(|| KioskConfigError::InvalidRotation(rotation.to_string()))?;
    let dir = Path::new(OVERLAY_DIR);
    write_overlay_atomic(&dir.join("touch_rotation"), normalised)?;
    write_overlay_atomic(
        &dir.join("touch_hflip"),
        if hflip { "true" } else { "false" },
    )?;
    write_overlay_atomic(
        &dir.join("touch_vflip"),
        if vflip { "true" } else { "false" },
    )?;
    Ok((normalised, hflip, vflip))
}

/// Result of the wizard's brute-force derivation. Carries the
/// winning triple and the mean per-sample residual distance in
/// normalised output units.
#[derive(Debug, Clone, PartialEq)]
pub struct DerivedTouchCalibration {
    /// Winning rotation. One of `"0"`, `"90"`, `"180"`, `"270"`.
    pub rotation: &'static str,
    /// Winning horizontal flip flag.
    pub hflip: bool,
    /// Winning vertical flip flag.
    pub vflip: bool,
    /// Mean per-sample residual distance in [0, 1]. Values near
    /// 0 indicate a clean fit; values approaching 0.5 suggest
    /// operator error or a non-affine touch surface.
    pub mean_error: f64,
}

/// Sample as it arrives from the wizard path: four
/// `(target, actual)` pairs in normalised output space.
#[derive(Debug, Clone, PartialEq)]
pub struct TouchSample {
    /// X of the target the UI drew on-screen, [0, 1].
    pub target_x: f64,
    /// Y of the target the UI drew on-screen, [0, 1].
    pub target_y: f64,
    /// X the operator actually tapped, post-libinput-identity-
    /// calibration, [0, 1].
    pub actual_x: f64,
    /// Y the operator actually tapped, in the same normalised
    /// frame, [0, 1].
    pub actual_y: f64,
}

/// Base 2×3 affine matrices (device_native → output). Same
/// values `evo-kiosk-touch-calibrate` composes; duplicated here
/// so the wizard can reason about them without shelling out.
const IDENT: [f64; 6] = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0];
const ROT_90: [f64; 6] = [0.0, 1.0, 0.0, -1.0, 0.0, 1.0];
const ROT_180: [f64; 6] = [-1.0, 0.0, 1.0, 0.0, -1.0, 1.0];
const ROT_270: [f64; 6] = [0.0, -1.0, 1.0, 1.0, 0.0, 0.0];
const HFLIP: [f64; 6] = [-1.0, 0.0, 1.0, 0.0, 1.0, 0.0];
const VFLIP: [f64; 6] = [1.0, 0.0, 0.0, 0.0, -1.0, 1.0];

/// 2×3 affine composition A * B (each extended to 3×3 with the
/// bottom row (0, 0, 1)).
fn compose(a: [f64; 6], b: [f64; 6]) -> [f64; 6] {
    [
        a[0] * b[0] + a[1] * b[3],
        a[0] * b[1] + a[1] * b[4],
        a[0] * b[2] + a[1] * b[5] + a[2],
        a[3] * b[0] + a[4] * b[3],
        a[3] * b[1] + a[4] * b[4],
        a[3] * b[2] + a[4] * b[5] + a[5],
    ]
}

/// Compose the full calibration matrix from a decomposed triple.
/// Same logic as `evo-kiosk-touch-calibrate` — kept aligned so
/// wizard, UI, and udev rule all agree.
fn matrix_for(rotation: &str, hflip: bool, vflip: bool) -> [f64; 6] {
    let rot = match rotation {
        "90" => ROT_90,
        "180" => ROT_180,
        "270" => ROT_270,
        _ => IDENT,
    };
    let mut m = rot;
    if hflip {
        m = compose(HFLIP, m);
    }
    if vflip {
        m = compose(VFLIP, m);
    }
    m
}

/// The 16 candidate (rotation, hflip, vflip) triples the wizard
/// picks from. Order stable so the search is trivially
/// reproducible.
const CANDIDATE_TRIPLES: [(&str, bool, bool); 16] = [
    ("0", false, false),
    ("0", true, false),
    ("0", false, true),
    ("0", true, true),
    ("90", false, false),
    ("90", true, false),
    ("90", false, true),
    ("90", true, true),
    ("180", false, false),
    ("180", true, false),
    ("180", false, true),
    ("180", true, true),
    ("270", false, false),
    ("270", true, false),
    ("270", false, true),
    ("270", true, true),
];

/// Derive the best (rotation, hflip, vflip) triple from four
/// corner samples and apply it as a side effect. Refuses non-4
/// sample counts and out-of-range coordinates.
pub fn derive_and_apply_touch_calibration(
    samples: &[TouchSample],
) -> Result<DerivedTouchCalibration, KioskConfigError> {
    let d = derive_touch_calibration(samples)?;
    set_touch_calibration(d.rotation, d.hflip, d.vflip)?;
    Ok(d)
}

/// Pure derivation — pick the candidate with minimum
/// mean-per-sample residual. Exposed as its own function so
/// tests can exercise the math without touching the filesystem.
pub fn derive_touch_calibration(
    samples: &[TouchSample],
) -> Result<DerivedTouchCalibration, KioskConfigError> {
    if samples.len() != 4 {
        return Err(KioskConfigError::SampleCountMismatch(samples.len()));
    }
    for s in samples {
        for v in [s.target_x, s.target_y, s.actual_x, s.actual_y] {
            if !(0.0..=1.0).contains(&v) {
                return Err(KioskConfigError::SampleOutOfRange(v));
            }
        }
    }

    let mut best = DerivedTouchCalibration {
        rotation: "0",
        hflip: false,
        vflip: false,
        mean_error: f64::INFINITY,
    };
    for &(rot, hf, vf) in &CANDIDATE_TRIPLES {
        let m = matrix_for(rot, hf, vf);
        let mut sq = 0.0;
        for s in samples {
            let px = m[0] * s.actual_x + m[1] * s.actual_y + m[2];
            let py = m[3] * s.actual_x + m[4] * s.actual_y + m[5];
            let dx = px - s.target_x;
            let dy = py - s.target_y;
            sq += dx * dx + dy * dy;
        }
        let mean = (sq / samples.len() as f64).sqrt();
        if mean < best.mean_error {
            best = DerivedTouchCalibration {
                rotation: rot,
                hflip: hf,
                vflip: vf,
                mean_error: mean,
            };
        }
    }
    Ok(best)
}

// ------------------------------ read side -----------------------------
//
// The reader helpers below mirror the writer helpers above: for every
// overlay a `set_*` function persists, a `read_*` returns the current
// value (or the documented default when the overlay is absent /
// unparseable). One authoritative source of overlay filesystem
// semantics — the writer and reader stay locked together by
// construction.
//
// Callers wanting the complete operator-visible state get it as a
// single call via `read_display_state()` → `DisplayState`, which is
// what the plugin's `get_display_state` read verb returns to a
// paired browser on mount.

/// Nested touch calibration triple. Kept as a struct so the wire
/// shape has a clear `touch: { rotation, hflip, vflip }` envelope
/// distinct from the display rotation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TouchState {
    /// Touch rotation, one of `"0"`, `"90"`, `"180"`, `"270"`.
    pub rotation: String,
    /// Horizontal flip flag applied after rotation.
    pub hflip: bool,
    /// Vertical flip flag applied after rotation.
    pub vflip: bool,
}

/// Complete operator-visible kiosk state. Serialised as JSON on
/// the wire in response to the plugin's `get_display_state` verb;
/// field names on the wire match the operator-visible surface the
/// UI's Display & Touch settings panel binds to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DisplayState {
    /// Compositor display rotation.
    pub display_rotation: String,
    /// Touch calibration triple.
    pub touch: TouchState,
    /// Backlight percent, 0..=100. Floored at 5 by the apply
    /// script so the operator's "raise brightness" control stays
    /// reachable; the read side reports whatever the overlay
    /// says without clamping so the UI can render an out-of-range
    /// overlay for diagnosis.
    pub brightness_percent: u8,
    /// Idle-sleep timeout in seconds. `0` means disabled.
    pub sleep_timeout_seconds: u32,
    /// Operator toggle for "keep the screen awake while playing."
    /// Composes with the plugin's MPD subscriber to override the
    /// base timeout while audio is playing.
    pub sleep_inhibit_while_playing: bool,
    /// Kiosk unit enabled state (mirror of the systemd unit set
    /// by the plugin's `set_enabled` verb). Fast-read source for
    /// the UI so it does not have to poll systemd on every
    /// settings-page render.
    pub enabled: bool,
}

/// Read a single-line overlay file. Returns `Some(trimmed_string)`
/// when the file is present and non-empty, `None` otherwise.
fn read_overlay(name: &str) -> Option<String> {
    let path = Path::new(OVERLAY_DIR).join(name);
    match std::fs::read_to_string(&path) {
        Ok(s) => {
            let trimmed = s.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        }
        Err(_) => None,
    }
}

fn parse_bool(raw: &str) -> Option<bool> {
    match raw {
        "true" | "1" | "yes" => Some(true),
        "false" | "0" | "no" => Some(false),
        _ => None,
    }
}

/// Read the persisted display rotation. Falls back to
/// [`DEFAULT_ROTATION`] when the overlay is absent, unparseable,
/// or empty. Honours the legacy single-axis `rotation` overlay
/// when the decoupled `display_rotation` overlay is missing — same
/// fallback the apply scripts use.
pub fn read_display_rotation() -> String {
    if let Some(raw) = read_overlay("display_rotation") {
        if let Some(norm) = normalise_rotation(&raw) {
            return norm.to_string();
        }
    }
    if let Some(raw) = read_overlay("rotation") {
        if let Some(norm) = normalise_rotation(&raw) {
            return norm.to_string();
        }
    }
    DEFAULT_ROTATION.to_string()
}

/// Read the persisted touch rotation. Same fallback ladder as
/// [`read_display_rotation`] — decoupled overlay first, then the
/// legacy single-axis overlay, then [`DEFAULT_ROTATION`].
pub fn read_touch_rotation() -> String {
    if let Some(raw) = read_overlay("touch_rotation") {
        if let Some(norm) = normalise_rotation(&raw) {
            return norm.to_string();
        }
    }
    if let Some(raw) = read_overlay("rotation") {
        if let Some(norm) = normalise_rotation(&raw) {
            return norm.to_string();
        }
    }
    DEFAULT_ROTATION.to_string()
}

/// Read the persisted touch horizontal flip flag. Falls back to
/// [`DEFAULT_TOUCH_FLIP`].
pub fn read_touch_hflip() -> bool {
    read_overlay("touch_hflip")
        .and_then(|s| parse_bool(&s))
        .unwrap_or(DEFAULT_TOUCH_FLIP)
}

/// Read the persisted touch vertical flip flag. Falls back to
/// [`DEFAULT_TOUCH_FLIP`].
pub fn read_touch_vflip() -> bool {
    read_overlay("touch_vflip")
        .and_then(|s| parse_bool(&s))
        .unwrap_or(DEFAULT_TOUCH_FLIP)
}

/// Read the persisted brightness percent. Falls back to
/// [`DEFAULT_BRIGHTNESS_PERCENT`] when the overlay is absent or
/// unparseable. Does not clamp — an out-of-range overlay is
/// reported verbatim so the UI can surface it for diagnosis.
pub fn read_brightness() -> u8 {
    read_overlay("brightness")
        .and_then(|s| s.parse::<u8>().ok())
        .unwrap_or(DEFAULT_BRIGHTNESS_PERCENT)
}

/// Read the persisted idle-sleep timeout in seconds. Falls back
/// to [`DEFAULT_SLEEP_TIMEOUT_SECONDS`].
pub fn read_sleep_timeout_seconds() -> u32 {
    read_overlay("sleep_timeout_seconds")
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(DEFAULT_SLEEP_TIMEOUT_SECONDS)
}

/// Read the persisted sleep-inhibit-while-playing toggle. Falls
/// back to [`DEFAULT_SLEEP_INHIBIT_WHILE_PLAYING`].
pub fn read_sleep_inhibit_while_playing() -> bool {
    read_overlay("sleep_inhibit_while_playing")
        .and_then(|s| parse_bool(&s))
        .unwrap_or(DEFAULT_SLEEP_INHIBIT_WHILE_PLAYING)
}

/// Read the persisted kiosk-enabled mirror. Falls back to
/// [`DEFAULT_KIOSK_ENABLED`].
pub fn read_kiosk_enabled() -> bool {
    read_overlay("kiosk_enabled")
        .and_then(|s| parse_bool(&s))
        .unwrap_or(DEFAULT_KIOSK_ENABLED)
}

/// Read the complete operator-visible state. Composes every
/// individual reader above into a single [`DisplayState`] the
/// plugin's `get_display_state` verb returns. Never fails — a
/// missing / unparseable / empty overlay collapses to its
/// documented default so a paired browser mounting on a fresh
/// boot with no operator changes yet made sees the system's
/// actual defaults, not a mix of `None`s.
pub fn read_display_state() -> DisplayState {
    DisplayState {
        display_rotation: read_display_rotation(),
        touch: TouchState {
            rotation: read_touch_rotation(),
            hflip: read_touch_hflip(),
            vflip: read_touch_vflip(),
        },
        brightness_percent: read_brightness(),
        sleep_timeout_seconds: read_sleep_timeout_seconds(),
        sleep_inhibit_while_playing: read_sleep_inhibit_while_playing(),
        enabled: read_kiosk_enabled(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_rotation_aliases() {
        assert_eq!(normalise_rotation("normal"), Some("0"));
        assert_eq!(normalise_rotation("0"), Some("0"));
        assert_eq!(normalise_rotation("  90 "), Some("90"));
        assert_eq!(normalise_rotation("180"), Some("180"));
        assert_eq!(normalise_rotation("270"), Some("270"));
        assert_eq!(normalise_rotation("360"), None);
        assert_eq!(normalise_rotation("portrait"), None);
        assert_eq!(normalise_rotation(""), None);
    }

    #[test]
    fn wizard_picks_identity_on_perfect_alignment() {
        let samples = vec![
            TouchSample {
                target_x: 0.1,
                target_y: 0.1,
                actual_x: 0.1,
                actual_y: 0.1,
            },
            TouchSample {
                target_x: 0.9,
                target_y: 0.1,
                actual_x: 0.9,
                actual_y: 0.1,
            },
            TouchSample {
                target_x: 0.9,
                target_y: 0.9,
                actual_x: 0.9,
                actual_y: 0.9,
            },
            TouchSample {
                target_x: 0.1,
                target_y: 0.9,
                actual_x: 0.1,
                actual_y: 0.9,
            },
        ];
        let d = derive_touch_calibration(&samples).unwrap();
        assert_eq!(d.rotation, "0");
        assert!(!d.hflip);
        assert!(!d.vflip);
        assert!(d.mean_error < 1e-9);
    }

    #[test]
    fn wizard_picks_rot_90_when_panel_is_90_off() {
        // Synthesize actuals as if the panel were rotated 270°
        // from the intended orientation. The wizard derives the
        // inverse (rotation "90") to bring taps back into
        // alignment with the targets.
        let m270 = matrix_for("270", false, false);
        let targets = [(0.1_f64, 0.1_f64), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)];
        let samples: Vec<_> = targets
            .iter()
            .map(|&(tx, ty)| {
                let ax = m270[0] * tx + m270[1] * ty + m270[2];
                let ay = m270[3] * tx + m270[4] * ty + m270[5];
                TouchSample {
                    target_x: tx,
                    target_y: ty,
                    actual_x: ax,
                    actual_y: ay,
                }
            })
            .collect();
        let d = derive_touch_calibration(&samples).unwrap();
        assert_eq!(d.rotation, "90");
        assert!(!d.hflip);
        assert!(!d.vflip);
        assert!(d.mean_error < 1e-9);
    }

    #[test]
    fn wizard_refuses_wrong_sample_count() {
        let samples = vec![
            TouchSample {
                target_x: 0.1,
                target_y: 0.1,
                actual_x: 0.1,
                actual_y: 0.1,
            },
            TouchSample {
                target_x: 0.9,
                target_y: 0.9,
                actual_x: 0.9,
                actual_y: 0.9,
            },
        ];
        let err = derive_touch_calibration(&samples).unwrap_err();
        assert!(matches!(err, KioskConfigError::SampleCountMismatch(2)));
    }

    #[test]
    fn wizard_refuses_out_of_range_coord() {
        let samples = vec![
            TouchSample {
                target_x: 0.1,
                target_y: 0.1,
                actual_x: 0.1,
                actual_y: 0.1,
            },
            TouchSample {
                target_x: 0.9,
                target_y: 0.1,
                actual_x: 1.2,
                actual_y: 0.1,
            },
            TouchSample {
                target_x: 0.9,
                target_y: 0.9,
                actual_x: 0.9,
                actual_y: 0.9,
            },
            TouchSample {
                target_x: 0.1,
                target_y: 0.9,
                actual_x: 0.1,
                actual_y: 0.9,
            },
        ];
        let err = derive_touch_calibration(&samples).unwrap_err();
        assert!(matches!(err, KioskConfigError::SampleOutOfRange(v) if v > 1.0));
    }

    #[test]
    fn matrix_for_matches_kiosk_shell_table() {
        // Every (rotation, hflip, vflip) combination the shell
        // `evo-kiosk-touch-calibrate` script also emits. If this
        // table drifts, the wizard and the udev rule disagree
        // about what the operator asked for.
        let rows: &[(&str, bool, bool, [f64; 6])] = &[
            ("0", false, false, [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]),
            ("0", false, true, [1.0, 0.0, 0.0, 0.0, -1.0, 1.0]),
            ("0", true, false, [-1.0, 0.0, 1.0, 0.0, 1.0, 0.0]),
            ("0", true, true, [-1.0, 0.0, 1.0, 0.0, -1.0, 1.0]),
            ("90", false, false, [0.0, 1.0, 0.0, -1.0, 0.0, 1.0]),
            ("90", false, true, [0.0, 1.0, 0.0, 1.0, 0.0, 0.0]),
            ("90", true, false, [0.0, -1.0, 1.0, -1.0, 0.0, 1.0]),
            ("90", true, true, [0.0, -1.0, 1.0, 1.0, 0.0, 0.0]),
            ("180", false, false, [-1.0, 0.0, 1.0, 0.0, -1.0, 1.0]),
            ("180", false, true, [-1.0, 0.0, 1.0, 0.0, 1.0, 0.0]),
            ("180", true, false, [1.0, 0.0, 0.0, 0.0, -1.0, 1.0]),
            ("180", true, true, [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]),
            ("270", false, false, [0.0, -1.0, 1.0, 1.0, 0.0, 0.0]),
            ("270", false, true, [0.0, -1.0, 1.0, -1.0, 0.0, 1.0]),
            ("270", true, false, [0.0, 1.0, 0.0, 1.0, 0.0, 0.0]),
            ("270", true, true, [0.0, 1.0, 0.0, -1.0, 0.0, 1.0]),
        ];
        for (rot, hf, vf, want) in rows {
            let got = matrix_for(rot, *hf, *vf);
            for i in 0..6 {
                assert!(
                    (got[i] - want[i]).abs() < 1e-9,
                    "matrix_for({rot}, {hf}, {vf}) mismatch at [{i}]: got={got:?} want={want:?}"
                );
            }
        }
    }

    #[test]
    fn parse_bool_accepts_documented_aliases() {
        assert_eq!(parse_bool("true"), Some(true));
        assert_eq!(parse_bool("1"), Some(true));
        assert_eq!(parse_bool("yes"), Some(true));
        assert_eq!(parse_bool("false"), Some(false));
        assert_eq!(parse_bool("0"), Some(false));
        assert_eq!(parse_bool("no"), Some(false));
        assert_eq!(parse_bool("nope"), None);
        assert_eq!(parse_bool(""), None);
    }

    #[test]
    fn display_state_wire_shape_matches_ui_spec() {
        // Locks the JSON shape to the UI contract.
        // Any drift here breaks the paired-browser get_display_state
        // consumer on mount.
        let s = DisplayState {
            display_rotation: "270".to_string(),
            touch: TouchState {
                rotation: "90".to_string(),
                hflip: false,
                vflip: false,
            },
            brightness_percent: 60,
            sleep_timeout_seconds: 120,
            sleep_inhibit_while_playing: true,
            enabled: true,
        };
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["display_rotation"], "270");
        assert_eq!(json["touch"]["rotation"], "90");
        assert_eq!(json["touch"]["hflip"], false);
        assert_eq!(json["touch"]["vflip"], false);
        assert_eq!(json["brightness_percent"], 60);
        assert_eq!(json["sleep_timeout_seconds"], 120);
        assert_eq!(json["sleep_inhibit_while_playing"], true);
        assert_eq!(json["enabled"], true);
    }

    #[test]
    fn defaults_are_the_operator_visible_expected_values() {
        // If any of these change, the UI's fresh-boot render
        // changes with them — flag it as a coordinated change.
        assert_eq!(DEFAULT_ROTATION, "0");
        assert!(!DEFAULT_TOUCH_FLIP);
        assert_eq!(DEFAULT_BRIGHTNESS_PERCENT, 80);
        assert_eq!(DEFAULT_SLEEP_TIMEOUT_SECONDS, 120);
        assert!(DEFAULT_SLEEP_INHIBIT_WHILE_PLAYING);
        assert!(!DEFAULT_SLEEP_INHIBIT_ACTIVE);
        assert!(DEFAULT_KIOSK_ENABLED);
    }
}
