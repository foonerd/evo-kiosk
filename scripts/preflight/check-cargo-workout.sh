#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# check-cargo-workout.sh — compulsory commit entry gate.
#
# Host-CI profile (no GTK/WebKit headers):
#   evo-kiosk-browser --lib --no-default-features
#   evo-kiosk-config  (no webkit feature)
# plus cargo clean and rustdoc -D warnings. The webkit binary is
# a device/deploy gate, not this host gate (see DEVELOPING.md
# and scripts/release/pre-tag-check.sh).
#
# Usage:
#   scripts/preflight/check-cargo-workout.sh
#   scripts/preflight/check-cargo-workout.sh --no-locked

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

TOOLCHAIN="${CARGO_TOOLCHAIN:-stable}"
LOCKED=1
if [[ "${1:-}" == "--no-locked" ]]; then
    LOCKED=0
fi

lock_args=()
if [[ "${LOCKED}" -eq 1 ]]; then
    lock_args+=(--locked)
fi

log_step() { printf '\n[workout] %s\n' "$*" >&2; }
log_ok()   { printf '[workout] OK: %s\n' "$*" >&2; }
log_fail() { printf '[workout] FAIL: %s\n' "$*" >&2; }

unset CARGO_TARGET_DIR

log_step "1/5 cargo +${TOOLCHAIN} clean"
cargo "+${TOOLCHAIN}" clean
log_ok "clean"

log_step "2/5 cargo +${TOOLCHAIN} fmt --all -- --check"
if ! cargo "+${TOOLCHAIN}" fmt --all -- --check; then
    log_fail "fmt drift. Fix: cargo +${TOOLCHAIN} fmt --all"
    exit 1
fi
log_ok "fmt"

log_step "3/5 clippy host-CI profile -D warnings"
if ! cargo "+${TOOLCHAIN}" clippy -p evo-kiosk-config --all-targets \
        "${lock_args[@]}" -- -D warnings; then
    log_fail "clippy -D warnings (evo-kiosk-config)"
    exit 1
fi
if ! cargo "+${TOOLCHAIN}" clippy -p evo-kiosk-browser --lib \
        --no-default-features "${lock_args[@]}" -- -D warnings; then
    log_fail "clippy -D warnings (evo-kiosk-browser --lib --no-default-features)"
    exit 1
fi
log_ok "clippy"

log_step "4/5 test host-CI profile"
if ! cargo "+${TOOLCHAIN}" test -p evo-kiosk-config "${lock_args[@]}"; then
    log_fail "tests (evo-kiosk-config)"
    exit 1
fi
if ! cargo "+${TOOLCHAIN}" test -p evo-kiosk-browser --lib \
        --no-default-features "${lock_args[@]}"; then
    log_fail "tests (evo-kiosk-browser --lib --no-default-features)"
    exit 1
fi
log_ok "test"

log_step "5/5 rustdoc -D warnings host-CI profile"
if ! RUSTDOCFLAGS='-D warnings' cargo "+${TOOLCHAIN}" doc \
        -p evo-kiosk-config --no-deps "${lock_args[@]}"; then
    log_fail "rustdoc -D warnings (evo-kiosk-config)"
    exit 1
fi
if ! RUSTDOCFLAGS='-D warnings' cargo "+${TOOLCHAIN}" doc \
        -p evo-kiosk-browser --no-deps --no-default-features \
        "${lock_args[@]}"; then
    log_fail "rustdoc -D warnings (evo-kiosk-browser --no-default-features)"
    exit 1
fi
log_ok "rustdoc"

printf '\n[workout] all five steps clean (kiosk host-CI, toolchain +%s%s).\n' \
    "${TOOLCHAIN}" "$([[ ${LOCKED} -eq 1 ]] && echo ', --locked' || true)" >&2
