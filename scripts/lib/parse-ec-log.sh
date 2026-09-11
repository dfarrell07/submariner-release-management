#!/bin/bash
# Parse a downloaded Konflux EC (Enterprise Contract) log file and extract
# actionable signal: failing rules, affected task names, and whether a task
# version bump can fix the failures.
#
# Usage:
#   parse-ec-log.sh <log-file>
#
# Output (stdout, structured text):
#
#   FAILING_RULES:
#     <rule-name> ...
#
#   AFFECTED_TASKS:
#     <task-name> ...
#
#   FIXABLE_BY_VERSION_BUMP: yes|no|unknown
#
# Exit codes:
#   0 — parsed; may have zero or more violations
#   1 — log file not found or unreadable
#   2 — no EC report section found (wrong file, or log from a passing run)
#
# Parsing strategy:
#   The EC log contains a "Success: " / "Failure: " summary block between the
#   marker lines produced by the ec-cli task. Within that block:
#     - Rule names appear after "msg=" or as "Name: <rule>" lines
#     - Task names appear after "Term:" — these are the tasks EC says are missing
#       or at the wrong version
#
# This is intentionally a dumb text-extractor. The caller (the agent or the
# tekton-task-version-bump.sh script) decides what to do with the output.

set -euo pipefail

LOG_FILE="${1:-}"

if [ -z "$LOG_FILE" ]; then
  echo "Usage: $0 <log-file>" >&2
  exit 1
fi

if [ ! -f "$LOG_FILE" ]; then
  echo "Error: log file not found: $LOG_FILE" >&2
  exit 1
fi

if [ ! -r "$LOG_FILE" ]; then
  echo "Error: log file not readable: $LOG_FILE" >&2
  exit 1
fi

# ── Extract the EC report section ─────────────────────────────────────────────
# Two log formats are handled:
#
# 1. Tekton step log format (produced by the Konflux UI "Download" button):
#    Lines begin with "STEP-<NAME>" as section headers, e.g.:
#      STEP-REPORT-JSON   — JSON violations array (primary data source)
#      STEP-DETAILED-REPORT — human-readable violations
#      STEP-SUMMARY       — {"failures":N,"warnings":N,...}
#
# 2. Legacy format (ec-cli direct output):
#    Sections are bounded by "Success: " or "Failure: " markers and end with
#    "----- DEBUG OUTPUT -----".
#
# Use `|| true` to suppress SIGPIPE exit (141) when head -c closes early on large logs.

# Try Tekton step log format first: extract STEP-REPORT-JSON section (JSON).
# When present this is the authoritative path — use jq to query only the
# "violations" array so we never surface passing-rule codes as failures.
IS_TEKTON_JSON=false
EC_JSON=$(sed -n '/^STEP-REPORT-JSON$/,/^STEP-[A-Z]/p' "$LOG_FILE" 2>/dev/null \
  | grep -v "^STEP-" || true)
if [ -n "$EC_JSON" ] && printf '%s' "$EC_JSON" | jq -e '.components' >/dev/null 2>&1; then
  IS_TEKTON_JSON=true
fi

# Legacy text format (ec-cli direct output / STEP-DETAILED-REPORT).
# Skip entirely when Tekton JSON already parsed successfully — it's authoritative,
# and running these greps anyway risks picking up unrelated "Name:"/"Success:"/
# "Failed"-shaped text elsewhere in the log (e.g. component names in a large
# multi-product report) and merging it into ALL_RULES as false positives.
EC_REPORT_TEXT=""
if [ "$IS_TEKTON_JSON" = "false" ]; then
  EC_REPORT_TEXT=$(sed -n '/^STEP-DETAILED-REPORT$/,/^STEP-[A-Z]/p' "$LOG_FILE" 2>/dev/null \
    | grep -v "^STEP-" | head -c 500000 || true)
  if [ -z "$EC_REPORT_TEXT" ]; then
    EC_REPORT_TEXT=$(sed -n '/^[[:space:]]*\(Success\|Failure\): /,/^----- DEBUG OUTPUT -----/p' "$LOG_FILE" 2>/dev/null | head -c 200000 || true)
  fi
  if [ -z "$EC_REPORT_TEXT" ]; then
    EC_REPORT_TEXT=$(sed -n '/^[[:space:]]*\(Passed\|Failed\)$/,/^$/p' "$LOG_FILE" 2>/dev/null | head -c 200000 || true)
  fi
