#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# pre-tag-check.sh — run the full pre-tag verification chain before
# the operator mints a release tag.
#
# Mirrors the discipline the peer repos enforce, scoped to
# kiosk's smaller surface:
# cargo workout (clean + fmt + clippy + host-CI test + rustdoc
# -D warnings) on evo-kiosk-config and the browser lib crate
# under --no-default-features, SPDX + leak scans across the
# tree, shellcheck on every shipped shell script, TOML
# validation of the privileges declaration, and a workspace
# build check under the webkit-off host-CI profile.
#
# Run this immediately before `git tag <release>`. Exits 0 only
# when every gate is clean.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

log_step() { printf '\n[pre-tag] %s\n' "$*" >&2; }
log_ok()   { printf '[pre-tag] OK: %s\n' "$*" >&2; }
log_fail() { printf '[pre-tag] FAIL: %s\n' "$*" >&2; }

# -------------------------------------------------------------
# Gates 1-3 + rustdoc: compulsory cargo workout (host-CI profile)
#
# The `webkit` feature (default) requires GTK4 + webkit2gtk system
# libraries that are not present in host CI. The workout runs
# cargo clean, fmt, clippy -D warnings, test, and rustdoc -D
# warnings on evo-kiosk-config plus evo-kiosk-browser --lib
# --no-default-features. Device builds (with the webkit feature)
# are validated on the target during the deploy path, not here.
# -------------------------------------------------------------

log_step "Gates 1-3 + rustdoc: scripts/preflight/check-cargo-workout.sh"
if ! bash "${REPO_ROOT}/scripts/preflight/check-cargo-workout.sh"; then
    log_fail "cargo workout (clean / fmt / clippy / test / rustdoc) failed"
    exit 1
fi
log_ok "cargo workout clean"

# -------------------------------------------------------------
# Gate 4: SPDX headers on every shipped source file
# -------------------------------------------------------------
#
# Every shipped file in these six globs MUST carry the BUSL-1.1
# SPDX identifier so a downstream consumer can inspect it in
# isolation and know its licence:
#   - crates/**/*.rs
#   - scripts/**/*.sh
#   - layer/**/*.sh
#   - layer/**/*.service
#   - layer/bin/*
#   - layer/sbin/*
# This is a cheap grep gate; it does not enforce formatting
# details. The skip set remains: target/, .git, .scrub-staging,
# and *.pem.

