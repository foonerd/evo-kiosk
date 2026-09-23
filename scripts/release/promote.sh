#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
#
# promote.sh — eng-side → public-side squash-and-scrub release cut.
#
# Builds a staging tree from the named eng-side tag, removes paths
# listed in `.scrub-exclude`, and applies the result to the public
# repo's main branch as a single squashed commit on top of
# `--prev-tag`. Tags + pushes are gated by `--no-push` for
# review-before-publish flows.
#
# Peer repos run additional staging-tree gates (fmt --check,
# clippy, test, Cargo.lock regen). Kiosk's staging tree is a
# scrub of the source tree — no code transform — so those gates
# are equivalent to the pre-tag-check already run before this
# script is invoked. Add them here if scrub scope ever grows to
# include content mutation.
#
# Workflow-preservation contract: the wipe-and-copy step
# preserves the PUBLIC repo's `.github/workflows/` directory
# verbatim and strips any workflow files from staging so copy
# cannot leak eng-side workflow content into the public tree.
# The public workflow set is the canonical shipping surface.
# This is a HARD invariant of the tool: never remove the
# preservation predicate without operator authorisation.
#
# `--dry-run` prints three buckets against the post-scrub
# staging tree before any public mutation:
#   WORKFLOW KEEP — public workflow filenames that survive
#   WOULD ADD     — paths staging would introduce
#   WOULD DELETE  — public paths staging would remove
# Staging `.github/workflows/` is excluded from ADD/DELETE
# because the mutate path strips it.
#
# Usage:
#
#   scripts/release/promote.sh \
#     --tag VERSION \
#     --public-repo PATH \
#     [--prev-tag VERSION] \
#     [--dry-run] \
#     [--no-push]
#
# Required arguments:
#
#   --tag VERSION
#     The eng-side tag to promote. Must already exist locally
#     (`git tag` in the eng working tree). The script does not
#     mint or move the eng-side tag; tag minting is a separate
#     authoring step the operator runs before promote.
#
#   --public-repo PATH
#     Filesystem path to a clone of the public evo-kiosk repo.
#     Working tree must be clean and on `main`. The script does
#     not clone the public repo for you; clone first, then point
#     this argument at the clone.
#
# Optional arguments:
#
#   --prev-tag VERSION
#     The previous public-side release tag. The squashed commit
#     is built on top of this tag. When omitted the script
#     auto-derives the latest matching tag from the public repo
#     (`git describe --abbrev=0 --tags`); if the public repo has
#     no matching tag yet (first cut), the squash commit is built
#     on top of the public main HEAD.
#
#   --dry-run
#     Run every check step but mutate nothing. The staging
#     tempdir is built and verified; the public repo is not
#     touched; no tag is created; no push happens. Used for
#     review-before-publish workflow. The script prints the
#     planned tree diff against the public main as the final
#     output so the operator sees exactly what would land.
#
#   --no-push
#     Mutate the public repo (commit + tag) but skip the final
#     `git push`. Used when the operator wants to inspect the
#     local public-repo state, run additional manual checks,
#     and trigger the push from a separate command.
#
# Preconditions enforced:
#
#   - eng working tree clean (`git status --porcelain` empty).
#   - eng tag exists.
#   - public-repo path is a git repo.
#   - public-repo working tree clean.
#   - public-repo on `main` branch.
#   - prev-tag exists in public repo (if explicit) OR the auto-
#     derived latest tag exists (if not explicit and any tag
#     matches). If no tag matches and no --prev-tag given, the
#     script promotes from public main HEAD (first-cut path).
#
# Refuses to proceed if any precondition fails.

set -euo pipefail

# -------------------------------------------------------------
# Argument parsing
# -------------------------------------------------------------

TAG=""
PUBLIC_REPO=""
PREV_TAG=""
DRY_RUN=0
NO_PUSH=0

print_usage() {
    sed -n '2,/^# Refuses/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)             TAG="$2"; shift 2 ;;
        --public-repo)     PUBLIC_REPO="$2"; shift 2 ;;
        --prev-tag)        PREV_TAG="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --no-push)         NO_PUSH=1; shift ;;
        -h|--help)         print_usage; exit 0 ;;
        *)
            echo "promote.sh: unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 2
            ;;
    esac
done

