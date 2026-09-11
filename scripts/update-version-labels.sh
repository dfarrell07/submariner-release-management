#!/bin/bash
# Update Konflux Dockerfile version labels across Submariner repositories
#
# Usage: update-version-labels.sh <version> [repo]
#
# Arguments:
#   version: Target release version (e.g., 0.23.1)
#   repo:    Optional repo filter (submariner-operator, submariner, lighthouse, shipyard, subctl)
#
# Updates version labels in 9 Dockerfiles across 5 repos so Konflux's
# {{ labels.version }} tag expansion produces correct image tags.
#
# Exit codes:
#   0: Success (at least one repo updated, or all already correct)
#   1: Failure (prerequisites, validation, or update failed)

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/git-utils.sh
source "$SCRIPT_DIR/lib/git-utils.sh" 2>/dev/null || true

# ━━━ CONSTANTS ━━━

readonly SUBMARINER_BASE="$HOME/go/src/submariner-io"

# Repo → Dockerfiles mapping (space-separated within value)
declare -A REPO_DOCKERFILES=(
  ["submariner-operator"]="package/Dockerfile.submariner-operator.konflux"
  ["submariner"]="package/Dockerfile.submariner-gateway.konflux package/Dockerfile.submariner-globalnet.konflux package/Dockerfile.submariner-route-agent.konflux"
  ["lighthouse"]="package/Dockerfile.lighthouse-agent.konflux package/Dockerfile.lighthouse-coredns.konflux"
  ["shipyard"]="package/Dockerfile.nettest.konflux"
  ["subctl"]="package/Dockerfile.subctl.konflux"
)

# Ordered list of repos (bash associative arrays don't preserve order)
readonly REPO_ORDER="submariner-operator submariner lighthouse shipyard subctl"

# ━━━ GLOBAL VARIABLES ━━━

VERSION=""
MAJOR_MINOR=""
RELEASE_BRANCH=""
REPO_FILTER=""

declare -a REPOS_UPDATED=()
declare -a REPOS_SKIPPED=()
declare -a REPOS_FAILED=()

# ━━━ HELPERS ━━━

