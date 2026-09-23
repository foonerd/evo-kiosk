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

// No writer re-exports. This crate used to re-export
// `evo-kiosk-config`'s overlay writers and wizard math so the
// binary's WebKit handlers could reach them. Those handlers are
// gone — display and touch writes go through the `system.kiosk`
// verbs, where the capability and household gates can refuse them
// — and nothing in this tree imported the re-exports afterwards.
// The plugin depends on `evo-kiosk-config` directly. A consumer
// that needs the write path takes that crate, not this one.
pub use mint::{
    js_string_literal, kiosk_sock_path, local_storage_inject_script, mint_once, mint_with_retry,
    renew_at_ms, MintError, MintedSession, BEARER_STORAGE_KEY, DEFAULT_KIOSK_SOCK,
};
pub use nav_policy::{navigation_allowed, parse_allowed_origin};

#[cfg(test)]
mod glass_probe {
    const MAIN: &str = include_str!("main.rs");

    #[test]
    fn touch_writer_handlers_are_not_registered() {
        assert!(
            !MAIN.contains("evo_set_touch_calibration"),
            "touch writer slot must not be registered"
        );
        assert!(
            !MAIN.contains("evo_sample_touch_calibration_from_corners"),
            "derive writer slot must not be registered"
        );
    }

    #[test]
    fn rotation_slot_is_a_probe_not_a_writer() {
        assert!(
            MAIN.contains("register_script_message_handler(\"evo_set_display_rotation\""),
            "glass probe slot must stay registered"
        );
        assert!(
            !MAIN.contains("set_display_rotation("),
            "probe must not write the rotation overlay"
        );
        assert!(
            !MAIN.contains("set_touch_calibration("),
            "browser must not write the touch overlay"
        );
        assert!(
            !MAIN.contains("derive_and_apply_touch_calibration("),
            "browser must not derive-and-apply in-process"
        );
    }
}
