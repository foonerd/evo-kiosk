#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# publish-artefacts.sh — sign every cross-built binary + its
# build-info manifest, place the signed set into the
# evo-kiosk-artefacts working tree, advance the named channel
# pointer, sign the pointer, commit, push.
#
# Runs after `scripts/release/cross-build.sh` has staged binaries
# under target/release-artefacts/<triple>/. Together with
# `scripts/release/promote.sh` (source-side eng -> public cut)
# this closes the release loop.
#
# Signing: Ed25519 private key in PEM form, matching the peer
# artefact repos' signing convention (openssl pkeyutl -sign).
# The operator provides the key path via --signing-key; the
# script never reads a key from a default location, so a
# forgotten flag fails loudly rather than silently signing with
# the wrong key.
#
# Channel model matches the peer artefact repos: dev / test /
# prod named pointers. Same-bytes-different-pointer semantics —
# promoting a version from dev to test edits the pointer only.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

log_step() { printf '\n[publish] %s\n' "$*" >&2; }
log_ok()   { printf '[publish] OK: %s\n' "$*" >&2; }
log_fail() { printf '[publish] FAIL: %s\n' "$*" >&2; }

# -------------------------------------------------------------
# CLI
# -------------------------------------------------------------

ARTEFACTS_REPO=""
SIGNING_KEY=""
CHANNEL=""
VERSION=""
NO_PUSH=0
DRY_RUN=0

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") [flags]

Required:
  --artefacts-repo PATH   Working tree of foonerd/evo-kiosk-artefacts
  --signing-key PATH      Ed25519 release private key (PEM)
  --channel NAME          Channel pointer to advance (dev|test|prod)
  --version STRING        Version string to record in the pointer,
                          typically the eng tag (e.g. v0.1.13)

Optional:
  --no-push               Commit but do not push (default: push)
  --dry-run               Print planned actions; do not write

Environment:
  KIOSK_STAGING_ROOT      Override the default staging directory
                          (target/release-artefacts). Useful when
                          cross-build.sh ran under a non-default
                          target-dir.
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artefacts-repo) ARTEFACTS_REPO="$2"; shift 2 ;;
        --signing-key) SIGNING_KEY="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --no-push) NO_PUSH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) log_fail "unknown flag: $1"; usage ;;
    esac
done

# -------------------------------------------------------------
# Preflight
# -------------------------------------------------------------

if [[ -z "${ARTEFACTS_REPO}" || -z "${SIGNING_KEY}" || -z "${CHANNEL}" || -z "${VERSION}" ]]; then
    log_fail "missing required flag"
    usage
fi

case "${CHANNEL}" in
    dev|test|prod) : ;;
    *) log_fail "invalid --channel: ${CHANNEL} (expected dev|test|prod)"; exit 1 ;;
esac

