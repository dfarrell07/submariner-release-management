#!/bin/bash
# Fan-out wrapper: run konflux-component-setup.sh for all 8 Submariner components
#
# Usage: tekton-component-setup.sh <version>
#
# Invoked by the autorelease conductor for the tektonComponents step (Y-stream only).
# Iterates all 8 (repo, component) pairs. For each: attempts git fetch origin (best-
# effort — expected to fail when yubikey is not present; falls through to local state
# so the inner script can still find a locally-checked-out bot/release branch).
#
# Exit codes:
#   0: all components succeeded (updated or already done)
#   1: one or more components failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMARINER_BASE="$HOME/go/src/submariner-io"

# shellcheck source=lib/git-utils.sh
source "$SCRIPT_DIR/lib/git-utils.sh" 2>/dev/null || true

# ━━━ COMPONENT PAIRS ━━━
# Format: "repo:component"
readonly COMPONENT_PAIRS=(
  "submariner-operator:submariner-operator"
  "submariner:submariner-gateway"
  "submariner:submariner-globalnet"
  "submariner:submariner-route-agent"
  "lighthouse:lighthouse-agent"
  "lighthouse:lighthouse-coredns"
  "shipyard:nettest"
  "subctl:subctl"
)

# ━━━ GLOBALS ━━━
VERSION=""
MAJOR_MINOR=""
RELEASE_BRANCH=""
COMPONENT_FILTER=""

declare -a COMPS_UPDATED=()
declare -a COMPS_FAILED=()

die() {
  echo "❌ ERROR: $1" >&2
  [ -n "${2:-}" ] && echo "$2" >&2
  exit 1
}

# ━━━ BOT PRECONDITION ━━━
# Check that Konflux bot has already created tekton config PR branches on
# submariner-io/submariner-operator. These branches are created automatically
# after configureDownstream merges. Running before they exist produces
# confusing failures deep inside konflux-component-setup.sh.
check_bot_branches() {
  local major_minor="$1"
  local dash_ver="${major_minor//./-}"   # 0.25 → 0-25

  # Skip the check when gh is not available (e.g. CI/test environments).
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi

  local branches
  branches=$(gh api --paginate repos/submariner-io/submariner-operator/branches \
    --jq '.[].name' 2>/dev/null) || {
    # Network/auth failure — don't block, inner script will surface the real error.
    echo "  ⚠ Could not reach GitHub to verify bot branches (gh auth/network) — continuing" >&2
    return 0
  }

  # Bot branches follow the pattern "konflux-<component>-<major>-<minor>"
  # e.g. konflux-submariner-operator-0-25
  if echo "$branches" | grep -q "^konflux-.*-${dash_ver}$"; then
    return 0
  fi

  echo "" >&2
  echo "❌ Tekton config PR branches not found for ${major_minor}." >&2
  echo "" >&2
  echo "   These branches are created automatically by the Konflux bot after" >&2
  echo "   the configureDownstream step (ReleasePlan) merges into" >&2
  echo "   konflux-release-data. The bot detects the new release-${major_minor}" >&2
  echo "   branches and opens tekton-config PR branches within a few minutes." >&2
  echo "" >&2
  echo "   Check whether the branches exist yet:" >&2
  echo "     gh api --paginate repos/submariner-io/submariner-operator/branches --jq '.[].name' | grep '^konflux-'" >&2
  echo "" >&2
  echo "   If the branches are missing, wait for the bot or verify that" >&2
  echo "   configureDownstream completed successfully, then re-run:" >&2
  echo "     /autorelease $major_minor" >&2
  return 1
}

# ━━━ ARGUMENTS ━━━

