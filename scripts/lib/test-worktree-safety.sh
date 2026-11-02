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
    # The shared RPM regressions model fetched refs without a remote transport.
    # Fresh-source fixtures configure a real bare origin and exercise actual fetch.
    if [ "$verb" = fetch ] && ! command git remote get-url origin >/dev/null 2>&1; then return 0; fi
    if { [ "$verb:$option" = checkout:-f ] || [ "$verb:$option" = checkout:--quiet ]; } && [ -n "${restore_marker:-}" ]; then
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
      fetch-fails:fetch:*) return 1 ;;
    esac
    command git "$@" || return
    if [ "$scenario:$verb:$option" = conflict:checkout:-f ] ||
       [ "$scenario:$verb:$option" = conflict:checkout:--quiet ]; then
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
  if [ "$kind" = tekton-task-refs-update ]; then
    DENY_RULES_CHECKED=1
    deny_rules_scan() { :; }
    repair_moved_task_refs() { printf '%s' "$PATCHER_SCRIPT" | bash -s; }
  fi
  local repo_dir="$TEST_ROOT/$kind-$scenario"
  setup_repo
  local fix_branch=fix-tekton-tasks-0.25
  if [ "$kind" = tekton-task-refs-update ]; then
    fix_branch='fix-tekton-tasks-0.25.1'
    git init -q --bare "$repo_dir-origin.git"
    git remote add origin "$repo_dir-origin.git"
    if [ "$scenario" != missing-base ]; then git push -q origin release-0.25; fi
  fi
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
          assert_eq 'user work not committed' "$(command git show "$fix_branch:payload")" baseline
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

ignored_tekton_case() (
  local kind="$1" scenario="$2"
  # shellcheck source=/dev/null
  source "$RELEASE_SCRIPTS/$kind.sh"
  local repo_dir="$TEST_ROOT/ignored-$kind-$scenario"
  setup_repo
  if [ "$scenario" = tracked ]; then
    git checkout -q release-0.25
    printf 'upstream pipeline\n' > .tekton/private.yaml
    git add .tekton/private.yaml
    git commit -qm 'Tracked file on release only'
    git checkout -q original
  fi
  printf '.tekton/private.yaml\n' > .gitignore
  git add .gitignore
  git commit -qm 'Ignore local experiment on original only'
  original_sha=$(git rev-parse HEAD)
  printf 'private local experiment\n' > .tekton/private.yaml
  git init -q --bare "$repo_dir-origin.git"
  git remote add origin "$repo_dir-origin.git"
  git push -q origin release-0.25
  dirty_work
  repo_path() { printf '%s\n' "$repo_dir"; }
  VERSION=0.25.1 MAJOR_MINOR=0.25 DENY_RULES_CHECKED=1
  local fix_branch=fix-tekton-tasks-0.25
  [ "$kind" != tekton-task-refs-update ] || fix_branch='fix-tekton-tasks-0.25.1'
  export IGNORED_TEST_PATCHER="$TEST_ROOT/patcher-$kind-$scenario"
  PATCHER_SCRIPT='printf called > "$IGNORED_TEST_PATCHER"'
  repair_moved_task_refs() { printf '%s' "$PATCHER_SCRIPT" | bash -s; }
  deny_rules_scan() { :; }
  if [ "$scenario" = restore-fails ]; then
    git() {
      [ "${1:-}:${2:-}" != -C:"$repo_dir" ] || {
        [ "${3:-}:${4:-}" != checkout:--quiet ] || return 1
      }
      command git "$@"
    }
  fi
  local log="$TEST_ROOT/ignored-$kind-$scenario.log"
  update_repo testcomp > "$log" 2>&1
  assert_eq 'ignored local content preserved' "$(< .tekton/private.yaml)" 'private local experiment'
  assert_eq 'original branch ref preserved' "$(command git rev-parse original)" "$original_sha"
  assert_eq 'repair never ran on unsafe checkout' "$([ -f "$IGNORED_TEST_PATCHER" ] && echo yes || echo no)" no
  assert_eq 'no private file committed' "${#REPOS_UPDATED[@]}" 0
  if [ "$scenario" = restore-fails ]; then
    assert_eq 'unsafe restore preserves repair ref' "$(command git branch --show-current)" "$fix_branch"
    assert_eq 'unsafe checkout creates no commit' "$(command git rev-parse "$fix_branch")" "$(command git rev-parse release-0.25)"
    assert_eq 'unsafe restore retains saved stash' "$(command git stash list | wc -l)" 2
    assert_eq 'unsafe restore keeps original stash' "$(command git rev-parse 'stash@{1}')" "$older_stash"
    assert_eq 'saved edits remain recoverable' "$(command git show 'stash@{0}:payload')" "$before_payload"
    grep -q 'saved stash:' "$log"
  else
    assert_eq 'unsafe checkout restores original branch' "$(command git branch --show-current)" original
    assert_eq 'unsafe checkout creates no repair commit' "$(command git branch --list "$fix_branch")" ''
    assert_work_restored
  fi
  local expected=testcomp:unsafe-checkout
  [ "$scenario" != tracked ] || expected=testcomp:branch-create-failed
  assert_eq 'unsafe checkout reported' "${REPOS_FAILED[0]:-}" "$expected"
)

