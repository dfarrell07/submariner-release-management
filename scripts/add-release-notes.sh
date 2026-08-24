#!/bin/bash
# Add release notes to component stage release YAML
#
# Usage: add-release-notes.sh <version> [--stage-yaml PATH]
#
# Arguments:
#   version: Submariner version (e.g., 0.22.1 or 0.22)
#   --stage-yaml: Optional path to specific stage YAML file
#
# Exit codes:
#   0: Success (release notes added and committed)
#   1: Failure (prerequisites, queries, or validation failed)

set -euo pipefail

# ============================================================================
# Parse Arguments
# ============================================================================

VERSION=""
STAGE_YAML_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage-yaml)
      [[ $# -lt 2 ]] && { echo "❌ ERROR: --stage-yaml requires a path" >&2; exit 1; }
      STAGE_YAML_ARG="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION="$1"
      else
        echo "Multiple positional arguments not supported" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "❌ ERROR: Version required" >&2
  echo "Usage: $0 <version> [--stage-yaml PATH]" >&2
  exit 1
fi

# ============================================================================
# Source Shared Library
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/lib" && pwd)"

# shellcheck source=lib/release-notes-common.sh
source "$LIB_DIR/release-notes-common.sh"

# Tracker integration
TRACKER_LIB="${TRACKER_LIB:-$LIB_DIR/jira-tracker.sh}"
# shellcheck source=lib/jira-tracker.sh
[ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
[ -n "${TRACKER:-}" ] && update_step "$VERSION" "releaseNotes" "in_progress" '{}' "$TRACKER"

# Check we are on the main branch (release notes must land on main)
_current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$_current_branch" != "main" ]; then
  echo "❌ This repo is on branch '$_current_branch', not 'main'" >&2
  echo "   Fix: git checkout main && git pull" >&2
  exit 1
fi

# ============================================================================
# Main Workflow
# ============================================================================

banner "Add Release Notes for $VERSION"

# Namespace temp files by version so concurrent releases don't corrupt each other.
export RELEASE_NOTES_DATA="${RELEASE_NOTES_DATA:-/tmp/release-notes-${VERSION}-data.json}"
export RELEASE_NOTES_TOPICS="${RELEASE_NOTES_TOPICS:-/tmp/release-notes-${VERSION}-topics.json}"

# Phase 1: Collect raw data from Jira and existing releases
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: Collect raw data"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -n "$STAGE_YAML_ARG" ]]; then
  "$SCRIPT_DIR/release-notes/collect.sh" "$VERSION" --stage-yaml "$STAGE_YAML_ARG"
else
  "$SCRIPT_DIR/release-notes/collect.sh" "$VERSION"
fi

if [[ ! -f "$RELEASE_NOTES_DATA" ]]; then
  echo "❌ ERROR: Phase 1 failed (no data file)" >&2
  exit 1
fi

echo ""

# Phase 2: Filter and group issues
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Filter and group issues"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$SCRIPT_DIR/release-notes/prepare.sh"

if [[ ! -f "$RELEASE_NOTES_TOPICS" ]]; then
  echo "❌ ERROR: Phase 2 failed (no topics file)" >&2
  exit 1
fi

echo ""

# Phase 3: Auto-apply ALL filtered issues to stage YAML
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3: Auto-apply release notes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
"$SCRIPT_DIR/release-notes/auto-apply.sh"

echo ""

# Phase 4: Verify CVE fixes in Clair reports (if CVEs present)
CVE_COUNT=$(jq -r '.cve_topics | length' "$RELEASE_NOTES_TOPICS" 2>/dev/null || echo "0")
if [[ "$CVE_COUNT" -gt 0 ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Phase 4: Verify CVE fixes in snapshot images"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  STAGE_YAML=$(jq -r '.metadata.stage_yaml' "$RELEASE_NOTES_DATA")
  if ! "$SCRIPT_DIR/release-notes/verify-cve-fixes.sh" "$STAGE_YAML"; then
    echo ""
    echo "⚠️  Some CVEs are NOT actually fixed - see verification output above"
    echo "Remove unfixed CVEs from commit: git commit --amend"
    [ -n "${AUTORELEASE_PUSH_LOG:-}" ] && \
      printf '  # WARNING: CVE verification failed — amend before pushing: git commit --amend\n' \
        >> "$AUTORELEASE_PUSH_LOG"
  fi
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Warn before marking complete if no issues were found. Zero issues is
# plausible (a patch with no Jira coverage) but also the signature of an
# untriaged Jira backlog — surface it prominently so the operator reviews
# before pushing the commit.
_notes_cve=$(jq -r '.cve_topics | length' "$RELEASE_NOTES_TOPICS" 2>/dev/null || echo "0")
_notes_non=$(jq -r '.non_cve_topics | length' "$RELEASE_NOTES_TOPICS" 2>/dev/null || echo "0")
if [ "$_notes_cve" -eq 0 ] && [ "$_notes_non" -eq 0 ]; then
  echo "⚠️  WARNING: 0 Jira issues found for $VERSION — Jira may not be triaged yet."
  echo "   Review before pushing: make review-release-notes VERSION=$VERSION"
  echo ""
  [ -n "${AUTORELEASE_PUSH_LOG:-}" ] && \
    printf '  # WARNING: 0 Jira issues found — verify with: make review-release-notes VERSION=%s\n' \
      "$VERSION" >> "$AUTORELEASE_PUSH_LOG"
fi

echo "✅ Release notes workflow complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Record completion
if [ -n "${TRACKER:-}" ]; then
  local_cve_count=$(jq -r '.cve_topics | length' "$RELEASE_NOTES_TOPICS" 2>/dev/null || echo "0")
  # Total issue count lives in topics.json statistics; data.json has no
  # total_issues key, so the old read here always recorded 0.
  local_total=$(jq -r '(.statistics.cve_count + .statistics.non_cve_total)' "$RELEASE_NOTES_TOPICS" 2>/dev/null || echo "0")
  local_type=$( [ "$local_cve_count" -gt 0 ] && echo "RHSA" || echo "RHBA" )
  data=$(jq -n --arg type "$local_type" --arg total "$local_total" --arg cves "$local_cve_count" \
    '{advisoryType:$type,totalIssues:($total|tonumber),cveCount:($cves|tonumber)}' | jq -c .) || data="{}"
  update_step "$VERSION" "releaseNotes" "complete" "$data" "$TRACKER"
fi
