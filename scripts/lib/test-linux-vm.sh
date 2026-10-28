#!/usr/bin/env bash
# Tests for the macOS Linux-VM wrapper (stubbed limactl, uname, gh)
# Run: ./scripts/lib/test-linux-vm.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
VM="$SCRIPT_DIR/../linux-vm.sh"
REAL_UNAME="$(command -v uname)" # captured before PATH points at the stubs

PASS=0; FAIL=0
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1"; echo "    got:  '$2'"; echo "    want: '$3'"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; echo "    in: $2"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}

# Fresh sandbox with stub binaries. limactl logs each call (CALL, then one argument per line).
new_sandbox() {
  SB="$TMP/sb$((++N))"
  mkdir -p "$SB/bin" "$SB/home/go/src/submariner-io"
  export HOME="$SB/home" PATH="$SB/bin:$ORIG_PATH"
  export LIMA_LOG="$SB/lima.log" FAKE_OS=Darwin REAL_UNAME VM_EXISTS=1 LIMA_START_RC=0 LIMA_SHELL_RC=0
  export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset LIMA_RUN LIMA_CHECK_RC GH_AUTH_RC SUBMARINER_BASE RH_ORG RH_ACTIVATION_KEY RH_REGISTRY_USER RH_REGISTRY_PASSWORD \
    ENTITLEMENT_PASSWORD GH_TOKEN LIMACTL LINUX_VM_NAME
  git config --file "$GIT_CONFIG_GLOBAL" user.name "Test User"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.com"
  cat > "$SB/bin/uname" <<'STUB'
#!/bin/bash
if [ "${1:-}" = -s ]; then echo "$FAKE_OS"; else exec "$REAL_UNAME" "$@"; fi
STUB
  cat > "$SB/bin/gh" <<'STUB'
#!/bin/bash
[ "$1 $2" = "auth token" ] && echo "tok-123"
[ "$1 $2" = "auth status" ] && exit "${GH_AUTH_RC:-0}"
exit 0
STUB
  cat > "$SB/bin/limactl" <<'STUB'
#!/bin/bash
{ printf 'CALL\n'; printf '%s\n' "$@"; } >> "$LIMA_LOG"
case "$1" in
  list) [ "$VM_EXISTS" = 1 ] && echo "${LINUX_VM_NAME:-submariner-release}" ;;
  start) exit "$LIMA_START_RC" ;;
  shell)
    # LIMA_RUN=1: run the command after `--` for real, as the VM would
    case "$*" in *'chk()'*) exit "${LIMA_CHECK_RC:-0}" ;; esac # the VM probes
    if [ -n "${LIMA_RUN:-}" ]; then
      shift; while [ "$1" != -- ]; do shift; done; shift
      exec "$@"
    fi
    exit "$LIMA_SHELL_RC"
    ;;
esac
exit 0
STUB
  chmod +x "$SB/bin/"*
  : > "$LIMA_LOG"
}

reexec() {
  OUT=$(bash -c 'source "$1"; shift; linux_vm_reexec "$@"; echo "fell through"' _ \
    "$SCRIPT_DIR/linux-vm.sh" "$@" 2>&1) && RC=0 || RC=$?
  CALLS=$(cat "$LIMA_LOG")
}

ORIG_PATH="$PATH"; N=0

echo "=== Linux: no VM involved ==="
new_sandbox; FAKE_OS=Linux
reexec /x/scripts/rpm-lockfile-update.sh 0.24
assert_eq "returns to the caller" "$OUT" "fell through"
assert_eq "limactl not called" "$CALLS" ""

echo "=== macOS: runs the script in the VM ==="
new_sandbox
export RH_ORG=123 ENTITLEMENT_PASSWORD="pw with space"
reexec /x/scripts/rpm-lockfile-update.sh 0.24 "two words" --flag
assert_eq "exits with the VM command's status" "$RC" "0"
assert_not_contains "does not fall through" "$OUT" "fell through"
assert_contains "starts the VM first" "$CALLS" $'CALL\nstart\n--tty=false\nsubmariner-release\n'
assert_contains "runs from the repo root" "$CALLS" $'CALL\nshell\n--workdir\n'"$ROOT"$'\nsubmariner-release\n'
assert_contains "script path and arguments reach the VM intact" "$CALLS" \
  "$ROOT/scripts/rpm-lockfile-update.sh"$'\n0.24\ntwo words\n--flag'
assert_contains "SUBMARINER_BASE defaults from the host HOME" "$CALLS" "SUBMARINER_BASE=$HOME/go/src/submariner-io"
assert_contains "gh token forwarded" "$CALLS" "GH_TOKEN=tok-123"
assert_contains "entitlement settings forwarded" "$CALLS" "RH_ORG=123"
assert_contains "values with spaces stay one argument" "$CALLS" $'\nENTITLEMENT_PASSWORD=pw with space\n'
assert_not_contains "unset settings are not forwarded" "$CALLS" "RH_ACTIVATION_KEY"

echo "=== macOS: failures ==="
new_sandbox; LIMA_SHELL_RC=7
reexec /x/scripts/rpm-lockfile-update.sh
assert_eq "command failure propagates its exit code" "$RC" "7"

