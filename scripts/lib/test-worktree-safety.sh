#!/usr/bin/env bash
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
    if [ "$scenario:$verb" = lockfile-status-fails:status ] && [[ "$*" == *rpm-lockfiles* ]]; then return 1; fi
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

# Two version-bump processes must not share branch/worktree mutations. The
# first holds the repository lock while its fake patcher runs; the second must
# stop before stashing, switching branches, or creating another fix branch.
version_bump_lock_case() (
  local repo_dir="$TEST_ROOT/tekton-task-version-bump-lock"
  local first_log="$TEST_ROOT/tekton-task-version-bump-lock-first.log"
  setup_repo

  (
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPTS/tekton-task-version-bump.sh"
    repo_path() { printf '%s\n' "$repo_dir"; }
    VERSION=0.25.1 MAJOR_MINOR=0.25
    PATCHER_SCRIPT='touch .git/lock-held; sleep 1; printf "task: v2\\n" > .tekton/pipe.yaml'
    update_repo testcomp
  ) >"$first_log" 2>&1 &
  local first_pid=$!

  # The patcher runs only after the lock is held, so its marker proves the lock is taken
  local lock_held="$repo_dir/.git/lock-held"
  local attempts=0
  while [ ! -e "$lock_held" ] && [ "$attempts" -lt 250 ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -e "$lock_held" ] || { echo 'FAIL: first update did not acquire lock' >&2; exit 1; }

  # shellcheck source=/dev/null
  source "$RELEASE_SCRIPTS/tekton-task-version-bump.sh"
  repo_path() { printf '%s\n' "$repo_dir"; }
  VERSION=0.25.1 MAJOR_MINOR=0.25
  PATCHER_SCRIPT=true
  REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=()
  update_repo testcomp >/dev/null 2>&1 || true
  assert_eq 'concurrent version-bump reports busy' "${REPOS_FAILED[0]:-}" 'testcomp:busy'

  wait "$first_pid"
  assert_eq 'concurrent version-bump keeps one fix branch' \
    "$(git -C "$repo_dir" branch --list 'fix-tekton-tasks-0.25*' | wc -l)" '1'
  assert_eq 'concurrent version-bump restores original branch' \
    "$(git -C "$repo_dir" branch --show-current)" 'original'
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
  cat > .rpm-lockfiles/update-lockfile.sh <<'FIXTURE'
#!/bin/bash
echo "$*" >> "$RPM_TEST_CALLS"
case "$RPM_TEST_MODE" in
  noop*) exit 0 ;;
  cdn-refused) echo "Error: Status code: 403 for https://cdn.redhat.com/x"; exit 1 ;;
  updater-fails) echo "Error: no such package foo-1.403.2 (sha256:ab4031cd)" ;; # looks like 403, is not a refusal
esac
printf "updated lockfile\n" > .rpm-lockfiles/gateway/rpms.lock.yaml
if [ "$RPM_TEST_MODE" = all-components ]; then
  printf "updated nettest lockfile\n" > .rpm-lockfiles/nettest/rpms.lock.yaml
  echo scratch > .rpm-lockfiles/gateway/scratch # not a lockfile: must never be committed
