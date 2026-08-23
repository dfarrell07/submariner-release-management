#!/bin/bash
# Phase 2: Filter and group release notes data
# Input: ${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}
# Output: ${RELEASE_NOTES_TOPICS:-/tmp/release-notes-topics.json}
set -euo pipefail

# ============================================================================
# Initialize
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=../lib/release-notes-common.sh
source "$LIB_DIR/release-notes-common.sh"

INPUT_JSON="${RELEASE_NOTES_DATA:-/tmp/release-notes-data.json}"
OUTPUT_JSON="${RELEASE_NOTES_TOPICS:-/tmp/release-notes-topics.json}"

if [[ ! -f "$INPUT_JSON" ]]; then
  echo "❌ ERROR: Input file not found: '$INPUT_JSON'" >&2
  echo "Run collect.sh first" >&2
  exit 1
fi

banner "Filter and Group Release Notes Data"

# ============================================================================
# Filter and Group with jq
# ============================================================================
# Single jq pipeline to:
#   1. Filter issues by:
#      - Existing prod releases
#      - Invalid resolutions (Won't Do, Won't Fix, Duplicate, Cannot Reproduce)
#      - Resolution date (Z-streams: exclude issues resolved before last publish)
#   2. Group CVEs by CVE key (multiple issues can fix same CVE)
#   3. Calculate statistics (CVE and non-CVE counts)
#   4. Generate recommendation (RHSA if CVEs, else RHBA)

jq '
# Extract metadata
.metadata as $meta |

# Extract existing issues array
.existing_issues as $existing |

# Define invalid resolutions to exclude
# NOTE: "Unresolved" is intentionally NOT excluded - release is what resolves issues,
# and Jira hygiene is not great at moving issues to testing/QE status.
# "Not a Bug" means Product Security evaluated the CVE as not applicable - never include.
# "Obsolete" is ambiguous but exclude from issues; CVE key preserved if other trackers are Done.
["Won\u0027t Do", "Won\u0027t Fix", "Duplicate", "Cannot Reproduce", "Not a Bug", "Obsolete"] as $invalid_resolutions |

# Filter non-CVE issues
(
  .non_cve_issues | map(
    select(
      # Exclude existing issues (in prod releases)
      (.issue_key | IN($existing[]) | not) and
      # Exclude invalid resolutions (but allow Unresolved - see NOTE above)
      (.resolution | IN($invalid_resolutions[]) | not) and
      # For Z-streams: exclude issues resolved before last published release
      (if ($meta.last_published_date != "" and .resolved != "")
       then (.resolved >= $meta.last_published_date)
       else true
       end)
    )
  )
) as $filtered_non_cve |

# Filter CVE issues
(
  .cve_issues | map(
    select(
      # Exclude existing issues (in prod releases)
      (.issue_key | IN($existing[]) | not) and
      # Exclude invalid resolutions (Not a Bug = CVE not applicable, Obsolete = stale)
      ((.resolution // "Unresolved") | IN($invalid_resolutions[]) | not) and
      # For Z-streams: exclude issues resolved before last published release
      (if ($meta.last_published_date != "" and .resolved != "")
       then (.resolved >= $meta.last_published_date)
       else true
       end)
    )
  )
) as $filtered_cve |

# Group CVEs by CVE key
(
  $filtered_cve | group_by(.cve_key) | map({
    cve_key: .[0].cve_key,
    issues: map({
      issue_key: .issue_key,
      component: .component_mapped
    })
  })
) as $cve_topics |

# Group all non-CVE issues into a single topic
(
  [{
    issues: $filtered_non_cve | map({
      issue_key: .issue_key
    })
  }]
) as $non_cve_topics |

# Calculate statistics
(
  {
    cve_count: ($filtered_cve | length),
    non_cve_total: ($filtered_non_cve | length)
  }
) as $statistics |

# Build recommendation
(
  {
    release_type: (if $statistics.cve_count > 0 then "RHSA" else "RHBA" end),
    reason: (
      if $statistics.cve_count > 0 then "CVEs present (RHSA required)"
      else "No CVEs (RHBA for bug fixes or RHEA for enhancements)"
      end
    )
  }
) as $recommendation |

# Build final output
{
  metadata: $meta,
  cve_topics: $cve_topics,
  non_cve_topics: $non_cve_topics,
  statistics: $statistics,
  recommendation: $recommendation
}
' "$INPUT_JSON" > "$OUTPUT_JSON"

echo "✓ Data prepared: $OUTPUT_JSON"

# ============================================================================
# Display Excluded Issues
# ============================================================================

# Show CVE issues that were filtered out (with reason)
EXCLUDED_CVES=$(jq -r '
  .existing_issues as $existing |
  ["Won\u0027t Do", "Won\u0027t Fix", "Duplicate", "Cannot Reproduce", "Not a Bug", "Obsolete"] as $invalid |
  .metadata as $meta |
  [.cve_issues[] | select(
    (.issue_key | IN($existing[])) or
    ((.resolution // "Unresolved") | IN($invalid[])) or
    (if ($meta.last_published_date != "" and .resolved != "")
     then (.resolved < $meta.last_published_date) else false end)
  ) | "\(.issue_key) (\(.resolution // "Unresolved")): \(.cve_key)"] | .[]
' "$INPUT_JSON" 2>/dev/null || true)

if [[ -n "$EXCLUDED_CVES" ]]; then
  echo ""
  echo "Excluded CVE issues:"
  echo "$EXCLUDED_CVES" | while read -r line; do echo "  ✗ $line"; done
fi

# Show non-CVE issues that were filtered out
EXCLUDED_NON_CVE=$(jq -r '
  .existing_issues as $existing |
  ["Won\u0027t Do", "Won\u0027t Fix", "Duplicate", "Cannot Reproduce", "Not a Bug", "Obsolete"] as $invalid |
  .metadata as $meta |
  [.non_cve_issues[] | select(
    (.issue_key | IN($existing[])) or
    (.resolution | IN($invalid[])) or
    (if ($meta.last_published_date != "" and .resolved != "")
     then (.resolved < $meta.last_published_date) else false end)
  ) | "\(.issue_key) (\(.resolution))"] | .[]
' "$INPUT_JSON" 2>/dev/null || true)

if [[ -n "$EXCLUDED_NON_CVE" ]]; then
  echo ""
  echo "Excluded non-CVE issues:"
  echo "$EXCLUDED_NON_CVE" | while read -r line; do echo "  ✗ $line"; done
fi

# ============================================================================
# Display Summary
# ============================================================================

jq -r '
"",
"Summary:",
"  CVE topics: \(.cve_topics | length)",
"  Non-CVE issues: \(.statistics.non_cve_total)",
"",
"Recommendation:",
"  Release type: \(.recommendation.release_type)",
"  Reason: \(.recommendation.reason)"
' "$OUTPUT_JSON" || true
