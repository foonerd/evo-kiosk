#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# Fixture for the OSK live-apply path in evo-kiosk-watch-settings.
#
# The watcher is a daemon, so it exposes its apply functions to a
# harness via EVO_KIOSK_WATCH_LIB_ONLY=1: sourced in that mode it
# defines everything and returns before arming the watch loop.
#
# What is asserted here is behaviour the boot-only script could not
# produce: writing `osk=none` must kill the running keyboard, and
# writing `osk=squeekboard` when none is running must start one —
# without cycling a keyboard that is already up.
#
# The OSK helper is stubbed so no real squeekboard is spawned; the
# "keyboard" is an ordinary background process, which is enough to
# prove the pidfile lifecycle the real one shares.
set -uo pipefail

WATCHER="$(cd "$(dirname "$0")/../.." && pwd)/layer/bin/evo-kiosk-watch-settings"
[[ -r "${WATCHER}" ]] || { echo "FAIL: watcher not found at ${WATCHER}"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"; [[ -n "${FAKE_PID:-}" ]] && kill "${FAKE_PID}" 2>/dev/null' EXIT

export KIOSK_SETTINGS_DIR="${WORK}/settings"
export XDG_RUNTIME_DIR="${WORK}/run"
mkdir -p "${KIOSK_SETTINGS_DIR}" "${XDG_RUNTIME_DIR}"

# Stub helper: records that it was asked to start the OSK.
export EVO_KIOSK_OSK_THEME="${WORK}/osk-theme-stub"
cat > "${EVO_KIOSK_OSK_THEME}" <<'STUB'
#!/bin/sh
echo "invoked" >> "${XDG_RUNTIME_DIR}/osk-theme-invocations"
STUB
chmod +x "${EVO_KIOSK_OSK_THEME}"

PIDFILE="${XDG_RUNTIME_DIR}/evo-kiosk-squeekboard.pid"
INVOCATIONS="${XDG_RUNTIME_DIR}/osk-theme-invocations"

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# Sourcing a watcher without the harness seam would arm the real
# watch loop and hang here, so the precondition is checked
# statically first and reported as a failure rather than a stall.
if ! grep -q 'EVO_KIOSK_WATCH_LIB_ONLY' "${WATCHER}"; then
    echo "FAIL: watcher has no EVO_KIOSK_WATCH_LIB_ONLY harness seam"
    echo "      sourcing it would arm the watch loop instead of"
    echo "      exposing the apply functions"
    exit 1
fi

# shellcheck source=/dev/null
EVO_KIOSK_WATCH_LIB_ONLY=1 . "${WATCHER}"

for fn in apply_osk stop_osk squeekboard_pid; do
    if ! command -v "$fn" >/dev/null 2>&1; then
        echo "FAIL: ${fn} is not defined by the watcher"
        echo "      (a boot-only watcher has no OSK live-apply at all)"
        exit 1
    fi
done

start_fake_osk() {
    sleep 300 &
    FAKE_PID=$!
    echo "${FAKE_PID}" > "${PIDFILE}"
}

echo "1. osk=none stops a running keyboard"
: > "${INVOCATIONS}"
start_fake_osk
printf 'none' > "${KIOSK_SETTINGS_DIR}/osk"
apply_osk
sleep 0.3
if kill -0 "${FAKE_PID}" 2>/dev/null; then bad "keyboard still alive after osk=none"; else ok "keyboard killed"; fi
if [[ -e "${PIDFILE}" ]]; then bad "pidfile survived osk=none"; else ok "pidfile removed"; fi
FAKE_PID=""

echo "2. osk=squeekboard starts one when none is running"
: > "${INVOCATIONS}"
rm -f "${PIDFILE}"
printf 'squeekboard' > "${KIOSK_SETTINGS_DIR}/osk"
apply_osk
check "helper invoked once" "$(wc -l < "${INVOCATIONS}" | tr -d ' ')" "1"

echo "3. a live keyboard is not cycled"
: > "${INVOCATIONS}"
start_fake_osk
printf 'squeekboard' > "${KIOSK_SETTINGS_DIR}/osk"
apply_osk
check "helper not re-invoked" "$(wc -l < "${INVOCATIONS}" | tr -d ' ')" "0"
if kill -0 "${FAKE_PID}" 2>/dev/null; then ok "keyboard left running"; else bad "live keyboard was killed"; fi
kill "${FAKE_PID}" 2>/dev/null; FAKE_PID=""
rm -f "${PIDFILE}"

echo "4. a missing overlay means the documented default (on)"
: > "${INVOCATIONS}"
rm -f "${KIOSK_SETTINGS_DIR}/osk" "${PIDFILE}"
apply_osk
check "helper invoked for absent overlay" "$(wc -l < "${INVOCATIONS}" | tr -d ' ')" "1"

echo
if [[ "${fails}" -eq 0 ]]; then echo "watch-settings OSK fixture: PASS"; exit 0; fi
echo "watch-settings OSK fixture: ${fails} FAILURE(S)"; exit 1
