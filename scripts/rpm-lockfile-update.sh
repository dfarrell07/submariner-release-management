#!/bin/bash
# Update RPM lockfiles across Submariner repositories
#
# Usage: rpm-lockfile-update.sh [branch] [repo|component]
#
# branch: Release branch (e.g., 0.21 or release-0.21), default: auto-detect
# repo|component: submariner, shipyard, gateway, globalnet, route-agent, nettest, default: all

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Constants
readonly SUBMARINER_BASE="${HOME}/go/src/submariner-io"
readonly COMPONENT_PATTERN="^(gateway|globalnet|route-agent|nettest)$"
readonly FILTER_PATTERN="^(submariner|shipyard|gateway|globalnet|route-agent|nettest|all)$"
readonly COMMIT_MSG="Regenerate RPM lockfiles for %s

Updated lockfiles to resolve latest package versions."

BRANCH=""
VERSION=""
COMPONENT_FILTER=""
declare -a REPOS_UPDATED=()
declare -a REPOS_SKIPPED=()
declare -a REPOS_FAILED=()

die() {
  echo "❌ $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

check_prerequisites() {
  local MISSING_TOOLS=()

  command -v git &>/dev/null || MISSING_TOOLS+=("git")
  command -v podman &>/dev/null || MISSING_TOOLS+=("podman")
  command -v gh &>/dev/null || MISSING_TOOLS+=("gh")

  [ "${#MISSING_TOOLS[@]}" -gt 0 ] && die "Missing required tools: ${MISSING_TOOLS[*]}"

  [ -z "${BASH_VERSINFO[0]}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] && \
    die "bash 4.0+ required" "macOS: brew install bash"

  ls /etc/pki/entitlement/*.pem &>/dev/null || \
    die "No Red Hat entitlements in /etc/pki/entitlement/" \
        "Setup: https://github.com/submariner-io/shipyard/blob/devel/.rpm-lockfiles/README.md"

  [ -s "${HOME}/.docker/config.json" ] || \
    die "Not authenticated to registry" "Run: podman login registry.redhat.io"

  gh auth status &>/dev/null || \
    die "Not authenticated to GitHub" "Run: gh auth login"

  echo "✓ Prerequisites verified"
}

parse_arguments() {
  local ARG1="${1:-}"
  local ARG2="${2:-}"
  local BRANCH_ARG=""

  [ $# -gt 2 ] && die "Too many arguments"

  COMPONENT_FILTER="all"

  if [ -n "$ARG1" ] && [ -z "$ARG2" ]; then
    if [[ "$ARG1" =~ $FILTER_PATTERN ]]; then
      COMPONENT_FILTER="$ARG1"
    else
      BRANCH_ARG="$ARG1"
    fi
  elif [ -n "$ARG2" ]; then
    BRANCH_ARG="$ARG1"
    [[ ! "$ARG2" =~ $FILTER_PATTERN ]] && \
      die "Invalid repo/component: $ARG2" \
          "Use: submariner, shipyard, gateway, globalnet, route-agent, nettest, or all"
    COMPONENT_FILTER="$ARG2"
  fi

  # Normalize: 0.21 → release-0.21, or accept any branch
  if [ -n "$BRANCH_ARG" ]; then
    case "$BRANCH_ARG" in
      release-*)
        BRANCH="$BRANCH_ARG"
        VERSION="${BRANCH#release-}"
        ;;
      [0-9].[0-9]*)
        VERSION="$BRANCH_ARG"
        BRANCH="release-$(echo "$VERSION" | cut -d. -f1-2)"
        ;;
      *)
        BRANCH="$BRANCH_ARG"
        VERSION="$BRANCH_ARG"
        ;;
    esac
  fi
}

cleanup_empty_branch() {
  local branch="$1" branch_ref="$2" fix_branch="$3"

  git show-ref --verify --quiet "refs/heads/$branch" && \
    git checkout "$branch" >/dev/null 2>&1 || \
    git checkout --detach "$branch_ref" >/dev/null 2>&1
  git branch -D "$fix_branch" >/dev/null 2>&1 || true
}

update_lockfiles() {
  local scope
  case "$COMPONENT_FILTER" in
    submariner|shipyard) scope="all components in $COMPONENT_FILTER" ;;
    gateway|globalnet|route-agent|nettest) scope="$COMPONENT_FILTER component" ;;
    *) scope="all components" ;;
  esac

  if [ -n "$BRANCH" ]; then
    echo "Updating $scope on branch $BRANCH"
  else
    echo "Updating $scope on current branch (auto-detect per repo)"
  fi
  echo ""

  local -a REPOS=()

  case "$COMPONENT_FILTER" in
    submariner|gateway|globalnet|route-agent)
      REPOS+=("$SUBMARINER_BASE/submariner")
      ;;
    shipyard|nettest)
      REPOS+=("$SUBMARINER_BASE/shipyard")
      ;;
    all)
      REPOS+=("$SUBMARINER_BASE/submariner")
      REPOS+=("$SUBMARINER_BASE/shipyard")
      ;;
  esac

  local ORIGINAL_DIR
  ORIGINAL_DIR=$(pwd)

  for REPO_PATH in "${REPOS[@]}"; do
    local REPO_NAME
    REPO_NAME=$(basename "$REPO_PATH")
    local DISPLAY_NAME="$REPO_NAME"
    [[ "$COMPONENT_FILTER" =~ $COMPONENT_PATTERN ]] && DISPLAY_NAME="$COMPONENT_FILTER"

    [ ! -d "$REPO_PATH" ] && { REPOS_SKIPPED+=("$DISPLAY_NAME:repo-not-found"); continue; }
    cd "$REPO_PATH" || { REPOS_FAILED+=("$DISPLAY_NAME:cd-failed"); continue; }

    # Auto-detect branch for this repo if not specified
    local REPO_BRANCH="$BRANCH"
    local REPO_VERSION="$VERSION"
    if [ -z "$REPO_BRANCH" ]; then
      REPO_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ -z "$REPO_BRANCH" ] || [ "$REPO_BRANCH" = "HEAD" ]; then
        REPOS_SKIPPED+=("$DISPLAY_NAME:no-current-branch")
        continue
      fi
      # Derive version from branch name
      case "$REPO_BRANCH" in
        release-*)
          REPO_VERSION="${REPO_BRANCH#release-}"
          ;;
        *)
          REPO_VERSION="$REPO_BRANCH"
          ;;
      esac
    fi

    [ "$DISPLAY_NAME" = "$REPO_NAME" ] && echo "==> $REPO_NAME" || echo "==> $DISPLAY_NAME (in $REPO_NAME)"
    echo "    Branch: $REPO_BRANCH"

    local BRANCH_REF="origin/$REPO_BRANCH"
    git show-ref --verify --quiet "refs/remotes/$BRANCH_REF" || {
      BRANCH_REF="$REPO_BRANCH"
      git show-ref --verify --quiet "refs/heads/$BRANCH_REF" || {
        REPOS_FAILED+=("$DISPLAY_NAME:branch-not-found")
        continue
      }
    }

    git ls-tree -r "$BRANCH_REF" -- .rpm-lockfiles/ 2>/dev/null | grep -q . || \
      { REPOS_SKIPPED+=("$DISPLAY_NAME:no-lockfiles"); continue; }

    local FIX_BRANCH="update-rpm-lockfiles-${REPO_VERSION}"

    git checkout -B "$FIX_BRANCH" "$BRANCH_REF" >/dev/null 2>&1 || \
      { REPOS_FAILED+=("$DISPLAY_NAME:branch-create-failed"); continue; }

    git show "origin/devel:.rpm-lockfiles/update-lockfile.sh" > .rpm-lockfiles/update-lockfile.sh 2>/dev/null || {
      echo "❌ Failed to copy update-lockfile.sh from origin/devel"
      echo "   Run: git fetch origin devel"
      REPOS_FAILED+=("$DISPLAY_NAME:script-copy-failed")
      continue
    }

    chmod +x .rpm-lockfiles/update-lockfile.sh

    # Fix UBI version mismatch: devel script may use ubi10 but release branches use RHEL 9 repos.
    # Detect from repo files and patch the script to match.
    if grep -q 'ubi9\|rhel9' .rpm-lockfiles/*/submariner-rhel-*.repo 2>/dev/null && \
       grep -q 'ubi10' .rpm-lockfiles/update-lockfile.sh; then
      sed -i 's|registry.access.redhat.com/ubi10/ubi:latest|registry.access.redhat.com/ubi9/ubi:latest|g' \
        .rpm-lockfiles/update-lockfile.sh
      echo "    (patched update-lockfile.sh: ubi10 → ubi9 to match branch repo files)"
    fi

    set +e  # Disable errexit to capture exit code and cleanup
    local LOCKFILE_PATTERN _lockfile_log
    _lockfile_log=$(mktemp)
    if [[ "$COMPONENT_FILTER" =~ $COMPONENT_PATTERN ]]; then
      LOCKFILE_PATTERN=".rpm-lockfiles/$COMPONENT_FILTER/rpms.lock.yaml"
      echo "Running: .rpm-lockfiles/update-lockfile.sh $FIX_BRANCH $COMPONENT_FILTER"
      echo ""
      .rpm-lockfiles/update-lockfile.sh "$FIX_BRANCH" "$COMPONENT_FILTER" > "$_lockfile_log" 2>&1
    else
      LOCKFILE_PATTERN=".rpm-lockfiles/*/rpms.lock.yaml"
      echo "Running: .rpm-lockfiles/update-lockfile.sh $FIX_BRANCH"
      echo ""
      .rpm-lockfiles/update-lockfile.sh "$FIX_BRANCH" > "$_lockfile_log" 2>&1
    fi
    local LOCKFILE_EXIT=$?
    # Show status lines and "No sources" warnings; suppress dnf/pip/skopeo setup noise
    # and update-lockfile.sh's own manual-use "To commit/To push" instructions.
    grep -E '^(--- |WARNING:rpm_lockfile: No sources)' "$_lockfile_log" || true
    # On failure, dump the full log so the problem is diagnosable.
    [ "$LOCKFILE_EXIT" -ne 0 ] && cat "$_lockfile_log" >&2
    rm -f "$_lockfile_log"
    set -e
    rm -f .rpm-lockfiles/update-lockfile.sh

    if [ $LOCKFILE_EXIT -ne 0 ]; then
      REPOS_FAILED+=("$DISPLAY_NAME:update-script-failed")
    elif git diff --quiet $LOCKFILE_PATTERN 2>/dev/null; then
      cleanup_empty_branch "$REPO_BRANCH" "$BRANCH_REF" "$FIX_BRANCH"
      REPOS_SKIPPED+=("$DISPLAY_NAME:no-changes")
    else
      # shellcheck disable=SC2086
      git add $LOCKFILE_PATTERN || {
        REPOS_FAILED+=("$DISPLAY_NAME:stage-failed")
        continue
      }

      # shellcheck disable=SC2059
      git commit -s -m "$(printf "$COMMIT_MSG" "$REPO_BRANCH")" || {
        REPOS_FAILED+=("$DISPLAY_NAME:commit-failed")
        continue
      }

      echo "✓ Committed lockfile changes"
      REPOS_UPDATED+=("$DISPLAY_NAME#$REPO_NAME#$REPO_VERSION#$REPO_BRANCH")
    fi
  done

  cd "$ORIGINAL_DIR"
}

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
      local display="${entry%%#*}"
      local rest="${entry#*#}"
      local repo="${rest%%#*}"
      rest="${rest#*#}"
      local version="${rest%%#*}"
      local branch="${rest#*#}"
      local fix_branch="update-rpm-lockfiles-${version}"
      local fork head_ref
      fork=$(fork_remote "$SUBMARINER_BASE/$repo" "$gh_user")
      head_ref="$fix_branch"
      [ -n "$gh_user" ] && head_ref="${gh_user}:${fix_branch}"
      echo ""
      echo "# $display"
      echo "cd $SUBMARINER_BASE/$repo"
      echo "git show"
      # --force-with-lease is safe for a re-run (idempotent if the remote matches
      # our last fetch), and required if the branch was already pushed and the
      # conductor re-ran after a silent tracker write failure.
      echo "git push --force-with-lease $fork $fix_branch"
      # gh pr merge needs the PR number (branch name fails for fork PRs); capture from gh pr create output.
      echo "PR_URL=\$(gh pr create --base $branch --head $head_ref --title \"Update RPM lockfiles for v${version}\" --body \"Update RPM lockfiles to resolve package CVEs.\" --assignee @me --label ready-to-test)"
      echo "gh pr merge --auto --rebase \"\${PR_URL##*/}\""
      # Append to push summary if conductor is running
      if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
        printf '\n  cd %s/%s\n  git push --force-with-lease %s %s\n  PR_URL=$(gh pr create --base %s --head %s --title "Update RPM lockfiles for v%s" --body "Update RPM lockfiles to resolve package CVEs." --assignee @me --label ready-to-test)\n  gh pr merge --auto --rebase "${PR_URL##*/}"\n' \
          "$SUBMARINER_BASE" "$repo" "$fork" "$fix_branch" "$branch" "$head_ref" "$version" \
          >> "$AUTORELEASE_PUSH_LOG"
      fi
    done
  fi

  echo ""
  [ "$FAILED_COUNT" -eq 0 ]
}

main() {
  check_prerequisites
  parse_arguments "$@"

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  # shellcheck source=lib/git-utils.sh
  [ -f "$SCRIPT_DIR/lib/git-utils.sh" ] && source "$SCRIPT_DIR/lib/git-utils.sh" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  # Only move tracker state on a full run. A filtered (single-component) run is a manual
  # partial retry: guarding in_progress the same way as completion (below) keeps it
  # from flipping an already-complete step back to in_progress and never restoring it.
  [ -n "${TRACKER:-}" ] && [ "$COMPONENT_FILTER" = "all" ] && update_step "$VERSION" "rpmLockfiles" "in_progress" '{}' "$TRACKER"

  update_lockfiles

  # Record completion only for a full run (COMPONENT_FILTER=all) with no
  # failures and no problem-skips. Benign skips — no-changes (already current)
  # and no-lockfiles (repo has none) — still count as done, so an all-current
  # re-run completes. But repo-not-found / no-current-branch mean a repo could
  # not be processed (problem-skips); branch-not-found is a hard failure
  # (REPOS_FAILED). A single-component run must not complete the whole step.
  local problem_skips=0 skip_entry
  if [ "${#REPOS_SKIPPED[@]}" -gt 0 ]; then
    for skip_entry in "${REPOS_SKIPPED[@]}"; do
      case "${skip_entry##*:}" in
        no-changes|no-lockfiles) ;;
        *) problem_skips=$((problem_skips + 1)) ;;
      esac
    done
  fi

  print_summary

  # review level: script stays in_progress. User must push the lockfile changes and
  # wait for Konflux to rebuild, then explicitly mark complete via autorelease verifier.
}

main "$@"
