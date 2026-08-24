#!/bin/bash
# Bump Tekton task references across Submariner Konflux repos
#
# Usage: tekton-task-refs-update.sh <version> [repo]
#
# Arguments:
#   version: Target release version (e.g., 0.23.1)
#   repo:    Optional repo filter (submariner-operator, submariner, lighthouse,
#            shipyard, subctl, fbc)
#
# Runs `pipeline-patcher bump-task-refs` in each of the 5 component repos (on
# release-<X.Y>) plus the FBC repo (on main), committing the refreshed .tekton/
# pipeline files on a per-repo fix branch. It never pushes — push/PR is left to
# the human (commands are printed and appended to $AUTORELEASE_PUSH_LOG). The
# downstream ecFixes verifier confirms Enterprise Contract passes once the PRs
# merge and Konflux rebuilds.
#
# Exit codes:
#   0: Success (every applicable repo bumped or already current)
#   1: Failure (prerequisites, or one or more repos failed)

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Capture the lib dir before sourcing: jira-tracker.sh (line 22) unconditionally
# resets SCRIPT_DIR to its own directory (scripts/lib/). Using _LIB_DIR for all
# subsequent lib sources prevents that contamination from corrupting our paths.
_LIB_DIR="$SCRIPT_DIR/lib"

# Source jira-tracker.sh early to provide FBC_REPO_DEFAULT before we assign
# FBC_REPO_PATH below. The include guard makes the later tracker-integration
# source inside main() a no-op.
# shellcheck source=lib/jira-tracker.sh
source "$_LIB_DIR/jira-tracker.sh" 2>/dev/null || true

# ━━━ CONSTANTS ━━━

readonly SUBMARINER_BASE="$HOME/go/src/submariner-io"
# FBC lives outside the upstream Go tree (see fbc-catalog-update.sh).
# FBC_REPO_DEFAULT is the canonical path defined once in lib/jira-tracker.sh.
readonly FBC_REPO_PATH="${FBC_REPO:-$FBC_REPO_DEFAULT}"

# Ordered repo list. Component repos live under $SUBMARINER_BASE and bump on
# release-<mm>; the FBC repo lives elsewhere and bumps on main (see repo_path /
# repo_base_branch). Associative arrays don't preserve order, hence a string.
readonly REPO_ORDER="submariner-operator submariner lighthouse shipyard subctl fbc"

# ━━━ GLOBAL VARIABLES ━━━

VERSION=""
MAJOR_MINOR=""
REPO_FILTER=""
PATCHER_SCRIPT=""   # verified pipeline-patcher, downloaded once by main

declare -a REPOS_UPDATED=()
declare -a REPOS_SKIPPED=()
declare -a REPOS_FAILED=()

# ━━━ HELPERS ━━━

die() {
  echo "❌ ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

# Filesystem path for a repo key.
repo_path() {
  case "$1" in
    fbc) echo "$FBC_REPO_PATH" ;;
    *)   echo "$SUBMARINER_BASE/$1" ;;
  esac
}

# Branch a repo's fix branch is cut from and its PR targets.
repo_base_branch() {
  case "$1" in
    fbc) echo "main" ;;
    *)   echo "release-$MAJOR_MINOR" ;;
  esac
}

# Return a repo to the ref it was on before we touched it. Passing a second
# argument also deletes that (commit-less) fix branch. Leaving a repo on the fix
# branch is the branch-inheritance hazard that misroutes a later bundleShas
# commit (see plan "Known bugs"), so every exit path restores the original ref.
#
# The checkout is forced: a patcher that fails mid-edit leaves .tekton/ dirty, and
# a plain `git checkout` would refuse ("local changes would be overwritten") and be
# swallowed by `|| true`, stranding us on the fix branch — the very misroute above.
# The dirty-tree guard in update_repo means the only uncommitted changes reachable
# here are our own partial patcher edits, so discarding them with -f is safe.
_restore_repo() {
  local original_ref="$1" drop_branch="${2:-}"
  git checkout -f "$original_ref" >/dev/null 2>&1 || true
  if [ -n "$drop_branch" ]; then
    git branch -D "$drop_branch" >/dev/null 2>&1 || true
  fi
}

# ━━━ PREREQUISITES ━━━

check_prerequisites() {
  local MISSING_TOOLS=()

  # git for repo ops; curl to fetch the patcher; oras + yq are required by
  # pipeline-patcher itself (it never checks, so we do).
  command -v git &>/dev/null || MISSING_TOOLS+=("git")
  command -v curl &>/dev/null || MISSING_TOOLS+=("curl")
  command -v oras &>/dev/null || MISSING_TOOLS+=("oras")
  command -v yq &>/dev/null || MISSING_TOOLS+=("yq")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    die "Missing required tools: ${MISSING_TOOLS[*]}"
  fi

  echo "✓ Prerequisites verified: git, curl, oras, yq"
}

# ━━━ ARGUMENT PARSING ━━━

