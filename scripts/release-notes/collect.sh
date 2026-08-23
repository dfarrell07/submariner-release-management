#!/bin/bash
# Phase 1: Collect raw release notes data from Jira and filesystem
# Output: ${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}
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

# Validate version format (X.Y.Z where X,Y,Z are numbers)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ ERROR: Invalid version format: $VERSION" >&2
  echo "Expected format: X.Y.Z (e.g., 0.23.1)" >&2
  exit 1
fi

# ============================================================================
# Initialize
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=../lib/release-notes-common.sh
source "$LIB_DIR/release-notes-common.sh"

OUTPUT_JSON="${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}"

# JQL text search filter to find Submariner component mentions
readonly JQL_TEXT_FILTER="(text ~ submariner OR text ~ lighthouse OR text ~ subctl OR text ~ nettest)"

banner "Collect Release Notes Data: $VERSION"

# ============================================================================
# Prerequisites
# ============================================================================

echo "Testing acli authentication..."
if ! acli jira workitem search --jql 'project=ACM' --limit 1 --json </dev/null >/dev/null 2>&1; then
  echo "❌ ERROR: acli authentication failed" >&2
  echo "Setup steps:" >&2
  echo "  1. Create API token: https://id.atlassian.com/manage-profile/security/api-tokens" >&2
  echo "  2. acli jira auth login --token" >&2
  echo "  3. acli jira auth status" >&2
  exit 1
fi
echo "✓ Authenticated to redhat.atlassian.net"

if ! command -v jq &>/dev/null; then
  echo "❌ ERROR: jq not installed" >&2
  exit 1
fi

echo "✓ Prerequisites verified"

# ============================================================================
# Calculate Versions
# ============================================================================

banner "Calculate Version and Locate Stage YAML"

calculate_acm_version
find_stage_yaml "$VERSION" "$STAGE_YAML_ARG"

echo "Version mapping: Submariner $VERSION_MAJOR_MINOR → $ACM_VERSION"
echo "Stage YAML: $STAGE_YAML"

# Extract snapshot build date from stage YAML (embedded in snapshot name: *-YYYYMMDD-*)
# CVEs filed after this date can't be verified — "absent in Clair" would be a false positive
# because the CVE didn't exist yet when the scan ran
# `|| true`: a malformed stage YAML makes yq exit non-zero, which under set -e
# would abort here instead of falling through to the empty-value guard below
# (snapshot date is optional — its absence only disables the CVE-date filter).
SNAPSHOT_NAME=$(yq eval '.spec.snapshot' "$STAGE_YAML" 2>/dev/null || true)
SNAPSHOT_DATE=""
if [[ -n "$SNAPSHOT_NAME" && "$SNAPSHOT_NAME" != "null" ]]; then
  SNAP_DATE_RAW=$(echo "$SNAPSHOT_NAME" | grep -oE '[0-9]{8}' | head -1 || true)
  if [[ -n "$SNAP_DATE_RAW" ]]; then
    SNAPSHOT_DATE="${SNAP_DATE_RAW:0:4}-${SNAP_DATE_RAW:4:2}-${SNAP_DATE_RAW:6:2}"
    echo "Snapshot date: $SNAPSHOT_DATE (CVEs filed after this are excluded)"
  fi
fi

# JQL version filter: match both ACM and Submariner version formats.
# Some issues use fixVersion "ACM 2.15.0", others use "Submariner 0.22.1".
# Jira rejects queries with nonexistent version values, so we check first.
VERSION_CLAUSE="(affectedVersion = \"$ACM_VERSION\" OR fixVersion = \"$ACM_VERSION\""

# Add Submariner version formats if they exist in Jira
for SUBM_VER in "Submariner $VERSION" "Submariner $VERSION_MAJOR_MINOR"; do
  if acli jira workitem search --jql "fixVersion = \"$SUBM_VER\"" --limit 1 --json </dev/null >/dev/null 2>&1; then
    VERSION_CLAUSE+=" OR fixVersion = \"$SUBM_VER\""
  fi
done
VERSION_CLAUSE+=")"

echo "Version clause: $VERSION_CLAUSE"

# ============================================================================
# Scan Existing Issues
# ============================================================================

banner "Checking for Existing Issues"

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [[ -z "$GIT_ROOT" ]]; then
  echo "❌ ERROR: Not in a git repository" >&2
  echo "Run this script from within the repository" >&2
  exit 1
fi

PROD_DIR="$GIT_ROOT/releases/$VERSION_MAJOR_MINOR/prod"

echo "Scanning $PROD_DIR/*.yaml for published issues..."

