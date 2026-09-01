// Copyright (c) 2026 Just a Nerd
// SPDX-License-Identifier: BUSL-1.1

//! Library surface for `evo-kiosk-browser`.
//!
//! The mint client and navigation-policy helpers are pure Rust
//! (stdlib plus `serde`, `url`, and `socket2`) so host CI can test
//! them without GTK/WebKit headers. The binary shell links GTK4 and
//! webkit2gtk.

pub mod mint;
pub mod nav_policy;

// Re-export the shared kiosk-settings write path + wizard math so
// existing consumers (main.rs script-message handlers) keep the
// same import surface. The implementation lives in the workspace
// crate `evo-kiosk-config`, which is also depended on by the
// org.evoframework.system.kiosk plugin — one source of truth for
// the atomic overlay writes and the calibration matrix table.
pub use evo_kiosk_config::{
    derive_and_apply_touch_calibration, derive_touch_calibration, set_display_rotation,
    set_touch_calibration, DerivedTouchCalibration, KioskConfigError, TouchSample, OVERLAY_DIR,
};
pub use mint::{
    js_string_literal, kiosk_sock_path, local_storage_inject_script, mint_once, mint_with_retry,
    renew_at_ms, MintError, MintedSession, BEARER_STORAGE_KEY, DEFAULT_KIOSK_SOCK,
};
pub use nav_policy::{navigation_allowed, parse_allowed_origin};
