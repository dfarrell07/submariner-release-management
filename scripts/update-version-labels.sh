#!/bin/bash
# Update Konflux Dockerfile version labels across Submariner repositories
#
# Usage: update-version-labels.sh <version> [repo]
#
# Arguments:
#   version: Target release version (e.g., 0.23.1)
#   repo:    Optional repo filter (submariner-operator, submariner, lighthouse, shipyard, subctl)
#
# Updates labels and compiled versions in 8 component Dockerfiles across 5 repos.
# Bundle labels are updated with the CSV by bundle-image-update.sh.
#
# Exit codes:
#   0: Success (at least one repo updated, or all already correct)
#   1: Failure (prerequisites, validation, or update failed)

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/git-utils.sh
source "$SCRIPT_DIR/lib/git-utils.sh" 2>/dev/null || true
# shellcheck source=lib/dockerfile-version.sh
source "$SCRIPT_DIR/lib/dockerfile-version.sh"

# ━━━ CONSTANTS ━━━

readonly SUBMARINER_BASE="${SUBMARINER_BASE:-$HOME/go/src/submariner-io}"

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
    if [ -z "${COMPONENT_DOCKERFILES[$REPO_ARG]+x}" ]; then
      die "Unknown repo: $REPO_ARG" \
          "Valid repos: ${COMPONENT_VERSION_REPOS}"
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

restore_original_ref() {
  restore_clean_ref "$1"
}

update_repo() {
  local REPO="$1"
  local REPO_PATH="$SUBMARINER_BASE/$REPO"
  local -a DOCKERFILES
  read -ra DOCKERFILES <<< "${COMPONENT_DOCKERFILES[$REPO]}"
  local FIX_BRANCH="fix-version-labels-${VERSION}"

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

  local initial_status
  if ! initial_status=$(git status --porcelain --untracked-files=all) || [ -n "$initial_status" ]; then
    echo "  ✗ Cannot safely switch $REPO_PATH; commit or stash local changes first." >&2
    REPOS_FAILED+=("$REPO:dirty-tree")
    return
  fi

  git fetch origin || {
    REPOS_FAILED+=("$REPO:fetch-failed")
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

  # Remember where the repo was so we can restore it after committing.
  local ORIGINAL_REF
  ORIGINAL_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$ORIGINAL_REF" ] || [ "$ORIGINAL_REF" = "HEAD" ]; then
    ORIGINAL_REF="$(git rev-parse HEAD 2>/dev/null || true)"
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
  local has_binary=true
  [ "$REPO" != shipyard ] || has_binary=false
  for FILE in "${DOCKERFILES[@]}"; do
    if [ ! -f "$FILE" ]; then
      echo "  ✗ File not found: $FILE"
      REPOS_FAILED+=("$REPO:file-not-found")
      restore_original_ref "$ORIGINAL_REF" || true  # failure already recorded
      echo ""
      return
    fi

    if set_component_version "$FILE" "$VERSION" "$has_binary"; then
      echo "  ✓ $FILE"
      FILES_UPDATED=$((FILES_UPDATED + 1))
    else
      echo "  ✗ Failed to align image and compiled versions in $FILE"
      REPOS_FAILED+=("$REPO:version-update-failed")
      restore_original_ref "$ORIGINAL_REF" || true  # failure already recorded
      echo ""
      return
    fi
  done

  # Check if anything actually changed
  if git diff --quiet; then
    echo "  - Already at v$VERSION"
    if ! restore_original_ref "$ORIGINAL_REF"; then
      REPOS_FAILED+=("$REPO:restore-failed")
      echo ""
      return
    fi
    git branch -D "$FIX_BRANCH" 2>/dev/null || true
    REPOS_SKIPPED+=("$REPO:no-changes")
    echo ""
    return
  fi

  # Commit
  # Branch changes can expose local files ignored only on the original ref.
  if ! git add -- "${DOCKERFILES[@]}"; then
    REPOS_FAILED+=("$REPO:stage-failed")
    restore_original_ref "$ORIGINAL_REF" || true  # failure already recorded
    return
  fi
  if git commit -s -m "Align component versions to v$VERSION

Match image labels and compiled Go versions, preserving source branch inputs." >/dev/null 2>&1; then
    echo "  ✓ Committed ($FILES_UPDATED file(s))"
    REPOS_UPDATED+=("$REPO#$VERSION#$RELEASE_BRANCH")
  else
    echo "  ✗ Commit failed"
    REPOS_FAILED+=("$REPO:commit-failed")
    restore_original_ref "$ORIGINAL_REF" || true  # failure already recorded
    echo ""
    return
  fi

  # Restore original branch so later steps don't find the repo on a stray branch.
  if ! restore_original_ref "$ORIGINAL_REF"; then
    REPOS_FAILED+=("$REPO:restore-failed")
  fi

  echo ""
}

update_all() {
  local ORIGINAL_DIR
  ORIGINAL_DIR=$(pwd)

  for REPO in $COMPONENT_VERSION_REPOS; do
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
      local version="${rest%%#*}"
      local branch="${rest#*#}"
      local path fork fix_branch head_ref
      path="$SUBMARINER_BASE/$repo"
      fix_branch="fix-version-labels-${version}"
      fork="$(fork_remote "$path" "$gh_user")"
      head_ref="$fix_branch"
      [ -n "$gh_user" ] && head_ref="${gh_user}:${fix_branch}"
      echo ""
      echo "# $repo"
      printf 'git -C %q show %q\n' "$path" "$fix_branch"
      local pr_filter push_commands
      pr_filter="[.[] | select(.headRepositoryOwner.login == \"$gh_user\")] | .[0].url // empty"
      printf -v push_commands '\n  cd %q\n  git push --force-with-lease %q %q\n  PR_URL=$(gh pr list --base %q --head %q --state open --json url,headRepositoryOwner --jq %q)\n  if [ -z "$PR_URL" ]; then\n    PR_URL=$(gh pr create --base %q --head %q --title %q --body %q --assignee @me --label ready-to-test)\n  fi\n  gh pr merge --auto --rebase "${PR_URL##*/}"\n' \
        "$path" "$fork" "$fix_branch" "$branch" "$fix_branch" "$pr_filter" \
        "$branch" "$head_ref" "Align component versions to v${version}" \
        "Align image labels and compiled Go versions. Bundle labels follow CSV regeneration."
      printf '%s' "$push_commands"
      # Append to push summary if conductor is running
      if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
        printf '%s' "$push_commands" >> "$AUTORELEASE_PUSH_LOG"
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

  # A full no-op verified every label on the freshly fetched release branches.
  # Changed repos remain in_progress until their PRs merge.
  if [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] &&
     [ "${#REPOS_UPDATED[@]}" -eq 0 ] && [ "${#REPOS_FAILED[@]}" -eq 0 ]; then
    local data
    data=$(jq -n --arg count "${#REPOS_UPDATED[@]}" --arg ver "$VERSION" \
      '{reposUpdated:($count|tonumber),version:$ver}' | jq -c .) || data="{}"
    update_step "$VERSION" "versionLabels" "complete" "$data" "$TRACKER"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
