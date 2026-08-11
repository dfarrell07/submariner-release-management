#!/bin/bash
# Tests for the signal-killed job detection in parallel-jobs.sh.
# A job registered in jobs.txt but missing its .exit file (killed before
# writing it) must be treated as failed — wait_parallel_jobs must return 1.
#
# Run: ./scripts/lib/test-parallel-jobs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0 FAIL=0
assert_exit() {
  local desc="$1" want="$2"
  shift 2
  local got=0
  "$@" 2>/dev/null || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc (exit $got, want $want)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== parallel-jobs.sh: signal-killed job detection ==="

# Helper: run wait_parallel_jobs in a subshell with its own TMPDIR.
# Args: job_names (space-separated), exit_files_to_create (space-separated)
# Remaining args: additional setup commands (unused for now)
run_with_jobs() {
  local jobs="$1"
  local create_exits="$2"

  (
    export TMPDIR
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    # Source inside the subshell so TMPDIR is correct
    source "$SCRIPT_DIR/parallel-jobs.sh"

    # Register jobs
    for j in $jobs; do
      echo "$j" >> "$TMPDIR/jobs.txt"
    done
    # pids.txt must exist (empty) so the wait loop is a no-op
    touch "$TMPDIR/pids.txt"

    # Write exit files for any jobs that "completed normally"
    for j in $create_exits; do
      echo "0" > "$TMPDIR/${j}.exit"
    done

    wait_parallel_jobs "snapshot"
  )
}

# A job in jobs.txt with no .exit file must cause wait_parallel_jobs to fail.
assert_exit "missing .exit file → exit 1" 1 \
  run_with_jobs "ocp-4-16" ""

# A job in jobs.txt with a .exit file (exit 0) must succeed.
assert_exit "present .exit file (exit 0) → exit 0" 0 \
  run_with_jobs "ocp-4-16" "ocp-4-16"

# Multiple jobs: one missing .exit is enough to fail.
assert_exit "one of two missing .exit → exit 1" 1 \
  run_with_jobs "ocp-4-16 ocp-4-17" "ocp-4-17"

# Multiple jobs: all .exit present → succeed.
assert_exit "both .exit present → exit 0" 0 \
  run_with_jobs "ocp-4-16 ocp-4-17" "ocp-4-16 ocp-4-17"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "All $PASS tests passed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$FAIL of $((PASS + FAIL)) tests FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
