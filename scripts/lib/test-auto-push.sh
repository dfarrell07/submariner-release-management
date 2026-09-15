#!/bin/bash
# Exercise the real RPM command producer and conductor consumer; no network writes.
# shellcheck disable=SC2034  # Globals are read by sourced functions/subprocess stubs.
set -euo pipefail
RELEASE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r git_env; do unset "$git_env"; done < <(git rev-parse --local-env-vars)
_AUTORELEASE_TESTING=true
# shellcheck source=../autorelease.sh
source "$RELEASE_SCRIPTS/autorelease.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export PUSH_TEST_ROOT="$TEST_ROOT" PUSH_TEST_MODE=normal
mkdir -p "$TEST_ROOT/repos with spaces/submariner" "$TEST_ROOT/repos with spaces/shipyard"

PASS=0
assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s (got %q, want %q)\n' "$1" "$2" "$3" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
  echo "  ✓ $1"
}

# Export stubs into the generated Bash script. Unknown calls fail closed.
git() {
  printf '%s: git %s\n' "$PWD" "$*" >> "$PUSH_TEST_ROOT/commands"
  [ "${1:-}" = push ] || return 99
  [ "$PUSH_TEST_MODE" != push-fails ]
}
gh() {
  printf '%s: gh %s\n' "$PWD" "$*" >> "$PUSH_TEST_ROOT/commands"
  local verb="${2:-}" base='' head='' filter='' state='' repo="${PWD##*/}"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift ;;
      --head) head="$2"; shift ;;
      --jq) filter="$2"; shift ;;
      --state) state="$2"; shift ;;
      --repo) repo="${2##*/}"; shift ;;
    esac
    shift
  done
  case "$verb" in
    list)
      [ "$PUSH_TEST_MODE" != lookup-fails ] || return 1
      # gh pr list does not accept owner:branch.
      [[ "$head" != *:* ]] || return 98
      if [ "$state" = all ]; then
        if [ "$repo" = submariner ]; then
          printf '%s\n' '[{"state":"OPEN","url":"https://example.invalid/pull/42"}]'
        else
          printf '[]\n'
        fi
      else
        [ "$base" = release-0.25 ] || return 97
        if [ "$repo" = submariner ]; then
          printf '%s\n' '[{"url":"https://example.invalid/pull/41","headRepositoryOwner":{"login":"someone-else"}},{"url":"https://example.invalid/pull/42","headRepositoryOwner":{"login":"test-user"}}]' | jq -r "$filter"
        elif [ -f "$PUSH_TEST_ROOT/created-$repo" ]; then
          printf '%s\n' '[{"url":"https://example.invalid/pull/44","headRepositoryOwner":{"login":"test-user"}}]' | jq -r "$filter"
        else
          printf '[]\n' | jq -r "$filter"
        fi
      fi
      ;;
    create)
      [ "$PUSH_TEST_MODE" != create-fails ] || return 1
      [ "$repo" != submariner ] && [ ! -f "$PUSH_TEST_ROOT/created-$repo" ] || return 1
      [ "$head" = test-user:update-rpm-lockfiles-0.25.1 ] || return 96
      : > "$PUSH_TEST_ROOT/created-$repo"
      printf 'https://example.invalid/pull/44\n'
      ;;
    merge) [ "$PUSH_TEST_MODE" != merge-fails ] ;;
    *) return 95 ;;
  esac
}
make() { printf '%s: make %s\n' "$PWD" "$*" >> "$PUSH_TEST_ROOT/manual"; }
export -f git gh make

