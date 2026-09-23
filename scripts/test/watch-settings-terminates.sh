#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# Fixture for watcher termination.
#
# The kiosk session kills the previous watcher by signal before
# spawning a new one. If the watcher does not die on that signal,
# the new one starts alongside it and every kiosk restart leaves
# another live-apply daemon on the same overlays.
#
# Counted by PARENTS. The daemon forks an inotify subshell that
# shares its argv, so a naive process count reads two for a healthy
# single instance and would hide the fault this fixture exists to
# catch.
#
# This file's own argv does not contain the watcher's name, so the
# pgrep below cannot match the fixture itself — an earlier inline
# version of this check matched its own shell and killed it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WATCHER="${ROOT}/layer/bin/evo-kiosk-watch-settings"
[[ -x "${WATCHER}" ]] || { echo "FAIL: watcher not executable"; exit 1; }

WORK="$(mktemp -d)"
export XDG_RUNTIME_DIR="${WORK}/run"
export KIOSK_SETTINGS_DIR="${WORK}/settings"
mkdir -p "${XDG_RUNTIME_DIR}" "${KIOSK_SETTINGS_DIR}"
export EVO_KIOSK_OSK_THEME="${WORK}/osk-stub"
printf '#!/bin/sh\nexit 0\n' > "${EVO_KIOSK_OSK_THEME}"
chmod +x "${EVO_KIOSK_OSK_THEME}"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

watcher_pids() { pgrep -f "${WATCHER}" 2>/dev/null || true; }

# Daemons only: a pid whose parent is not itself a watcher.
count_daemons() {
    local all pid ppid n=0
    all="$(watcher_pids)"
    [[ -z "${all}" ]] && { echo 0; return; }
    for pid in ${all}; do
        ppid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')"
        grep -qx "${ppid:-0}" <<<"${all}" || n=$((n + 1))
    done
    echo "${n}"
}

# shellcheck disable=SC2317  # invoked via the EXIT trap
cleanup() {
    local pid
    for pid in $(watcher_pids); do kill -9 "${pid}" 2>/dev/null; done
    rm -rf "${WORK}"
}
trap cleanup EXIT

start_watcher() { setsid "${WATCHER}" >>"${WORK}/w.log" 2>&1 & sleep 2; }

echo "1. the watcher dies when the session signals it"
start_watcher
FIRST="$(watcher_pids | head -1)"
if [[ -n "${FIRST}" ]]; then ok "started (pid ${FIRST})"; else bad "watcher did not start"; fi
kill "${FIRST}" 2>/dev/null
waited=0
while kill -0 "${FIRST}" 2>/dev/null && [[ "${waited}" -lt 50 ]]; do
    waited=$((waited + 1)); sleep 0.1
done
if kill -0 "${FIRST}" 2>/dev/null; then
    bad "watcher absorbed SIGTERM and kept running — restarts will stack it"
else
    ok "watcher exited on SIGTERM"
fi

echo "2. exactly one daemon after a kill-and-respawn"
for pid in $(watcher_pids); do kill -9 "${pid}" 2>/dev/null; done
sleep 0.5
start_watcher
OLD="$(watcher_pids | head -1)"
# What the session does: signal the old one, then spawn.
kill "${OLD}" 2>/dev/null
sleep 1
start_watcher
n="$(count_daemons)"
if [[ "${n}" -eq 1 ]]; then ok "one daemon after restart"; else bad "expected 1 daemon, found ${n}"; fi

echo
if [[ "${fails}" -eq 0 ]]; then echo "watcher termination fixture: PASS"; exit 0; fi
echo "watcher termination fixture: ${fails} FAILURE(S)"; exit 1
