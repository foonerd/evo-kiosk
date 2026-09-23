#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# Fixture for the pointer-visibility applier in evo-kiosk-launch.
#
# The pointer is hidden by selecting a transparent cursor theme at
# session start, never by a compositor action: labwc's HideCursor
# returns the cursor on the next pointer motion, and does not exist at
# all on labwc 0.8.3. These assertions pin that decision so a later
# edit cannot quietly reintroduce a keybind that cannot hold.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCH="${ROOT}/layer/bin/evo-kiosk-launch"
THEME="${ROOT}/layer/share/icons/evo-blank"
GEN="${ROOT}/scripts/build/gen-blank-cursor-theme.py"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
chk() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

[[ -r "${LAUNCH}" ]] || { echo "FAIL: launcher missing"; exit 1; }
if ! grep -q 'EVO_KIOSK_LAUNCH_LIB_ONLY' "${LAUNCH}"; then
    echo "FAIL: launcher has no EVO_KIOSK_LAUNCH_LIB_ONLY harness seam;"
    echo "      sourcing it would probe DRM and exec a compositor"
    exit 1
fi

# shellcheck source=/dev/null
EVO_KIOSK_LAUNCH_LIB_ONLY=1 . "${LAUNCH}"

if ! command -v cursor_theme_for >/dev/null 2>&1; then
    echo "FAIL: cursor_theme_for is not defined by the launcher"
    echo "      (a launcher with no theme applier cannot hide a pointer"
    echo "       once a mouse is attached)"
    exit 1
fi

echo "1. the overlay policy selects the theme"
chk "hide  -> blank theme" "$(cursor_theme_for hide)" "evo-blank"
chk "show  -> stock"       "$(cursor_theme_for show)" ""
chk "auto  -> stock"       "$(cursor_theme_for auto)" ""
chk "junk  -> stock"       "$(cursor_theme_for wobble)" ""
chk "empty -> stock"       "$(cursor_theme_for '')" ""

# Replays the launcher's export block for one policy and reports the
# variable a compositor would inherit. The subshell is the point — it
# isolates each case — and the answer escapes on stdout.
# shellcheck disable=SC2030,SC2031
exported_theme_for() {
    local policy="$1" inherited="${2:-}"
    (
        if [[ -n "${inherited}" ]]; then
            export XCURSOR_THEME="${inherited}"
        fi
        local chosen
        chosen=$(cursor_theme_for "${policy}")
        if [[ -n "${chosen}" ]]; then
            export XCURSOR_THEME="${chosen}"
        else
            unset XCURSOR_THEME || true
        fi
        printf '%s' "${XCURSOR_THEME:-}"
    )
}

echo "2. hide exports the theme, show unsets it"
chk "hide exports the blank theme" "$(exported_theme_for hide)" "evo-blank"
chk "show leaves nothing exported" "$(exported_theme_for show)" ""
chk "show clears an inherited blank theme" \
    "$(exported_theme_for show evo-blank)" ""
chk "hide overrides an inherited stock theme" \
    "$(exported_theme_for hide Adwaita)" "evo-blank"

echo "3. no compositor action is used for the pointer"
for banned in HideCursor WarpCursor ShowCursor; do
    if grep -q "name=\"${banned}\"\|wtype .*F2[34]\|${banned}\b" "${LAUNCH}" \
       && grep -q "${banned}" <(grep -v '^#' "${LAUNCH}"); then
        bad "${banned} referenced in executable launcher code"
    else
        ok "${banned} not used"
    fi
done

echo "4. no other script applies the pointer"
SESSION="${ROOT}/layer/bin/evo-kiosk-session"
RCXML="${ROOT}/layer/labwc/rc.xml"
if grep -vE '^\s*#' "${SESSION}" | grep -q "wtype"; then
    bad "session still fires wtype (the theme must be the only applier)"
else
    ok "session fires no wtype"
fi
# Parsed, not grepped: prose in a comment may legitimately name the
# action it explains, while an <action name="HideCursor"/> element is
# the thing labwc 0.8.3 rejects at config parse, logging
# "Invalid action: HideCursor" on every session whether or not the key
# is ever pressed.
if python3 - "${RCXML}" <<'PYX'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
bad = [a.get("name") for a in root.iter("action")
       if a.get("name") in ("HideCursor", "ShowCursor", "WarpCursor")]
if bad:
    print(f"    cursor actions still bound: {bad}")
sys.exit(1 if bad else 0)
PYX
then
    ok "rc.xml binds no cursor action"
else
    bad "rc.xml still binds a cursor action"
fi

echo "5. the shipped theme is present and fully transparent"
chk "index.theme present" "$([[ -f ${THEME}/index.theme ]] && echo yes || echo no)" "yes"
names=$(find "${THEME}/cursors" -mindepth 1 2>/dev/null | wc -l)
if [[ "${names}" -ge 60 ]]; then ok "cursor names: ${names}"; else bad "only ${names} cursor names"; fi
for must in default left_ptr pointer hand2 text watch; do
    if [[ -e "${THEME}/cursors/${must}" ]]; then
        ok "name '${must}' carried"
    else
        bad "name '${must}' missing"
    fi
done
if python3 - "${THEME}/cursors/default" <<'PY'
import struct, sys
raw = open(sys.argv[1], "rb").read()
magic, hsz, ver, ntoc = struct.unpack_from("<4sIII", raw, 0)
assert magic == b"Xcur", "not an Xcursor file"
opaque = 0
for i in range(ntoc):
    _t, _sub, pos = struct.unpack_from("<III", raw, 16 + 12 * i)
    w, h = struct.unpack_from("<II", raw, pos + 16)
    px_at = pos + 36
    for p in range(w * h):
        if struct.unpack_from("<I", raw, px_at + 4 * p)[0] >> 24:
            opaque += 1
print(f"  ok   Xcursor valid: {ntoc} sizes, {opaque} non-transparent pixels")
assert opaque == 0, "theme contains a visible pixel"
PY
then
    ok "theme is fully transparent"
else
    bad "theme is not fully transparent"
fi

echo "6. the committed theme matches the generator"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
python3 "${GEN}" "${TMP}/evo-blank" >/dev/null
if diff -r "${THEME}" "${TMP}/evo-blank" >/dev/null 2>&1; then
    ok "tree matches gen-blank-cursor-theme.py"
else
    bad "committed theme has drifted from the generator"
fi

echo
if [[ "${fails}" -eq 0 ]]; then echo "launch cursor-theme fixture: PASS"; exit 0; fi
echo "launch cursor-theme fixture: ${fails} FAILURE(S)"; exit 1
