# evo kiosk engineering workspace

Implementation workspace for the on-device kiosk session shell.

## Purpose

High-velocity workspace for:

- Wayland compositor session (labwc) and systemd units
- GTK4 + webkit2gtk kiosk browser binary
- mint on `/run/evo/kiosk.sock` and origin-bound cookie inject
- install / deploy scripts and cross-built prebuilts
- Plymouth handoff coordination (theme assets stay in the boot repo)

## Does not own

- Plymouth theme (owned by the boot workspace)
- UI SPA (owned by the UI workspace)
- Framework mint wire semantics (owned by the framework core)
- Distribution UID allowlist and packaging hooks (owned by the audio device distribution)

## Layout

- `crates/kiosk-browser/` - standalone WebKit kiosk binary
- `layer/` - systemd units, labwc config, launch/session/preflight helpers
- `scripts/install/` - device install helpers
- `scripts/release/` - pre-tag / promote helpers
- `docs/` - kiosk contract

## Contract

Delivers the operator-facing kiosk browser + boot integration + hardware acceptance surface.
