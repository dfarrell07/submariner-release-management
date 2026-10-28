#!/usr/bin/env bash
# Create or verify the Linux VM that runs the RPM lockfile steps on macOS.
#
# Usage: linux-vm.sh setup | check
#
#   setup  Create the Lima Fedora VM (first time), start it, and give it your git identity
#   check  Verify the VM has its tools and can mount and run podman volumes on the repos
#
# Needs Lima 2.0+ (brew install lima). To delete the VM, run
# `limactl shell submariner-release sudo subscription-manager unregister` first, or its
# registration stays on the shared account.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/linux-vm.sh
source "$SCRIPT_DIR/lib/linux-vm.sh"

die() { echo "❌ $1" >&2; exit 1; }

cmd_setup() {
  command -v "$LIMACTL" &>/dev/null || die "limactl not found. Install: brew install lima"
  local base="${SUBMARINER_BASE:-$HOME/go/src/submariner-io}" name email
  [ -d "$base" ] || die "SUBMARINER_BASE not found: $base (clone the Submariner repos there, or set SUBMARINER_BASE)"
  name=$(git config user.name || true) email=$(git config user.email || true)
  [ -n "$name" ] && [ -n "$email" ] || die "Set git user.name and user.email first; the VM commits lockfile updates"
  gh auth status &>/dev/null || die "Not logged in to GitHub. Run: gh auth login"
  if ! linux_vm_exists; then
    # Same paths as the host: the repos (writable; lockfile commits land there) and this repo (read-only)
    "$LIMACTL" create --name "$LINUX_VM_NAME" --tty=false \
      --mount-only "$base:w" --mount-only "$LINUX_VM_REPO_ROOT" "$SCRIPT_DIR/lima/release-vm.yaml" >&2
  fi
  "$LIMACTL" start --tty=false "$LINUX_VM_NAME" >&2
  "$LIMACTL" shell "$LINUX_VM_NAME" -- git config --global user.name "$name"
  "$LIMACTL" shell "$LINUX_VM_NAME" -- git config --global user.email "$email"
  echo "✓ VM created. Next: make linux-vm-check, then make setup-entitlements"
}

readonly GUEST_CHECKS='
ok=0
chk() { if "${@:2}" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1"; ok=1; fi; }
for t in git podman gh gpg subscription-manager; do chk "$t installed" command -v "$t"; done
chk "$1 is writable" test -w "$1"
chk "podman runs a container with a :z volume on the mount" \
  podman run --rm -v "$1:/probe:z" registry.access.redhat.com/ubi9/ubi-minimal true
exit $ok
'

cmd_check() {
  local base="${SUBMARINER_BASE:-$HOME/go/src/submariner-io}"
  linux_vm_exists && "$LIMACTL" start --tty=false "$LINUX_VM_NAME" >&2 || die "No VM '$LINUX_VM_NAME'. Run: make linux-vm-setup"
  echo "Linux VM '$LINUX_VM_NAME':"
  "$LIMACTL" shell "$LINUX_VM_NAME" -- bash -c "$GUEST_CHECKS" _ "$base"
}

case "${1:-}" in
  setup) cmd_setup ;;
  check) cmd_check ;;
  -h | --help | "") sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] ;;
  *) echo "Unknown command: $1 (see --help)" >&2; exit 2 ;;
esac
