#!/bin/bash
# Shared helper: run background jobs and collect their exit codes/stderr.
#
# Sourced by verify-fbc-release.sh and get-fbc-urls.sh, which both fan out
# per-OCP-version work (snapshot extraction / bundle lookup) across parallel
# subshells. The harness was previously duplicated verbatim in both scripts and
# had drifted (differing increment idiom and error-banner spacing) — the exact
# situation lib/pipeline-patcher.sh was created to fix.
#
# Both functions rely on the caller-set global TMPDIR (as pipeline-patcher.sh
# relies on caller state). This file is meant to be sourced, not executed.

# Run "$job_func $@" in the background, capturing its stderr and exit code under
# $TMPDIR/<job_name>.{stderr,exit}. Records the PID in $TMPDIR/pids.txt.
run_parallel_job() {
  local job_name="$1"
  local job_func="$2"
  shift 2
  (
    set -euo pipefail
    EXIT_CODE=0
    "${job_func}" "$@" 2>"$TMPDIR/${job_name}.stderr" || EXIT_CODE=$?
    echo "$EXIT_CODE" > "$TMPDIR/${job_name}.exit"
  ) &
  echo "$!" >> "$TMPDIR/pids.txt"
  echo "$job_name" >> "$TMPDIR/jobs.txt"
}

# Wait for every job started via run_parallel_job, then fail (return 1) if any
# job exited non-zero, printing each failed job's name and stderr. On success,
# cleans up the batch's tracking files so TMPDIR can be reused.
wait_parallel_jobs() {
  local job_description="$1"

  # Wait for all background jobs (don't abort on an individual failure)
  while read -r pid; do
    wait "$pid" || true
  done < "$TMPDIR/pids.txt"

  # Collect failures after all jobs complete
  local failed_count=0
  local error_msg=""
  local exit_code
  local job_name
  local stderr
  for exit_file in "$TMPDIR"/*.exit; do
    [ -f "$exit_file" ] || continue
    exit_code=$(cat "$exit_file")
    if [ "$exit_code" -ne 0 ]; then
      failed_count=$((failed_count + 1))
      job_name=$(basename "$exit_file" .exit)
      stderr=$(cat "${exit_file%.exit}.stderr" 2>/dev/null || echo "")
      error_msg="${error_msg}  ${job_name}: ${stderr}\n"
    fi
  done

  # Cross-check: jobs killed before writing .exit are treated as failed
  if [ -f "$TMPDIR/jobs.txt" ]; then
    while read -r job_name; do
      if [ ! -f "$TMPDIR/${job_name}.exit" ]; then
        failed_count=$((failed_count + 1))
        stderr=$(cat "$TMPDIR/${job_name}.stderr" 2>/dev/null || echo "unexpectedly killed (no exit code written)")
        error_msg="${error_msg}  ${job_name}: ${stderr}\n"
      fi
    done < "$TMPDIR/jobs.txt"
  fi

  if [ "$failed_count" -gt 0 ]; then
    echo "" >&2
    echo "❌ ERROR: $failed_count $job_description job(s) failed:" >&2
    echo -e "$error_msg" >&2
    return 1
  fi

  # Clean up for the next parallel batch
  rm -f "$TMPDIR/pids.txt" "$TMPDIR/jobs.txt" "$TMPDIR"/*.exit "$TMPDIR"/*.stderr 2>/dev/null || true
}
