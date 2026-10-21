#!/bin/bash
# Exercise source command producers and the conductor consumer; no network writes.
# shellcheck disable=SC2034  # Globals are read by sourced functions/subprocess stubs.
set -euo pipefail
RELEASE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r git_env; do unset "$git_env"; done < <(git rev-parse --local-env-vars)
_AUTORELEASE_TESTING=true
# shellcheck source=../autorelease.sh
source "$RELEASE_SCRIPTS/autorelease.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export PUSH_TEST_ROOT="$TEST_ROOT" PUSH_TEST_MODE=normal PUSH_TEST_BRANCH=update-rpm-lockfiles-0.25.1
mkdir -p "$TEST_ROOT/repos with spaces/submariner" "$TEST_ROOT/repos with spaces/shipyard"

assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s (got %q, want %q)\n' "$1" "$2" "$3" >&2
    exit 1
  fi
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
  if [ "$1" = api ]; then
    [ "$2 $3" = '--paginate --slurp' ] || return 94
    local endpoint="$4" repo_name head=fix-version-labels-0.25 history
    repo_name="${endpoint#repos/}"; repo_name="${repo_name#*/}"; repo_name="${repo_name%%/*}"
    [ "$PUSH_TEST_MODE" != lookup-fails ] || return 1
    if [ "$PUSH_TEST_MODE" = normal ]; then
      [ "$repo_name" = submariner ] || { printf '[[]]\n'; return; }
      head=update-rpm-lockfiles-0.25.1
    fi
    history=$(jq -cn --arg head "$head" '[[{state:"closed",merged_at:"2026-08-26T19:00:00Z",
      head:{ref:$head},base:{ref:"release-0.25"},html_url:"https://example.invalid/pull/10"}]]')
    case "$PUSH_TEST_MODE" in
      normal) history=$(jq '.[0][0] |= (.state="open" | .merged_at=null | .html_url="https://example.invalid/pull/42")' <<< "$history") ;;
      merged-and-open|open-and-merged)
        history=$(jq '.[0] += [.[0][0] | .state="open" | .merged_at=null | .html_url="https://example.invalid/pull/42"]' <<< "$history")
        [ "$PUSH_TEST_MODE" != open-and-merged ] || history=$(jq '.[0] |= reverse' <<< "$history") ;;
    esac
    printf '%s\n' "$history"
    return
  fi
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
      [ "$state" = open ] || return 96
      [ "$base" = release-0.25 ] || return 97
      if [ "$repo" = submariner ]; then
        printf '%s\n' '[{"url":"https://example.invalid/pull/41","headRepositoryOwner":{"login":"someone-else"}},{"url":"https://example.invalid/pull/42","headRepositoryOwner":{"login":"test-user"}}]' | jq -r "$filter"
      elif [ -f "$PUSH_TEST_ROOT/created-$repo" ]; then
        printf '%s\n' '[{"url":"https://example.invalid/pull/44","headRepositoryOwner":{"login":"test-user"}}]' | jq -r "$filter"
      else
        printf '[]\n' | jq -r "$filter"
      fi
      ;;
    create)
      [ "$PUSH_TEST_MODE" != create-fails ] || return 1
      [ "$repo" != submariner ] && [ ! -f "$PUSH_TEST_ROOT/created-$repo" ] || return 1
      [ "$head" = "test-user:$PUSH_TEST_BRANCH" ] || return 96
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

