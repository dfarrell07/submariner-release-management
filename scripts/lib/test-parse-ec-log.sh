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

# Tekton step log format (Konflux UI "Download" button) with an empty
# violations[] array — the real-world shape of a clean/passing EC run.
make_tekton_log_with_passing() {
  local f="$1"
  cat > "$f" <<'EOF'
STEP-REPORT-JSON
{"success": true, "components": [{"name": "widget-0-1", "containerImage": "quay.io/example/widget@sha256:abc", "violations": [], "warnings": [], "successes": []}]}
STEP-SUMMARY
{"successes": 100, "failures": 0, "warnings": 0, "result": "SUCCESS"}
EOF
}

# Tekton step log with valid STEP-REPORT-JSON plus "Name: <component>" lines
# elsewhere in the log body (as seen in real multi-product EC logs, e.g. a
# STEP-DETAILED-REPORT section listing every component). Regression guard for
# two bugs: (1) once JSON parses, the legacy-text fallback must not also run
# and merge in false positives; (2) even if it did run, an un-dotted "Name:"
# value (a component name, not a rule code) must not be treated as a rule.
make_tekton_log_with_component_names_in_text() {
  local f="$1"
  cat > "$f" <<'EOF'
STEP-REPORT-JSON
{"success": false, "components": [{"name": "widget-0-1", "containerImage": "quay.io/example/widget@sha256:abc", "violations": [{"msg": "Task \"git-clone-oci-ta\" is required and present but not from a trusted task", "metadata": {"code": "tasks.required_untrusted_task_found", "term": "git-clone-oci-ta"}}]}]}
STEP-SUMMARY
{"successes": 10, "failures": 1, "warnings": 0, "result": "FAILURE"}
STEP-DETAILED-REPORT
- Name: acm-cli-acm-214
- Name: cluster-backup-operator-acm-214
- Name: widget-0-1
EOF
}

# Tekton step log with two failing components at different git revisions (one
# more component passes cleanly) and a non-task rule with a real msg — covers
# per-rule violation counts, the FAILING_COMPONENTS list, the revision-mismatch
# warning, and NON_TASK_RULES message details all in one realistic fixture.
make_tekton_log_with_mixed_revisions() {
  local f="$1"
  cat > "$f" <<'EOF'
STEP-REPORT-JSON
{"success": false, "components": [
  {"name": "widget-a-0-1", "containerImage": "quay.io/example/widget-a@sha256:aaa", "source": {"git": {"revision": "1111111111111111111111111111111111111111"}}, "success": false, "violations": [{"msg": "Task \"git-clone-oci-ta\" is required and present but not from a trusted task", "metadata": {"code": "tasks.required_untrusted_task_found", "term": "git-clone-oci-ta"}}, {"msg": "CVE scan results were not found", "metadata": {"code": "cve.cve_results_found"}}]},
  {"name": "widget-b-0-1", "containerImage": "quay.io/example/widget-b@sha256:bbb", "source": {"git": {"revision": "2222222222222222222222222222222222222222"}}, "success": false, "violations": [{"msg": "Task \"git-clone-oci-ta\" is required and present but not from a trusted task", "metadata": {"code": "tasks.required_untrusted_task_found", "term": "git-clone-oci-ta"}}]},
  {"name": "widget-c-0-1", "containerImage": "quay.io/example/widget-c@sha256:ccc", "source": {"git": {"revision": "1111111111111111111111111111111111111111"}}, "success": true, "violations": []}
]}
STEP-SUMMARY
{"successes": 5, "failures": 3, "warnings": 0, "result": "FAILURE"}
EOF
}

# Tekton step log with a single failing component that has no source.git.revision
# field at all — regression guard: the "unknown" placeholder must not break the
# revision-count grep (which previously required [a-f0-9] and matched nothing).
make_tekton_log_with_missing_revision() {
  local f="$1"
  cat > "$f" <<'EOF'
STEP-REPORT-JSON
{"success": false, "components": [{"name": "widget-0-1", "containerImage": "quay.io/example/widget@sha256:abc", "success": false, "violations": [{"msg": "x", "metadata": {"code": "tasks.unsupported"}}]}]}
STEP-SUMMARY
{"successes": 1, "failures": 1, "warnings": 0, "result": "FAILURE"}
EOF
}