tekton_retry_case() (
  local scenario="$1"
  # shellcheck source=/dev/null
  source "$RELEASE_SCRIPTS/tekton-task-refs-update.sh"
  local repo_dir="$TEST_ROOT/task-retry-$scenario"
  setup_repo
  local repo=testcomp base=release-0.25 fix=fix-tekton-tasks-0.25.1
  if [ "$scenario" = custom-driver ]; then
    printf '*.yaml merge=ours\n' > .gitattributes
    git add .gitattributes
    git commit -qm 'Custom YAML merge driver'
    git branch -f "$base" HEAD
    git config merge.ours.driver true
  fi
  if [ "$scenario" = fbc-noop ]; then
    repo=fbc base=main
    git branch main
  fi
  git init -q --bare "$repo_dir-origin.git"
  git remote add origin "$repo_dir-origin.git"
  git push -q origin "$base"
  repo_path() { printf '%s\n' "$repo_dir"; }
  VERSION=0.25.1 MAJOR_MINOR=0.25 DENY_RULES_CHECKED=1
  deny_rules_scan() { :; }
  repair_moved_task_refs() {
    if [ "$scenario" = whitespace-collision ] || [ "$scenario" = custom-driver ]; then
      printf 'script: echo "ab"\n' > .tekton/pipe.yaml
    elif [ "$scenario" != fbc-noop ]; then
      printf 'task: v2\n' > .tekton/pipe.yaml
    fi
  }
  update_repo "$repo"
  if [ "$scenario" = fbc-noop ]; then
    assert_eq 'FBC main needs no artificial repair branch' "$(git branch --list "$fix")" ''
    assert_eq 'FBC no-op recorded' "${REPOS_SKIPPED[0]:-}" fbc:no-changes
    return
  fi
  local repair_sha
  repair_sha=$(git rev-parse "$fix")
  case "$scenario" in
    review-correction)
      git checkout -q "$fix"
      printf 'review correction\n' > .tekton/review.yaml
      git add .tekton/review.yaml
      git commit -qm 'Preserve review correction'
      git checkout -q original
      ;;
    whitespace-collision|custom-driver)
      git checkout -q "$base"
      printf 'script: echo "a b"\n' > .tekton/pipe.yaml
      git add .tekton/pipe.yaml
      git commit -qm 'Distinct upstream command with the same patch ID'
      assert_eq 'meaningful whitespace shares the repair patch ID' "$(git cherry "$base" "$fix" | cut -c1)" '-'
      if [ "$scenario" = custom-driver ]; then
        assert_eq 'custom merge driver hides the pending content' \
          "$(git merge-tree --write-tree "$base" "$fix")" "$(git rev-parse "$base^{tree}")"
      fi
      git push -q origin "$base"
      git checkout -q original
      ;;
    rebase-applied|merge-only)
      git checkout -q "$base"
      printf 'new upstream content\n' >> payload
      git add payload
      git commit -qm 'Upstream change before rebase merge'
      git cherry-pick "$repair_sha" >/dev/null
      assert_eq 'rebase merge changed commit ID' "$([ "$(git rev-parse HEAD)" != "$repair_sha" ] && echo yes)" yes
      git push -q origin "$base"
      if [ "$scenario" = merge-only ]; then
        git checkout -q "$fix"
        git merge --no-ff --no-commit "$base" >/dev/null 2>&1
        printf 'merge resolution work\n' > .tekton/resolution.yaml
        git add .tekton/resolution.yaml
        git commit -qm 'Merge with unpublished resolution'
      fi
      git checkout -q original
      ;;
  esac
  local pending_sha
  pending_sha=$(git rev-parse "$fix")
  dirty_work
  REPOS_UPDATED=() REPOS_SKIPPED=() REPOS_FAILED=()
  update_repo "$repo"
  assert_work_restored
  assert_eq 'retry restores original branch' "$(git branch --show-current)" original
  if [ "$scenario" = rebase-applied ]; then
    assert_eq 'applied repair rechecks as a no-op' "${REPOS_SKIPPED[0]:-}" testcomp:no-changes
    assert_eq 'applied repair does not fail' "${#REPOS_FAILED[@]}" 0
    assert_eq 'applied repair creates no new commit' "${#REPOS_UPDATED[@]}" 0
  else
    assert_eq 'pending repair blocks resetting branch' "${REPOS_FAILED[0]:-}" testcomp:existing-fix-branch
    assert_eq 'pending repair tip survives retry' "$(git rev-parse "$fix")" "$pending_sha"
    assert_eq 'pending repair creates no new commit' "${#REPOS_UPDATED[@]}" 0
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
  if [ "$scenario" = body-partial ]; then
    printf 'devel baseline\n' > payload
    printf '#!/bin/bash\nprintf "partial CVE fix\\n" > payload\n' > skills/cve-fix/scripts/fix-all.sh
  fi
  chmod +x skills/cve-fix/scripts/fix-all.sh
  git add skills payload
  git commit -qm 'Skill only on devel'
  if [ "$scenario" = ignored-tracked ]; then
    printf 'upstream pipeline\n' > .tekton/private.yaml
    git add .tekton/private.yaml
    git commit -qm 'Tracked only on devel'
  fi
  git checkout -q original
  if [[ "$scenario" == ignored-* ]]; then
    printf '.tekton/private.yaml\n' > .gitignore
    git add .gitignore
    git commit -qm 'Ignore local experiment on original'
    printf 'private local experiment\n' > .tekton/private.yaml
  fi
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
      update_all() {
        # Only the partial-body case runs the fixture child, never a CVE scanner.
        if [ "$scenario" = body-partial ]; then
          (cd "$repo_dir" && "$FIX_ALL_SCRIPT")
        fi
      }
      main 0.25.1
    else
      check_prerequisites
      [ "$scenario" != body-fails ] || exit 7
    fi
  )
  rc=$?
  set -e
  if [[ "$scenario" == ignored-* ]]; then
    assert_eq 'bootstrap preserves ignored file' "$(< .tekton/private.yaml)" 'private local experiment'
  fi
  case "$scenario" in
    normal) assert_eq 'prerequisites succeeded' "$rc" 0 ;;
    body-fails) assert_eq 'original failure preserved' "$rc" 7 ;;
    *) assert_eq 'failure propagated' "$rc" 1 ;;
  esac
  case "$scenario" in
    pop-fails|restore-fails|conflict|stash-ref-fails|post-stash-status-fails|body-partial)
      assert_eq 'stash retained for recovery' "$(command git stash list | wc -l)" 2
      assert_eq 'older stash retained' "$(command git rev-parse 'stash@{1}')" "$older_stash"
      if [ "$scenario" = body-partial ]; then
        assert_eq 'partial child fix retained' "$(< payload)" 'partial CVE fix'
        assert_eq 'partial child stays on its source branch' "$(command git branch --show-current)" devel
        assert_eq 'original index recoverable' "$(command git show 'stash@{0}^2:payload')" "$before_index"
        assert_eq 'original work recoverable' "$(command git show 'stash@{0}:payload')" "$before_payload"
      fi
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