# Query boundaries matter independently of the generated push commands.
pr_boundary_case() (
  local mode="$1" expected="$2" boundary_pages branch=fix-version-labels-0.25.1 rc=0
  local boundary_base=release-0.25 boundary_repo=org/submariner
  boundary_pages=$(jq -cn --arg branch "$branch" '[[{
    state:"closed",merged_at:"2026-10-01T12:00:00Z",head:{ref:$branch},
    base:{ref:"release-0.25"},html_url:"https://example.invalid/pull/10"}]]')
  case "$mode" in
    later-open) boundary_pages=$(jq '.[0][0] as $pr | [[range(5) | $pr], [$pr | .state="open" | .merged_at=null | .html_url="https://example.invalid/pull/42"]]' <<< "$boundary_pages") ;;
    wrong-base) boundary_pages=$(jq '.[0][0].base.ref="release-0.24"' <<< "$boundary_pages") ;;
    closed-unmerged) boundary_pages=$(jq '.[0][0].merged_at=null' <<< "$boundary_pages") ;;
    fbc-merged)
      boundary_base=main boundary_repo=stolostron/submariner-operator-fbc
      boundary_pages=$(jq '.[0][0].base.ref="main"' <<< "$boundary_pages") ;;
    empty-url) boundary_pages=$(jq '.[0][0].html_url=""' <<< "$boundary_pages") ;;
    malformed) boundary_pages='not-json' ;;
    invalid-schema) boundary_pages='[[{"state":"closed"}]]' ;;
    no-pages) boundary_pages='[]' ;;
  esac
  gh() {
    if [ "$1" = api ]; then
      [ "$2 $3" = '--paginate --slurp' ] || return 97
      [[ "$4" = *"state=all&base=$boundary_base&per_page=100" ]] || return 98
      printf '%s\n' "$boundary_pages"
    else
      return 99
    fi
  }
  _verify_prs_merged 0.25.1 TEST-1 "$branch" "$boundary_repo" > "$TEST_ROOT/boundary-output" 2> "$TEST_ROOT/boundary-errors" || rc=$?
  assert_eq "$mode PR query result" "$rc" "$expected"
  case "$expected" in
    0) assert_eq "$mode reports merged PR" "$(grep -c 'https://example.invalid/pull/10' "$TEST_ROOT/boundary-output")" 1 ;;
    3) assert_eq "$mode reports later open PR" "$(grep -c 'https://example.invalid/pull/42' "$TEST_ROOT/boundary-output")" 1 ;;
    *) assert_eq "$mode emits no completion evidence" "$(cat "$TEST_ROOT/boundary-output")" '' ;;
  esac
)
for spec in later-open:3 wrong-base:1 closed-unmerged:1 fbc-merged:0 empty-url:2 malformed:2 invalid-schema:2 no-pages:2; do
  pr_boundary_case "${spec%:*}" "${spec#*:}"
done

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
_verify_prs_merged 0.25.1 TEST-1 update-rpm-lockfiles-0.25.1 'org/submariner org/shipyard' > "$TEST_ROOT/verify-output" 2>/dev/null || verify_rc=$?
assert_eq 'open + missing PR waits for review' "$verify_rc" 3
assert_eq 'open + missing PR preserves pending evidence' \
  "$(grep -c 'https://example.invalid/pull/42' "$TEST_ROOT/verify-output")" 1

# Automation branches are reused across patch releases. An earlier merged PR
# must not certify a new open PR, regardless of GitHub's result order.
for mode in merged-and-open open-and-merged; do
  PUSH_TEST_MODE="$mode"
  verify_rc=0
  _verify_prs_merged 0.25.1 TEST-1 fix-version-labels-0.25 'org/submariner' > "$TEST_ROOT/verify-output" 2> "$TEST_ROOT/verify-errors" || verify_rc=$?
  assert_eq "$mode waits for the current PR" "$verify_rc" 3
  assert_eq "$mode reports the open PR" "$(grep -c 'https://example.invalid/pull/42' "$TEST_ROOT/verify-output")" 1
done
PUSH_TEST_MODE=merged
verify_rc=0
_verify_prs_merged 0.25.1 TEST-1 fix-version-labels-0.25 'org/submariner' > "$TEST_ROOT/verify-output" 2>&1 || verify_rc=$?
assert_eq 'merged PR without open work completes' "$verify_rc" 0
PUSH_TEST_MODE=previous-label-release
verify_rc=0
verify_versionLabels 0.25.1 TEST-1 > "$TEST_ROOT/verify-output" 2> "$TEST_ROOT/verify-errors" || verify_rc=$?
assert_eq 'earlier patch labels do not certify current version' "$verify_rc" 1
PUSH_TEST_MODE=normal

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

