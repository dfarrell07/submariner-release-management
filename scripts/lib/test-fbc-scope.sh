#!/bin/bash
# Tests for fbc-scope.sh.
# Run: ./scripts/lib/test-fbc-scope.sh
#
# get_fbc_ocp_scope reads a releases/ tree by filename date, no network, so it is
# driven here against a throwaway fixture tree of empty dated YAML files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fbc-scope.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}

OCP="16 17 18 19 20 21 22"

# Build a fixture tree for one release under a temp root.
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mk() { mkdir -p "$(dirname "$ROOT/$1")"; : > "$ROOT/$1"; }

# Component prod release for 0.24.1 on 2026-08-13.
mk releases/0.24/prod/submariner-0-24-1-prod-20260813-01.yaml
# FBC prod releases within ±3 days -> in scope (19, 20, 21, 22).
mk releases/fbc/4-19/prod/submariner-fbc-4-19-prod-20260814-01.yaml
mk releases/fbc/4-20/prod/submariner-fbc-4-20-prod-20260813-01.yaml
mk releases/fbc/4-21/prod/submariner-fbc-4-21-prod-20260815-01.yaml
mk releases/fbc/4-22/prod/submariner-fbc-4-22-prod-20260813-01.yaml
# 4-18 only has a much older release (a prior version) -> out of window, excluded.
mk releases/fbc/4-18/prod/submariner-fbc-4-18-prod-20251201-01.yaml
# 4-17 dir exists but holds no YAMLs -> excluded.
mkdir -p "$ROOT/releases/fbc/4-17/prod"

echo "=== get_fbc_ocp_scope Tests ==="

# Only the OCP versions with an FBC prod YAML inside the window are in scope.
assert_eq "prod scope = in-window OCP versions" \
  "$(get_fbc_ocp_scope "$ROOT" 0.24 0-24-1 prod "$OCP")" "19 20 21 22"

# An OCP version whose newest prod YAML predates the window is excluded (so a
# later release that dropped an EOL'd OCP version never blocks auto-close on it).
assert_eq "stale prior-release YAML excluded (4-18 absent)" \
  "$(get_fbc_ocp_scope "$ROOT" 0.24 0-24-1 prod "18")" ""

# No component YAML for the version -> empty (undeterminable, hold off).
assert_eq "no component YAML -> empty" \
  "$(get_fbc_ocp_scope "$ROOT" 0.99 0-99-9 prod "$OCP")" ""

# Wrong env (no stage tree here) -> empty.
assert_eq "no stage tree -> empty" \
  "$(get_fbc_ocp_scope "$ROOT" 0.24 0-24-1 stage "$OCP")" ""

# A newer in-window prod YAML added later for 4-18 pulls it into scope.
mk releases/fbc/4-18/prod/submariner-fbc-4-18-prod-20260813-02.yaml
assert_eq "in-window YAML pulls 4-18 into scope" \
  "$(get_fbc_ocp_scope "$ROOT" 0.24 0-24-1 prod "$OCP")" "18 19 20 21 22"

# Exactly-3-day boundary (259200s): the -le fix makes this in-scope;
# reverting to -lt would make this fail (mutation-verifiable).
mk releases/fbc/4-16/prod/submariner-fbc-4-16-prod-20260816-01.yaml
assert_eq "exactly 3-day boundary included (4-16, 20260816 = 20260813 + 3d)" \
  "$(get_fbc_ocp_scope "$ROOT" 0.24 0-24-1 prod "16")" "16"
# One day beyond the window is excluded.
mk releases/fbc/4-17/prod/submariner-fbc-4-17-prod-20260817-01.yaml
assert_eq "4-day gap excluded (4-17, 20260817 = 20260813 + 4d)" \
  "$(get_fbc_ocp_scope "$ROOT" 0.24 0-24-1 prod "17")" ""

echo ""
echo "=== get_release_ocp_scope Wrapper Argument-Mapping Tests ==="
# get_release_ocp_scope in release-status.sh is a thin wrapper that delegates to
# get_fbc_ocp_scope with positional arguments derived from globals.  An accidental
# transposition (e.g., MAJOR_MINOR and FULL_VERSION_DASH swapped) silently produces
# empty scope for every release-status query.  This test sources the live function
# body and uses a spy to verify the exact argument order it passes to get_fbc_ocp_scope.

_rs_file="$SCRIPT_DIR/../release-status.sh"
_wrapper_file=$(mktemp)
# Extract just the get_release_ocp_scope function definition from release-status.sh.
sed -n '/^get_release_ocp_scope()/,/^}/p' "$_rs_file" > "$_wrapper_file"
# shellcheck source=/dev/null
source "$_wrapper_file"
rm -f "$_wrapper_file"

# Spy: override get_fbc_ocp_scope to record arguments without doing real work.
_saved_get_fbc_ocp_scope=$(declare -f get_fbc_ocp_scope)
_spy_args=""
get_fbc_ocp_scope() { _spy_args="$*"; }

# shellcheck disable=SC2034  # consumed by get_release_ocp_scope via globals
MAJOR_MINOR="0.24"
# shellcheck disable=SC2034  # consumed by get_release_ocp_scope via globals
FULL_VERSION_DASH="0-24-1"
get_release_ocp_scope "prod" >/dev/null 2>&1 || true

# Restore the original implementation.
eval "$_saved_get_fbc_ocp_scope"

# The spy must have been called with:
#   arg1 = "."  (repo root — a literal dot)
#   arg2 = "0.24"  (MAJOR_MINOR — NOT FULL_VERSION_DASH)
#   arg3 = "0-24-1"  (FULL_VERSION_DASH — NOT MAJOR_MINOR)
#   arg4 = "prod"  (the env passed to the wrapper)
#   arg5 = "$FBC_OCP_VERSIONS"
_spy_arg1=$(echo "$_spy_args" | awk '{print $1}')
_spy_arg2=$(echo "$_spy_args" | awk '{print $2}')
_spy_arg3=$(echo "$_spy_args" | awk '{print $3}')
_spy_arg4=$(echo "$_spy_args" | awk '{print $4}')

assert_eq "get_release_ocp_scope: arg1 is repo root '.'" "$_spy_arg1" "."
assert_eq "get_release_ocp_scope: arg2 is MAJOR_MINOR (0.24)" "$_spy_arg2" "0.24"
assert_eq "get_release_ocp_scope: arg3 is FULL_VERSION_DASH (0-24-1)" "$_spy_arg3" "0-24-1"
assert_eq "get_release_ocp_scope: arg4 is env (prod)" "$_spy_arg4" "prod"

unset MAJOR_MINOR FULL_VERSION_DASH _spy_args _spy_arg1 _spy_arg2 _spy_arg3 _spy_arg4

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