if [[ -z "${TAG}" ]]; then
    echo "promote.sh: --tag is required" >&2
    exit 2
fi
if [[ -z "${PUBLIC_REPO}" ]]; then
    echo "promote.sh: --public-repo is required" >&2
    exit 2
fi

TAG_FORMAT_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$'
if ! [[ "${TAG}" =~ ${TAG_FORMAT_REGEX} ]]; then
    cat >&2 <<EOF
promote.sh: --tag does not match the release format contract.

Got:    ${TAG}
Regex:  ${TAG_FORMAT_REGEX}

Accepted shapes:
  v<MAJOR>.<MINOR>.<PATCH>                          e.g. v1.2.3
  v<MAJOR>.<MINOR>.<PATCH>.<CLOSURE>                e.g. v1.2.3.1
  v<MAJOR>.<MINOR>.<PATCH>-<PRERELEASE>             e.g. v1.2.4-rc.1
  v<MAJOR>.<MINOR>.<PATCH>.<CLOSURE>-<PRERELEASE>   e.g. v1.2.3.1-rc.2
EOF
    exit 2
fi
if [[ -n "${PREV_TAG}" ]] && ! [[ "${PREV_TAG}" =~ ${TAG_FORMAT_REGEX} ]]; then
    echo "promote.sh: --prev-tag does not match the release format contract: ${PREV_TAG}" >&2
    exit 2
fi

if [[ ! -d "${PUBLIC_REPO}" ]]; then
    echo "promote.sh: --public-repo path does not exist: ${PUBLIC_REPO}" >&2
    exit 2
fi
PUBLIC_REPO="$(cd "${PUBLIC_REPO}" && pwd)"

ENG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log_step() { printf '\n[promote] %s\n' "$*" >&2; }
log_ok()   { printf '[promote] OK: %s\n' "$*" >&2; }
log_fail() { printf '[promote] FAIL: %s\n' "$*" >&2; }
log_dry()  { printf '[promote][dry-run] %s\n' "$*" >&2; }

