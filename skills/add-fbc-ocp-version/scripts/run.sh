#!/usr/bin/env bash
# Resolve relative to this skill, independently of the invoking working directory.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
root=${RELEASE_MANAGEMENT_REPO:-$root}
root=$(cd "$root" && pwd -P)
workflow="$root/.agents/workflows/add-fbc-ocp-version.md"
if [ ! -f "$root/scripts/fbc-onboard.py" ] || [ ! -f "$workflow" ] ||
   [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" != "$root" ]; then
  echo "Set RELEASE_MANAGEMENT_REPO to a submariner-release-management checkout" >&2
  exit 1
fi
if [ "${1:-}" = --workflow ]; then
  [ "$#" -eq 1 ] || { echo '--workflow takes no other arguments' >&2; exit 2; }
  printf '%s\n' "$workflow"
  exit 0
fi
exec "$root/scripts/add-fbc-ocp-version.sh" "$@"