# Tekton step log format with a violation present but missing metadata.code —
# regression guard: this must NOT be reported as "confirmed clean" just because
# no rule code/term could be extracted from it.
make_tekton_log_with_malformed_violation() {
  local f="$1"
  cat > "$f" <<'EOF'
STEP-REPORT-JSON
{"success": false, "components": [{"name": "widget-0-1", "containerImage": "quay.io/example/widget@sha256:abc", "violations": [{"msg": "something broke"}]}]}
STEP-SUMMARY
{"successes": 0, "failures": 1, "warnings": 0, "result": "FAILURE"}
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
echo "=== Passing log (Tekton JSON format, empty violations[]) ==="

TEKTON_PASS_LOG="$TMPDIR_TEST/tekton-passing.log"; make_tekton_log_with_passing "$TEKTON_PASS_LOG"
OUT=$("$PARSE" "$TEKTON_PASS_LOG")
RC=0; "$PARSE" "$TEKTON_PASS_LOG" >/dev/null || RC=$?
assert_eq   "tekton passing log → exit 0"            "$RC" "0"
assert_contains "fixable=n/a for confirmed clean run" "$OUT" "FIXABLE_BY_VERSION_BUMP: n/a (no violations found)"

echo ""
echo "=== Malformed violation (present but no metadata.code) ==="

MALFORMED_LOG="$TMPDIR_TEST/tekton-malformed.log"; make_tekton_log_with_malformed_violation "$MALFORMED_LOG"
OUT=$("$PARSE" "$MALFORMED_LOG")
RC=0; "$PARSE" "$MALFORMED_LOG" >/dev/null || RC=$?
assert_eq   "malformed violation log → exit 0"          "$RC" "0"
assert_not_contains "must NOT report n/a when violation exists" "$OUT" "n/a (no violations found)"
assert_contains "falls back to unknown, not a false-clean" "$OUT" "FIXABLE_BY_VERSION_BUMP: unknown"

echo ""
echo "=== Component names in text section must not pollute FAILING_RULES ==="

COMPONENT_NAMES_LOG="$TMPDIR_TEST/tekton-component-names.log"; make_tekton_log_with_component_names_in_text "$COMPONENT_NAMES_LOG"
OUT=$("$PARSE" "$COMPONENT_NAMES_LOG")
assert_contains "real rule code still extracted"          "$OUT" "tasks.required_untrusted_task_found"
assert_not_contains "component name not misread as rule"  "$OUT" "acm-cli-acm-214"
assert_not_contains "second component name not misread"   "$OUT" "cluster-backup-operator-acm-214"
assert_not_contains "own component name not misread"      "$OUT" "widget-0-1"

echo ""
echo "=== Rule counts, FAILING_COMPONENTS, and revision mismatch ==="

MIXED_REV_LOG="$TMPDIR_TEST/tekton-mixed-revisions.log"; make_tekton_log_with_mixed_revisions "$MIXED_REV_LOG"
OUT=$("$PARSE" "$MIXED_REV_LOG")
assert_contains "rule count annotated"                "$OUT" "tasks.required_untrusted_task_found (2)"
assert_contains "FAILING_COMPONENTS section present"  "$OUT" "FAILING_COMPONENTS:"
assert_contains "failing component a listed"          "$OUT" "widget-a-0-1 (rev 11111111)"
assert_contains "failing component b listed"          "$OUT" "widget-b-0-1 (rev 22222222)"
assert_not_contains "passing component not listed"    "$OUT" "widget-c-0-1"
assert_contains "revision mismatch warning shown"     "$OUT" "2 different git revisions"
assert_contains "non-task rule message detail shown"  "$OUT" "CVE scan results were not found"

echo ""
echo "=== Missing source.git.revision must not crash the script ==="

MISSING_REV_LOG="$TMPDIR_TEST/tekton-missing-revision.log"; make_tekton_log_with_missing_revision "$MISSING_REV_LOG"
OUT=$("$PARSE" "$MISSING_REV_LOG")
RC=0; "$PARSE" "$MISSING_REV_LOG" >/dev/null || RC=$?
assert_eq   "missing revision log → exit 0"              "$RC" "0"
assert_contains "component listed with unknown revision" "$OUT" "widget-0-1 (rev unknown)"
assert_not_contains "no spurious mismatch warning"        "$OUT" "different git revisions"

echo ""
echo "=== Non-task violation log ==="

NONTASK_LOG="$TMPDIR_TEST/non-task.log"; make_log_with_non_task_violations "$NONTASK_LOG"
OUT=$("$PARSE" "$NONTASK_LOG")
assert_contains "non-task rule extracted"        "$OUT" "attestation.missing_sbom"
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
