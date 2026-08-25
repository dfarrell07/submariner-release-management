#!/bin/bash
# Update FBC catalog template with production bundle URLs after prod releases complete
#
# Usage: update-fbc-prod-urls.sh <version>
#
# After prod FBC releases complete, the bundle images in the FBC catalog template
# are still using temporary quay.io workspace URLs. This script converts them to
# permanent registry.redhat.io URLs by running `make update-bundle` in the FBC repo,
# which auto-audits which bundles have been released and converts them.
#
# The conversion happens automatically via the FBC repo's update-bundle.sh script:
# - audit_bundle_urls() checks which bundles exist at registry.redhat.io
# - convert_released_bundles() updates catalog-template.yaml with prod URLs
set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source jira-tracker.sh early to provide FBC_REPO_DEFAULT before we use it below.
# The include guard makes the later tracker-integration source a no-op.
TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
# shellcheck source=lib/jira-tracker.sh
[ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true

usage() { echo "Usage: $0 <version>" >&2; }

VERSION="${1:-}"
[ -z "$VERSION" ] && { usage; exit 1; }

# FBC_REPO_DEFAULT is the canonical path defined once in lib/jira-tracker.sh.
FBC_REPO="${FBC_REPO:-$FBC_REPO_DEFAULT}"
[ -d "$FBC_REPO" ] || {
  echo "❌ FBC repo not found at $FBC_REPO" >&2
  echo "   Clone: gh repo clone stolostron/submariner-operator-fbc $FBC_REPO" >&2
  exit 1
}

# Fail early with a friendly message if not authenticated (make update-bundle
# queries the prod registry). Read-only check — never mutates the cluster.
if ! oc auth can-i get namespaces &>/dev/null; then
  echo "❌ ERROR: Not logged into Konflux cluster" >&2
  echo "   Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/" >&2
  exit 1
fi

# Tracker integration
TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
# shellcheck source=/dev/null
[ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
# Mark step as in_progress; verifier will check actual completion once FBC rebuild finishes
[ -n "${TRACKER:-}" ] && update_step "$VERSION" "fbcProdUrls" "in_progress" '{}' "$TRACKER"

cd "$FBC_REPO"

# Pre-flight: verify prod FBC releases completed before we run make update-bundle.
# The FBC release pipeline must have succeeded to ensure the bundle is live in the
# prod operator index. If not yet succeeded, running update-bundle may find the
# bundle in the workspace build but not in the prod registry, leaving quay.io URLs.
if [ -n "${TRACKER:-}" ]; then
  # Get the latest prod FBC release for any OCP version to check prod pipeline status.
  # We check fbcProdReleases (which covers all OCP versions); any one being Succeeded
  # indicates the FBC prod releases are complete. We don't check individual OCP version
  # releases since they're symmetric — all succeed or all fail together.
  _prod_data=$(get_step "$VERSION" "fbcProdReleases" "$TRACKER" 2>/dev/null) || _prod_data=""
  _latest_snapshot=$(printf '%s' "$_prod_data" | jq -r '.snapshot // empty' 2>/dev/null) || _latest_snapshot=""

  if [ -n "$_latest_snapshot" ]; then
    # Sanity check: the snapshot should exist (means fbcProdReleases was applied)
    # We don't strictly require it to have completed yet — the verifier will check that.
    # But if no snapshot was recorded at all, that's suspicious.
    echo "ℹ️  FBC prod releases snapshot: $_latest_snapshot" >&2
  else
    echo "⚠️  Could not find fbcProdReleases snapshot from tracker." >&2
    echo "   Confirm prod FBC releases have been applied before running this step." >&2
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

echo "Running: make update-bundle VERSION=$VERSION" >&2
echo "(This auto-audits bundle URLs and converts quay.io → registry.redhat.io for released bundles)" >&2
echo "" >&2
make update-bundle VERSION="$VERSION"

echo "" >&2
echo "Running: make build-catalogs" >&2
make build-catalogs

echo "" >&2

# Commit if there are changes (audit_bundle_urls + convert_released_bundles may have made edits)
if git diff --quiet && git diff --cached --quiet; then
  echo "ℹ️  No changes (all bundles already use prod URLs or are unreleased)" >&2
else
  git add catalog-template.yaml catalog-*/
  git commit -s -m "Update FBC catalog prod URLs for Submariner $VERSION"
  echo "✓ Committed FBC prod URL conversion" >&2

  # Push summary. The rebuild wait (~15-30 min) is surfaced here so it appears
  # in the conductor's Pending Actions trailer alongside the push command.
  # Only emit when a commit was actually created.
  if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
    _branch=$(git rev-parse --abbrev-ref HEAD)
    printf '\n  cd %s\n  git push origin %s\n  # Wait ~15-30 min for FBC rebuild before re-running\n' \
      "$FBC_REPO" "$_branch" >> "$AUTORELEASE_PUSH_LOG"
  fi
fi

# Do NOT mark completion here — the verifier (verify_fbcProdUrls) is the authoritative
# source. The verifier will check if the conversion actually happened by inspecting
# catalog-template.yaml for registry.redhat.io URLs.
#
# If bundles are unreleased (still at quay.io), that's okay — the conversion will
# happen in a future release cycle. The verifier returns incomplete until then.
# If bundles are released, the conversion happens automatically and the next re-run's
# verifier will pass, allowing the release to close.

echo "" >&2
echo "Next steps:" >&2
echo "  1. Review: git show" >&2
echo "  2. Push: git push origin $(git rev-parse --abbrev-ref HEAD)" >&2
echo "  3. Wait for FBC rebuild (~15-30 min)" >&2
echo "  4. Re-run: /autorelease $VERSION" >&2
echo "     - Verifier will check if conversion completed" >&2
echo "     - If complete and bundle in prod index: release closes" >&2
echo "     - If incomplete: step remains, conversion may happen next release" >&2
