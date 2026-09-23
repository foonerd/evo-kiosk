#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# check-leak-regex-positive.sh — prove the release leak regex fires.
#
# The leak scan is one regex, and a clean run of it is not evidence.
# An alternative that matches nothing passes every tree ever built,
# and there is no outward difference between a pattern that found
# nothing and a pattern that cannot find anything. One wrong escape
# is enough.
#
# The regex is also written down twice — once as Gate 5 in
# `pre-tag-check.sh`, which scans the engineering tree, and once in
# `promote.sh`, which scans the staging tree after the scrub. Two
# copies of one rule drift, and they had: the promote copy was
# missing the three-digit decision-record form and both
# scope-narrowing phrases, so a string the pre-tag gate refused
# could still reach the public tree. This asserts they are byte
# identical before it asserts anything else.
#
# Then every alternative is planted on its own and the regex is run
# exactly as the gates run it — including the documentation-range
# filter, so an alternative cannot be credited for a hit that filter
# would have removed. Being refused is not enough on its own: the
# output has to name the planted text, or one alternative could be
# credited for another's match.
#
# An alternative added to either copy without a plant here fails
# this control rather than passing unproven.
#
# Nothing is committed and no tree is modified: plants are written
# to a temporary directory.
#
# Exits 0 only when the copies agree, every alternative is proved,
# and clean text still passes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRE_TAG="${REPO_ROOT}/scripts/release/pre-tag-check.sh"
PROMOTE="${REPO_ROOT}/scripts/release/promote.sh"
for f in "${PRE_TAG}" "${PROMOTE}"; do
    if [[ ! -f "${f}" ]]; then
        echo "leak-regex-positive: missing ${f}" >&2
        exit 1
    fi
done

# The documentation ranges the gates exempt (RFC 5737 reserves them
# for docs), read from Gate 5 so this control filters exactly what
# the gate filters.
DOC_RANGE_FILTER='192\.0\.2\.|198\.51\.100\.|203\.0\.113\.'

GATE_REGEX="$(
    sed -n "s/^LEAK_REGEX='\(.*\)'\$/\1/p" "${PRE_TAG}"
)"
if [[ -z "${GATE_REGEX}" ]]; then
    echo "leak-regex-positive: no LEAK_REGEX found in pre-tag-check.sh" >&2
    exit 1
fi

# The promote copy is an inline argument rather than a named
# variable; it is the single-quoted line carrying the lab range.
PROMOTE_REGEX="$(
    sed -n "s/^[[:space:]]*'\(192\\\\\.168[^']*\)'[[:space:]]*\\\\\$/\1/p" \
        "${PROMOTE}"
)"
if [[ -z "${PROMOTE_REGEX}" ]]; then
    echo "leak-regex-positive: no leak regex found in promote.sh" >&2
    exit 1
fi

if [[ "${GATE_REGEX}" != "${PROMOTE_REGEX}" ]]; then
    echo "leak-regex-positive: the two copies have DRIFTED." >&2
    echo "  pre-tag-check.sh: ${GATE_REGEX}" >&2
    echo "  promote.sh      : ${PROMOTE_REGEX}" >&2
    echo "One rule, written down twice, must say the same thing in" >&2
    echo "both places or the weaker copy decides what ships." >&2
    exit 1
fi

# Split the alternation at depth zero only. This regex genuinely
# carries a group — the private 172.16/12 range is written as
# `172\.(1[6-9]|2[0-9]|3[01])\.` — so a naive split on every `|`
# would tear that group into fragments that match nothing and then
# report them as broken alternatives. Escaped parentheses do not
# open a group and are not counted.
split_alternation() {
    # A literal backslash is written as `$'\\'` throughout: inside
    # ANSI-C quoting that is one backslash, and unlike `'\'` it does
    # not read as an attempt to escape a quote.
    local re="$1" depth=0 cur="" i ch prev="" backslash=$'\\'
    for ((i = 0; i < ${#re}; i++)); do
        ch="${re:i:1}"
        if [[ "${prev}" == "${backslash}" ]]; then
            cur+="${ch}"
            prev=""
            continue
        fi
        case "${ch}" in
            $'\\') cur+="${ch}"; prev="${backslash}"; continue ;;
            '(') depth=$((depth + 1)); cur+="${ch}" ;;
            ')') depth=$((depth - 1)); cur+="${ch}" ;;
            '|')
                if [[ "${depth}" -eq 0 ]]; then
                    printf '%s\n' "${cur}"
                    cur=""
                else
                    cur+="${ch}"
                fi
                ;;
            *) cur+="${ch}" ;;
        esac
        prev=""
    done
    printf '%s\n' "${cur}"
}

