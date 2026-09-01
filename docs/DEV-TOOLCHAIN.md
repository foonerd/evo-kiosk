# Dev-Box Toolchain Reference

Every build tool this repository needs is installed on the shared dev box. This document lists where each tool lives, which version is present, and the canonical commands for cross-building `evo-kiosk-browser` for the supported rig architectures. Follow the commands verbatim; do not wrap them in an alternative sandbox to work around a missing-tool report — the tool is on `PATH` unless a shell rc has been deliberately cleared.

The companion doc [`DEVELOPING.md`](../DEVELOPING.md) covers workflow conventions (branching, PRs, review). This document covers the mechanical toolchain.

Kiosk-browser links `libgtk-4` and `libwebkitgtk-6.0` at both build time (pkg-config discovery) and run time (dynamic linking). Cross-arch releases therefore require those `-dev` packages present in the target architecture inside a container — plain host cargo cannot resolve them. This repository uses `cross-rs` for every non-host release build. `Cross.toml` at the repo root already declares the correct base image + pre-build apt install per target.

## Toolchain inventory

| Tool | Path | Version | Purpose |
| --- | --- | --- | --- |
| `cargo` | `$HOME/.cargo/bin/cargo` | 1.97.1 | Rust build / test / run (host builds + local dev) |
| `rustc` | `$HOME/.cargo/bin/rustc` | 1.97.1 | Rust compiler (invoked by cargo) |
| `rustup` | `$HOME/.cargo/bin/rustup` | 1.29.0 | Toolchain + target manager |
| `cross` | `$HOME/.cargo/bin/cross` | 0.2.5 | Containerised cross-compile — **required** for every non-host release |
| `docker` | `/usr/bin/docker` | 29.7.2 | Container runtime — daemon running, reachable |
| `aarch64-linux-gnu-gcc` | `/usr/bin/aarch64-linux-gnu-gcc` | — | aarch64 cross-linker (present but unused: kiosk goes via `cross`, not plain cargo, because of the GTK/WebKit native deps) |
| `arm-linux-gnueabihf-gcc` | `/usr/bin/arm-linux-gnueabihf-gcc` | — | armv7 cross-linker (same note as above) |

**Rust targets already installed** (verify with `rustup target list --installed`):

- `aarch64-unknown-linux-gnu` (Pi 5, ARM NUCs)
- `armv7-unknown-linux-gnueabihf` (older 32-bit Pi)
- `x86_64-unknown-linux-gnu` (dev-box host + x86 NUCs / VMs)

## Where the tools come from — brief

- **Rust toolchain (`cargo` / `rustc` / `rustup`).** Installed via `rustup` in the user profile at `~/.cargo/bin/`. `~/.cargo/bin/` is on the interactive `PATH` from the shell rc. When invoking from a non-login script (systemd unit, CI runner), source the shell rc or prepend the absolute path.
- **`cross` (containerised cross-compile).** Installed via `cargo install cross`. Wraps `docker` with the base image declared per target in [`Cross.toml`](../Cross.toml) — currently `ghcr.io/cross-rs/<triple>:main` (Ubuntu 24.04-based, the earliest LTS that ships `libwebkitgtk-6.0-dev` and `libgtk-4-dev`). The `pre-build` steps in `Cross.toml` add the target Debian architecture, refresh apt sources, and install the GTK4 + WebKit6 development headers plus JavaScriptCore6 and pkg-config. First build against each triple pays the apt cost; the post-`pre-build` image is cached locally so subsequent builds against the same triple are fast.
- **`docker`.** Installed via the OS package manager; daemon is up and reachable. `cross` invokes it for every cross-target build.
- **Cross-linkers.** Present on the box but not used by this repo — kiosk goes via `cross` because the GTK/WebKit native deps require the container path, not plain host cargo with a cross-linker.

## Canonical commands — full release matrix

The canonical release-cut entry is [`scripts/release/cross-build.sh`](../scripts/release/cross-build.sh). Run it after `scripts/release/pre-tag-check.sh` clears and the release tag is minted; run it before `scripts/release/publish-artefacts.sh` signs and pushes into `foonerd/evo-kiosk-artefacts`.

