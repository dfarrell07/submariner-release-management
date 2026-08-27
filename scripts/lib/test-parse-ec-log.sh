#!/bin/bash
# Tests for parse-ec-log.sh
# Run: ./scripts/lib/test-parse-ec-log.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE="$SCRIPT_DIR/parse-ec-log.sh"

PASS=0; FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1"; echo "    got:  '$2'"; echo "    want: '$3'"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3' in output)"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if ! printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_exit() {
  local label="$1" expected="$2"; shift 2
  local rc=0; "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$label" "$rc" "$expected"
}

# ── Fixture helpers ────────────────────────────────────────────────────────────

make_log_with_task_violations() {
  local f="$1"
  cat > "$f" <<'EOF'
Some build output...
  Failure: 2 EC violations found

  Name: required_tasks
  Violations: 2, Warnings: 0
    Term: clamav-scan
    Term: sast-snyk-check-oci-ta
  code="required_tasks.missing_required_task" msg="missing_required_task"

----- DEBUG OUTPUT -----
debug lines...
EOF
}

make_log_with_passing() {
  local f="$1"
  cat > "$f" <<'EOF'
Some build output...
  Success: 0 EC violations

----- DEBUG OUTPUT -----
EOF
}

make_log_with_non_task_violations() {
  local f="$1"
  cat > "$f" <<'EOF'
Some build output...
  Failure: 1 EC violation found

  Name: sbom_format
  code="attestation.missing_sbom" msg="missing_sbom_attestation"

----- DEBUG OUTPUT -----
EOF
}

make_log_with_mixed_violations() {
  local f="$1"
  cat > "$f" <<'EOF'
Some build output...
  Failure: 3 EC violations

  Name: required_tasks
    Term: git-clone-oci-ta
  code="required_tasks.missing_required_task" msg="missing_required_task"
  code="attestation.missing_sbom" msg="missing_sbom_attestation"

----- DEBUG OUTPUT -----
EOF
}

make_log_no_ec_section() {
  local f="$1"
  cat > "$f" <<'EOF'
Just some random log output
with no EC section markers
EOF
}

# ── Tests ──────────────────────────────────────────────────────────────────────

echo "=== Error handling ==="

assert_exit "missing arg → exit 1"  1  "$PARSE"
assert_exit "nonexistent file → exit 1" 1 "$PARSE" "/nonexistent/file.log"

NO_EC="$TMPDIR_TEST/no-ec.log"; make_log_no_ec_section "$NO_EC"
assert_exit "no EC section → exit 2" 2 "$PARSE" "$NO_EC"

echo ""
echo "=== Task violation log ==="

TASK_LOG="$TMPDIR_TEST/task-violations.log"; make_log_with_task_violations "$TASK_LOG"
OUT=$("$PARSE" "$TASK_LOG")
RC=0; "$PARSE" "$TASK_LOG" >/dev/null || RC=$?
assert_eq   "task violations → exit 0"           "$RC" "0"
assert_contains "FAILING_RULES section present"  "$OUT" "FAILING_RULES:"
assert_contains "task rule detected"             "$OUT" "required_tasks"
assert_contains "AFFECTED_TASKS section present" "$OUT" "AFFECTED_TASKS:"
assert_contains "clamav-scan extracted"          "$OUT" "clamav-scan"
assert_contains "sast-snyk-check extracted"      "$OUT" "sast-snyk-check-oci-ta"
assert_contains "fixable=yes for task rules"     "$OUT" "FIXABLE_BY_VERSION_BUMP: yes"

echo ""
echo "=== Passing log (no violations) ==="

PASS_LOG="$TMPDIR_TEST/passing.log"; make_log_with_passing "$PASS_LOG"
OUT=$("$PARSE" "$PASS_LOG")
RC=0; "$PARSE" "$PASS_LOG" >/dev/null || RC=$?
assert_eq   "passing log → exit 0"               "$RC" "0"
assert_contains "none detected for rules"        "$OUT" "(none detected)"
assert_contains "fixable=unknown when no data"   "$OUT" "FIXABLE_BY_VERSION_BUMP: unknown"

echo ""
echo "=== Non-task violation log ==="

NONTASK_LOG="$TMPDIR_TEST/non-task.log"; make_log_with_non_task_violations "$NONTASK_LOG"
OUT=$("$PARSE" "$NONTASK_LOG")
assert_contains "non-task rule extracted"        "$OUT" "sbom_format"
assert_not_contains "no task names for sbom"     "$OUT" "clamav"
assert_contains "fixable=no for non-task rules"  "$OUT" "FIXABLE_BY_VERSION_BUMP: no"

echo ""
echo "=== Mixed violations (task + non-task) ==="

MIXED_LOG="$TMPDIR_TEST/mixed.log"; make_log_with_mixed_violations "$MIXED_LOG"
OUT=$("$PARSE" "$MIXED_LOG")
assert_contains "task extracted from mixed"      "$OUT" "git-clone-oci-ta"
assert_contains "fixable=partial for mixed"      "$OUT" "FIXABLE_BY_VERSION_BUMP: partial"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "All $PASS tests passed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$FAIL/$((PASS + FAIL)) tests FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