if ! [[ "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$ ]]; then
    log_fail "invalid --version: ${VERSION} (expected e.g. v0.1.13 or v0.1.13-rc1)"
    exit 1
fi

if [[ ! -d "${ARTEFACTS_REPO}/.git" ]]; then
    log_fail "artefacts repo has no .git directory: ${ARTEFACTS_REPO}"
    exit 1
fi

if [[ ! -r "${SIGNING_KEY}" ]]; then
    log_fail "signing key not readable: ${SIGNING_KEY}"
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    log_fail "openssl not on PATH; required for Ed25519 signing"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    log_fail "python3 not on PATH; required for channel pointer edit"
    exit 1
fi

staging_root="${KIOSK_STAGING_ROOT:-${REPO_ROOT}/target/release-artefacts}"
if [[ ! -d "${staging_root}" ]]; then
    log_fail "staging root missing: ${staging_root} (run scripts/release/cross-build.sh first)"
    exit 1
fi

# -------------------------------------------------------------
# Enumerate staged triples
# -------------------------------------------------------------

log_step "Step 1/5: enumerate staged triples"

declare -a triples=()
while IFS= read -r -d '' d; do
    triple="$(basename "${d}")"
    if [[ ! -x "${d}/evo-kiosk-browser" ]]; then
        log_fail "staging ${triple} missing evo-kiosk-browser binary"
        exit 1
    fi
    if [[ ! -r "${d}/evo-kiosk-browser.sha256" ]]; then
        log_fail "staging ${triple} missing evo-kiosk-browser.sha256"
        exit 1
    fi
    if [[ ! -r "${d}/build-info.toml" ]]; then
        log_fail "staging ${triple} missing build-info.toml"
        exit 1
    fi
    triples+=( "${triple}" )
done < <(find "${staging_root}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#triples[@]} -eq 0 ]]; then
    log_fail "no staged triples under ${staging_root}"
    exit 1
fi
log_ok "staged triples: ${triples[*]}"

# -------------------------------------------------------------
# Sign each triple's artefacts
# -------------------------------------------------------------

log_step "Step 2/5: sign binaries + build-info per triple"

for triple in "${triples[@]}"; do
    stage_dir="${staging_root}/${triple}"

    for f in evo-kiosk-browser build-info.toml; do
        sig="${stage_dir}/${f}.sig"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_ok "[dry-run] would sign ${triple}/${f} -> ${f}.sig"
            continue
        fi
        if ! openssl pkeyutl -sign -inkey "${SIGNING_KEY}" \
                -rawin -in "${stage_dir}/${f}" -out "${sig}"; then
            log_fail "openssl sign failed for ${triple}/${f}"
            exit 1
        fi
    done
    log_ok "${triple} signed"
done

# -------------------------------------------------------------
# Copy signed set into artefacts repo working tree
# -------------------------------------------------------------

log_step "Step 3/5: place signed artefacts under ${ARTEFACTS_REPO}/binaries/"

for triple in "${triples[@]}"; do
    stage_dir="${staging_root}/${triple}"
    dst_dir="${ARTEFACTS_REPO}/binaries/${triple}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_ok "[dry-run] would place ${stage_dir}/* -> ${dst_dir}/"
        continue
    fi

    mkdir -p "${dst_dir}"
    cp "${stage_dir}/evo-kiosk-browser" "${dst_dir}/"
    cp "${stage_dir}/evo-kiosk-browser.sha256" "${dst_dir}/"
    cp "${stage_dir}/evo-kiosk-browser.sig" "${dst_dir}/"
    cp "${stage_dir}/build-info.toml" "${dst_dir}/"
    cp "${stage_dir}/build-info.toml.sig" "${dst_dir}/build-info.sig"
    log_ok "placed ${triple}"
done

# -------------------------------------------------------------
# Advance the channel pointer + sign it
# -------------------------------------------------------------

log_step "Step 4/5: advance channel pointer ${CHANNEL} -> ${VERSION}"

channel_file="${ARTEFACTS_REPO}/channels/${CHANNEL}.toml"
if [[ ! -r "${channel_file}" ]]; then
    log_fail "channel pointer missing: ${channel_file}"
    exit 1
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_ok "[dry-run] would rewrite ${channel_file}: version -> ${VERSION}, updated_at -> now"
    log_ok "[dry-run] would sign ${channel_file} -> ${channel_file%.toml}.sig"
else
    updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp_pointer="$(mktemp)"
    trap 'rm -f "${tmp_pointer}"' EXIT INT TERM

    # Rewrite the pointer in place. tomllib parses; python re-emits
    # a minimal shape that matches the peer schema. Comments are
    # not preserved by tomllib round-trip, so the emitted file is
    # canonical (no operator hand-notes carried across releases).
    python3 - "${channel_file}" "${VERSION}" "${updated_at}" "${tmp_pointer}" <<'PY'
import sys, tomllib
src, version, updated_at, dst = sys.argv[1:]
with open(src, "rb") as f:
    data = tomllib.load(f)

lines = []
lines.append(f'schema_version = {data.get("schema_version", 0)}')
lines.append(f'publisher = "{data.get("publisher", "org.evoframework")}"')
lines.append(f'channel = "{data.get("channel")}"')
lines.append(f'updated_at = "{updated_at}"')
lines.append('')

pointers = data.get("pointers", [])
if not pointers:
    print("pointer file has no [[pointers]] entry", file=sys.stderr)
    sys.exit(1)

for p in pointers:
    lines.append('[[pointers]]')
    lines.append(f'piece = "{p["piece"]}"')
    lines.append(f'version = "{version}"')
    lines.append('')

archs = data.get("architectures", [])
if archs:
    lines.append('architectures = [')
    for a in archs:
        lines.append(f'    "{a}",')
    lines.append(']')

with open(dst, "w") as f:
    f.write("\n".join(lines).rstrip() + "\n")
PY

    cp "${tmp_pointer}" "${channel_file}"
    log_ok "pointer rewritten"

    sig_file="${channel_file%.toml}.sig"
    if ! openssl pkeyutl -sign -inkey "${SIGNING_KEY}" \
            -rawin -in "${channel_file}" -out "${sig_file}"; then
        log_fail "openssl sign failed for channel pointer"
        exit 1
    fi
    log_ok "pointer signed"
fi

# -------------------------------------------------------------
# Commit + push
# -------------------------------------------------------------

log_step "Step 5/5: commit + push artefacts repo"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_ok "[dry-run] would commit + push"
    exit 0
fi

pushd "${ARTEFACTS_REPO}" >/dev/null

git add binaries channels
commit_msg="release ${VERSION} on channel ${CHANNEL}

Published at tag ${VERSION} via
scripts/release/cross-build.sh + scripts/release/publish-artefacts.sh.

Cross-compiled per target triple; each binary + build-info
manifest signed with the release private key. Channel pointer
${CHANNEL} advanced to ${VERSION} and signed."

if ! git commit --signoff -m "${commit_msg}"; then
    log_fail "git commit failed in ${ARTEFACTS_REPO}"
    exit 1
fi
log_ok "committed in ${ARTEFACTS_REPO}"

if [[ "${NO_PUSH}" -eq 1 ]]; then
    log_ok "--no-push set; skipping git push"
    log_ok "manual push: git -C ${ARTEFACTS_REPO} push origin main"
else
    if ! git push origin main; then
        log_fail "git push failed"
        exit 1
    fi
    log_ok "pushed origin main"
fi

popd >/dev/null

cat >&2 <<BANNER

[publish] Release ${VERSION} placed on channel ${CHANNEL} in
${ARTEFACTS_REPO}.

Downstream:
  Consumers on channel ${CHANNEL} pick up the new binary set
  on their next fetch. Distributions bundling the trust root
  will verify the pointer signature against the release public
  key before applying.
BANNER