mapfile -t ALTERNATIVES < <(split_alternation "${GATE_REGEX}")
if [[ ${#ALTERNATIVES[@]} -eq 0 ]]; then
    echo "leak-regex-positive: the alternation split produced nothing." >&2
    exit 1
fi

# Sample text for each alternative. Two parallel lists rather than a
# `case`, because a case label is a glob and these alternatives carry
# `[0-9]` and other characters a glob would reinterpret.
SAMPLE_KEYS=(
    '192\.168\.[0-9]+\.[0-9]+'
    '10\.30\.[0-9]+\.[0-9]+'
    '172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+'
    'pi5target'
    'evoproto@'
    'SESSION_LOG [0-9]{4}-'
    'andrew@dt-ltd'
    'andser@'
    'ADR-[0-9]{3,4}'
    '\bR-[0-9]{3,}'
    '\bPD-[0-9]{3,}'
    'first cut'
    'swap later'
)
SAMPLE_VALS=(
    'reachable at 192.168.30.24'
    'reachable at 10.30.1.5'
    'reachable at 172.16.0.1'
    'the host called pi5target'
    'the account evoproto@box'
    'see SESSION_LOG 2026- for the entry'
    'mail andrew@dt-ltd.example'
    'mail andser@example.test'
    'see ADR-0161 for the rationale'
    'R-042 covers this'
    'PD-017 covers this'
    'landed as a first cut'
    'we can swap later'
)

sample_for() {
    local want="$1" i
    for i in "${!SAMPLE_KEYS[@]}"; do
        # POSIX string equality: `[[ = ]]` would glob the right side.
        if [ "${SAMPLE_KEYS[$i]}" = "${want}" ]; then
            printf '%s' "${SAMPLE_VALS[$i]}"
            return 0
        fi
    done
    return 1
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/leak-regex-positive.XXXXXX")"
# shellcheck disable=SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT
PLANT="${WORKDIR}/plant.txt"

# The gates' own pipeline: match, then drop documentation-range
# addresses.
scan() {
    grep -InE "${GATE_REGEX}" -- "${PLANT}" 2>/dev/null \
        | grep -vE "${DOC_RANGE_FILTER}" \
        || true
}

# Clean text first: if that were reported as a hit, every assertion
# below would pass for the wrong reason.
printf 'ordinary prose naming no host and no identifier\n' >"${PLANT}"
if [[ -n "$(scan)" ]]; then
    echo "leak-regex-positive: clean text was reported as a leak." >&2
    scan >&2
    exit 1
fi

PROVED=0
for alt in "${ALTERNATIVES[@]}"; do
    [[ -z "${alt}" ]] && continue
    if ! sample="$(sample_for "${alt}")"; then
        echo "leak-regex-positive: no plant for: ${alt}" >&2
        echo "The regex carries this alternative and nothing here" >&2
        echo "triggers it, so it would pass unproven. Add a sample" >&2
        echo "to SAMPLE_KEYS / SAMPLE_VALS." >&2
        exit 1
    fi
    printf '%s\n' "${sample}" >"${PLANT}"
    hits="$(scan)"
    if [[ -z "${hits}" ]]; then
        echo "leak-regex-positive: planted '${sample}' was CLEAN." >&2
        echo "The alternative ${alt} matches nothing." >&2
        exit 1
    fi
    if ! printf '%s\n' "${hits}" | grep -Fq "${sample}"; then
        echo "leak-regex-positive: ${alt} reported a hit that does" >&2
        echo "not name the planted text '${sample}'." >&2
        printf '%s\n' "${hits}" >&2
        exit 1
    fi
    PROVED=$((PROVED + 1))
done

echo "leak-regex-positive: ${PROVED} alternatives caught in both copies;"
echo "clean text passes."
exit 0