fi
[ "$RPM_TEST_MODE" != updater-fails ]
FIXTURE
  git add .rpm-lockfiles/update-lockfile.sh
  git commit -qm 'Fixture updater'
  git update-ref refs/remotes/origin/devel HEAD
  case "$scenario" in
    tracked|noop-tracked)
      # Real release branches already track their own copy of the updater.
      git checkout -q release-0.25
      printf '#!/bin/bash\n# release branch copy\n' > .rpm-lockfiles/update-lockfile.sh
      git add .rpm-lockfiles/update-lockfile.sh
      git commit -qm 'Release updater'
      ;;
    all-components)
      git checkout -q release-0.25
      mkdir -p .rpm-lockfiles/nettest
      printf 'baseline nettest lockfile\n' > .rpm-lockfiles/nettest/rpms.lock.yaml
      git add .rpm-lockfiles/nettest
      git commit -qm 'Second component'
      ;;
    new-lockfile)
      # A component whose lockfile is generated for the first time.
      git checkout -q release-0.25
      git rm -q .rpm-lockfiles/gateway/rpms.lock.yaml
      mkdir -p .rpm-lockfiles/gateway
      printf 'packages: []\n' > .rpm-lockfiles/gateway/rpms.in.yaml
      git add .rpm-lockfiles/gateway/rpms.in.yaml
      git commit -qm 'No lockfile yet'
      ;;
  esac
  git checkout -q original
  case "$scenario" in
    dirty) dirty_work ;;
    detached) git checkout -q --detach ;;
  esac
  export RPM_TEST_MODE="$scenario" RPM_TEST_CALLS="$SUBMARINER_BASE/updater-calls"
  export TMPDIR="$SUBMARINER_BASE/tmp"
  mkdir -p "$TMPDIR"
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  BRANCH=release-0.25 VERSION=0.25.1 COMPONENT_FILTER=gateway
  [ "$scenario" != all-components ] || COMPONENT_FILTER=all
  inject_git_failures
  update_lockfiles 2> "$SUBMARINER_BASE/stderr"
  assert_eq 'original commit preserved' "$(command git rev-parse original)" "$original_sha"
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD)
  case "$scenario" in
    normal|detached|noop|tracked|noop-tracked|new-lockfile)
      expected_branch=original
      [ "$scenario" = detached ] && expected_branch=HEAD
      assert_eq 'original branch restored' "$branch" "$expected_branch"
      assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
      assert_eq 'worktree clean' "$(command git status --porcelain --untracked-files=all)" ''
      if [ "$scenario" = noop ] || [ "$scenario" = noop-tracked ]; then
        assert_eq 'no-op recorded' "${REPOS_SKIPPED[0]:-}" gateway:no-changes
      else
        assert_eq 'update recorded' "${#REPOS_UPDATED[@]}" 1
      fi
      case "$scenario" in
        tracked|noop-tracked)
          assert_eq 'tracked updater untouched' "$(command git show release-0.25:.rpm-lockfiles/update-lockfile.sh | tail -1)" '# release branch copy' ;;
      esac
      case "$scenario" in
        tracked|new-lockfile)
          assert_eq 'only the lockfile is committed' \
            "$(command git diff --name-only release-0.25 update-rpm-lockfiles-0.25.1)" .rpm-lockfiles/gateway/rpms.lock.yaml ;;
      esac
      ;;
    dirty|status-fails|checkout-fails|copy-fails|cdn-refused)
      assert_eq 'original branch untouched' "$branch" original
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      if [ "$scenario" = dirty ]; then assert_work_restored; fi
      ;;
    *)
      assert_eq 'unfinished work stays on fix branch' "$branch" update-rpm-lockfiles-0.25.1
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      case "$scenario" in
        lockfile-status-fails) assert_eq 'recorded as status-failed' "${REPOS_FAILED[0]:-}" gateway:status-failed ;;
        all-components)
          # the commit happens, then the scratch file blocks restoring the original branch
          assert_eq 'both lockfiles committed, nothing else' \
            "$(command git diff --name-only release-0.25 update-rpm-lockfiles-0.25.1 | tr '\n' ' ')" \
            '.rpm-lockfiles/gateway/rpms.lock.yaml .rpm-lockfiles/nettest/rpms.lock.yaml '
          assert_eq 'update recorded' "${#REPOS_UPDATED[@]}" 1
          assert_eq 'restore reported' "${REPOS_FAILED[0]##*:}" restore-failed ;;
      esac
      case "$scenario" in
        updater-fails|stage-fails|commit-fails)
          assert_eq 'partial edits preserved' "$(< .rpm-lockfiles/gateway/rpms.lock.yaml)" 'updated lockfile' ;;
        hook-artifact) assert_eq 'hook output preserved' "$(< artifact)" 'hook artifact' ;;
      esac
      ;;
  esac
  calls=0; [ ! -e "$RPM_TEST_CALLS" ] || calls=$(wc -l < "$RPM_TEST_CALLS")
  case "$scenario" in
    cdn-refused)
      assert_eq 'a refused download is not retried' "$calls" 1
      assert_eq 'refusal tells the user what to do' "$(grep -c 'make setup-entitlements FORCE=1' "$SUBMARINER_BASE/stderr")" 1 ;;
    updater-fails)
      assert_eq 'a failed update is not retried' "$calls" 1
      assert_eq 'no refusal hint for an unrelated failure' "$(grep -c 'FORCE=1' "$SUBMARINER_BASE/stderr")" 0 ;;
    normal) assert_eq 'component reaches the updater' "$(head -1 "$RPM_TEST_CALLS")" 'update-rpm-lockfiles-0.25.1 gateway' ;;
  esac
  assert_eq 'no temp files left behind' "$(find "$TMPDIR" -type f | wc -l | tr -d ' ')" 0
  get_gh_user() { printf 'test-user\n'; }
  summary_rc=0
  print_summary >/dev/null || summary_rc=$?
  if [ "${#REPOS_FAILED[@]}" -gt 0 ]; then assert_eq 'summary fails' "$summary_rc" 1; fi
)

refusal_pattern_case() (
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  for line in 'error: Status code: 403 for https://cdn.redhat.com/x/repomd.xml (IP: 1.2.3.4)' 'HTTP/1.1 403 Forbidden'; do
    printf '%s\n' "$line" | grep -qE "$CDN_REFUSAL_PATTERN" || { echo "should match: $line" >&2; exit 1; }
  done
  for line in 'Failed to download metadata for repo x: Curl error (6): Could not resolve host: cdn.redhat.com' \
              'Cannot download repomd.xml: All mirrors were tried' 'Status code: 404 for https://cdn.redhat.com/x' \
              'no such package foo-1.403.2 (sha256:ab4031cd)'; do
    ! printf '%s\n' "$line" | grep -qE "$CDN_REFUSAL_PATTERN" || { echo "should not match: $line" >&2; exit 1; }
  done
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
run_logged version_bump_lock_case
echo "  ✓ tekton-task-version-bump / concurrent lock"
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
for scenario in normal noop tracked noop-tracked new-lockfile all-components cdn-refused lockfile-status-fails detached dirty status-fails checkout-fails copy-fails updater-fails stage-fails commit-fails restore-fails noop-restore-fails hook-artifact; do
  run_logged rpm_case "$scenario"
  echo "  ✓ rpm / $scenario"
  PASS=$((PASS + 1))
done
run_logged refusal_pattern_case
echo "  ✓ rpm / refusal hint pattern"
PASS=$((PASS + 1))
for scenario in normal dirty untracked status-fails restore-fails; do
  run_logged bundle_case "$scenario"
  echo "  ✓ bundle / $scenario"
  PASS=$((PASS + 1))
done
echo "All $PASS tests passed"