# Labels use the same retry contract, with a branch specific to the patch.
produce_label_log() (
  SUBMARINER_BASE="$TEST_ROOT/repos with spaces"
  # shellcheck source=../update-version-labels.sh
  source "$RELEASE_SCRIPTS/update-version-labels.sh"
  get_gh_user() { printf 'test-user\n'; }
  fork_remote() { printf 'fork\n'; }
  VERSION=0.25.1
  REPOS_UPDATED=(submariner#0.25.1#release-0.25 shipyard#0.25.1#release-0.25)
  AUTORELEASE_PUSH_LOG="$push_log"
  print_summary >/dev/null
)
PUSH_TEST_BRANCH=fix-version-labels-0.25.1
rm -f "$TEST_ROOT/commands" "$TEST_ROOT/created-shipyard"
produce_label_log
_try_auto_push "$push_log" versionLabels 0 > "$TEST_ROOT/output" 2>&1
assert_eq 'label pushes clear pending block' "$(wc -c < "$push_log")" 0
assert_eq 'label retry reuses current owner PR' "$(grep -c 'gh pr merge --auto --rebase 42' "$TEST_ROOT/commands")" 1
assert_eq 'label missing PR created once' "$(grep -c 'gh pr create' "$TEST_ROOT/commands")" 1
assert_eq 'label pushes use lease and patch-specific branch' \
  "$(grep -c 'git push --force-with-lease fork fix-version-labels-0.25.1' "$TEST_ROOT/commands")" 2
produce_label_log
_try_auto_push "$push_log" versionLabels 0 > "$TEST_ROOT/output" 2>&1
assert_eq 'label rerun creates no duplicate PRs' "$(grep -c 'gh pr create' "$TEST_ROOT/commands")" 1

produce_tekton_log() (
  # shellcheck source=../tekton-task-refs-update.sh
  source "$RELEASE_SCRIPTS/tekton-task-refs-update.sh"
  repo_path() { printf '%s/repos with spaces/%s\n' "$TEST_ROOT" "$1"; }
  get_gh_user() { printf 'test-user\n'; }
  fork_remote() { printf 'fork\n'; }
  VERSION=0.25.1
  DENY_RULES_CHECKED=1
  REPOS_UPDATED=(submariner#fix-tekton-tasks-0.25.1#release-0.25 shipyard#fix-tekton-tasks-0.25.1#release-0.25)
  AUTORELEASE_PUSH_LOG="$push_log"
  print_summary >/dev/null
)
PUSH_TEST_BRANCH=fix-tekton-tasks-0.25.1
rm -f "$TEST_ROOT/commands" "$TEST_ROOT/created-shipyard"
produce_tekton_log
_try_auto_push "$push_log" tektonTasks 0 > "$TEST_ROOT/output" 2>&1
assert_eq 'Tekton pushes clear pending block' "$(wc -c < "$push_log")" 0
assert_eq 'Tekton missing PR created once' "$(grep -c 'gh pr create' "$TEST_ROOT/commands")" 1
assert_eq 'Tekton pushes use lease and patch-specific branch' \
  "$(grep -c 'git push --force-with-lease fork fix-tekton-tasks-0.25.1' "$TEST_ROOT/commands")" 2
produce_tekton_log
_try_auto_push "$push_log" tektonTasks 0 > "$TEST_ROOT/output" 2>&1
assert_eq 'Tekton rerun creates no duplicate PRs' "$(grep -c 'gh pr create' "$TEST_ROOT/commands")" 1
PUSH_TEST_BRANCH=update-rpm-lockfiles-0.25.1

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
echo "All producer/consumer tests passed"
