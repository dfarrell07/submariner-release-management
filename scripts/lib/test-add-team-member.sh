#!/bin/bash
# Exercise add-team-member against disposable konflux-release-data repositories.

set -euo pipefail

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADD_TEAM_MEMBER="$SCRIPT_ROOT/add-team-member.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

while IFS= read -r git_env; do
  unset "$git_env"
done < <(git rev-parse --local-env-vars)

PASS=0
FAIL=0

pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (got '$actual', expected '$expected')"
  fi
}

new_fixture() {
  local name=$1 root="$TEST_ROOT/$1"
  mkdir -p "$root/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant"
  mkdir -p "$root/tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant"

  local role
  for role in admin maintainer contributor; do
    cat > "$root/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/rbac-${role}s.yaml" <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: submariner-tenant-konflux-${role}s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: konflux-${role}-user-actions
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: auser
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: zuser
EOF
  done

  cat > "$root/tenants-config/build-single.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = submariner-tenant ]
source_dir=cluster/kflux-prd-rh02/tenants/submariner-tenant
target_dir=auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant
for role in admins maintainers contributors; do
  cp "$source_dir/rbac-$role.yaml" \
    "$target_dir/rbac.authorization.k8s.io_v1_rolebinding_submariner-tenant-konflux-$role.yaml"
done
EOF
  chmod +x "$root/tenants-config/build-single.sh"
  (cd "$root/tenants-config" && ./build-single.sh submariner-tenant)

  git init -q -b main "$root"
  git -C "$root" config user.name 'Team Member Test'
  git -C "$root" config user.email test@example.invalid
  git -C "$root" config core.hooksPath /dev/null
  git -C "$root" config commit.gpgsign false
  git -C "$root" add -A
  git -C "$root" commit -qm base
  printf '%s' "$root"
}

run_success() {
  local name=$1 user=$2 role_arg=${3:-} expected_role=$4
  local root output source_file generated_file
  root=$(new_fixture "$name")
  if [ -n "$role_arg" ]; then
    output=$(KONFLUX_RELEASE_DATA="$root" "$ADD_TEAM_MEMBER" "$user" "$role_arg" 2>&1)
  else
    output=$(KONFLUX_RELEASE_DATA="$root" "$ADD_TEAM_MEMBER" "$user" 2>&1)
  fi

  source_file="tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/rbac-${expected_role}s.yaml"
  generated_file="tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant/rbac.authorization.k8s.io_v1_rolebinding_submariner-tenant-konflux-${expected_role}s.yaml"
  assert_eq "$name branch" "$(git -C "$root" branch --show-current)" "add-$user-$expected_role"
  assert_eq "$name sorted source" \
    "$(yq eval '.subjects[].name' "$root/$source_file" | paste -sd, -)" "auser,$user,zuser"
  if TARGET_USER="$user" yq eval -e \
    '.subjects[] | select(.kind == "User" and .name == strenv(TARGET_USER))' \
    "$root/$generated_file" >/dev/null; then
    pass "$name generated manifest"
  else
    fail "$name generated manifest"
  fi
  assert_eq "$name committed paths" \
    "$(git -C "$root" diff-tree --no-commit-id --name-only -r HEAD | sort | paste -sd, -)" \
    "$generated_file,$source_file"
  if git -C "$root" show -s --format=%B HEAD | grep -q '^Signed-off-by: Team Member Test <test@example.invalid>$'; then
    pass "$name signed-off commit"
  else
    fail "$name signed-off commit"
  fi
  assert_eq "$name commit subject" \
    "$(git -C "$root" show -s --format=%s HEAD)" \
    "Add $user to submariner-tenant ${expected_role}s"
  if git -C "$root" show -s --format=%B HEAD | grep -q \
    "^Grants $expected_role access to Submariner Konflux namespace and Web UI.$"; then
    pass "$name commit body"
  else
    fail "$name commit body"
  fi
  assert_eq "$name clean after commit" \
    "$(git -C "$root" status --porcelain --untracked-files=all)" ''
  if [[ "$output" == *"No branch was pushed."* ]]; then
    pass "$name reports local-only result"
  else
    fail "$name reports local-only result"
  fi
}

expect_failure() {
  local label=$1 expected=$2 root=$3
  shift 3
  local output
  if output=$(KONFLUX_RELEASE_DATA="$root" "$ADD_TEAM_MEMBER" "$@" 2>&1); then
    fail "$label unexpectedly succeeded"
  elif [[ "$output" == *"$expected"* ]]; then
    pass "$label"
  else
    fail "$label missing error '$expected': $output"
  fi
}

echo "=== Successful role updates ==="
run_success 'path with spaces' bmiller admin admin
run_success maintainer csmith maintainers maintainer
run_success default-contributor dgreen '' contributor