rpm_prerequisites_case() (
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  SCRIPT_DIR="$TEST_ROOT/rpm-prerequisites"
  mkdir -p "$SCRIPT_DIR"
  export RPM_PREREQUISITE_MARKER="$SCRIPT_DIR/checked"
  printf '#!/bin/bash\nprintf checked > "$RPM_PREREQUISITE_MARKER"\n' > "$SCRIPT_DIR/setup-entitlements.sh"
  chmod 600 "$SCRIPT_DIR/setup-entitlements.sh"
  podman() { :; }; gh() { :; }; skopeo() { :; }; jq() { :; }
  check_prerequisites
  assert_eq 'non-executable prerequisite runs through bash' "$(cat "$RPM_PREREQUISITE_MARKER")" checked
)

rpm_case() (
  local scenario="$1"
  SUBMARINER_BASE="$TEST_ROOT/rpm-$scenario"
  local repo_dir="$SUBMARINER_BASE/submariner"
  setup_repo
  git checkout -qb devel
  cat > .rpm-lockfiles/update-lockfile.sh <<'FIXTURE'
#!/bin/bash
# registry.access.redhat.com/ubi10/ubi:latest
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
  mkdir -p .rpm-lockfiles/gateway/cache
  echo nested > .rpm-lockfiles/gateway/cache/rpms.lock.yaml # outside the component lockfile scope
fi
[ "$RPM_TEST_MODE" != updater-fails ]
FIXTURE
  git add .rpm-lockfiles/update-lockfile.sh
  git commit -qm 'Fixture updater'
  git update-ref refs/remotes/origin/devel HEAD
  case "$scenario" in
    remote-repair)
      # Simulate a fetched review correction whose local branch was deleted.
      local remote_before bare_repo="$SUBMARINER_BASE/fork.git"
      git clone -q --bare "$repo_dir" "$bare_repo"
      git remote add origin "$bare_repo"
      git checkout -qb update-rpm-lockfiles-0.25.1 release-0.25
      printf 'review correction\n' > remote-correction
      git add remote-correction; git commit -qm 'Pending review correction'
      git push -q origin update-rpm-lockfiles-0.25.1
      remote_before=$(git rev-parse HEAD)
      git checkout -q original
      git branch -D update-rpm-lockfiles-0.25.1 >/dev/null
      git fetch -q origin
      ;;
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
    patch-fails)
      git checkout -q release-0.25
      printf 'rhel9\n' > .rpm-lockfiles/gateway/submariner-rhel-9.repo
      git add .rpm-lockfiles/gateway/submariner-rhel-9.repo
      git commit -qm 'RHEL 9 repository'
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
    ignored-tracked)
      git checkout -q release-0.25
      printf 'upstream pipeline\n' > .tekton/private.yaml
      git add .tekton/private.yaml
      git commit -qm 'Tracked only on release'
      ;;
  esac
  git checkout -q original
  if [[ "$scenario" == ignored-* ]]; then
    printf '.tekton/private.yaml\n' > .gitignore
    git add .gitignore
    git commit -qm 'Ignore local experiment on original'
    original_sha=$(git rev-parse HEAD)
    printf 'private local experiment\n' > .tekton/private.yaml
  fi
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
  skopeo() { echo 'real skopeo reached' >&2; return 1; }  # the fixture has no pinned base
  [ "$scenario" != all-components ] || COMPONENT_FILTER=all
  inject_git_failures
  mktemp() {
    case "$scenario:${1:-}" in
      updater-temp-fails:*update-lockfile*|log-temp-fails:) return 1 ;;
    esac
    command mktemp "$@"
  }
  sed() {
    [ "$scenario" != patch-fails ] || return 1
    command sed "$@"
  }
  update_lockfiles 2> "$SUBMARINER_BASE/stderr"
  assert_eq 'original commit preserved' "$(command git rev-parse original)" "$original_sha"
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD)
  case "$scenario" in
    normal|detached|noop|tracked|noop-tracked|new-lockfile|remote-repair|push-log-fails)
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
    dirty|status-fails|checkout-fails|copy-fails|cdn-refused|patch-fails|updater-temp-fails|log-temp-fails|ignored-tracked|ignored-exposed)
      assert_eq 'original branch untouched' "$branch" original
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      if [ "$scenario" = dirty ]; then assert_work_restored; fi
      if [[ "$scenario" == ignored-* ]]; then
        assert_eq 'RPM preserves ignored local file' "$(< .tekton/private.yaml)" 'private local experiment'
        assert_eq 'RPM does not run updater on unsafe checkout' "$([ -f "$RPM_TEST_CALLS" ] && echo yes || echo no)" no
        assert_eq 'RPM does not create repair commit' "${#REPOS_UPDATED[@]}" 0
        assert_eq 'RPM removes unused repair branch' "$(command git branch --list update-rpm-lockfiles-0.25.1)" ''
      fi
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
  case "$scenario" in
    patch-fails|updater-temp-fails|log-temp-fails)
      assert_eq 'preparation failure recorded' "${REPOS_FAILED[0]:-}" gateway:script-copy-failed
      assert_eq 'updater never ran after preparation failure' "$([ -e "$RPM_TEST_CALLS" ] && echo yes || echo no)" no ;;
    cdn-refused)
      assert_eq 'refusal tells the user what to do' "$(grep -c 'make setup-entitlements FORCE=1' "$SUBMARINER_BASE/stderr")" 1 ;;
    updater-fails)
      assert_eq 'no refusal hint for an unrelated failure' "$(grep -c 'FORCE=1' "$SUBMARINER_BASE/stderr")" 0 ;;
    normal) assert_eq 'component reaches the updater' "$(head -1 "$RPM_TEST_CALLS")" 'update-rpm-lockfiles-0.25.1 gateway' ;;
  esac
  assert_eq 'no temp files left behind' "$(find "$TMPDIR" -type f | wc -l | tr -d ' ')" 0
  get_gh_user() { printf 'test-user\n'; }
  if [ "$scenario" = remote-repair ]; then
    AUTORELEASE_PUSH_LOG="$SUBMARINER_BASE/push-commands"
    export RPM_PUSH_GH_MARKER="$SUBMARINER_BASE/gh-called"
    gh() { echo called >> "$RPM_PUSH_GH_MARKER"; return 99; }
    export -f gh
  fi
  if [ "$scenario" = push-log-fails ]; then
    AUTORELEASE_PUSH_LOG="$SUBMARINER_BASE/missing-directory/push.log"
  fi
  summary_rc=0
  print_summary >/dev/null || summary_rc=$?
  if [ "${#REPOS_FAILED[@]}" -gt 0 ]; then assert_eq 'summary fails' "$summary_rc" 1; fi
  if [ "$scenario" = push-log-fails ]; then
    assert_eq 'pending command log failure is reported' "$summary_rc" 1
  fi
  if [ "$scenario" = remote-repair ]; then
    local push_rc=0
    bash -euo pipefail "$AUTORELEASE_PUSH_LOG" > "$SUBMARINER_BASE/push-output" 2>&1 || push_rc=$?
    assert_eq 'divergent remote RPM correction blocks publication' "$push_rc" 1
    assert_eq 'remote RPM correction survives' \
      "$(command git --git-dir="$bare_repo" rev-parse refs/heads/update-rpm-lockfiles-0.25.1)" "$remote_before"
    assert_eq 'rejected RPM push never reaches GitHub' "$(test -f "$RPM_PUSH_GH_MARKER" && echo called || true)" ''
  fi
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