parse_arguments() {
  local VERSION_ARG="${1:-}"
  local COMP_ARG="${2:-}"

  if [ -z "$VERSION_ARG" ]; then
    echo "Usage: $0 <version> [component]" >&2
    echo "Example: $0 0.25.0" >&2
    echo "Example: $0 0.25.0 submariner-operator  # single component retry" >&2
    exit 1
  fi

  if ! [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid version: $VERSION_ARG" "Expected X.Y.Z (e.g., 0.25.0)"
  fi

  VERSION="$VERSION_ARG"
  MAJOR_MINOR="${VERSION%.*}"          # 0.25.0 → 0.25
  RELEASE_BRANCH="release-${MAJOR_MINOR}"
  COMPONENT_FILTER="${COMP_ARG:-}"

  if [ -n "$COMPONENT_FILTER" ]; then
    local found=0
    for pair in "${COMPONENT_PAIRS[@]}"; do
      [ "${pair#*:}" = "$COMPONENT_FILTER" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
      local known
      known=$(printf '%s\n' "${COMPONENT_PAIRS[@]}" | sed 's/.*://' | tr '\n' ' ')
      die "Unknown component: $COMPONENT_FILTER" "Known components: $known"
    fi
  fi

  echo ""
  echo "============================================"
  echo "Tekton Component Setup"
  echo "============================================"
  echo "Version: $VERSION  →  Y-stream $MAJOR_MINOR"
  echo "Branch:  $RELEASE_BRANCH"
  if [ -n "$COMPONENT_FILTER" ]; then
    echo "Filter:  $COMPONENT_FILTER (single-component retry)"
  else
    echo "Components: all 8"
  fi
  echo ""
}

# ━━━ PER-COMPONENT PROCESSING ━━━

process_component() {
  local REPO="$1"
  local COMPONENT="$2"
  local REPO_PATH="$SUBMARINER_BASE/$REPO"

  echo "━━━ $REPO / $COMPONENT ━━━"

  if [ ! -d "$REPO_PATH" ]; then
    echo "  ✗ Repo not found: $REPO_PATH" >&2
    COMPS_FAILED+=("$REPO:$COMPONENT:repo-not-found")
    echo ""
    return
  fi

  # Best-effort fetch: populates local tracking refs so the inner script can find
  # the bot branch or release branch. Expected to fail when yubikey is not present;
  # falls through to whatever is already in local state.
  local fetch_rc=0
  git -C "$REPO_PATH" fetch origin "$RELEASE_BRANCH" \
    "refs/heads/konflux-${COMPONENT}-${MAJOR_MINOR//./-}:refs/heads/konflux-${COMPONENT}-${MAJOR_MINOR//./-}" \
    2>/dev/null || fetch_rc=$?
  if [ "$fetch_rc" -ne 0 ]; then
    echo "  ⚠ fetch failed (yubikey absent or network error) — inner script will fall back to local state" >&2
  fi

  # Run the inner script (all output goes to stderr so conductor captures it).
  local inner_exit=0
  "$SCRIPT_DIR/konflux-component-setup.sh" \
    "$REPO" "$COMPONENT" "$MAJOR_MINOR" >&2 || inner_exit=$?

  if [ "$inner_exit" -ne 0 ]; then
    echo "  ✗ konflux-component-setup.sh exited $inner_exit for $REPO/$COMPONENT" >&2
    COMPS_FAILED+=("$REPO:$COMPONENT:setup-failed")
    echo ""
    return
  fi

  # Capture the branch the inner script left the repo on (for push log).
  local active_branch
  active_branch=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

  echo "  ✓ $REPO/$COMPONENT (branch: $active_branch)" >&2
  COMPS_UPDATED+=("$REPO:$COMPONENT:$active_branch")

  # Append push command to conductor push log.
  if [ -n "${AUTORELEASE_PUSH_LOG:-}" ] && [ -n "$active_branch" ]; then
    local _gh_user _fork
    _gh_user=$(get_gh_user)
    _fork=$(fork_remote "$REPO_PATH" "$_gh_user")
    printf '\n  cd %s\n  git push %s %s\n' \
      "$REPO_PATH" "$_fork" "$active_branch" >> "$AUTORELEASE_PUSH_LOG"
  fi

  echo ""
}

process_all() {
  for pair in "${COMPONENT_PAIRS[@]}"; do
    local repo="${pair%%:*}"
    local component="${pair#*:}"

    if [ -n "$COMPONENT_FILTER" ] && [ "$component" != "$COMPONENT_FILTER" ]; then
      continue
    fi

    process_component "$repo" "$component"
  done
}

# ━━━ SUMMARY ━━━

print_summary() {
  local FAILED=${#COMPS_FAILED[@]}

  echo ""
  echo "Summary"

  if [ "${#COMPS_UPDATED[@]}" -gt 0 ]; then
    echo ""
    echo "Updated (${#COMPS_UPDATED[@]}):"
    for e in "${COMPS_UPDATED[@]}"; do
      local pair="${e%:*}"   # strip trailing :branch
      echo "  ✓ ${pair%%:*}/${pair#*:}"
    done
  fi

  if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "Failed ($FAILED):"
    for e in "${COMPS_FAILED[@]}"; do
      local pair="${e%:*}"
      echo "  ✗ ${pair%%:*}/${pair#*:} (${e##*:})"
    done
    echo ""
    echo "Fix failures then re-run: /autorelease $VERSION"
    echo "Or for a single retry:   $0 $VERSION <component>"
    return 1
  fi

  if [ "${#COMPS_UPDATED[@]}" -gt 0 ]; then
    echo ""
    echo "Next: review each branch (git show) then push (see Pending Actions below)"
  fi

  return 0
}

# ━━━ MAIN ━━━

main() {
  parse_arguments "$@"

  # Fail early with a human-readable message if bot branches not yet created.
  # Always run this check, including single-component (filtered) invocations, so
  # that a user who passes a component filter before bot branches exist still gets
  # the helpful error rather than a confusing failure deep in
  # konflux-component-setup.sh.
  #
  # NOTE: This checks only submariner-operator as a proxy for all 5 repos.
  # A partial bot run (branches on some repos but not all) will pass this
  # check and may fail later in the per-repo setup. Full 5-repo checking
  # would require querying all repos individually.
  check_bot_branches "$MAJOR_MINOR" || exit 1

  # Tracker integration (sourced via TRACKER_LIB set by conductor, or default path).
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)

  # Mark in_progress only on a full (unfiltered) run.
  [ -n "${TRACKER:-}" ] && [ -z "$COMPONENT_FILTER" ] && \
    update_step "$VERSION" "tektonComponents" "in_progress" '{}' "$TRACKER"

  process_all

  # Mark complete only when the full set ran with no failures.
  if [ -n "${TRACKER:-}" ] && [ -z "$COMPONENT_FILTER" ] && [ "${#COMPS_FAILED[@]}" -eq 0 ]; then
    local data
    # shellcheck disable=SC2034
    data=$(jq -n \
      --arg count "${#COMPS_UPDATED[@]}" \
      --arg ver "$VERSION" \
      '{componentsUpdated:($count|tonumber),version:$ver}' | jq -c .) || data="{}"
  fi

  print_summary
}

if [ "${_TEKTON_COMPONENT_SETUP_TESTING:-}" != "true" ]; then
  main "$@"
fi
