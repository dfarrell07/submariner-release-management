#!/usr/bin/env bash
# Tests for lib/upstream-tags.sh's require_upstream_tag.
# Run: ./scripts/lib/test-upstream-tags.sh
# shellcheck disable=SC2329  # _git_ls_remote is called by the sourced library
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/upstream-tags.sh"

PASS=0 FAIL=0
_git_ls_remote() {  # <--tags> <repo url> <ref>
  case "$_LS_MODE" in
    tagged) printf 'abc\t%s\n' "$3" ;;
    rc-only) printf 'abc\t%s-rc1\n' "$3" ;;
    missing) [ "${2##*/}" = shipyard ] || printf 'abc\t%s\n' "$3" ;;
    timeout) return 124 ;;
  esac
}
check() {  # <desc> <ls mode> <override> <want rc> [want output]
  local rc=0 out
  out=$(_LS_MODE="$2" ALLOW_PRE_TAG_CANDIDATE="$3" require_upstream_tag 0.99.0 bundleShas 2>&1) || rc=$?
  if [ "$rc" = "$4" ] && printf '%s' "$out" | grep -qF -- "${5:-}"; then
    echo "  ✓ $1"; PASS=$((PASS + 1))
  else
    echo "  ✗ $1 (rc $rc, want $4; output: $out)"; FAIL=$((FAIL + 1))
  fi
}

echo "=== require_upstream_tag Tests ==="
check "tag present → continue"           tagged  ""    0 "v0.99.0 is on all five component repos"
check "tag missing on one repo → stop"   missing ""    1 "ALLOW_PRE_TAG_CANDIDATE=true"
check "only an rc tag → stop"            rc-only ""    1
check "override → continue with warning" missing true  0 "WARNING: continuing without v0.99.0"
check "override other than true → stop"  missing 1     1
check "ls-remote failure → stop, rc 1"   timeout ""    1 "re-run to retry"
check "ls-remote failure, override → stop" timeout true 1

echo ""
if [ "$FAIL" -eq 0 ]; then echo "All $PASS tests passed"; exit 0; fi
echo "$FAIL of $((PASS + FAIL)) tests FAILED"; exit 1