parse_arguments() {
  local VERSION_ARG="${1:-}"
  local REPO_ARG="${2:-}"

  if [ -z "$VERSION_ARG" ]; then
    echo "Usage: $0 <version> [repo]"
    echo "Example: $0 0.23.1"
    echo "Example: $0 0.23.1 fbc"
    exit 1
  fi

  [ $# -gt 2 ] && die "Too many arguments"

  # Validate version format (X.Y.Z; the conductor passes X.Y.0 for Y-stream)
  if ! [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid version format: $VERSION_ARG" \
        "Expected: X.Y.Z (e.g., 0.23.1)"
  fi

  VERSION="$VERSION_ARG"
  MAJOR_MINOR="${VERSION%.*}"

  # Parse optional repo filter (validated against REPO_ORDER)
  if [ -n "$REPO_ARG" ]; then
    if [[ " $REPO_ORDER " != *" $REPO_ARG "* ]]; then
      die "Unknown repo: $REPO_ARG" \
          "Valid repos: ${REPO_ORDER}"
    fi
    REPO_FILTER="$REPO_ARG"
  fi

  echo ""
  echo "============================================"
  echo "Update Tekton Task References"
  echo "============================================"
  echo "Version: $VERSION"
  if [ -n "$REPO_FILTER" ]; then
    echo "Repo:    $REPO_FILTER"
  else
    echo "Repos:   all (6: 5 components + FBC)"
  fi
  echo ""
}

# ━━━ UPDATE LOGIC ━━━

update_repo() {
  local REPO="$1"
  local REPO_PATH BASE_BRANCH FIX_BRANCH
  REPO_PATH="$(repo_path "$REPO")"
  BASE_BRANCH="$(repo_base_branch "$REPO")"
  FIX_BRANCH="fix-tekton-tasks-${MAJOR_MINOR}"

  echo "━━━ $REPO ━━━"

  # Check repo exists
  if [ ! -d "$REPO_PATH" ]; then
    echo "  ✗ Repo not found: $REPO_PATH"
    REPOS_FAILED+=("$REPO:repo-not-found")
    echo ""
    return
  fi

  cd "$REPO_PATH" || {
    REPOS_FAILED+=("$REPO:cd-failed")
    echo ""
    return
  }

  # Refuse to touch a dirty tree: we switch branches and restore afterwards,
  # which is unsafe with uncommitted changes (and the patcher would fail anyway).
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "  ✗ Working tree not clean (commit/stash first)"
    REPOS_FAILED+=("$REPO:dirty-tree")
    echo ""
    return
  fi

  # Remember where the repo was so we can leave it exactly as found. On a branch
  # this is the branch name (so we return *to the branch*, not a detached commit).
  # On a detached HEAD `--abbrev-ref` prints the literal "HEAD" (exit 0), so fall
  # back to the raw SHA — otherwise `git checkout HEAD` at restore time would
  # strand the repo on the fix branch's tip, the very branch-misroute we prevent.
  local ORIGINAL_REF
  ORIGINAL_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$ORIGINAL_REF" ] || [ "$ORIGINAL_REF" = "HEAD" ]; then
    # `|| true` so a degenerate/unborn HEAD marks just this repo failed downstream
    # rather than aborting the whole run mid-loop under set -e.
    ORIGINAL_REF="$(git rev-parse HEAD 2>/dev/null || true)"
  fi

  # Resolve base branch (prefer origin/, fall back to local)
  local BRANCH_REF="origin/$BASE_BRANCH"
  if ! git show-ref --verify --quiet "refs/remotes/$BRANCH_REF"; then
    BRANCH_REF="$BASE_BRANCH"
    if ! git show-ref --verify --quiet "refs/heads/$BRANCH_REF"; then
      echo "  ✗ Branch $BASE_BRANCH not found (run: git fetch origin $BASE_BRANCH)"
      # A missing base branch means this repo could NOT be processed — a failure
      # (needs a git fetch), not a benign skip, so the step is not marked done.
      REPOS_FAILED+=("$REPO:branch-not-found")
      echo ""
      return
    fi
  fi

  # Create fix branch from base branch (still on ORIGINAL_REF if this fails)
  if ! git checkout -B "$FIX_BRANCH" "$BRANCH_REF" >/dev/null 2>&1; then
    echo "  ✗ Failed to create branch $FIX_BRANCH"
    REPOS_FAILED+=("$REPO:branch-create-failed")
    echo ""
    return
  fi

  if [ ! -d .tekton ]; then
    echo "  ✗ No .tekton/ directory on $BASE_BRANCH"
    REPOS_FAILED+=("$REPO:no-tekton")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH"
    echo ""
    return
  fi

  # Bump task refs. The patcher edits .tekton/ in place; capture output so a
  # failure is not opaque.
  local patcher_out
  if ! patcher_out=$(printf '%s' "$PATCHER_SCRIPT" | bash -s bump-task-refs 2>&1); then
    echo "  ✗ pipeline-patcher failed:"
    printf '%s\n' "$patcher_out" | sed 's/^/      /'
    REPOS_FAILED+=("$REPO:patcher-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH"
    echo ""
    return
  fi

  # Stage only .tekton changes. Skip the commit if the patcher was a no-op (refs
  # already latest, or a re-run) — an unconditional commit would fail.
  git add .tekton/
  if git diff --cached --quiet; then
    echo "  - Task refs already current"
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH"
    REPOS_SKIPPED+=("$REPO:no-changes")
    echo ""
    return
  fi

  # Commit
  if git commit -s -m "Update Tekton task references to latest versions

Refreshes .tekton pipeline task bundle references so Konflux builds pass
Enterprise Contract validation." >/dev/null 2>&1; then
    echo "  ✓ Committed"
    REPOS_UPDATED+=("$REPO#$FIX_BRANCH#$BASE_BRANCH")
    # Keep the fix branch (it holds the commit); restore the original ref.
    _restore_repo "$ORIGINAL_REF"
  else
    echo "  ✗ Commit failed"
    REPOS_FAILED+=("$REPO:commit-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH"
  fi

  echo ""
}

update_all() {
  local ORIGINAL_DIR
  ORIGINAL_DIR=$(pwd)

  for REPO in $REPO_ORDER; do
    if [ -n "$REPO_FILTER" ] && [ "$REPO" != "$REPO_FILTER" ]; then
      continue
    fi
    update_repo "$REPO"
  done

  cd "$ORIGINAL_DIR"
}

# ━━━ SUMMARY ━━━

print_section() {
  local title="$1"
  local symbol="$2"
  local -n entries="$3"
  local show_reason="${4:-false}"

  [ "${#entries[@]}" -eq 0 ] && return

  echo ""
  echo "$title (${#entries[@]}):"
  for entry in "${entries[@]}"; do
    if [ "$show_reason" = "true" ]; then
      echo "  $symbol ${entry%%:*} (${entry##*:})"
    else
      echo "  $symbol ${entry%%#*}"
    fi
  done
}

print_summary() {
  echo ""
  echo "Summary"

  print_section "Updated" "✓" REPOS_UPDATED
  print_section "Skipped" "-" REPOS_SKIPPED true
  print_section "Failed" "✗" REPOS_FAILED true

  local UPDATED_COUNT=${#REPOS_UPDATED[@]}
  local FAILED_COUNT=${#REPOS_FAILED[@]}

  if [ "$UPDATED_COUNT" -gt 0 ]; then
    echo ""
    echo "Next Steps"
    for entry in "${REPOS_UPDATED[@]}"; do
      local repo="${entry%%#*}"
      local rest="${entry#*#}"
      local fix_branch="${rest%%#*}"
      local base_branch="${rest#*#}"
      local path
      path="$(repo_path "$repo")"
      echo ""
      echo "# $repo"
      echo "cd $path"
      echo "git show"
      echo "git push origin $fix_branch"
      echo "gh pr create --base $base_branch --head $fix_branch --title \"Update Tekton task references\" --body \"Refresh .tekton task refs for Enterprise Contract.\""
      # Append to push summary if conductor is running
      if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
        printf '\n  cd %s\n  git push origin %s\n  gh pr create --base %s --head %s\n' \
          "$path" "$fix_branch" "$base_branch" "$fix_branch" \
          >> "$AUTORELEASE_PUSH_LOG"
      fi
    done
  fi

  echo ""
  [ "$FAILED_COUNT" -eq 0 ]
}

# ━━━ MAIN ━━━

main() {
  check_prerequisites
  parse_arguments "$@"

  # Download + verify the pipeline-patcher once (shared helper: pinned SHA +
  # checksum). Reused per-repo in update_repo.
  # shellcheck source=/dev/null
  source "$_LIB_DIR/pipeline-patcher.sh"
  PATCHER_SCRIPT=$(download_and_verify_patcher) || \
    die "Failed to download/verify pipeline-patcher" \
      "Check network connectivity and GitHub access"
  echo "✓ Pipeline-patcher checksum verified"

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$_LIB_DIR/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  # Only move tracker state on a full run. A filtered (single-repo) run is a manual
  # partial retry: guarding in_progress the same way as completion (below) keeps it
  # from flipping an already-complete step back to in_progress and never restoring it.
  [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] && update_step "$VERSION" "tektonTasks" "in_progress" '{}' "$TRACKER"

  update_all

  print_summary

  # Record completion when the full repo set was processed with no failures.
  # "All already current" (0 updated, 0 failed) is still success. A single-repo
  # run (REPO_FILTER) covers only part of the step, so it must not complete it.
  # update_step is called AFTER print_summary so that a push-log write failure
  # (inside print_summary) leaves the tracker at 'in_progress' rather than 'complete'.
  if [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] && [ "${#REPOS_FAILED[@]}" -eq 0 ]; then
    local data
    data=$(jq -n --arg count "${#REPOS_UPDATED[@]}" --arg ver "$VERSION" \
      '{reposUpdated:($count|tonumber),version:$ver}' | jq -c .) || data="{}"
    update_step "$VERSION" "tektonTasks" "complete" "$data" "$TRACKER"
  fi
}

# Guard so tests can source helpers without running a release.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
