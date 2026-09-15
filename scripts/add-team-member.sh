#!/bin/bash
# Add a user to the Submariner tenant RBAC in konflux-release-data.

set -euo pipefail

usage() {
  echo "Usage: $0 <username> [admin|maintainer|contributor]" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

TARGET_USER=$1
ROLE=${2:-contributor}

case "$ROLE" in
  admin|maintainer|contributor) ;;
  admins|maintainers|contributors) ROLE=${ROLE%s} ;;
  *) die "Invalid role '$ROLE' (expected admin, maintainer, or contributor)" ;;
esac

if [[ ! "$TARGET_USER" =~ ^[a-z][a-z0-9]{0,7}$ ]]; then
  die "Invalid username '$TARGET_USER' (expected 1-8 lowercase letters or numbers, starting with a letter)"
fi

for command in git yq yamllint; do
  command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

TARGET_ROOT=${KONFLUX_RELEASE_DATA:-$HOME/konflux/konflux-release-data}
[ -d "$TARGET_ROOT" ] || die "konflux-release-data repository not found: $TARGET_ROOT"
cd "$TARGET_ROOT"

[ -f tenants-config/build-single.sh ] || \
  die "Invalid konflux-release-data repository (missing tenants-config/build-single.sh)"
git_root=$(git rev-parse --show-toplevel 2>/dev/null) || \
  die "Target is not a Git worktree: $TARGET_ROOT"
if [ "$(cd "$git_root" && pwd -P)" != "$(pwd -P)" ]; then
  die "Git root does not match target directory: $TARGET_ROOT"
fi

worktree_status=$(git status --porcelain --untracked-files=all) || \
  die "Failed to inspect target worktree"
if [ -n "$worktree_status" ]; then
  echo "ERROR: Target worktree has uncommitted changes:" >&2
  printf '%s\n' "$worktree_status" >&2
  exit 1
fi

RBAC_FILE="tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/rbac-${ROLE}s.yaml"
[ -f "$RBAC_FILE" ] || die "RBAC file not found: $RBAC_FILE"
yamllint "$RBAC_FILE"

if TARGET_USER="$TARGET_USER" yq eval -e \
  '.subjects[] | select(.kind == "User" and .name == strenv(TARGET_USER))' \
  "$RBAC_FILE" >/dev/null 2>&1; then
  echo "User '$TARGET_USER' already exists in the $ROLE role. No changes needed."
  exit 0
fi

BRANCH="add-${TARGET_USER}-${ROLE}"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "Branch '$BRANCH' already exists locally; review or remove it manually before retrying"
fi
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  die "Branch '$BRANCH' already exists on origin; choose the existing work or remove it before retrying"
fi
git checkout -b "$BRANCH"

TARGET_USER="$TARGET_USER" yq eval \
  '.subjects += [{"apiGroup": "rbac.authorization.k8s.io", "kind": "User", "name": strenv(TARGET_USER)}] | .subjects |= sort_by(.name)' \
  -i "$RBAC_FILE"

TARGET_USER="$TARGET_USER" yq eval -e \
  '.subjects[] | select(.kind == "User" and .name == strenv(TARGET_USER))' \
  "$RBAC_FILE" >/dev/null || \
  die "Failed to add '$TARGET_USER' to $RBAC_FILE"
yamllint "$RBAC_FILE"

(cd tenants-config && ./build-single.sh submariner-tenant)

GENERATED_DIR="tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant"
GENERATED_FILE="$GENERATED_DIR/rbac.authorization.k8s.io_v1_rolebinding_submariner-tenant-konflux-${ROLE}s.yaml"
[ -f "$GENERATED_FILE" ] || die "Generated RBAC file not found: $GENERATED_FILE"
TARGET_USER="$TARGET_USER" yq eval -e \
  '.subjects[] | select(.kind == "User" and .name == strenv(TARGET_USER))' \
  "$GENERATED_FILE" >/dev/null || \
  die "Generated RBAC file does not contain '$TARGET_USER': $GENERATED_FILE"

git add "$RBAC_FILE" "$GENERATED_DIR/"
git commit -s -m "Add $TARGET_USER to submariner-tenant ${ROLE}s

Grants $ROLE access to Submariner Konflux namespace and Web UI."

echo
echo "Added $TARGET_USER as a submariner-tenant $ROLE."
echo "Branch: $BRANCH"
echo "Review the local commit with: git show"
echo "No branch was pushed."