echo
echo "=== Input validation ==="
validation_root=$(new_fixture validation)
expect_failure missing-user 'Usage:' "$validation_root"
for invalid_user in Alice 1alice toolong99 'bad-name'; do
  expect_failure "invalid user $invalid_user" 'Invalid username' "$validation_root" "$invalid_user"
done

default_home="$TEST_ROOT/default-home"
default_root=$(new_fixture 'default-home/konflux/konflux-release-data')
yamllint_site=$(python3 -c 'import pathlib, yamllint; print(pathlib.Path(yamllint.__file__).resolve().parent.parent)')
output=$(env -u KONFLUX_RELEASE_DATA HOME="$default_home" PYTHONPATH="$yamllint_site" \
  "$ADD_TEAM_MEMBER" auser 2>&1)
if [[ "$output" == *"No changes needed."* ]] && [ "$default_root" = "$default_home/konflux/konflux-release-data" ]; then
  pass 'default target path'
else
  fail 'default target path'
fi
expect_failure invalid-role 'Invalid role' "$validation_root" alice owner
expect_failure extra-argument 'Usage:' "$validation_root" alice admin extra

echo
echo "=== Plural roles and duplicate users ==="
for role in admins maintainers contributors; do
  root=$(new_fixture "duplicate-$role")
  before=$(git -C "$root" rev-parse HEAD)
  output=$(KONFLUX_RELEASE_DATA="$root" "$ADD_TEAM_MEMBER" auser "$role" 2>&1)
  assert_eq "$role duplicate keeps commit" "$(git -C "$root" rev-parse HEAD)" "$before"
  assert_eq "$role duplicate keeps branch" "$(git -C "$root" branch --show-current)" main
  if [[ "$output" == *"No changes needed."* ]]; then
    pass "$role accepted and duplicate detected"
  else
    fail "$role duplicate message"
  fi
done

echo
echo "=== Repository safety ==="
dirty_root=$(new_fixture dirty)
touch "$dirty_root/untracked"
expect_failure dirty-worktree 'uncommitted changes' "$dirty_root" newuser

missing_builder=$(new_fixture missing-builder)
rm "$missing_builder/tenants-config/build-single.sh"
git -C "$missing_builder" add -u
git -C "$missing_builder" commit -qm 'Remove builder'
expect_failure missing-builder 'missing tenants-config/build-single.sh' "$missing_builder" newuser

missing_rbac=$(new_fixture missing-rbac)
rm "$missing_rbac/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/rbac-admins.yaml"
git -C "$missing_rbac" add -u
git -C "$missing_rbac" commit -qm 'Remove admin RBAC'
expect_failure missing-rbac 'RBAC file not found' "$missing_rbac" newuser admin

malformed_rbac=$(new_fixture malformed-rbac)
printf 'subjects:\n  - name: [\n' > \
  "$malformed_rbac/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/rbac-admins.yaml"
git -C "$malformed_rbac" add -u
git -C "$malformed_rbac" commit -qm 'Break admin RBAC YAML'
expect_failure malformed-rbac 'syntax error' "$malformed_rbac" newuser admin
assert_eq 'malformed RBAC does not create branch' \
  "$(git -C "$malformed_rbac" branch --show-current)" main

wrong_root=$(new_fixture wrong-root)
mkdir "$wrong_root/nested"
mv "$wrong_root/tenants-config" "$wrong_root/nested/"
git -C "$wrong_root" add -A
git -C "$wrong_root" commit -qm 'Nest target structure'
expect_failure wrong-git-root 'Git root does not match target directory' \
  "$wrong_root/nested" newuser

local_branch=$(new_fixture local-branch)
git -C "$local_branch" checkout -qb add-newuser-contributor
printf 'preserve me\n' > "$local_branch/local-work"
git -C "$local_branch" add local-work
git -C "$local_branch" commit -qm 'Unpushed branch work'
local_branch_sha=$(git -C "$local_branch" rev-parse HEAD)
git -C "$local_branch" checkout -q main
expect_failure local-branch-exists 'already exists locally' "$local_branch" newuser
assert_eq 'existing local branch is preserved' \
  "$(git -C "$local_branch" rev-parse add-newuser-contributor)" "$local_branch_sha"

remote_branch=$(new_fixture remote-branch)
git -C "$remote_branch" update-ref \
  refs/remotes/origin/add-newuser-contributor HEAD
expect_failure remote-branch-exists 'already exists on origin' "$remote_branch" newuser
assert_eq 'remote collision does not create local branch' \
  "$(git -C "$remote_branch" branch --list add-newuser-contributor)" ''

stale_generated=$(new_fixture stale-generated)
cat > "$stale_generated/tenants-config/build-single.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = submariner-tenant ]
EOF
chmod +x "$stale_generated/tenants-config/build-single.sh"
git -C "$stale_generated" add tenants-config/build-single.sh
git -C "$stale_generated" commit -qm 'Make generated output stale'
expect_failure stale-generated 'Generated RBAC file does not contain' "$stale_generated" newuser

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