# File-level promote plan. Workflows are a keep-list, not an
# add/delete, because the mutate path restores public workflows
# after wipe. Staging target/ is stripped before copy.
print_promote_plan() {
    local public_repo="$1"
    local staging="$2"
    local pub_file stg_file

    printf 'WORKFLOW KEEP\n'
    if [[ -d "${public_repo}/.github/workflows" ]]; then
        ls -1 "${public_repo}/.github/workflows"
    else
        printf '(none)\n'
    fi

    pub_file="$(mktemp)"
    stg_file="$(mktemp)"
    git -C "${public_repo}" ls-files >"${pub_file}.raw"
    grep -v '^\.github/workflows/' "${pub_file}.raw" >"${pub_file}.keep" || true
    sort "${pub_file}.keep" >"${pub_file}"
    rm -f "${pub_file}.raw" "${pub_file}.keep"
    (
        cd "${staging}"
        find . -mindepth 1 \
            \( -path './.git' -o -path './.git/*' \
               -o -path './.github/workflows' -o -path './.github/workflows/*' \
               -o -path './target' -o -path './target/*' \) -prune \
            -o \( -type f -o -type l \) -print
    ) | sed 's|^\./||' | sort >"${stg_file}"

    printf 'WOULD ADD\n'
    comm -13 "${pub_file}" "${stg_file}"
    printf 'WOULD DELETE\n'
    comm -23 "${pub_file}" "${stg_file}"
    rm -f "${pub_file}" "${stg_file}"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_step "DRY-RUN mode: no mutations will be applied to ${PUBLIC_REPO}"
fi

# -------------------------------------------------------------
# Step 1: precondition gates
# -------------------------------------------------------------

log_step "Step 1/6: precondition gates"

# eng working tree clean.
if [[ -n "$(git -C "${ENG_REPO}" status --porcelain)" ]]; then
    log_fail "eng working tree is dirty; commit or stash before promote"
    exit 1
fi
log_ok "eng working tree clean"

# eng tag exists.
if ! git -C "${ENG_REPO}" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    log_fail "eng tag ${TAG} does not exist; mint it before promote"
    exit 1
fi
log_ok "eng tag ${TAG} exists"

# public repo is a git repo.
if [[ ! -d "${PUBLIC_REPO}/.git" ]]; then
    log_fail "${PUBLIC_REPO} is not a git repository"
    exit 1
fi
log_ok "${PUBLIC_REPO} is a git repository"

# public repo working tree clean.
if [[ -n "$(git -C "${PUBLIC_REPO}" status --porcelain)" ]]; then
    log_fail "public repo working tree is dirty; clean before promote"
    exit 1
fi
log_ok "public repo working tree clean"

# public repo on main.
public_branch="$(git -C "${PUBLIC_REPO}" branch --show-current)"
if [[ "${public_branch}" != "main" ]]; then
    log_fail "public repo not on main branch (currently: ${public_branch})"
    exit 1
fi
log_ok "public repo on main"

# prev-tag resolution.
if [[ -n "${PREV_TAG}" ]]; then
    if ! git -C "${PUBLIC_REPO}" rev-parse -q --verify "refs/tags/${PREV_TAG}" >/dev/null; then
        log_fail "explicit --prev-tag ${PREV_TAG} does not exist in public repo"
        exit 1
    fi
    log_ok "prev-tag ${PREV_TAG} exists in public repo"
elif git -C "${PUBLIC_REPO}" describe --abbrev=0 --tags --match='v[0-9]*' >/dev/null 2>&1; then
    PREV_TAG="$(git -C "${PUBLIC_REPO}" describe --abbrev=0 --tags --match='v[0-9]*')"
    log_ok "auto-derived prev-tag ${PREV_TAG} from public repo"
else
    log_ok "no prior release tag in public repo; promoting on top of public main HEAD (first-cut path)"
fi

# -------------------------------------------------------------
# Step 2: build staging tree from eng tag + apply .scrub-exclude
# -------------------------------------------------------------

log_step "Step 2/6: building staging tree from eng tag"

STAGE_DIR="$(mktemp -d -t evo-kiosk-promote.XXXXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT INT TERM

# `git archive` produces a tarball of the eng tag's tree without .git;
# extract into the staging dir so subsequent scrub steps operate on
# a plain filesystem.
git -C "${ENG_REPO}" archive --format=tar "${TAG}" | tar -x -C "${STAGE_DIR}"
log_ok "staging tree at ${STAGE_DIR} (from eng tag ${TAG})"

log_step "Step 2b/6: applying .scrub-exclude"

SCRUB_EXCLUDE="${STAGE_DIR}/.scrub-exclude"
if [[ ! -f "${SCRUB_EXCLUDE}" ]]; then
    log_fail ".scrub-exclude missing from eng tag ${TAG} staging tree"
    exit 1
fi
# Read entries, strip comments + blank lines, remove each from the
# staging tree. Missing entries are permitted (idempotent scrub).
grep -vE '^\s*(#|$)' "${SCRUB_EXCLUDE}" | while IFS= read -r path; do
    path="${path%%#*}"
    path="$(echo "${path}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${path}" ]] && continue
    # Refuse to scrub outside the staging tree (paranoia).
    case "${path}" in
        /*|../*) log_fail "refusing to scrub absolute or parent path: ${path}"; exit 1 ;;
    esac
    log_ok "scrub: ${path}"
    rm -rf "${STAGE_DIR:?}/${path}"
done
log_ok ".scrub-exclude applied"

# -------------------------------------------------------------
# Step 3: leak scan on the staging tree (post-scrub)
# -------------------------------------------------------------

log_step "Step 3/6: leak scan on staging tree"

leak_hits="$(
  grep -rInE \
    '192\.168\.[0-9]+\.[0-9]+|10\.30\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|pi5target|evoproto@|SESSION_LOG [0-9]{4}-|andrew@dt-ltd|andser@|ADR-[0-9]{3,4}|\bR-[0-9]{3,}|\bPD-[0-9]{3,}|first cut|swap later' \
    "${STAGE_DIR}" 2>/dev/null \
  | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' \
  || true
)"
if [[ -n "${leak_hits}" ]]; then
    log_fail "leak scan hit on staging tree — scrub these before promoting:"
    printf '%s\n' "${leak_hits}" >&2
    log_fail "either extend .scrub-exclude to remove the source file, or"
    log_fail "amend the eng-side source to redact the leaked identifier"
    log_fail "and re-cut the tag"
    exit 1
fi
log_ok "staging leak scan clean"

# -------------------------------------------------------------
# Step 4: diff preview + dry-run stop
# -------------------------------------------------------------

log_step "Step 4/6: staging vs public tree plan"

print_promote_plan "${PUBLIC_REPO}" "${STAGE_DIR}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_dry "would: cd ${PUBLIC_REPO}"
    if [[ -n "${PREV_TAG}" ]]; then
        log_dry "would: git reset --soft ${PREV_TAG}"
    fi
    log_dry "would: preserve public .github/workflows/ verbatim across the wipe"
    log_dry "would: replace working tree with staging contents (workflows stripped from staging)"
    log_dry "would: git add -A && git commit --signoff -m 'release ${TAG}'"
    log_dry "would: git tag ${TAG}"
    log_step "DRY-RUN: stopping before public repo mutation"
    log_ok "re-run without --dry-run to apply"
    exit 0
fi

# -------------------------------------------------------------
# Step 5: mutate public repo
# -------------------------------------------------------------

log_step "Step 5/6: applying staging tree to public repo"

pushd "${PUBLIC_REPO}" >/dev/null

# Rebase point.
if [[ -n "${PREV_TAG}" ]]; then
    git reset --soft "${PREV_TAG}"
    log_ok "public repo reset --soft to ${PREV_TAG}"
else
    log_ok "public repo left at main HEAD (first-cut path)"
fi

# Preserve public .github/workflows/ across the wipe. The
# public workflow set is the canonical shipping surface;
# a wipe-and-copy that let staging land workflows over the
# public tree would delete public workflows or route public
# CI to the wrong runner pool. This is a HARD invariant of
# the tool: never remove the preservation predicate without
# operator authorisation.
PRESERVED_WORKFLOWS="$(mktemp -d -t evo-promote-workflows-XXXXXX)"
if [[ -d ".github/workflows" ]]; then
    cp -a ".github/workflows/." "${PRESERVED_WORKFLOWS}/"
fi

# Wipe the working tree (except .git) and replace from staging.
find . -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +

rm -rf "${STAGE_DIR}/target"
rm -rf "${STAGE_DIR}/.github/workflows"

# cp -a preserves attributes + dotfiles. The trailing /. on
# the source ensures hidden files are copied too.
cp -a "${STAGE_DIR}/." .

# Restore preserved public workflows verbatim.
if [[ -n "$(ls -A "${PRESERVED_WORKFLOWS}" 2>/dev/null || true)" ]]; then
    mkdir -p ".github/workflows"
    cp -a "${PRESERVED_WORKFLOWS}/." ".github/workflows/"
fi
rm -rf "${PRESERVED_WORKFLOWS}"
rm -f .scrub-exclude
git add -A

# Commit with a promote-shaped message referencing the eng tag.
commit_msg="release ${TAG}

Promoted via scripts/release/promote.sh from the source
tree at tag ${TAG}. This repository carries release-only
squash commits."

git commit --signoff -m "${commit_msg}"
log_ok "public repo committed release ${TAG}"

git tag -a "${TAG}" -m "release ${TAG}"
log_ok "public repo tagged ${TAG}"

popd >/dev/null

# -------------------------------------------------------------
# Step 6: push (unless --no-push)
# -------------------------------------------------------------

log_step "Step 6/6: push public repo"

if [[ "${NO_PUSH}" -eq 1 ]]; then
    log_ok "--no-push set; skipping git push"
    log_ok "manual push: git -C ${PUBLIC_REPO} push origin main --follow-tags"
else
    git -C "${PUBLIC_REPO}" push origin main
    git -C "${PUBLIC_REPO}" push origin "refs/tags/${TAG}"
    log_ok "public repo main + tag ${TAG} pushed"
fi

cat >&2 <<BANNER

[promote] Release ${TAG} applied to ${PUBLIC_REPO}.

Follow-up:
  1. Cross-compile the release browser binary:
       scripts/release/cross-build.sh
  2. Sign the binaries + advance the artefacts-repo channel
     pointer:
       scripts/release/publish-artefacts.sh \\
           --artefacts-repo <PATH> \\
           --signing-key <KEY> \\
           --channel dev \\
           --version ${TAG}
  3. Verify GitHub Release drafts (if using gh release workflow).
BANNER
