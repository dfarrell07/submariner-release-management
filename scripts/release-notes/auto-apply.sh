#!/bin/bash
# Phase 3: Auto-apply ALL filtered issues to stage YAML
# Input: ${RELEASE_NOTES_TOPICS:-/tmp/release-notes-topics.json}, ${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}
# Output: Updated stage YAML + git commit
set -euo pipefail

# ============================================================================
# Initialize
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=../lib/release-notes-common.sh
source "$LIB_DIR/release-notes-common.sh"

TOPICS_JSON="${RELEASE_NOTES_TOPICS:-/tmp/release-notes-topics.json}"
DATA_JSON="${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}"

if [[ ! -f "$TOPICS_JSON" ]]; then
  echo "❌ ERROR: Topics file not found: '$TOPICS_JSON'" >&2
  echo "Run prepare.sh first" >&2
  exit 1
fi

if [[ ! -f "$DATA_JSON" ]]; then
  echo "❌ ERROR: Data file not found: '$DATA_JSON'" >&2
  echo "Run collect.sh first" >&2
  exit 1
fi

FORCE="${FORCE:-false}"

banner "Auto-Apply ALL Filtered Issues to Stage YAML"

extract_and_validate_metadata "$DATA_JSON"

# Check if YAML already has populated release notes (not just placeholder)
EXISTING_ISSUES=$(grep -c "id: ACM-" "$STAGE_YAML" 2>/dev/null || true)
if [[ "$EXISTING_ISSUES" -gt 0 && "$FORCE" != "true" ]]; then
  echo "⚠️  Stage YAML already has $EXISTING_ISSUES issues in release notes."
  echo "    Re-running will overwrite existing notes (including review removals)."
  echo "    To overwrite: FORCE=true $0 $*"
  echo "    To review existing: git show"
  exit 1
fi

# ============================================================================
# Build releaseNotes Section
# ============================================================================

echo "Building releaseNotes YAML section..."

RELEASE_TYPE=$(jq -r '.recommendation.release_type' "$TOPICS_JSON")

read -r CVE_COUNT CVE_ISSUE_KEYS < <(jq -r '[.cve_topics[].issues[].issue_key] | unique | "\(length) \(join(" "))"' "$TOPICS_JSON")
read -r NON_CVE_COUNT NON_CVE_ISSUE_KEYS < <(jq -r '[.non_cve_topics[].issues[].issue_key] | unique | "\(length) \(join(" "))"' "$TOPICS_JSON")

echo "Auto-including ALL filtered issues:"
echo "  CVE issues: $CVE_COUNT"
echo "  Non-CVE issues: $NON_CVE_COUNT"

ISSUES_FIXED_YAML=$(build_issues_fixed_yaml "$CVE_COUNT" "$CVE_ISSUE_KEYS" "$NON_CVE_COUNT" "$NON_CVE_ISSUE_KEYS")

CVES_YAML=""
if [[ "$CVE_COUNT" -gt 0 ]]; then
  CVES_YAML=$(jq -r '
    .cve_topics[] |
    .cve_key as $cve_key |
    (.issues | length) as $issue_count |
    (.issues | map(.component) | unique) as $components |
    if $issue_count == 1 then
      "        # \($cve_key)\n"
    else
      "        # \($cve_key) (\($issue_count) issues)\n"
    end +
    ($components | map("        - key: \($cve_key)\n          component: \(.)") | join("\n"))
  ' "$TOPICS_JSON")
fi

RELEASE_NOTES_YAML=$(build_release_notes_yaml "$RELEASE_TYPE" "$ISSUES_FIXED_YAML" "$CVES_YAML")

display_release_notes_summary "$RELEASE_TYPE" "$CVE_COUNT" "$NON_CVE_COUNT"

# ============================================================================
# Update Stage YAML
# ============================================================================

update_stage_yaml_data_section "$STAGE_YAML" "$RELEASE_NOTES_YAML"

# ============================================================================
# Validate
# ============================================================================

validate_stage_yaml "$STAGE_YAML"

# ============================================================================
# Commit
# ============================================================================

echo "Preparing commit..."

COMMIT_MSG="Add release notes for $VERSION

Type: $RELEASE_TYPE
CVE issues: $CVE_COUNT
Non-CVE issues: $NON_CVE_COUNT

All filtered issues auto-applied. Review commit and amend to
remove any that don't belong in release notes."

commit_release_notes "$STAGE_YAML" "$COMMIT_MSG" "auto-applied"

echo "Next steps:"
echo "  1. Review auto-included issues: git show"
echo "  2. Per-issue agent review: make review-release-notes VERSION=$VERSION"
echo "  3. Push when satisfied: git push"
