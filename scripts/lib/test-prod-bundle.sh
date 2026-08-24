#!/bin/bash
# Tests for prod-bundle.sh.
# Run: ./scripts/lib/test-prod-bundle.sh
#
# bundle_shipped_verdict and index_lists_bundle are pure, so no registry/network
# is needed. The I/O wrappers (prod_bundle_shipped, prod_index_has_bundle) are
# thin skopeo/oc glue and are left to integration use, matching the repo
# convention of testing the pure decision, not the network probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/prod-bundle.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}

echo "=== bundle_shipped_verdict Tests ==="

# New-scheme .0 at release time: no exact vX.Y.0 tag, floating vX.Y still on .0.
assert_eq "new .0 at release time -> shipped" \
  "$(bundle_shipped_verdict 0.24.0 true "" v0.24.0)" "shipped"

# New-scheme .0 after its first patch shipped: floating moved to .1 (the known
# limitation) -> not-shipped, the safe false-negative direction.
assert_eq "new .0 after .1 shipped -> not-shipped" \
  "$(bundle_shipped_verdict 0.24.0 true "" v0.24.1)" "not-shipped"

# Patch release: exact tag exists and floating also resolves to it.
assert_eq "patch release -> shipped" \
  "$(bundle_shipped_verdict 0.24.1 true v0.24.1 v0.24.1)" "shipped"

# Old-scheme .0 (<=0.22): exact vX.Y.0 tag exists.
assert_eq "old-scheme .0 -> shipped" \
  "$(bundle_shipped_verdict 0.22.0 true v0.22.0 v0.22.0)" "shipped"

# Exact match wins even if the floating tag has already moved past it.
assert_eq "exact match, floating moved on -> shipped" \
  "$(bundle_shipped_verdict 0.24.1 true v0.24.1 v0.24.2)" "shipped"

# Genuinely-never-shipped version, registry reachable -> not-shipped.
assert_eq "never shipped, reachable -> not-shipped" \
  "$(bundle_shipped_verdict 0.24.9 true "" v0.24.1)" "not-shipped"

# Registry unreachable (no probe resolved): must NOT claim not-shipped.
assert_eq "unreachable registry -> unreachable" \
  "$(bundle_shipped_verdict 0.24.0 false "" "")" "unreachable"

# Unreachable takes precedence only when there is no positive match; a resolved
# matching tag with reachable=false shouldn't occur, but if labels match we
# still honor the match.
assert_eq "match present despite reachable=false -> shipped" \
  "$(bundle_shipped_verdict 0.24.0 false v0.24.0 "")" "shipped"

echo ""
echo "=== index_lists_bundle Tests ==="

# Build a throwaway bundles dir mirroring what `oc image extract` drops.
IDX_DIR="$(mktemp -d)"
trap 'rm -rf "$IDX_DIR"' EXIT
touch "$IDX_DIR/bundle-v0.24.0.json" "$IDX_DIR/bundle-v0.24.1.json"

# Exact version present as .json -> yes.
assert_eq "index lists exact .json -> yes" \
  "$(index_lists_bundle "$IDX_DIR" 0.24.1)" "yes"

# A .yaml entry (older catalog format) is equally valid.
touch "$IDX_DIR/bundle-v0.23.5.yaml"
assert_eq "index lists exact .yaml -> yes" \
  "$(index_lists_bundle "$IDX_DIR" 0.23.5)" "yes"

# Version not in the index (this OCP didn't carry it) -> no.
assert_eq "version absent from index -> no" \
  "$(index_lists_bundle "$IDX_DIR" 0.24.2)" "no"

# No prefix/substring false positives: 0.24.1 present must not match 0.24.10.
assert_eq "no substring false-positive -> no" \
  "$(index_lists_bundle "$IDX_DIR" 0.24.10)" "no"

# Empty/never-extracted dir -> no (never a false shipped claim).
assert_eq "empty dir -> no" \
  "$(index_lists_bundle "$(mktemp -d)" 0.24.1)" "no"

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
