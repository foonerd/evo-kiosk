# SPDX-License-Identifier: BUSL-1.1
#
# Cross-build image for evo-kiosk-browser targeting
# armv7-unknown-linux-gnueabihf (32-bit ARMv7 hard-float). Base
# pinned to `debian:trixie` for runtime-parity ABI (see the
# x86_64 sibling for the rationale).
#
# Same shape as the aarch64 sibling with `armhf` instead of
# `arm64` as the target dpkg arch and `arm-linux-gnueabihf`
# instead of `aarch64-linux-gnu` as the cross-toolchain prefix.
#
# Compatible with cross-rs 0.2.5's `[target.<triple>] dockerfile`
# mechanism.

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture armhf && \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      ca-certificates \
      gcc-arm-linux-gnueabihf \
      libc6-dev:armhf \
      libgtk-4-dev:armhf \
      libwebkitgtk-6.0-dev:armhf \
      libjavascriptcoregtk-6.0-dev:armhf \
    && rm -rf /var/lib/apt/lists/*
# libc6-dev:armhf required — see aarch64 sibling for the same
# cc-rs multiarch header rationale.

ENV CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=arm-linux-gnueabihf-gcc \
    PKG_CONFIG_ALLOW_CROSS_armv7_unknown_linux_gnueabihf=1 \
    PKG_CONFIG_PATH_armv7_unknown_linux_gnueabihf=/usr/lib/arm-linux-gnueabihf/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR_armv7_unknown_linux_gnueabihf=/
