# SPDX-License-Identifier: BUSL-1.1
#
# Cross-build image for evo-kiosk-browser targeting
# aarch64-unknown-linux-gnu. Base pinned to `debian:trixie` for
# runtime-parity ABI (see the x86_64 sibling for the rationale).
#
# Cross toolchain shape:
#
#   - Host arch (amd64) build-essential for build-scripts + procs.
#   - Cross-linker for aarch64: gcc-aarch64-linux-gnu.
#   - dpkg multi-arch: arm64 enabled so apt can install the
#     target-arch dev libraries alongside amd64 build tools.
#   - Target-arch dev libraries: libgtk-4-dev:arm64 +
#     libwebkitgtk-6.0-dev:arm64 + libjavascriptcoregtk-6.0-dev:arm64.
#     Debian trixie's `ports.debian.org`-tracked archive carries
#     these at the same upstream + vendor patch level as amd64,
#     so cross-build and native x86_64 build produce binaries
#     that link against symbol-equivalent runtime libs.
#   - pkg-config env vars: cargo (via the crate build scripts)
#     resolves pkg-config against target-arch .pc files under
#     /usr/lib/aarch64-linux-gnu/pkgconfig.
#
# Compatible with cross-rs 0.2.5's `[target.<triple>] dockerfile`
# mechanism.

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture arm64 && \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      ca-certificates \
      gcc-aarch64-linux-gnu \
      libc6-dev:arm64 \
      libgtk-4-dev:arm64 \
      libwebkitgtk-6.0-dev:arm64 \
      libjavascriptcoregtk-6.0-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*
# libc6-dev:arm64 required in addition to gcc-aarch64-linux-gnu for
# any downstream crate using cc-rs to cross-compile C sources (ring /
# aws-lc-sys / rustls native backends). cc-rs resolves <stdlib.h>
# via Debian's multiarch layout; the bits/ subheader lives in
# libc6-dev:arm64.

# Point cargo at the cross-linker + pkg-config at the target-arch
# sysroot. Cross-rs propagates these into the cargo subprocess it
# runs against the workspace.
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    PKG_CONFIG_ALLOW_CROSS_aarch64_unknown_linux_gnu=1 \
    PKG_CONFIG_PATH_aarch64_unknown_linux_gnu=/usr/lib/aarch64-linux-gnu/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR_aarch64_unknown_linux_gnu=/
