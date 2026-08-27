#!/bin/bash
# Update FBC catalog with bundle from Konflux snapshot
#
# Usage: fbc-catalog-update.sh <version> [--snapshot <name>] [--replace <old-version>]
#
# Thin wrapper around the FBC repo's make update-bundle + build-catalogs.
# The FBC repo scripts handle all snapshot queries and template updates.
# --snapshot / --replace are forwarded to `make update-bundle` for the explicit
# snapshot and REPLACE scenarios; make ignores them when unset.
set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source jira-tracker.sh early to provide FBC_REPO_DEFAULT before we use it
# below. The include guard makes the later tracker-integration source a no-op.
TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
# shellcheck source=lib/jira-tracker.sh
[ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
# shellcheck source=lib/git-utils.sh
source "$SCRIPT_DIR/lib/git-utils.sh" 2>/dev/null || true

usage() { echo "Usage: $0 <version> [--snapshot <name>] [--replace <old-version>]" >&2; }

VERSION=""
SNAPSHOT=""
REPLACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) SNAPSHOT="${2:-}"; shift 2 ;;
    --replace)  REPLACE="${2:-}";  shift 2 ;;
    -*)         echo "❌ ERROR: Unknown flag: $1" >&2; usage; exit 1 ;;
    *)          VERSION="$1"; shift ;;
  esac
done
[ -z "$VERSION" ] && { usage; exit 1; }

# FBC_REPO_DEFAULT is the canonical path defined once in lib/jira-tracker.sh.
FBC_REPO="${FBC_REPO:-$FBC_REPO_DEFAULT}"
[ -d "$FBC_REPO" ] || { echo "❌ FBC repo not found at $FBC_REPO" >&2; echo "   Clone: gh repo clone stolostron/submariner-operator-fbc $FBC_REPO" >&2; exit 1; }

# Fail early with a friendly message if not authenticated (make update-bundle
# queries Konflux snapshots). Read-only check — never mutates the cluster.
if ! oc auth can-i get snapshots -n submariner-tenant &>/dev/null; then
  echo "❌ ERROR: Not logged into Konflux cluster" >&2
  echo "   Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/" >&2
  exit 1
fi

# Tracker integration
TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
# shellcheck source=/dev/null
[ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
[ -n "${TRACKER:-}" ] && update_step "$VERSION" "fbcCatalogUpdate" "in_progress" '{}' "$TRACKER"

cd "$FBC_REPO"

# Pre-flight: the stage release pipeline must be Succeeded before we run
# make update-bundle. The bundle URL written by the stage release pipeline
# is what update-bundle pulls from the registry; running it before the
# pipeline succeeds produces a 'not found' error or picks up a stale image.
if [ -n "${TRACKER:-}" ]; then
  _stage_data=$(get_step "$VERSION" "componentStage" "$TRACKER" 2>/dev/null) || _stage_data=""
  _stage_rel=$(printf '%s' "$_stage_data" | jq -r '.data.releaseName // empty' 2>/dev/null) || _stage_rel=""
  if [ -n "$_stage_rel" ]; then
    _stage_status=$(oc get release "$_stage_rel" -n submariner-tenant \
      -o jsonpath='{.status.conditions[?(@.type=="Released")].status}' 2>/dev/null || true)
    if [ "$_stage_status" != "True" ]; then
      echo "❌ Stage release pipeline not yet Succeeded (status: ${_stage_status:-unknown})" >&2
      echo "   Apply and watch the stage release first:" >&2
      echo "   make apply FILE=<stage-yaml>  &&  make watch NAME=$_stage_rel" >&2
      exit 1
    fi
    echo "✓ Stage release pipeline succeeded: $_stage_rel" >&2
  else
    echo "⚠️  Could not verify stage pipeline from tracker (no releaseName recorded)." >&2
    echo "   Confirm make apply + make watch succeeded for the stage release." >&2
  fi
fi

_current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$_current_branch" != "main" ]; then
  echo "❌ FBC repo is on branch '$_current_branch', not 'main'" >&2
  echo "   Fix: cd $FBC_REPO && git checkout main && git pull" >&2
  exit 1
fi

# Verify clean working tree
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  echo "⚠️  FBC repo has uncommitted changes" >&2
  git status --short >&2
fi

MAKE_ARGS=(VERSION="$VERSION")
[ -n "$SNAPSHOT" ] && MAKE_ARGS+=(SNAPSHOT="$SNAPSHOT")
[ -n "$REPLACE" ] && MAKE_ARGS+=(REPLACE="$REPLACE")
echo "Running: make update-bundle ${MAKE_ARGS[*]}" >&2
make update-bundle "${MAKE_ARGS[@]}"

echo "" >&2
echo "Running: make build-catalogs" >&2
make build-catalogs

echo "" >&2

# Resolve fork remote once for both push-log and next-steps output
_gh_user=$(get_gh_user)
_fork=$(fork_remote "$FBC_REPO" "$_gh_user")
_cur_branch=$(git rev-parse --abbrev-ref HEAD)

# Commit if there are changes
if git diff --quiet && git diff --cached --quiet; then
  echo "ℹ️  No changes (catalog already up to date)" >&2
else
  git add catalog-template.yaml catalog-*/
  git commit -s -m "Update FBC catalog for Submariner $VERSION"
  echo "✓ Committed FBC catalog update" >&2

  # Push summary. The rebuild wait (~15-30 min) is surfaced here so it appears
  # in the conductor's Pending Actions trailer alongside the push command.
  # Only emit when a commit was actually created (matches bundle-image-update.sh pattern).
  if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
    printf '\n  cd %s\n  git push %s %s\n  # Wait ~15-30 min for FBC rebuild before re-running\n' \
      "$FBC_REPO" "$_fork" "$_cur_branch" >> "$AUTORELEASE_PUSH_LOG"
  fi
fi

# review level: script stays in_progress. User must push the catalog update and
# wait for the FBC rebuild (~15-30 min), then explicitly mark complete.
if [ -n "${TRACKER:-}" ]; then
  _data=$(snapshot_step_data "$VERSION" "$TRACKER")
fi
echo "" >&2
echo "Next steps:" >&2
echo "  1. Review: git show" >&2
echo "  2. Push: git push $_fork $_cur_branch" >&2
echo "  3. Wait for FBC rebuild (~15-30 min)" >&2