rpm_tracker_case() (
  local scenario="$1"
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  # main re-executes in the Linux VM on macOS, which these fixtures don't have.
  linux_vm_reexec() { :; }
  local transitions="$TEST_ROOT/rpm-tracker-$scenario"
  TRACKER_LIB="$TEST_ROOT/rpm-tracker-stub.sh"
  cat > "$TRACKER_LIB" <<'STUB'
find_release_tracker() { printf 'TEST-1\n'; }
update_step() { printf '%s\n' "$3" >> "$transitions"; }
STUB
  check_prerequisites() { :; }
  update_lockfiles() {
    case "$scenario" in
      current|filtered) REPOS_SKIPPED=(submariner:no-changes shipyard:no-changes) ;;
      no-lockfiles) REPOS_SKIPPED=(submariner:no-changes shipyard:no-lockfiles) ;;
      missing) REPOS_SKIPPED=(submariner:no-changes shipyard:repo-not-found) ;;
      updated) REPOS_UPDATED=(submariner#submariner#0.25.1#release-0.25) ;;
      failed) REPOS_FAILED=(shipyard:update-script-failed) ;;
    esac
  }
  get_gh_user() { :; }
  fork_remote() { printf 'fork\n'; }
  local rc=0
  if [ "$scenario" = filtered ]; then
    main 0.25.1 gateway >/dev/null || rc=$?
    assert_eq 'partial run does not update tracker' "$(cat "$transitions" 2>/dev/null || true)" ''
  else
    main 0.25.1 >/dev/null || rc=$?
    local expected=in_progress
    case "$scenario" in current|no-lockfiles) expected+=$'\ncomplete' ;; esac
    assert_eq 'RPM tracker reflects fresh full-run outcome' "$(cat "$transitions")" "$expected"
  fi
  local expected_rc=0
  [ "$scenario" != failed ] || expected_rc=1
  assert_eq 'RPM outcome preserves failure status' "$rc" "$expected_rc"
)

