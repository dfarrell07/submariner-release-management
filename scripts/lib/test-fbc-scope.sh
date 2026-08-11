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
