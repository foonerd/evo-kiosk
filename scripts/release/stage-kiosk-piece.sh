#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# stage-kiosk-piece.sh — stage the evo-kiosk session layer as a
# piece source tree WITH the compiled program for every tester
# triple, then hand it to pack-signed-tree.sh.
#
# The class this exists for: `layer/binaries/` is gitignored, so
# it is never in a checkout. A mint that stages the git tree and
# packs it produces a piece with sources and no program. The
# composed first-boot box then has no
# layer/binaries/<triple>/evo-kiosk-browser, bootstrap.sh selects
# cargo mode, and the tester's device apt-installs a toolchain
# and builds WebKit on itself. That is the brick.
#
# So the program is taken from the cross-build output, not from
# the working tree: whatever a developer's laptop happens to have
# under layer/binaries/ is purged from the staged copy before the
# built set is placed. The train builds and stores; it does not
# inherit.
#
# Runs after scripts/release/cross-build.sh has staged every
# triple; runs before the piece is uploaded to
# foonerd/evo-device-audio-artefacts.
#
# Usage:
#   EVO_PLUGIN_SIGNING_KEY=/path/to.pem \
#   scripts/release/stage-kiosk-piece.sh \
#     --version 0.1.13 \
#     --out-dir /tmp/stage/bundles/evo-kiosk/0.1.13 \
#     [--staging-root target/release-artefacts] \
#     [--src-out PATH]
#
# Environment:
#   KIOSK_PIECE_TARGETS  space-separated triple list; overrides
#                        the built-in tester set when set.
#
# Exit codes:
#   0 — piece staged, program present for every required triple.
#   2 — usage / precondition failure.
#   3 — a required triple has no built program (fail closed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

VERSION=""
OUT=""
STAGING_ROOT=""
SRC_OUT=""

# The triples testers install on. A piece missing any one of
# these composes into a box that bricks on that architecture.
DEFAULT_TARGETS=(
    x86_64-unknown-linux-gnu
    aarch64-unknown-linux-gnu
    armv7-unknown-linux-gnueabihf
)

log_step() { printf '\n[stage-piece] %s\n' "$*" >&2; }
log_ok()   { printf '[stage-piece] OK: %s\n' "$*" >&2; }
log_fail() { printf '[stage-piece] FAIL: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION="$2"; shift 2 ;;
        --out-dir)      OUT="$2"; shift 2 ;;
        --staging-root) STAGING_ROOT="$2"; shift 2 ;;
        --src-out)      SRC_OUT="$2"; shift 2 ;;
        *) log_fail "unknown argument: $1"; exit 2 ;;
    esac
done

if [[ -z "${VERSION}" || -z "${OUT}" ]]; then
    log_fail "usage: stage-kiosk-piece.sh --version V --out-dir DIR [--staging-root DIR] [--src-out DIR]"
    exit 2
fi

STAGING_ROOT="${STAGING_ROOT:-${REPO_ROOT}/target/release-artefacts}"

if [[ -n "${KIOSK_PIECE_TARGETS:-}" ]]; then
    read -r -a TARGETS <<< "${KIOSK_PIECE_TARGETS}"
else
    TARGETS=( "${DEFAULT_TARGETS[@]}" )
fi

if [[ ! -d "${STAGING_ROOT}" ]]; then
    log_fail "staging root missing: ${STAGING_ROOT} (run scripts/release/cross-build.sh first)"
    exit 3
fi

# -------------------------------------------------------------
# Step 1: every required triple must have a built program
# -------------------------------------------------------------
# Checked before anything is staged, so a mint that cannot ship
# a complete piece fails before it writes one.

log_step "Step 1/4: require a built program for ${#TARGETS[@]} triple(s)"

missing=()
for triple in "${TARGETS[@]}"; do
    built="${STAGING_ROOT}/${triple}/evo-kiosk-browser"
    if [[ ! -f "${built}" ]]; then
        missing+=( "${triple} (no ${built})" )
        continue
    fi
    if [[ ! -s "${built}" ]]; then
        missing+=( "${triple} (empty ${built})" )
        continue
    fi
    log_ok "${triple}: $(wc -c < "${built}") bytes"
done

