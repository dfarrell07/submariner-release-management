#!/bin/bash
# Review release notes issues with per-issue agent review
# Spawns one Claude agent per non-CVE issue to verify it belongs
# Usage: review.sh VERSION [--stage-yaml PATH]
set -euo pipefail

# ============================================================================
# Argument Parsing
# ============================================================================

VERSION=""
STAGE_YAML_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage-yaml)
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
  echo "Usage: $0 VERSION [--stage-yaml PATH]" >&2
  exit 1
fi

if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
  VERSION="${VERSION}.0"
fi

# ============================================================================
# Initialize
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=../lib/release-notes-common.sh
source "$LIB_DIR/release-notes-common.sh"

banner "Review Release Notes Issues: $VERSION"

# ============================================================================
# Locate Stage YAML
# ============================================================================

calculate_acm_version
find_stage_yaml "$VERSION" "$STAGE_YAML_ARG"

echo "Version: $VERSION"
echo "ACM Version: $ACM_VERSION"
echo "Stage YAML: $STAGE_YAML"

# ============================================================================
# Extract Non-CVE Issue Keys
# ============================================================================

# Get all issue keys from YAML
ALL_ISSUE_KEYS=$(yq eval '.spec.data.releaseNotes.issues.fixed[].id' "$STAGE_YAML" 2>/dev/null || echo "")

if [[ -z "$ALL_ISSUE_KEYS" ]]; then
  echo "No issues found in YAML — nothing to review"
  exit 0
fi

# Get CVE issue keys to skip (security-critical, always included). These keys come
# only from collect.sh's structured output — the stage YAML has no per-issue CVE marker.
# Re-collect whenever that file is missing OR for the wrong version: otherwise
# CVE_ISSUE_KEYS would be empty, every CVE issue would fall through to the removal agent,
# and a shipped security CVE could be silently dropped.
_REVIEW_DATA="${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}"
DATA_VERSION=""
if [[ -f "$_REVIEW_DATA" ]]; then
  DATA_VERSION=$(jq -r '.metadata.version // ""' "$_REVIEW_DATA" 2>/dev/null || echo "")
fi
if [[ "$DATA_VERSION" != "$VERSION" ]]; then
  echo "⚠️  Data file missing or for '${DATA_VERSION:-none}', not $VERSION — re-collecting..."
  if ! "$SCRIPT_DIR/collect.sh" "$VERSION" --stage-yaml "$STAGE_YAML" >/dev/null 2>&1; then
    echo "❌ collect.sh failed (Jira auth/network?) — cannot build the CVE-skip list." >&2
    echo "   Aborting: reviewing without it could drop a shipped CVE from the release notes." >&2
    exit 1
  fi
fi
CVE_ISSUE_KEYS=$(jq -r '.cve_issues[].issue_key // empty' "$_REVIEW_DATA" 2>/dev/null || echo "")

# Build list of non-CVE issue keys to review
REVIEW_KEYS=()
for KEY in $ALL_ISSUE_KEYS; do
  if echo "$CVE_ISSUE_KEYS" | grep -qw "$KEY" 2>/dev/null; then
    echo "Skipping $KEY (CVE issue — always included)"
  else
    REVIEW_KEYS+=("$KEY")
  fi
done

TOTAL=${#REVIEW_KEYS[@]}
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No non-CVE issues to review"
  exit 0
fi

echo ""
echo "Reviewing $TOTAL non-CVE issues (CVE issues skipped)..."
echo ""

# ============================================================================
# Per-Issue Agent Review
# ============================================================================

KEPT=0
REMOVED=0
CURRENT=0

for KEY in "${REVIEW_KEYS[@]}"; do
  CURRENT=$((CURRENT + 1))
  echo "[$CURRENT/$TOTAL] Reviewing $KEY..."

  "$SCRIPT_DIR/review-issue.sh" "$KEY" "$VERSION" "$STAGE_YAML" || {
    echo "  ? KEEP  $KEY - review failed, keeping by default"
  }

  # Check if issue was removed (no longer in YAML)
  if ! yq eval ".spec.data.releaseNotes.issues.fixed[] | select(.id == \"$KEY\")" "$STAGE_YAML" 2>/dev/null | grep -q "$KEY"; then
    REMOVED=$((REMOVED + 1))
  else
    KEPT=$((KEPT + 1))
  fi
done

# ============================================================================
# Summary
# ============================================================================

banner "Review Complete"
echo "Results: $KEPT kept, $REMOVED removed out of $TOTAL reviewed"

if [[ "$REMOVED" -gt 0 ]]; then
  echo ""
  echo "Review removals:"
  echo "  git log --oneline -$REMOVED"
  echo ""
  echo "Revert a removal:"
  echo "  git revert <commit-hash>"
fi