log_step "Gate 4/8: SPDX headers on shipped source files"
spdx_missing=""
while IFS= read -r file; do
    # Skip the target/ tree, .git, the release-tempdir if present, and
    # PEM cryptographic material (a public key is not source code and
    # PEM parsers accept but do not require preceding text).
    case "${file}" in
        */target/*|*/.git/*|*/.scrub-staging/*|*.pem) continue ;;
    esac
    if ! head -8 "${file}" | grep -q 'SPDX-License-Identifier:'; then
        spdx_missing="${spdx_missing}${file}\n"
    fi
done < <(git ls-files \
    'crates/**/*.rs' \
    'scripts/**/*.sh' \
    'layer/**/*.sh' \
    'layer/**/*.service' \
    'layer/bin/*' \
    'layer/sbin/*')
if [[ -n "${spdx_missing}" ]]; then
    log_fail "files missing SPDX-License-Identifier header:"
    printf '%b' "${spdx_missing}" >&2
    exit 1
fi
log_ok "SPDX headers present on every shipped source file"

# -------------------------------------------------------------
# Gate 5: public-leak scan (surfaces that will squash-and-scrub
# into evo-kiosk must not carry rig-specific IPs, hostnames,
# session-log dates, personal identifiers)
# -------------------------------------------------------------

log_step "Gate 5/8: public-leak scan"
# Leak surface: rig-specific 192.168.x.y (RFC 1918 that names a
# real network we operate), rig hostnames, session-log entries,
# personal git identity references, internal-only artefact
# identifiers (ADR-XXXX; internal decision records must not
# surface on public artefacts), and scope-narrowing framings
# ("first cut" / "swap later") that leak roadmap voice.
# Documentation-range IPs (192.0.2.0/24 + 198.51.100.0/24 +
# 203.0.113.0/24) are permitted since RFC 5737 reserves them
# for docs.
#
# Scope: only paths that will reach the public promote. Paths
# listed in `.scrub-exclude` are removed by `promote.sh` before the
# staging tree lands on public main, so this gate skips them here
# to avoid metaproblems (a regex that defines what a leak looks
# like is not itself a leak).
LEAK_REGEX='192\.168\.[0-9]+\.[0-9]+|10\.30\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|pi5target|evoproto@|SESSION_LOG [0-9]{4}-|andrew@dt-ltd|andser@|ADR-[0-9]{3,4}|\bR-[0-9]{3,}|\bPD-[0-9]{3,}|first cut|swap later'
declare -a scan_paths=()
while IFS= read -r p; do
    scan_paths+=("${p}")
done < <(git ls-files 'crates' 'layer' 'docs' 'README.md' 'scripts/install' 'Cargo.toml' 'Cargo.lock' 2>/dev/null)
# shellcheck disable=SC2086
leak_hits="$(
  grep -InE "${LEAK_REGEX}" -- "${scan_paths[@]}" 2>/dev/null \
  | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' \
  || true
)"
if [[ -n "${leak_hits}" ]]; then
    log_fail "public-leak scan hit — scrub these before promoting:"
    printf '%s\n' "${leak_hits}" >&2
    exit 1
fi
log_ok "leak scan clean"

# -------------------------------------------------------------
# Gate 6: shellcheck on every shipped shell script
# -------------------------------------------------------------
#
# Every script that installs on-device or runs at unit start MUST
# clear this static analyser under the appropriate dialect. Missing
# the analyser binary is a hard fail on the release path — CI must
# ship it.

log_step "Gate 6/8: shellcheck on shipped shell scripts"
if ! command -v shellcheck >/dev/null 2>&1; then
    log_fail "shellcheck not installed; required for release gate"
    exit 1
fi
sh_files_sh="$(git ls-files 'layer/bin/*' | tr '\n' ' ')"
sh_files_bash="$(git ls-files 'scripts/install/*.sh' 'scripts/release/*.sh' \
    'scripts/test/*.sh' | tr '\n' ' ')"
# shellcheck disable=SC2086
if [[ -n "${sh_files_sh}" ]] && ! shellcheck --shell=sh ${sh_files_sh}; then
    log_fail "shellcheck (sh) hit"
    exit 1
fi
# shellcheck disable=SC2086
if [[ -n "${sh_files_bash}" ]] && ! shellcheck --shell=bash ${sh_files_bash}; then
    log_fail "shellcheck (bash) hit"
    exit 1
fi
log_ok "shellcheck clean"

# -------------------------------------------------------------
# Gate 7: privileges declaration parseable + workspace build
# -------------------------------------------------------------

log_step "Gate 7/8: privileges + trust anchor + verify tool + Cross.toml + workspace build"
privileges_file="${REPO_ROOT}/layer/kiosk.privileges.toml"
if [[ ! -r "${privileges_file}" ]]; then
    log_fail "layer/kiosk.privileges.toml missing"
    exit 1
fi
if ! python3 -c "
import sys, tomllib
with open('${privileges_file}', 'rb') as f:
    data = tomllib.load(f)
# Sanity: required-binaries + required-services + host_provisioning
# must be present and non-empty for a runnable install.
assert data.get('required_binaries'), 'required_binaries empty'
assert data.get('required_system_services'), 'required_system_services empty'
apt = ((data.get('host_provisioning', {}) or {}).get('debian', {}) or {}).get('apt_packages', {}) or {}
assert apt.get('required'), 'host_provisioning.debian.apt_packages.required empty'
print('privileges declaration valid', file=sys.stderr)
" 2>&1; then
    log_fail "privileges declaration failed structural validation"
    exit 1
fi

# Trust anchor: install-time signature verification depends on
# this PEM being carried by the install source. Missing = the
# whole signed-fetch mode goes silently unusable at operator
# install time.
trust_anchor="${REPO_ROOT}/layer/trust/evo-release-signing-public.pem"
if [[ ! -r "${trust_anchor}" ]]; then
    log_fail "layer/trust/evo-release-signing-public.pem missing"
    exit 1
fi
if ! openssl pkey -pubin -in "${trust_anchor}" -noout 2>/dev/null; then
    log_fail "trust anchor is not a parseable public key"
    exit 1
fi

# Verify primitive: the POSIX sh tool that consumers (install.sh
# signed mode + distribution build scripts) call to gate binary
# placement on signed evidence. Missing = install.sh signed mode
# cannot function.
verify_tool="${REPO_ROOT}/layer/bin/evo-kiosk-verify"
if [[ ! -x "${verify_tool}" ]]; then
    log_fail "layer/bin/evo-kiosk-verify missing or not executable"
    exit 1
fi

# Cross.toml: cross-rs config for the release-cut binaries.
# Missing at pre-tag = release cannot cross-compile = no
# artefacts to publish downstream. Structural check confirms
# each supported target has an image + pre-build declared.
cross_file="${REPO_ROOT}/Cross.toml"
if [[ ! -r "${cross_file}" ]]; then
    log_fail "Cross.toml missing at repo root"
    exit 1
fi
if ! python3 -c "
import sys, tomllib
with open('${cross_file}', 'rb') as f:
    data = tomllib.load(f)
targets = data.get('target', {}) or {}
required = [
    'aarch64-unknown-linux-gnu',
    'x86_64-unknown-linux-gnu',
    'armv7-unknown-linux-gnueabihf',
]
for t in required:
    entry = targets.get(t) or {}
    # cross-rs accepts either shape.
    # Shape one: prebuilt image plus per-target pre-build steps.
    # Shape two: build-on-demand via dockerfile.file. This repo
    # uses shape two for runtime-parity ABI on debian trixie.
    has_image = bool(entry.get('image'))
    dockerfile = entry.get('dockerfile') or {}
    has_dockerfile = bool(dockerfile.get('file'))
    assert has_image or has_dockerfile, (
        f'target.{t}: neither image nor dockerfile.file present'
    )
    if has_image:
        assert entry.get('pre-build'), (
            f'target.{t}.pre-build missing (required with image)'
        )
print('Cross.toml declaration valid', file=sys.stderr)
" 2>&1; then
    log_fail "Cross.toml failed structural validation"
    exit 1
fi

# Host-CI workspace build. Only the lib surface builds without
# GTK/WebKit system libs; the binary target is validated on device.
if ! cargo build -p evo-kiosk-browser --lib --no-default-features --locked; then
    log_fail "workspace build (host-CI profile) failed"
    exit 1
fi
log_ok "privileges declaration + workspace build clean"

# -------------------------------------------------------------
# Gate 8: on-device behaviour fixtures
# -------------------------------------------------------------
#
# The layer scripts are the live-apply path for operator settings.
# A fixture here asserts behaviour the shipped script must have —
# not merely that it parses — so a regression that turns a live
# apply back into a boot-only apply fails the release gate.

log_step "Gate 8/8: layer script behaviour fixtures"
fixture_failures=0
while IFS= read -r fixture; do
    [ -n "${fixture}" ] || continue
    if ! bash "${fixture}"; then
        log_fail "fixture failed: ${fixture}"
        fixture_failures=$((fixture_failures + 1))
    fi
done <<< "$(git ls-files 'scripts/test/*.sh')"
if [[ "${fixture_failures}" -ne 0 ]]; then
    exit 1
fi
log_ok "layer script fixtures pass"

# -------------------------------------------------------------
# All gates clean
# -------------------------------------------------------------

cat >&2 <<'BANNER'

[pre-tag] All eight gates clean. Ready for tag mint.

Next steps:
  1. Cross-build the release browser binary for every supported
     target (aarch64-unknown-linux-gnu + x86_64-unknown-linux-gnu
     at minimum). Publish under layer/binaries/<triple>/ or
     alongside the artefacts repo.
  2. Mint the tag:
       v<MAJOR>.<MINOR>.<PATCH>[.<CLOSURE>][-<PRERELEASE>]
     Tag-format regex enforced at publish:
       ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$
  3. Run scripts/release/promote.sh --tag <VERSION>
     --public-repo <PATH> to drive the eng -> public
     squash-and-scrub.
BANNER