# The shared RPM matrix above covers generic lifecycle failures. These cases
# need a real origin or a tracked release updater to exercise distinct behavior.
rpm_fresh_source_case() (
  local scenario="$1"
  SUBMARINER_BASE="$TEST_ROOT/rpm-fresh-$scenario"
  local repo_dir="$SUBMARINER_BASE/submariner"
  setup_repo
  # Real release branches track their updater; the devel copy is temporary.
  printf '# release updater must remain unchanged\n' > .rpm-lockfiles/update-lockfile.sh
  git add .rpm-lockfiles/update-lockfile.sh
  git commit -qm 'Release updater fixture'
  git branch -f release-0.25 HEAD
  original_sha=$(git rev-parse HEAD)
  git checkout -qb devel
  cat > .rpm-lockfiles/update-lockfile.sh <<'UPDATER'
#!/bin/bash
if [ "$RPM_TEST_MODE" = no-sources ]; then
  printf 'WARNING:rpm_lockfile:No sources found for package-one\n' >&2
  printf 'WARNING:rpm_lockfile: No sources found for package-two\n' >&2
fi
printf 'updated lockfile\n' > .rpm-lockfiles/gateway/rpms.lock.yaml
[ "$RPM_TEST_MODE" != updater-fails ]
UPDATER
  git add .rpm-lockfiles/update-lockfile.sh
  git commit -qm 'Fixture updater'
  git init -q --bare "$SUBMARINER_BASE/origin.git"
  git remote add origin "$SUBMARINER_BASE/origin.git"
  git push -q origin devel
  if [ "$scenario" != local-base ]; then git push -q origin release-0.25; fi
  local upstream_sha="$original_sha"
  if [ "$scenario" = stale-origin ]; then
    # A narrow default fetch must refresh both the release and devel refs.
    git push -q origin original:unrelated
    git config remote.origin.fetch '+refs/heads/unrelated:refs/remotes/origin/unrelated'
    local old_devel_sha
    old_devel_sha=$(git rev-parse devel)
    printf '\nprintf "fresh updater\\n" > "$RPM_UPDATER_MARKER"\n' >> .rpm-lockfiles/update-lockfile.sh
    git add .rpm-lockfiles/update-lockfile.sh
    git commit -qm 'New upstream updater'
    git push -q origin devel
    git update-ref refs/remotes/origin/devel "$old_devel_sha"
    git checkout -q release-0.25
    printf 'upstream change\n' > upstream-only
    git add upstream-only
    git commit -qm 'New upstream source'
    upstream_sha=$(git rev-parse HEAD)
    git push -q origin release-0.25
    git update-ref refs/remotes/origin/release-0.25 "$original_sha"
  fi
  git checkout -q original
  if [ "$scenario" = pending-fix ]; then
    git checkout -qb update-rpm-lockfiles-0.25.1 release-0.25
    printf 'unpublished RPM repair\n' > pending-repair
    git add pending-repair; git commit -qm 'Preserve pending RPM repair'
    pending_sha=$(git rev-parse HEAD)
    git checkout -q original
  fi
  export RPM_TEST_MODE="$scenario"
  export RPM_UPDATER_MARKER="$SUBMARINER_BASE/updater-used"
  # shellcheck source=../rpm-lockfile-update.sh
  source "$RELEASE_SCRIPTS/rpm-lockfile-update.sh"
  BRANCH=release-0.25 VERSION=0.25.1 COMPONENT_FILTER=gateway
  skopeo() { echo 'real skopeo reached' >&2; return 1; }  # the fixture has no pinned base
  inject_git_failures
  local updater_output="$SUBMARINER_BASE/updater-output"
  update_lockfiles > "$updater_output" 2>&1
  cat "$updater_output"
  if [ "$scenario" = stale-origin ]; then
    assert_eq 'fresh devel updater executed despite narrow fetch refspec' \
      "$(cat "$RPM_UPDATER_MARKER" 2>/dev/null || true)" 'fresh updater'
  fi
  if [ "$scenario" = no-sources ]; then
    assert_eq 'source warnings remain visible' \
      "$(grep -Ec '^WARNING:rpm_lockfile: ?No sources' "$updater_output" || true)" 2
  fi
  assert_eq 'original commit preserved' "$(command git rev-parse original)" "$original_sha"
  assert_eq 'release updater preserved' "$(< .rpm-lockfiles/update-lockfile.sh)" '# release updater must remain unchanged'
  local branch
  branch=$(command git rev-parse --abbrev-ref HEAD)
  case "$scenario" in
    stale-origin|local-base|no-sources)
      assert_eq 'original branch restored' "$branch" original
      assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
      assert_eq 'worktree clean' "$(command git status --porcelain --untracked-files=all)" ''
      assert_eq 'update recorded' "${#REPOS_UPDATED[@]}" 1
      assert_eq 'RPM fix includes current upstream commit' \
        "$(command git merge-base "$upstream_sha" update-rpm-lockfiles-0.25.1)" "$upstream_sha"
      ;;
    pending-fix)
      assert_eq 'pending RPM repair leaves checkout intact' "$branch" original
      assert_eq 'pending RPM repair commit preserved' "$(command git rev-parse update-rpm-lockfiles-0.25.1)" "$pending_sha"
      assert_eq 'pending RPM repair records failure' "${REPOS_FAILED[0]:-}" gateway:existing-fix-branch
      ;;
    fetch-fails|copy-fails)
      assert_eq 'original branch untouched' "$branch" original
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      if [ "$scenario" = fetch-fails ]; then
        assert_eq 'fetch failure reported' "${REPOS_FAILED[0]}" gateway:fetch-failed
        assert_eq 'fetch failure creates no fix branch' \
          "$(command git branch --list update-rpm-lockfiles-0.25.1)" ''
      fi
      if [ "$scenario" = copy-fails ]; then
        assert_eq 'failed updater read preserves the checkout' "${REPOS_FAILED[0]}" gateway:script-copy-failed
      fi
      ;;
    updater-fails)
      assert_eq 'unfinished work stays on fix branch' "$branch" update-rpm-lockfiles-0.25.1
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      assert_eq 'partial edits preserved' "$(< .rpm-lockfiles/gateway/rpms.lock.yaml)" 'updated lockfile'
      ;;
  esac
  get_gh_user() { printf 'test-user\n'; }
  summary_rc=0
  print_summary >/dev/null || summary_rc=$?
  if [ "${#REPOS_FAILED[@]}" -gt 0 ]; then assert_eq 'summary fails' "$summary_rc" 1; fi
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
for scenario in pending review-correction whitespace-collision custom-driver rebase-applied merge-only fbc-noop; do
  run_logged tekton_retry_case "$scenario"
  echo "  ✓ tekton-task-refs-update / retry $scenario"
  PASS=$((PASS + 1))
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

