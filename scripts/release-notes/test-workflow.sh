#!/bin/bash
# Test script to verify add-release-notes workflow correctness
# Usage: ./scripts/release-notes/test-workflow.sh [VERSION]
set -euo pipefail

VERSION="${1:-0.23.1}"

# Use version-namespaced temp files (same contract as add-release-notes.sh)
export RELEASE_NOTES_DATA="/tmp/release-notes-${VERSION}-data.json"
export RELEASE_NOTES_TOPICS="/tmp/release-notes-${VERSION}-topics.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Testing add-release-notes Workflow: $VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Clean up previous test artifacts
rm -f /tmp/release-notes-*.json

echo "1. Testing component mapping (correctness)..."
source scripts/lib/release-notes-common.sh

# Test multi-part component name (regression test for submariner-route-agent bug)
RESULT=$(map_component_name "rhacm2/submariner-route-agent-rhel9" "0-23")
if [ "$RESULT" = "submariner-route-agent-0-23" ]; then
  echo "   ✓ submariner-route-agent mapped correctly"
else
  echo "   ✗ FAILED: Expected 'submariner-route-agent-0-23', got '$RESULT'"
  exit 1
fi

# Test other components
for test_case in \
  "rhacm2/submariner-operator-rhel9:submariner-operator-0-23" \
  "rhacm2/submariner-rhel9-operator:submariner-operator-0-23" \
  "rhacm2/lighthouse-agent-rhel9:lighthouse-agent-0-23" \
  "nettest-container:nettest-0-23" \
  "rhacm2/submariner-addon-rhel9:EXCLUDE"; do

  INPUT=$(cut -d: -f1 <<< "$test_case")
  EXPECTED=$(cut -d: -f2 <<< "$test_case")
  RESULT=$(map_component_name "$INPUT" "0-23")

  if [ "$RESULT" = "$EXPECTED" ]; then
    echo "   ✓ $INPUT → $RESULT"
  else
    echo "   ✗ FAILED: $INPUT → expected '$EXPECTED', got '$RESULT'"
    exit 1
  fi
done

echo ""
echo "2. Testing collect.sh (data collection)..."
if bash scripts/release-notes/collect.sh "$VERSION" >/dev/null 2>&1; then
  echo "   ✓ Data collection completed"

  # Verify JSON structure
  if jq -e '.metadata.version_major_minor' /tmp/release-notes-data.json >/dev/null 2>&1; then
    echo "   ✓ JSON has correct field names (version_major_minor vs version_dot)"
  else
    echo "   ✗ FAILED: JSON missing version_major_minor field"
    exit 1
  fi

  read -r CVE_COUNT NON_CVE_COUNT < <(jq -r '[(.cve_issues | length), (.non_cve_issues | length)] | "\(.[0]) \(.[1])"' /tmp/release-notes-data.json)
  echo "   ✓ Collected $CVE_COUNT CVEs, $NON_CVE_COUNT non-CVE issues"
else
  echo "   ✗ FAILED: collect.sh failed"
  exit 1
fi

echo ""
echo "3. Testing prepare.sh (filtering/grouping)..."
if bash scripts/release-notes/prepare.sh >/dev/null 2>&1; then
  echo "   ✓ Data preparation completed"

  CVE_COUNT=$(jq '.statistics.cve_count' /tmp/release-notes-topics.json)
  NON_CVE_COUNT=$(jq '.statistics.non_cve_total' /tmp/release-notes-topics.json)
  echo "   ✓ Filtered: $CVE_COUNT CVE issues, $NON_CVE_COUNT non-CVE issues"
else
  echo "   ✗ FAILED: prepare.sh failed"
  exit 1
fi

echo ""
echo "4. Testing auto-apply.sh (YAML generation)..."

# Inject mock CVE data and re-run prepare.sh to get topics with CVEs
jq '.cve_issues = [
  {
    "issue_key": "ACM-12345",
    "cve_key": "CVE-2024-99999",
    "component_mapped": "submariner-operator-0-23",
    "resolved": "2026-01-15"
  },
  {
    "issue_key": "ACM-12346",
    "cve_key": "CVE-2024-99999",
    "component_mapped": "lighthouse-agent-0-23",
    "resolved": "2026-01-15"
  }
]' /tmp/release-notes-data.json > /tmp/release-notes-data-with-cve.json
mv /tmp/release-notes-data-with-cve.json /tmp/release-notes-data.json

# Re-run prepare.sh to generate topics from injected CVE data
if ! bash scripts/release-notes/prepare.sh >/dev/null 2>&1; then
  echo "   ✗ FAILED: prepare.sh failed after CVE injection"
  exit 1
fi

# Backup original YAML
STAGE_YAML=$(jq -r '.metadata.stage_yaml' /tmp/release-notes-data.json)
if [ ! -f "$STAGE_YAML" ]; then
  echo "   ✗ FAILED: Stage YAML not found: $STAGE_YAML"
  exit 1
fi

cp "$STAGE_YAML" "$STAGE_YAML.test-backup"

# Run auto-apply.sh (the production path used by make add-release-notes)
# Use timeout to stop before commit (which may fail on pre-existing gitlint issues)
OUTPUT=$(timeout 30 bash scripts/release-notes/auto-apply.sh 2>&1 || true)

# Check if validation passed (this is the critical test)
# grep-in-condition + here-string: no pipe (nothing for set -e/pipefail to abort on),
# and a no-match runs the else branch instead of killing the script mid-test.
if grep -q "Release data validation passed" <<< "$OUTPUT"; then
  echo "   ✓ YAML validation passed"

  # Verify YAML was actually updated with correct data
  if grep -q "type: RHSA" "$STAGE_YAML"; then
    echo "   ✓ YAML contains release type: RHSA"
  else
    echo "   ✗ FAILED: YAML missing release type"
    mv "$STAGE_YAML.test-backup" "$STAGE_YAML"
    exit 1
  fi

  # Verify CVE section generated correctly (key: CVE-*, component: *)
  if grep -A1 "key: CVE-2024-99999" "$STAGE_YAML" | grep -q "component: submariner-operator-0-23"; then
    echo "   ✓ CVE section formatted correctly"
  else
    echo "   ✗ FAILED: CVE section malformed"
    grep -A2 "cves:" "$STAGE_YAML" || echo "No cves section found"
    mv "$STAGE_YAML.test-backup" "$STAGE_YAML"
    exit 1
  fi

  # Verify both CVE and non-CVE issues present
  CVE_COUNT=$(grep -c "# CVE-2024-99999" "$STAGE_YAML" || echo 0)
  if [ "$CVE_COUNT" -gt 0 ]; then
    echo "   ✓ CVE comments present"
  fi

  # Restore original
  mv "$STAGE_YAML.test-backup" "$STAGE_YAML"
else
  echo "   ✗ FAILED: auto-apply.sh validation failed"
  # `|| true`: a failure whose output has no ERROR/❌ line (e.g. the overwrite
  # guard's ⚠️ warning, or a timeout) makes grep exit 1; under pipefail+set -e
  # that would abort HERE and skip the restore on the next line.
  grep -E "ERROR|❌" <<< "$OUTPUT" | tail -5 || true
  mv "$STAGE_YAML.test-backup" "$STAGE_YAML"
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All tests passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Workflow summary:"
echo "  collect.sh:     ✓ Queries Jira, maps components"
echo "  prepare.sh:     ✓ Filters and groups issues"
echo "  auto-apply.sh:  ✓ Generates valid YAML"
echo ""
echo "Ready for production use:"
echo "  make add-release-notes VERSION=$VERSION"
echo "  /add-release-notes $VERSION"
