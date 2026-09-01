# SPDX-License-Identifier: BUSL-1.1
#
# Cross-build image for evo-kiosk-browser targeting
# x86_64-unknown-linux-gnu. Base pinned to `debian:trixie` to
# match the runtime OS on target devices, so build-time
# libwebkitgtk-6.0-dev + libgtk-4-dev + libjavascriptcoregtk-6.0-dev
# link against the SAME symbol versions and vendor patch level
# that the runtime dynamic loader presents at load time. Ubuntu
# base (cross-rs's default `ghcr.io/cross-rs/*:main` images)
# would build against `2.52.3-0ubuntu0.24.04.1`; the device runs
# `2.52.5-1~deb13u1`. Different upstream patch + vendor stream;
# hidden ABI divergence risk. Debian-trixie base eliminates it.
#
# Native build: this image runs on x86_64 hosts and produces
# x86_64 binaries. No cross-linker + no dpkg add-arch needed.
# Sibling images (aarch64 + armv7) fence a target arch and
# install its cross-linker.
#
# Compatible with cross-rs 0.2.5's `[target.<triple>] dockerfile`
# mechanism. Cross-rs mounts the workspace at /project + the host
# cargo + rustup dirs at runtime; the image supplies base OS +
# native toolchain + dev libraries. No rustup/cargo installed
# inside the image on purpose (cross-rs owns that).

FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      ca-certificates \
      libgtk-4-dev \
      libwebkitgtk-6.0-dev \
      libjavascriptcoregtk-6.0-dev \
    && rm -rf /var/lib/apt/lists/*