# Extract issue IDs from prod releases only (prod releases are published to registry.redhat.io)
EXISTING_ISSUES_JSON="[]"
if [[ -d "$PROD_DIR" ]]; then
  EXISTING_ISSUES=$(find "$PROD_DIR" -name "*.yaml" -type f -print0 | \
    xargs -0 yq eval ".spec.data.releaseNotes.issues.fixed[].id" 2>/dev/null | \
    sort -u || echo "")
  if [[ -n "$EXISTING_ISSUES" ]]; then
    EXISTING_ISSUES_JSON=$(jq -Rs 'split("\n") | map(select(length > 0))' <<< "$EXISTING_ISSUES")
    echo "Found $(jq 'length' <<< "$EXISTING_ISSUES_JSON") published issues (from prod releases)"
  else
    echo "No published issues found (clean slate for $VERSION_MAJOR_MINOR)"
  fi
else
  echo "No published issues found (clean slate for $VERSION_MAJOR_MINOR)"
fi

# ============================================================================
# Get Last Published Release Info (Metadata Only)
# ============================================================================

banner "Checking Last Published Release"

PATCH_VERSION="${VERSION##*.}"

# Check if this is the first release in the series
PROD_RELEASE_COUNT=0
if [[ -d "$PROD_DIR" ]]; then
  PROD_RELEASE_COUNT=$(find "$PROD_DIR" -name "*.yaml" -type f 2>/dev/null | wc -l)
fi

# Determine release type
if [[ "$PROD_RELEASE_COUNT" -eq 0 ]]; then
  # First release for this Y-stream (no prior prod releases)
  echo "First release in $VERSION_MAJOR_MINOR series"
  RELEASE_TYPE="first-in-series"
  LAST_PUBLISHED_DATE=""
elif [[ "$PATCH_VERSION" == "0" ]]; then
  # First patch release (X.Y.0) with existing prod releases
  echo "Y-stream release ($VERSION)"
  RELEASE_TYPE="y-stream"
  LAST_PUBLISHED_DATE=""
else
  # Subsequent patch release (X.Y.Z where Z > 0)
  echo "Z-stream release ($VERSION)"
  RELEASE_TYPE="z-stream"

  # Get last published version's build date from registry.redhat.io
  echo "Finding last published version for $VERSION_MAJOR_MINOR series..."

  LAST_TAG="v${VERSION_MAJOR_MINOR}"
  BUILD_DATE=$(skopeo inspect "docker://registry.redhat.io/rhacm2/submariner-rhel9-operator:${LAST_TAG}" 2>/dev/null | \
    jq -r '.Labels["build-date"] // empty' || true)

  if [[ -n "$BUILD_DATE" ]]; then
    LAST_PUBLISHED_DATE=$(date -d "$BUILD_DATE" +%Y-%m-%d 2>/dev/null || echo "")
    if [[ -n "$LAST_PUBLISHED_DATE" ]]; then
      echo "✓ Found last published version: $LAST_TAG (built $BUILD_DATE)"
      echo "  Last published date: $LAST_PUBLISHED_DATE (for filtering old issues)"
    else
      echo "⚠️  Failed to parse build date '$BUILD_DATE'" >&2
      LAST_PUBLISHED_DATE=""
    fi
  else
    echo "⚠️  Could not find $LAST_TAG in registry" >&2
    LAST_PUBLISHED_DATE=""
  fi
fi

echo "Querying ALL issues for $ACM_VERSION (filtering in next phase)"

# ============================================================================
# Query CVE Issues
# ============================================================================

banner "Querying Jira for CVE Issues"

echo "Fetching Security-labeled issues..."

CVE_JQL="project=ACM AND labels in (Security) AND $JQL_TEXT_FILTER AND $VERSION_CLAUSE"

CVE_JSON=$(query_jira --jql "$CVE_JQL")
read -r CVE_COUNT CVE_KEYS < <(jq -r '[.[].key] | "\(length) \(join(" "))"' <<< "$CVE_JSON")

if [[ "$CVE_COUNT" -eq 0 ]]; then
  echo "No CVE issues found."
  CVE_ISSUES_JSON="[]"
