#!/bin/bash
# Real disposable repositories; only external work and selected failures are fake.
# shellcheck disable=SC2034  # Globals are consumed by the sourced scripts.
set -euo pipefail

RELEASE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
TEST_OWNER_PID=$BASHPID
trap 'if [ "$BASHPID" = "$TEST_OWNER_PID" ]; then rm -rf "$TEST_ROOT"; fi' EXIT
# Never let hook-exported Git state address the caller's repository/index.
while IFS= read -r git_env; do unset "$git_env"; done < <(git rev-parse --local-env-vars)

assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s (got %q, want %q)\n' "$1" "$2" "$3" >&2
    exit 1
  fi
}

setup_repo() {
  mkdir -p "$repo_dir/.tekton" "$repo_dir/bundle/manifests" "$repo_dir/.rpm-lockfiles/gateway"
  git init -q -b original "$repo_dir"
  cd "$repo_dir"
  git config user.name 'Worktree Test'
  git config user.email test@example.invalid
  git config core.hooksPath /dev/null
  git config commit.gpgsign false
  git config status.showUntrackedFiles no
  printf 'baseline\n' > payload
  printf 'task: v1\n' > .tekton/pipe.yaml
  printf 'spec:\n  version: 0.25.1\n' > bundle/manifests/submariner.clusterserviceversion.yaml
  printf 'baseline lockfile\n' > .rpm-lockfiles/gateway/rpms.lock.yaml
  git add -A
  git commit -qm base
  git branch release-0.25
  original_sha=$(git rev-parse HEAD)
}

dirty_work() {
  # An older stash must survive both successful and failed automatic cleanup.
  printf 'older stash\n' >> payload
  git stash push -qm older
  older_stash=$(git rev-parse refs/stash)
  printf 'staged work\n' >> payload
  git add payload
  printf 'unstaged work\n' >> payload
  printf 'untracked work\n' > notes
  before_status=$(git status --porcelain --untracked-files=all)
  before_index=$(git show :payload)
  before_payload=$(< payload)
}

assert_work_restored() {
  assert_eq 'worktree restored' "$(command git status --porcelain --untracked-files=all)" "$before_status"
  assert_eq 'index restored' "$(command git show :payload)" "$before_index"
  assert_eq 'unstaged content restored' "$(< payload)" "$before_payload"
  assert_eq 'untracked content restored' "$(< notes)" 'untracked work'
  assert_eq 'older stash is untouched' "$(command git rev-parse refs/stash)" "$older_stash"
  assert_eq 'only older stash remains' "$(command git stash list | wc -l)" 1
}

inject_git_failures() {
  # All successful Git operations are real, including stash/pop and checkout.
  git() {
    local -a args=("$@")
    local offset=0
    [ "${args[0]:-}" = -C ] && offset=2
    local verb="${args[offset]:-}" option="${args[offset+1]:-}"
    if [ "$verb:$option" = checkout:-f ] && [ -n "${restore_marker:-}" ]; then
      printf 'attempt\n' >> "$restore_marker"
    fi
    if [ "$scenario:$verb" = post-stash-status-fails:status ] &&
       [ "$(command git rev-parse refs/stash)" != "$older_stash" ]; then return 1; fi
    case "$scenario:$verb:$option" in
      stash-fails:stash:push|pop-fails:stash:pop|status-fails:status:*) return 1 ;;
      stash-ref-fails:rev-parse:--verify) return 1 ;;
      checkout-fails:checkout:-B|checkout-fails:checkout:-b|checkout-fails:checkout:devel) return 1 ;;
      restore-fails:checkout:-f|restore-fails:checkout:--quiet|noop-restore-fails:checkout:--quiet) return 1 ;;
      stage-fails:add:*|commit-fails:commit:*|copy-fails:show:origin/devel:*) return 1 ;;
    esac
    command git "$@" || return
    if [ "$scenario:$verb:$option" = conflict:checkout:-f ]; then
      printf 'conflicting work\n' > payload
    elif [ "$scenario:$verb" = hook-artifact:commit ]; then
      printf 'hook artifact\n' > artifact
    fi
    return 0
  }
}