fi

if [ "$IS_TEKTON_JSON" = "false" ] && [ -z "$EC_REPORT_TEXT" ]; then
  echo "Error: no EC report section found in $(basename "$LOG_FILE")" >&2
  echo "  Expected: Tekton step log (STEP-REPORT-JSON) or legacy EC format" >&2
  echo "  This may not be an EC log, or the log is from a passing run with no violations." >&2
  exit 2
fi

# ── Extract failing rule names ─────────────────────────────────────────────────
# For Tekton JSON (STEP-REPORT-JSON): query only the violations[] array via jq.
# For legacy text: grep for rule-name patterns in the text section.

ALL_RULES=""
AFFECTED_TASKS=""

if [ "$IS_TEKTON_JSON" = "true" ]; then
  # Authoritative: jq extracts codes and terms only from violations arrays.
  ALL_RULES=$(printf '%s' "$EC_JSON" \
    | jq -r '[.components[].violations[]?.metadata | .code // empty] | sort | unique[]' \
    2>/dev/null | grep -v "^$" || true)
  AFFECTED_TASKS=$(printf '%s' "$EC_JSON" \
    | jq -r '[.components[].violations[]?.metadata | .term // empty] | sort | unique[]' \
    2>/dev/null \
    | grep -E '^[a-z][a-z0-9-]+$' \
    | grep -v "^CVE-\|^sha256:" | sort -u || true)
  # Raw violation count, independent of whether each entry's metadata.code/.term
  # parsed cleanly — used below to avoid misreporting a log as "confirmed clean"
  # when violations exist but are malformed/unparseable.
  RAW_VIOLATION_COUNT=$(printf '%s' "$EC_JSON" \
    | jq '[.components[].violations[]?] | length' 2>/dev/null || echo 0)

  # Per-rule violation counts, e.g. "tasks.unsupported (12)" — distinguishes a
  # rule failing on one component from one failing across the whole fanout.
  RULE_COUNTS=$(printf '%s' "$EC_JSON" \
    | jq -r '[.components[].violations[]?.metadata.code // empty] | group_by(.) | .[] | "\(.[0]) (\(length))"' \
    2>/dev/null || true)

  # Rule message/solution text, deduped per rule code — so NON_TASK_RULES tells
  # you what to actually do, not just the code you already saw in FAILING_RULES.
  RULE_MESSAGES=$(printf '%s' "$EC_JSON" \
    | jq -r '[.components[].violations[]?] | group_by(.metadata.code) |
        .[] | "\(.[0].metadata.code): \(.[0].msg)"' \
    2>/dev/null || true)

  # Base component names (no arch/sha suffix) with success=false, paired with
  # their short git revision — surfaces which components are actually failing
  # and lets a stale/mid-merge snapshot (mismatched revisions across sibling
  # components) be spotted at a glance instead of requiring manual jq digging.
  FAILING_COMPONENTS=$(printf '%s' "$EC_JSON" \
    | jq -r '.components[] | select(.name | test("-sha256:")|not) | select(.success == false) |
        "\(.name) (rev \(.source.git.revision // "unknown" | .[0:8]))"' \
    2>/dev/null || true)
fi

# Also extract from legacy text section (may add context if JSON was absent/truncated)
RULES_FROM_MSG=$(printf '%s' "$EC_REPORT_TEXT" | grep -oP '(?<=msg=")[^"]+' 2>/dev/null \
  | grep -oE '^[a-z_]+\.[a-z_]+(\.[a-z_]+)*$' | sort -u || true)
# Real EC rule codes are always dotted lowercase identifiers (e.g. "tasks.unsupported").
# "Name:" and "[Violation]" lines can also carry component/task names with no dot
# (e.g. "Name: submariner-fbc-4-19") — require the dotted shape so those aren't
# misclassified as rule codes.
RULES_FROM_NAME=$(printf '%s' "$EC_REPORT_TEXT" | grep -oP '(?<=^|\s)Name:\s+\K\S+' 2>/dev/null \
  | grep -oE '^[a-z_]+\.[a-z_]+(\.[a-z_]+)*$' | sort -u || true)
RULES_FROM_VIOLATION=$(printf '%s' "$EC_REPORT_TEXT" | grep -oP '(?<=✕ \[Violation\] )\S+' 2>/dev/null \
  | grep -oE '^[a-z_]+\.[a-z_]+(\.[a-z_]+)*$' | sort -u || true)
RULES_FROM_CODE=$(printf '%s' "$EC_REPORT_TEXT" \
  | grep -oP '(?<="code": ")[^"]+|(?<="code":")[^"]+|(?<=code=")[^"]+' 2>/dev/null \
  | grep '\.' | grep -v '@sha256\|sha256:' | sort -u || true)

ALL_RULES=$(printf '%s\n%s\n%s\n%s\n%s\n' "$ALL_RULES" "$RULES_FROM_MSG" "$RULES_FROM_NAME" \
  "$RULES_FROM_VIOLATION" "$RULES_FROM_CODE" | grep -v "^$" | sort -u || true)

# ── Extract affected task names ────────────────────────────────────────────────
AFFECTED_TASKS_TEXT=$(printf '%s' "$EC_REPORT_TEXT" \
  | awk '/✕ \[Violation\]/{in_v=1} in_v && /^[[:space:]]*Term:/{print $2} /^[[:space:]]*$/{in_v=0}' \
  | sort -u | grep -v "^$" || true)
if [ -z "$AFFECTED_TASKS_TEXT" ]; then
  AFFECTED_TASKS_TEXT=$(printf '%s' "$EC_REPORT_TEXT" | grep "Term:" | awk '{print $2}' | sort -u | grep -v "^$" || true)
fi
AFFECTED_TASKS=$(printf '%s\n%s\n' "$AFFECTED_TASKS" "$AFFECTED_TASKS_TEXT" \
  | grep -v "^$" | sort -u || true)

# ── Determine fixability ───────────────────────────────────────────────────────
# "Fixable by version bump" means the failing rules are about task versions or
# missing required tasks — the kinds ec-fix addresses. Rules about signatures,
# SBOM, Dockerfile, operator content, or custom policies need different fixes.
#
# trusted_task.trusted and slsa_build_scripted_build.image_built_by_trusted_task
# are also fixable by bumping the SHA reference — they mean an untrusted SHA is
# in the pipeline, which pipeline-patcher corrects.
TASK_RELATED_RULES=$(printf '%s' "$ALL_RULES" | grep -iE \
  "required_tasks|missing_required_task|missing_required_step_runner|task.*version|tasks\.|trusted_task|slsa_build_scripted_build" \
  2>/dev/null || true)
TASK_RELATED_RULES=$(printf '%s' "$TASK_RELATED_RULES" | grep -v "^$" || true)

NON_TASK_RULES=$(printf '%s' "$ALL_RULES" | grep -ivE \
  "required_tasks|missing_required_task|missing_required_step_runner|task.*version|tasks\.|trusted_task|slsa_build_scripted_build" \
  2>/dev/null || true)
NON_TASK_RULES=$(printf '%s' "$NON_TASK_RULES" | grep -v "^$" || true)

# Use AFFECTED_TASKS as a signal only when there are also rule violations to confirm it.
# A passing log can have Term: lines in Warning blocks — AFFECTED_TASKS alone without
# any failing rules should not cause a "yes" classification.
if [ -z "$ALL_RULES" ] && [ -z "$AFFECTED_TASKS" ]; then
  if [ "$IS_TEKTON_JSON" = "true" ] && [ "${RAW_VIOLATION_COUNT:-0}" = "0" ]; then
    # violations[] is actually empty (not just unparseable) — confirmed clean/passing
    # log, not an indeterminate parse failure.
    FIXABLE="n/a (no violations found)"
  else
    # Either legacy text format, or Tekton JSON with violations present that we
    # failed to extract rule codes/terms from — genuinely indeterminate, do not
    # claim clean.
    FIXABLE="unknown"
  fi
elif [ -n "$TASK_RELATED_RULES" ] || { [ -n "$AFFECTED_TASKS" ] && [ -n "$ALL_RULES" ]; }; then
  if [ -z "$NON_TASK_RULES" ]; then
    FIXABLE="yes"
  else
    FIXABLE="partial"  # some rules fixable, some need manual intervention
  fi
elif [ -n "$ALL_RULES" ]; then
  FIXABLE="no"
else
  FIXABLE="unknown"
fi

# ── Emit structured output ────────────────────────────────────────────────────
echo "FAILING_RULES:"
if [ -n "${RULE_COUNTS:-}" ]; then
  # Tekton JSON path: annotate each rule with its violation count so a rule
  # failing on one component reads differently from one failing across the
  # whole fanout.
  printf '%s\n' "$RULE_COUNTS" | sed 's/^/  /'
elif [ -n "$ALL_RULES" ]; then
  printf '%s\n' "$ALL_RULES" | sed 's/^/  /'
else
  echo "  (none detected)"
fi

echo ""
echo "AFFECTED_TASKS:"
if [ -n "$AFFECTED_TASKS" ]; then
  printf '%s\n' "$AFFECTED_TASKS" | sed 's/^/  /'
else
  echo "  (none detected)"
fi

if [ -n "${FAILING_COMPONENTS:-}" ]; then
  echo ""
  echo "FAILING_COMPONENTS:"
  printf '%s\n' "$FAILING_COMPONENTS" | sed 's/^/  /'

  # Flag mismatched revisions across failing components — the signature of a
  # snapshot caught mid-merge, where some components already have a fix and
  # others don't. Not proof by itself, but worth calling out since diagnosing
  # this by hand (matching revisions against merged PRs) is slow.
  REV_COUNT=$(printf '%s' "$FAILING_COMPONENTS" | { grep -oP '(?<=\(rev )[a-z0-9]+(?=\))' || true; } | sort -u | wc -l)
  if [ "$REV_COUNT" -gt 1 ]; then
    echo ""
    echo "  ⚠ Failing components are at $REV_COUNT different git revisions."
    echo "    This can mean the snapshot was assembled mid-merge (some components"
    echo "    already have a fix, others don't) rather than a uniform failure."
    echo "    Check whether the older revision(s) predate a recent fix PR merge."
  fi
fi

echo ""
echo "FIXABLE_BY_VERSION_BUMP: $FIXABLE"

if [ "$FIXABLE" = "partial" ] || [ "$FIXABLE" = "no" ]; then
  echo ""
  echo "NON_TASK_RULES (require manual fix):"
  if [ -n "$NON_TASK_RULES" ]; then
    printf '%s\n' "$NON_TASK_RULES" | sed 's/^/  /'
    if [ -n "${RULE_MESSAGES:-}" ]; then
      echo ""
      echo "  Details:"
      printf '%s' "$RULE_MESSAGES" | grep -F -f <(printf '%s\n' "$NON_TASK_RULES") | sed 's/^/    /'
    fi
  else
    echo "  (none identified — check FAILING_RULES above)"
  fi
fi