push_log="$TEST_ROOT/push.log"
produce_rpm_log() (
  SUBMARINER_BASE="$TEST_ROOT/repos with spaces"
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  get_gh_user() { printf 'test-user\n'; }
  fork_remote() { printf 'fork\n'; }
  REPOS_UPDATED=(submariner#submariner#0.25.1#release-0.25 shipyard#shipyard#0.25.1#release-0.25)
  AUTORELEASE_PUSH_LOG="$push_log"
  print_summary >/dev/null
)

verify_rc=0
_verify_prs_merged 0.25.1 TEST-1 update-rpm-lockfiles-0.25.1 'org/submariner org/shipyard' >/dev/null 2>&1 || verify_rc=$?
assert_eq 'open + missing PR requests retry' "$verify_rc" 1

produce_rpm_log
_try_auto_push "$push_log" rpmLockfiles 0 > "$TEST_ROOT/output" 2>&1
assert_eq 'successful pushes clear pending block' "$(wc -c < "$push_log")" 0
assert_eq 'existing PR reused, only missing PR created' "$(grep -c 'gh pr create' "$TEST_ROOT/commands")" 1
assert_eq 'correct owner PR merged' "$(grep -c 'gh pr merge --auto --rebase 42' "$TEST_ROOT/commands")" 1
assert_eq 'second repo reached and merged' "$(grep -c 'gh pr merge --auto --rebase 44' "$TEST_ROOT/commands")" 1
produce_rpm_log
_try_auto_push "$push_log" rpmLockfiles 0 > "$TEST_ROOT/output" 2>&1
assert_eq 'repeat run creates no duplicate PRs' "$(grep -c 'gh pr create' "$TEST_ROOT/commands")" 1

for mode in push-fails lookup-fails create-fails merge-fails; do
  # Fresh state for the repo that still needs its PR.
  rm -f "$TEST_ROOT/created-shipyard"
  produce_rpm_log
  cp "$push_log" "$TEST_ROOT/before"
  PUSH_TEST_MODE="$mode"
  rc=0
  _try_auto_push "$push_log" rpmLockfiles 0 > "$TEST_ROOT/output" 2>&1 || rc=$?
  assert_eq "$mode reports failure" "$rc" 1
  cmp "$push_log" "$TEST_ROOT/before"
  assert_eq "$mode retains fallback commands" "$(grep -c 'Auto-push failed' "$TEST_ROOT/output")" 1
  : > "$push_log"
done
PUSH_TEST_MODE=normal

# Older pending actions must retain every byte, including trailing newlines.
printf '# earlier step\n  make watch NAME=older\n\n' > "$push_log"
cp "$push_log" "$TEST_ROOT/expected"
log_before=$(wc -c < "$push_log")
for repo in submariner shipyard; do
  printf '  cd %q\n  git push origin release\n  make apply FILE=%s.yaml\n  make watch NAME=%s\n' \
    "$TEST_ROOT/repos with spaces/$repo" "$repo" "$repo" >> "$push_log"
  printf '  cd %q\n  make apply FILE=%s.yaml\n  make watch NAME=%s\n' \
    "$TEST_ROOT/repos with spaces/$repo" "$repo" "$repo" >> "$TEST_ROOT/expected"
done
_try_auto_push "$push_log" componentStage "$log_before" > "$TEST_ROOT/output" 2>&1
cmp "$push_log" "$TEST_ROOT/expected"
assert_eq 'apply/watch never executed automatically' "$([ -e "$TEST_ROOT/manual" ] && echo yes || echo no)" no
# Execute only retained commands through the harmless make stub to verify cwd.
bash "$push_log"
assert_eq 'first deferred apply uses correct directory' "$(grep -c 'repos with spaces/submariner: make apply' "$TEST_ROOT/manual")" 1
assert_eq 'second deferred apply uses correct directory' "$(grep -c 'repos with spaces/shipyard: make apply' "$TEST_ROOT/manual")" 1

cp "$push_log" "$TEST_ROOT/before"
_try_auto_push "$push_log" componentStage "$(wc -c < "$push_log")"
cmp "$push_log" "$TEST_ROOT/before"
assert_eq 'step adding nothing preserves pending actions' "$?" 0
echo "All $PASS tests passed"