tekton_case() (
  local kind="$1" scenario="$2"
  # shellcheck source=/dev/null
  source "$RELEASE_SCRIPTS/$kind.sh"
  local repo_dir="$TEST_ROOT/$kind-$scenario"
  setup_repo
  repo_path() { printf '%s\n' "$repo_dir"; }
  VERSION=0.25.1 MAJOR_MINOR=0.25
  PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml'
  if [ "$scenario" = sed-fails ]; then
    git checkout -q release-0.25
    printf 'bundle: quay.io/konflux-ci/tekton-catalog/task-git-clone:0.1\n' > .tekton/pipe.yaml
    git add .tekton
    git commit -qm 'Task version fixture'
    git checkout -q original
    latest_task_version() { printf '0.2\n'; }
    sed() {
      [ "${1:-}" != -i.bak ] || return 1
      command sed "$@"
    }
  fi
  dirty_work
  case "$scenario" in
    missing-base) git branch -d release-0.25 ;;
    detached) git checkout -q --detach ;;
    noop) PATCHER_SCRIPT=true ;;
    patcher-fails) PATCHER_SCRIPT+='; exit 1' ;;
  esac
  inject_git_failures
  # Not conditional: keep production errexit semantics active.
  update_repo testcomp
  assert_eq 'original branch commit preserved' "$(command git rev-parse original)" "$original_sha"
  case "$scenario" in
    restore-fails|pop-fails|conflict|stash-ref-fails|post-stash-status-fails)
      expected_failure=testcomp:restore-failed
      [[ "$scenario" == *stash* ]] && expected_failure=testcomp:stash-failed
      assert_eq 'preservation failure reported' "${REPOS_FAILED[0]:-}" "$expected_failure"
      assert_eq 'stash retained for recovery' "$(command git stash list | wc -l)" 2
      assert_eq 'original stash preserved' "$(command git rev-parse 'stash@{1}')" "$older_stash"
      assert_eq 'saved index recoverable' "$(command git show 'stash@{0}^2:payload')" "$before_index"
      assert_eq 'saved work recoverable' "$(command git show 'stash@{0}:payload')" "$before_payload"
      ;;
    *)
      assert_work_restored
      expected_branch=original
      [ "$scenario" = detached ] && expected_branch=HEAD
      assert_eq 'original ref restored' "$(command git rev-parse --abbrev-ref HEAD)" "$expected_branch"
      case "$scenario" in
        normal|detached)
          assert_eq 'update recorded' "${#REPOS_UPDATED[@]}" 1
          assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
          assert_eq 'user work not committed' "$(command git show fix-tekton-tasks-0.25:payload)" baseline
          ;;
        noop)
          assert_eq 'no-op recorded' "${REPOS_SKIPPED[0]:-}" testcomp:no-changes
          assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
          ;;
        *) assert_eq 'failure reported once' "${#REPOS_FAILED[@]}" 1 ;;
      esac
      ;;
  esac
  # Ensure cleanup failures affect the script's overall result as well.
  get_gh_user() { :; }
  summary_rc=0
  print_summary >/dev/null || summary_rc=$?
  # Version-bump's main checks REPOS_FAILED after its informational summary;
  # refs-update returns that status directly from print_summary.
  if [ "$kind" = tekton-task-refs-update ] && [ "${#REPOS_FAILED[@]}" -gt 0 ]; then
    assert_eq 'summary fails' "$summary_rc" 1
  fi
)

