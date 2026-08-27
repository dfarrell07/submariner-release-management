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
# The ec-cli task emits a block starting with "Success: " or "Failure: " that
# contains the structured violation/warning counts. Extract lines between the
# first occurrence of that marker and the debug output footer.
EC_REPORT=$(sed -n '/^[[:space:]]*\(Success\|Failure\): /,/^----- DEBUG OUTPUT -----/p' "$LOG_FILE" 2>/dev/null | head -c 200000)

if [ -z "$EC_REPORT" ]; then
  # Try the simpler marker used in some log variants
  EC_REPORT=$(sed -n '/^[[:space:]]*\(Passed\|Failed\)$/,/^$/p' "$LOG_FILE" 2>/dev/null | head -c 200000)
fi

if [ -z "$EC_REPORT" ]; then
  echo "Error: no EC report section found in $(basename "$LOG_FILE")" >&2
  echo "  Expected markers: 'Success:' or 'Failure:' followed by '----- DEBUG OUTPUT -----'" >&2
  echo "  This may not be an EC log, or the log is from a passing run with no violations." >&2
  exit 2
fi

# ── Extract failing rule names ─────────────────────────────────────────────────
# Rule names appear as "msg=<rule>" in JSON-formatted output, or as bare
# "Name: <rule>" lines in the text summary. Collect both forms.
RULES_FROM_MSG=$(printf '%s' "$EC_REPORT" | grep -oP '(?<="msg"|msg=")[^"]+' 2>/dev/null | grep -v "^$" | sort -u || true)
RULES_FROM_NAME=$(printf '%s' "$EC_REPORT" | grep -oP '(?<=^|\s)Name:\s+\K\S+' 2>/dev/null | sort -u || true)
# Also catch "code:" style rule identifiers (e.g. required_tasks.missing_required_task)
RULES_FROM_CODE=$(printf '%s' "$EC_REPORT" | grep -oP '(?<="code"|code=")[^"]+' 2>/dev/null | grep '\.' | sort -u || true)

ALL_RULES=$(printf '%s\n%s\n%s\n' "$RULES_FROM_MSG" "$RULES_FROM_NAME" "$RULES_FROM_CODE" \
  | grep -v "^$" | sort -u || true)

# ── Extract affected task names ────────────────────────────────────────────────
# EC reports task names after "Term:" — these are tasks that are missing or at
# the wrong version. This is the primary signal for which tasks to bump.
AFFECTED_TASKS=$(printf '%s' "$EC_REPORT" | grep "Term:" | awk '{print $2}' | sort -u | grep -v "^$" || true)

# ── Determine fixability ───────────────────────────────────────────────────────
# "Fixable by version bump" means the failing rules are about task versions or
# missing required tasks — the kinds ec-fix addresses. Rules about signatures,
# SBOM, Dockerfile, or custom policies need different fixes.
TASK_RELATED_RULES=$(printf '%s' "$ALL_RULES" | grep -iE \
  "required_tasks|missing_required_task|missing_required_step_runner|task.*version|tasks\." \
  2>/dev/null || true)
TASK_RELATED_RULES=$(printf '%s' "$TASK_RELATED_RULES" | grep -v "^$" || true)

NON_TASK_RULES=$(printf '%s' "$ALL_RULES" | grep -ivE \
  "required_tasks|missing_required_task|missing_required_step_runner|task.*version|tasks\." \
  2>/dev/null || true)
NON_TASK_RULES=$(printf '%s' "$NON_TASK_RULES" | grep -v "^$" || true)

if [ -z "$ALL_RULES" ] && [ -z "$AFFECTED_TASKS" ]; then
  FIXABLE="unknown"
elif [ -n "$AFFECTED_TASKS" ] || [ -n "$TASK_RELATED_RULES" ]; then
  if [ -z "$NON_TASK_RULES" ]; then
    FIXABLE="yes"
  else
    FIXABLE="partial"  # some rules fixable, some need manual intervention
  fi
else
  FIXABLE="no"
fi

# ── Emit structured output ────────────────────────────────────────────────────
echo "FAILING_RULES:"
if [ -n "$ALL_RULES" ]; then
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

echo ""
echo "FIXABLE_BY_VERSION_BUMP: $FIXABLE"