```bash
# Full matrix (aarch64 + x86_64 + armv7):
./scripts/release/cross-build.sh

# Override the target list to build a subset:
KIOSK_CROSS_TARGETS="aarch64-unknown-linux-gnu" ./scripts/release/cross-build.sh

# Extra cross-build flags appended verbatim:
KIOSK_CROSS_ARGS="--features some-optional-flag" ./scripts/release/cross-build.sh
```

Successful runs land per-triple artefacts under `target/release-artefacts/<triple>/`:

- `evo-kiosk-browser` — the binary
- `evo-kiosk-browser.sha256` — content hash
- `build-info.toml` — build metadata (git rev, host, target, image)

A single-target failure fails the whole script — a partial release plane is worse than no release plane.

## Canonical commands — single-target cross-build

For a one-off cross-build outside the full-matrix release path (debug, feature-flag experiment, incremental fix):

```bash
# From the repo root:
cross build --release --target aarch64-unknown-linux-gnu    # Pi 5 rigs
cross build --release --target x86_64-unknown-linux-gnu     # NUC / VM rigs
cross build --release --target armv7-unknown-linux-gnueabihf   # older 32-bit Pi
```

`cross` picks up the target image + pre-build from `Cross.toml` automatically. First run per triple: several minutes (apt install inside the container). Subsequent runs: seconds (cached layer).

Output lands at `target/<triple>/release/evo-kiosk-browser` (standard cargo layout for cross-target builds).

## Canonical commands — host build (dev / test / lint)

Kiosk's host toolchain is host-arch; host builds do not need `cross` and do not exercise the GTK/WebKit link path in the same way as a cross-target build (the host has the target-arch dev packages natively via `apt`).

```bash
# From the repo root:
cargo build --release
cargo test --workspace --locked
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
```

If a host build fails to link with a `libwebkitgtk` or `libgtk-4` error, the host is missing those dev packages — install with:

```bash
sudo apt-get install -y libgtk-4-dev libwebkitgtk-6.0-dev libjavascriptcoregtk-6.0-dev pkg-config
```

The shared dev box has these installed; the `apt-get` above is only for a fresh host being brought up.

## When NOT to use `cross`

- **Host-arch build for local dev / test.** Plain `cargo build` / `cargo test` is faster and does not touch docker.
- **A pure-Rust crate with zero native deps.** Not this repo — kiosk-browser is not pure-Rust. But if a helper crate under `crates/` is genuinely pure-Rust and needs cross-building against a target with no other native deps in its build graph, plain `cargo build --target <triple>` with a rustup-added target + linker block is faster than `cross`.

For every other cross-target case in this repo — every release-cut build across all three supported triples — `cross` is the canonical path.

## Shell / `PATH` hygiene

- Interactive shells source `~/.bashrc` (or equivalent), which pulls in `~/.cargo/env`. `cargo` / `rustc` / `cross` are on `PATH` in that state.
- Non-login shells (systemd units, cron, CI runners) do NOT source the shell rc. Either source it explicitly at the top of the script or use absolute paths (`$HOME/.cargo/bin/cargo`, `$HOME/.cargo/bin/cross`).
- If a build command reports a tool "not found", run `which <tool>` first. If `which` also reports missing, the tool genuinely isn't on the current `PATH`. Fix the `PATH` (source the rc, prepend the absolute directory) — do not wrap the command in a container as a workaround.
- `docker` is on the default `PATH` on the shared dev box; the daemon is up. If `cross` prints "docker daemon not reachable", check `docker info` first — if that also fails, the daemon has stopped and needs a Framework-side restart.

## Reporting a genuinely missing tool

If a tool is genuinely absent from the shared dev box (every entry in the inventory table above has been verified present), flag it back on the workstream chat and it will be installed. Do not invent an alternative execution surface to work around a missing tool — that fragments the build path and produces the stale-artefact class the canonical `scripts/release/cross-build.sh` entry exists to prevent.