cve_case() (
  local scenario="$1" mode="${2:-prerequisites}"
  SUBMARINER_BASE="$TEST_ROOT/cve-$scenario-$mode"
  local repo_dir="$SUBMARINER_BASE/shipyard"
  local restore_marker="$SUBMARINER_BASE/restore-count"
  setup_repo
  git checkout -qb devel
  mkdir -p skills/cve-fix/scripts
  printf '#!/bin/bash\nexit 0\n' > skills/cve-fix/scripts/fix-all.sh
  chmod +x skills/cve-fix/scripts/fix-all.sh
  git add skills
  git commit -qm 'Skill only on devel'
  git checkout -q original
  dirty_work
  inject_git_failures
  local rc
  set +e
  (
    # shellcheck source=../cve-fixes-update.sh
    source "$RELEASE_SCRIPTS/cve-fixes-update.sh"
    if [ "$mode" = main ]; then
      TRACKER_LIB=/dev/null
      find_release_tracker() { printf 'TEST-1\n'; }
      update_step() { printf '%s\n' "$3" >> "$SUBMARINER_BASE/tracker-state"; }
      update_all() { :; }  # No CVE scanner or external release operations.
      main 0.25.1
    else
      check_prerequisites
      [ "$scenario" != body-fails ] || exit 7
    fi
  )
  rc=$?
  set -e
  case "$scenario" in
    normal) assert_eq 'prerequisites succeeded' "$rc" 0 ;;
    body-fails) assert_eq 'original failure preserved' "$rc" 7 ;;
    *) assert_eq 'failure propagated' "$rc" 1 ;;
  esac
  case "$scenario" in
    pop-fails|restore-fails|conflict|stash-ref-fails|post-stash-status-fails)
      assert_eq 'stash retained for recovery' "$(command git stash list | wc -l)" 2
      assert_eq 'older stash retained' "$(command git rev-parse 'stash@{1}')" "$older_stash"
      ;;
    *)
      assert_work_restored
      assert_eq 'original branch restored' "$(command git branch --show-current)" original
      ;;
  esac
  if [ "$mode" = main ]; then
    expected_state=in_progress
    [ "$scenario" = normal ] && expected_state=$'in_progress\ncomplete'
    assert_eq 'tracker completion follows restoration' "$(< "$SUBMARINER_BASE/tracker-state")" "$expected_state"
  fi
  case "$scenario" in
    stash-fails|stash-ref-fails|post-stash-status-fails|status-fails)
      assert_eq 'no forced cleanup after failed preservation' "$([ -f "$restore_marker" ] && echo yes || echo no)" no ;;
    *) assert_eq 'restoration attempted exactly once' "$(wc -l < "$restore_marker")" 1 ;;
  esac
)

rpm_case() (
  local scenario="$1"
  SUBMARINER_BASE="$TEST_ROOT/rpm-$scenario"
  local repo_dir="$SUBMARINER_BASE/submariner"
  setup_repo
  git checkout -qb devel
  printf '#!/bin/bash\ncase "$RPM_TEST_MODE" in noop*) exit 0 ;; esac\nprintf "updated lockfile\\n" > .rpm-lockfiles/gateway/rpms.lock.yaml\n[ "$RPM_TEST_MODE" != updater-fails ]\n' \
    > .rpm-lockfiles/update-lockfile.sh
  git add .rpm-lockfiles/update-lockfile.sh
  git commit -qm 'Fixture updater'
  git update-ref refs/remotes/origin/devel HEAD
  git checkout -q original
  case "$scenario" in
    dirty) dirty_work ;;
    detached) git checkout -q --detach ;;
  esac
  export RPM_TEST_MODE="$scenario"
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  BRANCH=release-0.25 VERSION=0.25.1 COMPONENT_FILTER=gateway
  inject_git_failures
  update_lockfiles
  assert_eq 'original commit preserved' "$(command git rev-parse original)" "$original_sha"
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD)
  case "$scenario" in
    normal|detached|noop)
      expected_branch=original
      [ "$scenario" = detached ] && expected_branch=HEAD
      assert_eq 'original branch restored' "$branch" "$expected_branch"
      assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
      assert_eq 'worktree clean' "$(command git status --porcelain --untracked-files=all)" ''
      if [ "$scenario" = noop ]; then
        assert_eq 'no-op recorded' "${REPOS_SKIPPED[0]:-}" gateway:no-changes
      else
        assert_eq 'update recorded' "${#REPOS_UPDATED[@]}" 1
      fi
      ;;
    dirty|status-fails|checkout-fails)
      assert_eq 'original branch untouched' "$branch" original
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      if [ "$scenario" = dirty ]; then assert_work_restored; fi
      ;;
    *)
      assert_eq 'unfinished work stays on fix branch' "$branch" update-rpm-lockfiles-0.25.1
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      case "$scenario" in
        updater-fails|stage-fails|commit-fails)
          assert_eq 'partial edits preserved' "$(< .rpm-lockfiles/gateway/rpms.lock.yaml)" 'updated lockfile' ;;
        hook-artifact) assert_eq 'hook output preserved' "$(< artifact)" 'hook artifact' ;;
      esac
      ;;
  esac
  get_gh_user() { printf 'test-user\n'; }
  summary_rc=0
  print_summary >/dev/null || summary_rc=$?
  if [ "${#REPOS_FAILED[@]}" -gt 0 ]; then assert_eq 'summary fails' "$summary_rc" 1; fi
)

