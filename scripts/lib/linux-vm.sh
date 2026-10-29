#!/usr/bin/env bash
# On macOS, re-run the calling script in the Lima Fedora VM (scripts/linux-vm.sh setup),
# which has subscription-manager and /etc/pki/entitlement. No-op on Linux.
# Direct runs may use macOS's bash 3.2, so keep this 3.2-compatible. Test hook: LIMACTL.

LINUX_VM_NAME="${LINUX_VM_NAME:-submariner-release}"
LIMACTL="${LIMACTL:-limactl}"
LINUX_VM_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# `limactl start NAME` creates a default VM when NAME does not exist, so check first
linux_vm_exists() { "$LIMACTL" list -q 2>/dev/null | grep -qx "$LINUX_VM_NAME"; }

# linux_vm_reexec SCRIPT ARGS...: run SCRIPT (in this repo's scripts/) in the VM and exit with its status.
# It runs as `bash SCRIPT` so it does not depend on the exec bit surviving the host mount.
linux_vm_reexec() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local script="$LINUX_VM_REPO_ROOT/scripts/${1##*/}" base="${SUBMARINER_BASE:-$HOME/go/src/submariner-io}" var tok
  shift
  command -v "$LIMACTL" &>/dev/null || { echo "❌ limactl not found. Install: brew install lima; then: make linux-vm-setup" >&2; exit 1; }
  linux_vm_exists && "$LIMACTL" start --tty=false "$LINUX_VM_NAME" >&2 ||
    { echo "❌ Linux VM '$LINUX_VM_NAME' unavailable. Create it: make linux-vm-setup" >&2; exit 1; }
  # The VM has no gh login or secrets of its own; pass what the scripts read (visible in ps, like the activation key)
  local -a vars=("SUBMARINER_BASE=$base")
  for var in ENTITLEMENT_PASSWORD RH_ORG RH_ACTIVATION_KEY RH_REGISTRY_USER RH_REGISTRY_PASSWORD; do
    [ -z "${!var:-}" ] || vars+=("$var=${!var}")
  done
  tok=$(gh auth token 2>/dev/null || true)
  [ -z "$tok" ] || vars+=("GH_TOKEN=$tok")
  # Mounts are fixed when the VM is created; a moved SUBMARINER_BASE would otherwise skip every repo silently
  exec "$LIMACTL" shell --workdir "$LINUX_VM_REPO_ROOT" "$LINUX_VM_NAME" -- bash -c \
    'test -d "$1" || { echo "❌ $1 is not mounted in the VM. Recreate it: limactl delete -f '"$LINUX_VM_NAME"'; make linux-vm-setup" >&2; exit 1; }; shift; exec env "$@"' \
    _ "$base" "${vars[@]}" bash "$script" "$@"
}