else
  echo "Found $CVE_COUNT CVE issues, fetching details and mapping components..."

  CVE_DATA_LINES=()
  for KEY in $CVE_KEYS; do
    [[ -z "$KEY" || "$KEY" == "null" ]] && continue

    ISSUE_JSON=$(view_jira "$KEY" --fields "labels,resolutiondate,created,resolution") || {
      echo "⚠️  $KEY: Failed to fetch details, skipping" >&2
      continue
    }

    # Skip CVEs filed after the snapshot was built
    if [[ -n "$SNAPSHOT_DATE" ]]; then
      CREATED=$(jq -r '(.fields.created // "")[:10]' <<< "$ISSUE_JSON")
      if [[ -n "$CREATED" && "$CREATED" > "$SNAPSHOT_DATE" ]]; then
        echo "  $KEY: Skipping (created $CREATED, after snapshot $SNAPSHOT_DATE)"
        continue
      fi
    fi

    read -r CVE_KEY PSCOMPONENT < <(jq -r '
      ([.fields.labels[] | select(startswith("CVE-"))] | first // "") as $cve |
      ([.fields.labels[] | select(startswith("pscomponent:")) | sub("pscomponent:"; "")] | first // "") as $ps |
      "\($cve) \($ps)"
    ' <<< "$ISSUE_JSON")

    if [[ -z "$CVE_KEY" || -z "$PSCOMPONENT" ]]; then
      echo "⚠️  $KEY: Missing CVE or pscomponent label, skipping" >&2
      continue
    fi

    COMPONENT_MAPPED=$(map_component_name "$PSCOMPONENT" "$VERSION_MAJOR_MINOR_DASH")
    # EXCLUDE is intentional (e.g. addon is built separately); UNKNOWN means a
    # pscomponent label map_component_name didn't recognize — warn so a drifted
    # label format can't silently drop a real Submariner CVE from the RHSA.
    if [[ "$COMPONENT_MAPPED" == "EXCLUDE" ]]; then
      continue
    elif [[ "$COMPONENT_MAPPED" == "UNKNOWN" ]]; then
      echo "⚠️  $KEY: Unrecognized pscomponent '$PSCOMPONENT', skipping (update map_component_name)" >&2
      continue
    fi

    RESOLVED=$(jq -r '(.fields.resolutiondate // "")[:10]' <<< "$ISSUE_JSON")
    RESOLUTION=$(jq -r '.fields.resolution.name // "Unresolved"' <<< "$ISSUE_JSON")
    CVE_DATA_LINES+=("$(jq -n --arg ik "$KEY" --arg ck "$CVE_KEY" --arg cm "$COMPONENT_MAPPED" --arg rd "$RESOLVED" --arg res "$RESOLUTION" '{issue_key:$ik,cve_key:$ck,component_mapped:$cm,resolved:$rd,resolution:$res}')")
  done

  CVE_ISSUES_JSON=$(printf '%s\n' "${CVE_DATA_LINES[@]}" | jq -s '.')
  echo "Mapped ${#CVE_DATA_LINES[@]} CVE issues to components"
fi

# ============================================================================
# Query Non-CVE Issues
# ============================================================================

banner "Querying Jira for Non-CVE Issues"

echo "Fetching ALL non-Security issues for $ACM_VERSION..."
if [[ -n "$LAST_PUBLISHED_DATE" ]]; then
  echo "(Last published: $LAST_PUBLISHED_DATE - for filtering old issues)"
fi

NON_CVE_JQL="project=ACM AND $JQL_TEXT_FILTER AND $VERSION_CLAUSE AND (labels is EMPTY OR labels not in (Security, SecurityTracking))"

NON_CVE_JSON=$(query_jira --jql "$NON_CVE_JQL")
read -r NON_CVE_COUNT NON_CVE_KEYS < <(jq -r '[.[].key] | "\(length) \(join(" "))"' <<< "$NON_CVE_JSON")

if [[ "$NON_CVE_COUNT" -eq 0 ]]; then
  echo "No non-CVE issues found."
  NON_CVE_ISSUES_JSON="[]"
else
  echo "Found $NON_CVE_COUNT non-CVE issues, fetching details..."

  NON_CVE_DATA_LINES=()
  for KEY in $NON_CVE_KEYS; do
    [[ -z "$KEY" || "$KEY" == "null" ]] && continue

    ISSUE_JSON=$(view_jira "$KEY" --fields "summary,status,resolutiondate,resolution,labels,components,issuelinks") || {
      echo "⚠️  $KEY: Failed to fetch details, skipping" >&2
      continue
    }

    # Only include issues owned by Submariner (Multicluster Networking) or Documentation.
    # The JQL text filter catches many false positives from other ACM teams (Console, CNV,
    # PICS, Installer, QE) whose issues mention "submariner" in passing.
    COMPONENTS=$(jq -r '[.fields.components[]?.name] | join(", ")' <<< "$ISSUE_JSON")
    if ! echo "$COMPONENTS" | grep -qE "Multicluster Networking|Documentation"; then
      echo "  $KEY: Skipping (component: $COMPONENTS)"
      continue
    fi

    # Skip submariner-addon issues (addon is built separately in ACM/MCE)
    if jq -e '[.fields.labels[]? | select(startswith("component:submariner-addon"))] | length > 0' <<< "$ISSUE_JSON" >/dev/null 2>&1; then
      echo "  $KEY: Skipping (submariner-addon, built separately)"
      continue
    fi

    # Skip process/tracking tasks that never produce code changes
    SUMMARY=$(jq -r '.fields.summary' <<< "$ISSUE_JSON")
    if echo "$SUMMARY" | grep -qiE "Branch Cut|Support Matri|Doc audit|REMOVE old known issues"; then
      echo "  $KEY: Skipping (process task: $SUMMARY)"
      continue
    fi

    # Skip untouched issues: status New/Backlog + Unresolved + no issue links + no merged PRs.
    # Only filter truly untouched — "In Progress" or "Testing" means active work
    # even if the fix isn't linked to this Jira key.
    # Require MERGED PRs (not just open) — an open PR means work in progress, not shipped.
    RESOLUTION=$(jq -r '.fields.resolution.name // "Unresolved"' <<< "$ISSUE_JSON")
    STATUS=$(jq -r '.fields.status.name' <<< "$ISSUE_JSON")
    LINK_COUNT=$(jq '[.fields.issuelinks[]? | select(.type.name != "Cloners")] | length' <<< "$ISSUE_JSON")
    if [[ "$RESOLUTION" == "Unresolved" && "$LINK_COUNT" -eq 0 ]] && echo "$STATUS" | grep -qiE "^(New|Backlog|To Do)$"; then
      # Fail-safe merged-PR check. Count matches via gh's built-in --jq; on a gh
      # error (rate-limit/network) the `|| VAR=""` leaves "" (not "0"), so we KEEP
      # the issue rather than silently dropping a shipped fix. Skip only when BOTH
      # queries SUCCEED and return 0 matches. (review.sh only re-examines issues
      # already in the YAML, so a drop here is unrecoverable — hence keep-on-error,
      # matching the rest of this deliberately fail-safe subsystem.)
      SUBM_PRS=$(gh search prs "$KEY" --owner submariner-io --state merged --json url --limit 1 --jq 'length' 2>/dev/null) || SUBM_PRS=""
      STOL_PRS=$(gh search prs "$KEY" --owner stolostron --state merged --json url --limit 1 --jq 'length' 2>/dev/null) || STOL_PRS=""
      if [[ "$SUBM_PRS" == "0" && "$STOL_PRS" == "0" ]]; then
        echo "  $KEY: Skipping ($STATUS, unresolved, no links, no merged PRs)"
        continue
      fi
    fi

    NON_CVE_DATA_LINES+=("$(jq -c --arg ik "$KEY" '
      {
        issue_key: $ik,
        resolved: ((.fields.resolutiondate // "")[:10]),
        resolution: (.fields.resolution.name // "Unresolved")
      }
    ' <<< "$ISSUE_JSON")")
  done

  NON_CVE_ISSUES_JSON=$(printf '%s\n' "${NON_CVE_DATA_LINES[@]}" | jq -s '.')
  echo "Collected ${#NON_CVE_DATA_LINES[@]} non-CVE issue details"
fi

# ============================================================================
# Build Output JSON
# ============================================================================

echo "Building output JSON..."

jq -n \
  --arg version "$VERSION" \
  --arg version_major_minor "$VERSION_MAJOR_MINOR" \
  --arg acm_version "$ACM_VERSION" \
  --arg stage_yaml "$STAGE_YAML" \
  --arg last_published_date "$LAST_PUBLISHED_DATE" \
  --arg release_type "$RELEASE_TYPE" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson existing_issues "$EXISTING_ISSUES_JSON" \
  --argjson cve_issues "$CVE_ISSUES_JSON" \
  --argjson non_cve_issues "$NON_CVE_ISSUES_JSON" \
  '{
    metadata: {
      version: $version,
      version_major_minor: $version_major_minor,
      acm_version: $acm_version,
      stage_yaml: $stage_yaml,
      last_published_date: $last_published_date,
      release_type: $release_type,
      collected_at: $collected_at
    },
    existing_issues: $existing_issues,
    cve_issues: $cve_issues,
    non_cve_issues: $non_cve_issues
  }' > "$OUTPUT_JSON"

echo "✓ Data collected: $OUTPUT_JSON"

jq -r '"Summary:",
  "  CVE issues: \(.cve_issues | length)",
  "  Non-CVE issues: \(.non_cve_issues | length)",
  "  Existing issues: \(.existing_issues | length)"' "$OUTPUT_JSON"