bundle_case() (
  local scenario="$1" repo_dir="$TEST_ROOT/bundle-$1"
  setup_repo
  case "$scenario" in
    dirty) dirty_work ;;
    untracked) printf 'untracked work\n' > notes ;;
  esac
  local rc
  inject_git_failures
  set +e
  (
    # shellcheck source=../bundle-image-update.sh
    source "$RELEASE_SCRIPTS/bundle-image-update.sh"
    BRANCH=original
    parse_arguments 0.25.1
  )
  rc=$?
  set -e
  if [ "$scenario" = normal ]; then
    assert_eq 'clean switch succeeds' "$rc" 0
    assert_eq 'correct release branch' "$(command git branch --show-current)" release-0.25
  else
    assert_eq 'unsafe switch refused' "$rc" 1
    assert_eq 'original branch untouched' "$(command git branch --show-current)" original
    case "$scenario" in
      dirty) assert_work_restored ;;
      untracked) assert_eq 'untracked work preserved' "$(< notes)" 'untracked work' ;;
    esac
  fi
)

PASS=0
case_log="$TEST_ROOT/case.log"
run_logged() {
  local test_rc
  # Capture failure only after restoring stdout/stderr. Do not invoke tests
  # conditionally: that disables errexit throughout the sourced implementation.
  set +e
  (set -e; "$@") > "$case_log" 2>&1
  test_rc=$?
  set -e
  if [ "$test_rc" -ne 0 ]; then
    tail -80 "$case_log" >&2
    return "$test_rc"
  fi
}
for script in tekton-task-refs-update tekton-task-version-bump; do
  for scenario in normal noop detached stash-fails stash-ref-fails post-stash-status-fails status-fails missing-base checkout-fails patcher-fails stage-fails commit-fails restore-fails pop-fails conflict; do
    run_logged tekton_case "$script" "$scenario"
    echo "  ✓ $script / $scenario"
    PASS=$((PASS + 1))
  done
done
run_logged tekton_case tekton-task-version-bump sed-fails
echo "  ✓ tekton-task-version-bump / sed-fails"
PASS=$((PASS + 1))
for scenario in normal body-fails stash-fails stash-ref-fails post-stash-status-fails status-fails checkout-fails restore-fails pop-fails conflict; do
  run_logged cve_case "$scenario"
  echo "  ✓ cve / $scenario"
  PASS=$((PASS + 1))
done
for scenario in normal restore-fails pop-fails conflict; do
  run_logged cve_case "$scenario" main
  echo "  ✓ cve main / $scenario"
  PASS=$((PASS + 1))
done
for scenario in normal noop detached dirty status-fails checkout-fails copy-fails updater-fails stage-fails commit-fails restore-fails noop-restore-fails hook-artifact; do
  run_logged rpm_case "$scenario"
  echo "  ✓ rpm / $scenario"
  PASS=$((PASS + 1))
done
for scenario in normal dirty untracked status-fails restore-fails; do
  run_logged bundle_case "$scenario"
  echo "  ✓ bundle / $scenario"
  PASS=$((PASS + 1))
done
echo "All $PASS tests passed"
