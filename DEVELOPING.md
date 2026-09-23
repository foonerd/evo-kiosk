# Developing

## Prerequisites

- Rust stable toolchain
- On Linux build hosts targeting the device: `libgtk-4-dev`, `libwebkitgtk-6.0-dev`, `libsoup-3.0-dev`, `pkg-config`
- Running steward with `/run/evo/kiosk.sock` and `EVO_KIOSK_UIDS` for mint integration tests

## Workspace

Lib / mint unit tests (no GTK/WebKit link):

```bash
cargo test -p evo-kiosk-browser --lib --no-default-features
```

Release browser binary (needs GTK/WebKit):

```bash
cargo build -p evo-kiosk-browser --release --features webkit
```

Compulsory commit entry gate (host-CI profile: no GTK/WebKit headers). rustdoc `-D warnings` is part of the gate. Run before every commit:

```bash
scripts/preflight/check-cargo-workout.sh
```

That is `cargo clean`, `fmt --all -- --check`, then clippy / test / rustdoc `-D warnings` on `evo-kiosk-config` and on `evo-kiosk-browser --lib --no-default-features`. The webkit binary is a device/deploy gate, not this host gate.

Also useful while editing:

```bash
cargo fmt --all -- --check
cargo clippy -p evo-kiosk-browser --lib --no-default-features --locked -- -D warnings
```

The browser crate intentionally does not depend on `evo-core`. Mint client talks to the Unix socket with a minimal framed client.

## Session layer

Helpers live under `layer/bin/` and install to `/usr/local/bin/evo-kiosk-*`. See `docs/KIOSK.md` for process shape, paths, overlays, and mint ownership.

```bash
sudo ./scripts/install/install.sh
```

## Stack locks

- labwc + GTK4 + webkit2gtk 6
- maximize (not fullscreen) for OSK
- browser owns mint + cookie inject on `/run/evo/kiosk.sock` only
- default-on when non-headless; Settings toggle for operator control