for kind in tekton-task-refs-update tekton-task-version-bump; do
  for scenario in tracked exposed restore-fails; do
    run_logged ignored_tekton_case "$kind" "$scenario"
    echo "  ✓ $kind / ignored $scenario"
    PASS=$((PASS + 1))
  done
done
for scenario in ignored-tracked ignored-exposed; do
  run_logged cve_case "$scenario"
  echo "  ✓ cve / $scenario"
  PASS=$((PASS + 1))
done
for scenario in normal restore-fails pop-fails conflict body-partial; do
  run_logged cve_case "$scenario" main
  echo "  ✓ cve main / $scenario"
  PASS=$((PASS + 1))
done
run_logged rpm_prerequisites_case
echo "  ✓ rpm / non-executable prerequisites"
PASS=$((PASS + 1))
for scenario in normal noop tracked noop-tracked new-lockfile remote-repair push-log-fails all-components cdn-refused lockfile-status-fails detached dirty status-fails checkout-fails copy-fails patch-fails updater-temp-fails log-temp-fails updater-fails stage-fails commit-fails restore-fails noop-restore-fails hook-artifact ignored-tracked ignored-exposed; do
  run_logged rpm_case "$scenario"
  echo "  ✓ rpm / $scenario"
  PASS=$((PASS + 1))
done
for scenario in normal dirty untracked status-fails restore-fails; do
  run_logged bundle_case "$scenario"
  echo "  ✓ bundle / $scenario"
  PASS=$((PASS + 1))
done
for scenario in pending-fix stale-origin local-base fetch-fails no-sources copy-fails updater-fails; do
  run_logged rpm_fresh_source_case "$scenario"
  echo "  ✓ fresh RPM source / $scenario"
  PASS=$((PASS + 1))
done
for scenario in current no-lockfiles missing updated failed filtered; do
  run_logged rpm_tracker_case "$scenario"
  echo "  ✓ rpm tracker / $scenario"
  PASS=$((PASS + 1))
done
echo "All $PASS tests passed"
