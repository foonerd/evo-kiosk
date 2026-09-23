#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# cross-build.sh — cross-compile evo-kiosk-browser for every
# supported target triple and stage the results under
# target/release-artefacts/<triple>/ ready for the sign+publish
# step.
#
# Runs after `scripts/release/pre-tag-check.sh` clears and the
# release tag has been minted; runs before
# `scripts/release/publish-artefacts.sh` signs and pushes into
# foonerd/evo-kiosk-artefacts.
#
# Targets:
#   - aarch64-unknown-linux-gnu
#   - x86_64-unknown-linux-gnu
#   - armv7-unknown-linux-gnueabihf
#
# Environment:
#   KIOSK_CROSS_TARGETS  space-separated triple list; overrides
#                        the built-in target list when set.
#   KIOSK_CROSS_ARGS     extra flags appended verbatim to
#                        `cross build --release ...`.
#
# Preconditions:
#   - cross-rs installed on PATH (`cross --version`)
#   - Docker (or podman via cross-rs config) available
#   - The Cross.toml at repo root declares each target's image +
#     pre-build apt install of libgtk-4-dev + libwebkitgtk-6.0-dev
#
# On success:
#   - target/release-artefacts/<triple>/evo-kiosk-browser
#   - target/release-artefacts/<triple>/evo-kiosk-browser.sha256
#   - target/release-artefacts/<triple>/build-info.toml
#
# On any target's failure, the whole script fails — a partial
# release plane is worse than no release plane.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

log_step() { printf '\n[cross-build] %s\n' "$*" >&2; }
log_ok()   { printf '[cross-build] OK: %s\n' "$*" >&2; }
log_fail() { printf '[cross-build] FAIL: %s\n' "$*" >&2; }

# -------------------------------------------------------------
# Preflight
# -------------------------------------------------------------

if ! command -v cross >/dev/null 2>&1; then
    log_fail "cross-rs not on PATH; install with: cargo install cross --git https://github.com/cross-rs/cross"
    exit 1
fi

if [[ ! -r "${REPO_ROOT}/Cross.toml" ]]; then
    log_fail "Cross.toml missing at repo root; cross-build needs it to name per-target images + pre-build steps"
    exit 1
fi

# Resolve the tag we are building against. Prefer the currently-
# checked-out tag (release-cut invocation); fall back to the
# short SHA (dev invocation).
resolved_ref="$(git describe --tags --exact-match HEAD 2>/dev/null || git rev-parse --short HEAD)"
built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Which targets to build.
default_targets=(
    "aarch64-unknown-linux-gnu"
    "x86_64-unknown-linux-gnu"
    "armv7-unknown-linux-gnueabihf"
)
if [[ -n "${KIOSK_CROSS_TARGETS:-}" ]]; then
    # shellcheck disable=SC2206
    targets=( ${KIOSK_CROSS_TARGETS} )
else
    targets=( "${default_targets[@]}" )
fi

# Extra build args.
extra_args=()
if [[ -n "${KIOSK_CROSS_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=( ${KIOSK_CROSS_ARGS} )
fi

staging_root="${REPO_ROOT}/target/release-artefacts"
mkdir -p "${staging_root}"

log_step "release ref: ${resolved_ref}"
log_step "targets: ${targets[*]}"

# -------------------------------------------------------------
# Per-target build loop
# -------------------------------------------------------------

for target in "${targets[@]}"; do
    log_step "cross build --release --target ${target} -p evo-kiosk-browser --features webkit --locked ${extra_args[*]:-}"

    # cross-rs picks up Cross.toml + image + pre-build automatically.
    if ! cross build \
            --release \
            --target "${target}" \
            -p evo-kiosk-browser \
            --features webkit \
            --locked \
            "${extra_args[@]}"; then
        log_fail "cross build failed for ${target}"
        exit 1
    fi

    src_binary="${REPO_ROOT}/target/${target}/release/evo-kiosk-browser"
    if [[ ! -x "${src_binary}" ]]; then
        log_fail "expected binary not produced: ${src_binary}"
        exit 1
    fi

    stage_dir="${staging_root}/${target}"
    mkdir -p "${stage_dir}"

    # Copy binary and strip debug symbols for release.
    cp "${src_binary}" "${stage_dir}/evo-kiosk-browser"
    # Strip only for host-arch matches; cross-arch strip needs a
    # per-target strip binary that cross-rs's image supplies.
    # Skip strip in this stage — cross-rs's release profile already
    # emits size-optimised binaries when Cargo.toml declares it,
    # and cross-arch strip introduces failure modes we cannot
    # verify offline. Downstream may run strip on-target if desired.

    # Compute SHA-256 checksum.
    (cd "${stage_dir}" && sha256sum evo-kiosk-browser > evo-kiosk-browser.sha256)

    # Build-info manifest.
    binary_size="$(stat -c '%s' "${stage_dir}/evo-kiosk-browser")"
    cat > "${stage_dir}/build-info.toml" <<EOF
schema_version = 0
kind = "kiosk-binaries"
evo_kiosk_ref = "${resolved_ref}"
target = "${target}"
binaries = ["evo-kiosk-browser"]
binary_size_bytes = ${binary_size}
built_at = "${built_at}"
publisher = "org.evoframework"
EOF

    log_ok "${target} — $(du -h "${stage_dir}/evo-kiosk-browser" | cut -f1) -> ${stage_dir}"
done

# -------------------------------------------------------------
# All targets clean
# -------------------------------------------------------------

cat >&2 <<BANNER

[cross-build] All targets built. Staged under:
  ${staging_root}

Next step: scripts/release/publish-artefacts.sh signs each
binary + build-info manifest with the release private key,
writes the signed set into the artefacts repository, updates
the channel pointer, signs the pointer, commits, pushes.

  scripts/release/publish-artefacts.sh \\
      --artefacts-repo /path/to/evo-kiosk-artefacts \\
      --signing-key /path/to/release-signing-private.pem \\
      --channel dev \\
      --version ${resolved_ref}
BANNER