die() {
  echo "❌ ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

# ━━━ PREREQUISITES ━━━

check_prerequisites() {
  local MISSING_TOOLS=()

  command -v git &>/dev/null || MISSING_TOOLS+=("git")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    die "Missing required tools: ${MISSING_TOOLS[*]}"
  fi

  echo "✓ Prerequisites verified: git"
}

# ━━━ ARGUMENT PARSING ━━━

parse_arguments() {
  local VERSION_ARG="${1:-}"
  local REPO_ARG="${2:-}"

  if [ -z "$VERSION_ARG" ]; then
    echo "Usage: $0 <version> [repo]"
    echo "Example: $0 0.23.1"
    echo "Example: $0 0.23.1 subctl"
    exit 1
  fi

  [ $# -gt 2 ] && die "Too many arguments"

  # Validate version format (must be X.Y.Z for Z-stream)
  if ! [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid version format: $VERSION_ARG" \
        "Expected: X.Y.Z (e.g., 0.23.1)"
  fi

  VERSION="$VERSION_ARG"
  MAJOR_MINOR="${VERSION%.*}"
  RELEASE_BRANCH="release-${MAJOR_MINOR}"

  # Parse optional repo filter
  if [ -n "$REPO_ARG" ]; then
    if [ -z "${REPO_DOCKERFILES[$REPO_ARG]+x}" ]; then
      die "Unknown repo: $REPO_ARG" \
          "Valid repos: ${REPO_ORDER}"
    fi
    REPO_FILTER="$REPO_ARG"
  fi

  echo ""
  echo "============================================"
  echo "Update Version Labels"
  echo "============================================"
  echo "Version: $VERSION"
  echo "Branch:  $RELEASE_BRANCH"
  if [ -n "$REPO_FILTER" ]; then
    echo "Repo:    $REPO_FILTER"
  else
    echo "Repos:   all (5)"
  fi
  echo ""
}

# ━━━ UPDATE LOGIC ━━━

update_repo() {
  local REPO="$1"
  local REPO_PATH="$SUBMARINER_BASE/$REPO"
  local DOCKERFILES="${REPO_DOCKERFILES[$REPO]}"
  local FIX_BRANCH="fix-version-labels-${MAJOR_MINOR}"

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

  # Find branch ref (try origin/ first, fall back to local)
  local BRANCH_REF="origin/$RELEASE_BRANCH"
  if ! git show-ref --verify --quiet "refs/remotes/$BRANCH_REF"; then
    BRANCH_REF="$RELEASE_BRANCH"
    if ! git show-ref --verify --quiet "refs/heads/$BRANCH_REF"; then
      echo "  ✗ Branch $RELEASE_BRANCH not found (run: git fetch origin $RELEASE_BRANCH)"
      # A missing release branch means this repo could NOT be processed — that is
      # a failure (needs a git fetch), not a benign skip. Recording it as skipped
      # would let the run exit 0 and mark the tracker step complete while a repo
      # went untouched.
      REPOS_FAILED+=("$REPO:branch-not-found")
      echo ""
      return
    fi
  fi

  # Create fix branch from release branch
  if ! git checkout -B "$FIX_BRANCH" "$BRANCH_REF" >/dev/null 2>&1; then
    echo "  ✗ Failed to create branch $FIX_BRANCH"
    REPOS_FAILED+=("$REPO:branch-create-failed")
    echo ""
    return
  fi

  # Update standard Dockerfiles
  local FILES_UPDATED=0
  for FILE in $DOCKERFILES; do
    if [ ! -f "$FILE" ]; then
      echo "  ✗ File not found: $FILE"
      REPOS_FAILED+=("$REPO:file-not-found")
      echo ""
      return
    fi

    sed -i 's/version="v[0-9.]*"/version="v'"$VERSION"'"/' "$FILE"

    if grep -q "version=\"v${VERSION}\"" "$FILE"; then
      echo "  ✓ $FILE"
      FILES_UPDATED=$((FILES_UPDATED + 1))
    else
      echo "  ✗ Failed to update $FILE"
      REPOS_FAILED+=("$REPO:sed-failed")
      echo ""
      return
    fi
  done

  # Bundle special case (submariner-operator only)
  if [ "$REPO" = "submariner-operator" ] && [ -f "bundle.Dockerfile.konflux" ]; then
    sed -i \
      -e 's/^LABEL csv-version="[0-9.]*"/LABEL csv-version="'"$VERSION"'"/' \
      -e 's/^LABEL release="v[0-9.]*"/LABEL release="v'"$VERSION"'"/' \
      -e 's/^LABEL version="v[0-9.]*"/LABEL version="v'"$VERSION"'"/' \
      bundle.Dockerfile.konflux

    if grep -q "csv-version=\"${VERSION}\"" bundle.Dockerfile.konflux && \
       grep -q "release=\"v${VERSION}\"" bundle.Dockerfile.konflux && \
       grep -q "version=\"v${VERSION}\"" bundle.Dockerfile.konflux; then
      echo "  ✓ bundle.Dockerfile.konflux (3 labels)"
      FILES_UPDATED=$((FILES_UPDATED + 1))
    else
      echo "  ✗ Failed to update bundle.Dockerfile.konflux"
      REPOS_FAILED+=("$REPO:bundle-sed-failed")
      echo ""
      return
    fi
  fi

  # Check if anything actually changed
  if git diff --quiet; then
    echo "  - Already at v$VERSION"
    git checkout - 2>/dev/null
    git branch -D "$FIX_BRANCH" 2>/dev/null || true
    REPOS_SKIPPED+=("$REPO:no-changes")
    echo ""
    return
  fi

  # Commit
  git add -A
  if git commit -s -m "Update version labels to v$VERSION

Enables correct Konflux image tagging via {{ labels.version }}." >/dev/null 2>&1; then
    echo "  ✓ Committed ($FILES_UPDATED file(s))"
    REPOS_UPDATED+=("$REPO#$MAJOR_MINOR#$RELEASE_BRANCH")
  else
    echo "  ✗ Commit failed"
    REPOS_FAILED+=("$REPO:commit-failed")
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
    local gh_user
    gh_user=$(get_gh_user)
    for entry in "${REPOS_UPDATED[@]}"; do
      local repo="${entry%%#*}"
      local rest="${entry#*#}"
      local major_minor="${rest%%#*}"
      local branch="${rest#*#}"
      local path fork fix_branch head_ref
      path="$SUBMARINER_BASE/$repo"
      fix_branch="fix-version-labels-${major_minor}"
      fork="$(fork_remote "$path" "$gh_user")"
      head_ref="$fix_branch"
      [ -n "$gh_user" ] && head_ref="${gh_user}:${fix_branch}"
      echo ""
      echo "# $repo"
      echo "cd $path"
      echo "git show"
      echo "git push $fork $fix_branch"
      echo "PR_URL=\$(gh pr create --base $branch --head $head_ref --title \"Update version labels to v$VERSION\" --body \"Enables correct Konflux image tagging.\" --assignee @me --label ready-to-test)"
      echo "gh pr merge --auto --rebase \"\${PR_URL##*/}\""
      # Append to push summary if conductor is running
      if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
        printf '\n  cd %s\n  git push %s %s\n  PR_URL=$(gh pr create --base %s --head %s --title "Update version labels to v%s" --body "Enables correct Konflux image tagging." --assignee @me --label ready-to-test)\n  gh pr merge --auto --rebase "${PR_URL##*/}"\n' \
          "$path" "$fork" "$fix_branch" "$branch" "$head_ref" "$VERSION" \
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

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  # Only move tracker state on a full run. A filtered (single-repo) run is a manual
  # partial retry: guarding in_progress the same way as completion (below) keeps it
  # from flipping an already-complete step back to in_progress and never restoring it.
  [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] && update_step "$VERSION" "versionLabels" "in_progress" '{}' "$TRACKER"

  update_all

  print_summary

  # Record completion when the full repo set was processed with no failures.
  # "All already correct" (0 updated, 0 failed) is still success — requiring
  # REPOS_UPDATED>0 left the step stuck in_progress on a no-op re-run. A
  # single-repo run (REPO_FILTER) covers only part of the step, so it must not
  # mark the whole step complete.
  # update_step is called AFTER print_summary so that a push-log write failure
  # (inside print_summary) leaves the tracker at 'in_progress' rather than 'complete'.
  # review level: script stays in_progress. User must push the label changes and
  # wait for Konflux to rebuild, then explicitly mark complete.
  if [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] && [ "${#REPOS_FAILED[@]}" -eq 0 ]; then
    local data
    # shellcheck disable=SC2034
    data=$(jq -n --arg count "${#REPOS_UPDATED[@]}" --arg ver "$VERSION" \
      '{reposUpdated:($count|tonumber),version:$ver}' | jq -c .) || data="{}"
  fi
}

main "$@"
