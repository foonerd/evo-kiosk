#!/usr/bin/env bash
# pack-signed-tree.sh — sign a directory as an append-only tree piece.
set -euo pipefail

PIECE=""
VERSION=""
KIND=""
SRC=""
OUT=""
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --piece)   PIECE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --kind)    KIND="$2"; shift 2 ;;
        --src)     SRC="$2"; shift 2 ;;
        --out-dir) OUT="$2"; shift 2 ;;
        --target)  TARGET="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "${PIECE}" && -n "${VERSION}" && -n "${KIND}" && -n "${SRC}" && -n "${OUT}" ]] \
    || { echo "usage: pack-signed-tree.sh --piece --version --kind --src --out-dir [--target]" >&2; exit 2; }
[[ -d "${SRC}" ]] || { echo "src is not a directory: ${SRC}" >&2; exit 2; }
[[ -n "${EVO_PLUGIN_SIGNING_KEY:-}" && -r "${EVO_PLUGIN_SIGNING_KEY}" ]] \
    || { echo "EVO_PLUGIN_SIGNING_KEY is unset or unreadable" >&2; exit 2; }

mkdir -p "${OUT}"
TMP="$(mktemp -d -t evo-pack-XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
STAGE="${TMP}/${PIECE}"
mkdir -p "${STAGE}"
cp -a "${SRC}/." "${STAGE}/"

tar -C "${TMP}" \
    --sort=name \
    --mtime='2026-01-01 00:00:00 UTC' \
    --owner=0 --group=0 --numeric-owner \
    -czf "${OUT}/tree.tar.gz" \
    "${PIECE}"

openssl pkeyutl -sign \
    -inkey "${EVO_PLUGIN_SIGNING_KEY}" -rawin \
    -in "${OUT}/tree.tar.gz" \
    -out "${OUT}/tree.tar.gz.sig"
(cd "${OUT}" && sha256sum tree.tar.gz > tree.tar.gz.sha256)

{
    echo "schema_version = 0"
    echo "kind = \"${KIND}\""
    echo "piece = \"${PIECE}\""
    echo "version = \"${VERSION}\""
    if [[ -n "${TARGET}" ]]; then
        echo "target = \"${TARGET}\""
    fi
    echo "built_at = \"$(date -u +%FT%TZ)\""
    echo "publisher = \"org.evoframework\""
    if git rev-parse HEAD >/dev/null 2>&1; then
        echo "git_rev = \"$(git rev-parse HEAD)\""
    fi
} > "${OUT}/build-info.toml"

openssl pkeyutl -sign \
    -inkey "${EVO_PLUGIN_SIGNING_KEY}" -rawin \
    -in "${OUT}/build-info.toml" \
    -out "${OUT}/build-info.sig"