new_sandbox; LIMA_START_RC=1
reexec /x/scripts/rpm-lockfile-update.sh
assert_eq "VM unavailable: exits 1" "$RC" "1"
assert_contains "VM unavailable: says how to create it" "$OUT" "make linux-vm-setup"
assert_not_contains "VM unavailable: never shells in" "$CALLS" $'CALL\nshell'

new_sandbox; VM_EXISTS=0
reexec /x/scripts/rpm-lockfile-update.sh
assert_eq "VM missing: exits 1" "$RC" "1"
assert_contains "VM missing: says how to create it" "$OUT" "make linux-vm-setup"
assert_not_contains "VM missing: never runs limactl start (it would create a default VM)" "$CALLS" $'CALL\nstart'

new_sandbox; rm "$SB/bin/limactl"
reexec /x/scripts/rpm-lockfile-update.sh
assert_eq "no limactl: exits 1" "$RC" "1"
assert_contains "no limactl: says how to install" "$OUT" "brew install lima"

new_sandbox; export LINUX_VM_NAME=other
reexec /x/scripts/rpm-lockfile-update.sh
assert_contains "VM name is configurable" "$CALLS" $'CALL\nstart\n--tty=false\nother\n'

echo "=== the command that runs in the VM ==="
new_sandbox; export LIMA_RUN=1
reexec /x/scripts/linux-vm.sh --help
assert_contains "hands off to the script with its arguments" "$OUT" "Usage: linux-vm.sh setup | check"

new_sandbox; export LIMA_RUN=1 SUBMARINER_BASE="$SB/moved"
reexec /x/scripts/linux-vm.sh --help
assert_eq "unmounted SUBMARINER_BASE: exits 1 instead of skipping repos" "$RC" "1"
assert_contains "unmounted SUBMARINER_BASE: says how to recreate" "$OUT" "is not mounted in the VM"
assert_not_contains "unmounted SUBMARINER_BASE: script never runs" "$OUT" "Usage:"

echo "=== linux-vm.sh setup ==="
new_sandbox; VM_EXISTS=0
OUT=$(cd "$SB" && "$VM" setup 2>&1) && RC=0 || RC=$?; CALLS=$(cat "$LIMA_LOG")
assert_eq "succeeds" "$RC" "0"
assert_contains "creates the VM with the repos as writable and this repo read-only" "$CALLS" \
  $'create\n--name\nsubmariner-release\n--tty=false\n--mount-only\n'"$SB/home/go/src/submariner-io:w"$'\n--mount-only\n'"$ROOT"$'\n'
assert_contains "starts it" "$CALLS" $'CALL\nstart\n--tty=false\nsubmariner-release'
assert_contains "gives it the git identity" "$CALLS" $'git\nconfig\n--global\nuser.email\ntest@example.com'

new_sandbox
OUT=$(cd "$SB" && "$VM" setup 2>&1) && RC=0 || RC=$?; CALLS=$(cat "$LIMA_LOG")
assert_not_contains "existing VM is not recreated" "$CALLS" $'CALL\ncreate'

new_sandbox; export SUBMARINER_BASE="$SB/nonexistent"
OUT=$(cd "$SB" && "$VM" setup 2>&1) && RC=0 || RC=$?
assert_eq "missing SUBMARINER_BASE fails" "$RC" "1"
assert_contains "names the missing path" "$OUT" "SUBMARINER_BASE not found"

new_sandbox; : > "$GIT_CONFIG_GLOBAL"
OUT=$(cd "$SB" && "$VM" setup 2>&1) && RC=0 || RC=$?; CALLS=$(cat "$LIMA_LOG")
assert_eq "no git identity: fails" "$RC" "1"
assert_not_contains "no git identity: nothing created" "$CALLS" $'CALL\ncreate'

new_sandbox; export GH_AUTH_RC=1
OUT=$(cd "$SB" && "$VM" setup 2>&1) && RC=0 || RC=$?
assert_eq "not logged in to gh: fails" "$RC" "1"
assert_contains "not logged in to gh: says how to fix it" "$OUT" "gh auth login"

echo "=== linux-vm.sh check / usage ==="
new_sandbox
OUT=$("$VM" check 2>&1) && RC=0 || RC=$?
assert_eq "passing probes: check succeeds" "$RC" "0"
new_sandbox; export LIMA_CHECK_RC=1
OUT=$("$VM" check 2>&1) && RC=0 || RC=$?
assert_eq "a failing probe fails check" "$RC" "1"
new_sandbox; VM_EXISTS=0
OUT=$("$VM" check 2>&1) && RC=0 || RC=$?; CALLS=$(cat "$LIMA_LOG")
assert_eq "no VM: check fails" "$RC" "1"
assert_not_contains "no VM: check never runs limactl start" "$CALLS" $'CALL\nstart'

OUT=$("$VM" --help 2>&1) && RC=0 || RC=$?
assert_eq "--help exits 0" "$RC" "0"
OUT=$("$VM" bogus 2>&1) && RC=0 || RC=$?
assert_eq "unknown command exits 2" "$RC" "2"

echo
echo "════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then echo "All $PASS tests passed"; else echo "$FAIL FAILED, $PASS passed"; exit 1; fi
