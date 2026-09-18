#!/bin/bash
# Verify repository-owned release delegates do not depend on the caller's cwd.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UNRELATED_DIR=$(mktemp -d)
trap 'rm -rf "$UNRELATED_DIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local name=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (got: '$actual', want: '$expected')"
    FAIL=$((FAIL + 1))
  fi
}

resolved_root() {
  local script=$1 variable=$2
  (
    cd "$UNRELATED_DIR"
    # shellcheck disable=SC1090
    source "$script"
    printf '%s' "${!variable}"
  )
}

echo "=== Release Root Resolution Tests ==="

assert_eq "component release resolves its checkout" \
  "$(resolved_root "$RELEASE_ROOT/scripts/create-component-release.sh" GIT_ROOT)" "$RELEASE_ROOT"
assert_eq "FBC release resolves its checkout" \
  "$(resolved_root "$RELEASE_ROOT/scripts/create-fbc-releases.sh" GIT_ROOT)" "$RELEASE_ROOT"
assert_eq "FBC URL lookup resolves its checkout" \
  "$(resolved_root "$RELEASE_ROOT/scripts/get-fbc-urls.sh" GIT_ROOT)" "$RELEASE_ROOT"

status_help=$(cd "$UNRELATED_DIR" && "$RELEASE_ROOT/scripts/release-status.sh" help)
if [[ "$status_help" == *"Usage: scripts/release-status.sh <version>"* ]]; then
  echo "  ✓ release status starts outside its checkout"
  PASS=$((PASS + 1))
else
  echo "  ✗ release status failed outside its checkout"
  FAIL=$((FAIL + 1))
fi

# Keep release-status's data reads anchored as new checks are added. This is a
# narrow executable-path invariant, not a prose-format assertion.
if rg -n 'find "releases/|for [^;]+ in releases/' "$RELEASE_ROOT/scripts/release-status.sh"; then
  echo "  ✗ release status contains caller-relative release paths"
  FAIL=$((FAIL + 1))
else
  echo "  ✓ release status data paths are checkout-relative"
  PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