if [[ ${#missing[@]} -gt 0 ]]; then
    log_fail "cross-build output incomplete — the piece would ship without a program for:"
    for m in "${missing[@]}"; do
        printf '[stage-piece]   %s\n' "${m}" >&2
    done
    log_fail "run scripts/release/cross-build.sh for every target before minting the piece"
    exit 3
fi

# -------------------------------------------------------------
# Step 2: stage the piece source tree
# -------------------------------------------------------------
# Same set the piece has always carried. Adding the program does
# not change what else ships.

log_step "Step 2/4: stage piece source tree"

if [[ -n "${SRC_OUT}" ]]; then
    SRC="${SRC_OUT}"
    rm -rf "${SRC}"
    mkdir -p "${SRC}"
else
    SRC="$(mktemp -d -t evo-kiosk-src-XXXXXX)"
    trap 'rm -rf "${SRC}"' EXIT
fi

cd "${REPO_ROOT}"
for sub in scripts layer crates; do
    [[ -d "${sub}" ]] && cp -a "${sub}" "${SRC}/"
done
for f in Cargo.toml Cargo.lock README.md DEVELOPING.md Cross.toml VERSION; do
    [[ -f "${f}" ]] && cp -a "${f}" "${SRC}/"
done
log_ok "staged scripts/ layer/ crates/ + top-level files"

# -------------------------------------------------------------
# Step 3: purge inherited binaries, then place the built set
# -------------------------------------------------------------
# layer/binaries/ is gitignored, so in CI the copy above brings
# nothing. On a developer machine it can bring a stale local
# build. Neither is what ships: the directory is emptied and
# refilled from the cross-build output every time.

log_step "Step 3/4: place built programs under layer/binaries/"

if [[ -d "${SRC}/layer/binaries" ]]; then
    inherited="$(find "${SRC}/layer/binaries" -type f | wc -l)"
    rm -rf "${SRC}/layer/binaries"
    log_ok "purged ${inherited} inherited file(s) from the staged layer/binaries/"
fi

for triple in "${TARGETS[@]}"; do
    dst="${SRC}/layer/binaries/${triple}"
    mkdir -p "${dst}"
    install -m 0755 "${STAGING_ROOT}/${triple}/evo-kiosk-browser" \
        "${dst}/evo-kiosk-browser"
    if [[ -f "${STAGING_ROOT}/${triple}/evo-kiosk-browser.sha256" ]]; then
        install -m 0644 "${STAGING_ROOT}/${triple}/evo-kiosk-browser.sha256" \
            "${dst}/evo-kiosk-browser.sha256"
    fi
    log_ok "placed ${triple}/evo-kiosk-browser"
done

# Post-condition on the staged tree, not on the inputs: what the
# packer is about to read is what is asserted.
for triple in "${TARGETS[@]}"; do
    staged="${SRC}/layer/binaries/${triple}/evo-kiosk-browser"
    if [[ ! -x "${staged}" ]]; then
        log_fail "staged program is not executable: ${staged}"
        exit 3
    fi
    if [[ ! -s "${staged}" ]]; then
        log_fail "staged program is empty: ${staged}"
        exit 3
    fi
done
log_ok "every required triple has an executable program in the staged tree"

# -------------------------------------------------------------
# Step 4: pack + sign
# -------------------------------------------------------------

log_step "Step 4/4: pack signed tree into ${OUT}"

mkdir -p "${OUT}"
bash "${REPO_ROOT}/scripts/release/pack-signed-tree.sh" \
    --piece evo-kiosk \
    --version "${VERSION}" \
    --kind kiosk-session \
    --src "${SRC}" \
    --out-dir "${OUT}"

# Prove the program survived into the archive rather than
# trusting that the packer copied what it was handed.
for triple in "${TARGETS[@]}"; do
    member="evo-kiosk/layer/binaries/${triple}/evo-kiosk-browser"
    if ! tar -tzf "${OUT}/tree.tar.gz" "${member}" >/dev/null 2>&1; then
        log_fail "packed piece has no ${member}"
        exit 3
    fi
done
log_ok "packed piece carries a program for: ${TARGETS[*]}"

log_ok "piece ${VERSION} staged at ${OUT}"
