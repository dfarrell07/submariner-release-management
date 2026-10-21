#!/bin/bash
# Exercise branch restoration against disposable repositories, never real releases.
# shellcheck disable=SC2034  # Globals are read by the sourced implementation.
set -euo pipefail

LABEL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/update-version-labels.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# A pre-commit hook can export an absolute index path. Fixture git commands must
# not use the caller's index or object database.
while IFS= read -r git_env; do
  unset "$git_env"
done < <(git rev-parse --local-env-vars)

assert_eq() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s (got: %s; want: %s)\n' "$1" "$2" "$3" >&2
    exit 1
  fi
}

run_case() (
  scenario="$1"
  SUBMARINER_BASE="$TEST_ROOT/$scenario"
  # shellcheck source=../update-version-labels.sh
  source "$LABEL_SCRIPT"
  VERSION=0.25.1
  MAJOR_MINOR=0.25
  RELEASE_BRANCH=release-0.25
  repo=submariner
  [[ "$scenario" == bundle-* ]] && repo=submariner-operator
  repo_dir="$SUBMARINER_BASE/$repo"
  mkdir -p "$repo_dir/package"
  git init -q -b original "$repo_dir"
  cd "$repo_dir"
  git config user.name 'Version Label Test'
  git config user.email 'test@example.invalid'
  git config core.hooksPath /dev/null
  git config commit.gpgsign false
  # Cleanup must notice untracked files even when the user normally hides them.
  git config status.showUntrackedFiles no

  initial_version=0.25.0
  [[ "$scenario" == no-op* || "$scenario" == binary-only ]] && initial_version="$VERSION"
  read -ra files <<< "${COMPONENT_DOCKERFILES[$repo]}"
  first="${files[0]}"
  second="${files[1]:-$first}"
  binary_version='${BASE_BRANCH}'
  [[ "$scenario" != no-op* ]] || binary_version="v$VERSION"
  [ "$scenario" != literal-version ] || binary_version=v0.25.0
  for file in "${files[@]}"; do
    printf 'ARG BASE_BRANCH=release-0.25\nFROM scratch\nARG BASE_BRANCH\nRUN go build -ldflags "-X main.version=%s -X main.gitCommitHash=preserved"\nLABEL version="v%s"\n' \
      "$binary_version" "$initial_version" > "$file"
  done
  if [ "$repo" = submariner-operator ]; then
    printf 'FROM scratch\nLABEL csv-version="0.25.0"\nLABEL release="v0.25.0"\nLABEL version="v0.25.0"\n' \
      > bundle.Dockerfile.konflux
  fi
  printf 'baseline work\n' > payload
  git add -A
  git commit -qm base
  git checkout -qb "$RELEASE_BRANCH"

  case "$scenario" in
    missing-first) git rm -q -- "$first" ;;
    missing-later*) git rm -q -- "$second" ;;
    malformed-first) printf 'LABEL version="vlatest"\n' > "$first" ;;
    malformed-later) printf 'LABEL version="vlatest"\n' > "$second" ;;
    missing-flags-first) sed -i 's/main.version=/main.buildTag=/' "$first" ;;
    missing-flags-later) sed -i 's/main.version=/main.buildTag=/' "$second" ;;
    bundle-malformed) printf 'LABEL csv-version="invalid"\n' > bundle.Dockerfile.konflux ;;
  esac
  git add -A
  if ! git diff --cached --quiet; then git commit -qm 'Failure fixture'; fi
  git checkout -q original
  # Divergent branches make checkout reject partial edits. The same-content
  # variant also verifies that we refuse to carry edits even when Git permits it.
  if [ "$scenario" != missing-later-same ]; then
    printf 'FROM scratch\nLABEL version="v0.26.0"\n' > "$first"
    git add -- "$first"
    git commit -qm 'Original branch differs from release'
  fi
  original_sha=$(git rev-parse HEAD)
  if [ "$scenario" = ignored-artifact ]; then
    printf 'local-cache/\n' > .gitignore
    git add .gitignore
    git commit -qm 'Ignore local cache only on original branch'
    original_sha=$(git rev-parse HEAD)
    mkdir local-cache
    printf 'private cached binary\n' > local-cache/grype
  fi
  git init -q --bare "$SUBMARINER_BASE/origin.git"
  git remote add origin "$SUBMARINER_BASE/origin.git"
  if [ "$scenario" = local-base ]; then
    git push -q origin original:devel
  else
    git push -q origin "$RELEASE_BRANCH"
  fi
  if [ "$scenario" = stale-origin ]; then
    stale_sha=$(git rev-parse "origin/$RELEASE_BRANCH")
    git checkout -q "$RELEASE_BRANCH"
    printf 'new upstream change\n' > upstream-change
    git add upstream-change
    git commit -qm 'New upstream release work'
    upstream_sha=$(git rev-parse HEAD)
    git push -q origin "$RELEASE_BRANCH"
    git update-ref "refs/remotes/origin/$RELEASE_BRANCH" "$stale_sha"
    git checkout -q original
  fi
  if [ "$scenario" = dirty ]; then
    printf 'staged work\n' >> payload
    git add payload
    printf 'unstaged work\n' >> payload
    printf 'private untracked notes\n' > notes
    initial_status=$(git status --porcelain --untracked-files=all)
    initial_index=$(git show :payload)
    initial_payload=$(< payload)
  fi
  expected_branch=original
  if [ "$scenario" = detached ]; then
    git checkout -q --detach
    expected_branch=HEAD
  fi

  # Failure injection only: all successful git and sed operations are real.
  git() {
    if [ "$scenario" = untracked-after-commit ] && [ "${1:-}" = commit ]; then
      command git "$@" || return
      printf 'Simulated commit-hook artifact\n' > hook-artifact
      return
    fi
    if [ "$scenario" = commit-failure ] && [ "${1:-}" = commit ]; then
      return 1
    fi
    if [ "$scenario" = stage-failure ] && [ "${1:-}" = add ]; then return 1; fi
    if [[ "$scenario" == *checkout-failure ]] &&
       [ "${1:-}" = checkout ] && [ "${3:-}" = original ]; then
      echo 'Injected checkout failure' >&2
      return 1
    fi
    if [ "${1:-}" = status ] &&
       { [ "$scenario" = initial-status-failure ] ||
         { [ "$scenario" = status-failure ] && [ "$(command git branch --show-current)" = fix-version-labels-0.25.1 ]; }; }; then
      echo 'Injected status failure' >&2
      return 1
    fi
    if [ "$scenario" = fetch-failure ] && [ "${1:-}" = fetch ]; then return 1; fi
    command git "$@"
  }
  sed() {
    case "$scenario:${*: -1}" in
      "sed-first:$first"|"sed-later:$second")
        echo 'Injected sed failure' >&2
        return 1 ;;
    esac
    command sed "$@"
  }

  log="$SUBMARINER_BASE/output.log"
  # Do not invoke conditionally: keep production's set -e behavior active so
  # unhandled command failures cannot look like successfully tested cleanup.
  update_repo "$repo" > "$log" 2>&1
  branch=$(command git rev-parse --abbrev-ref HEAD)
  dirty=$(command git status --porcelain --untracked-files=all)
  assert_eq 'original branch commit preserved' "$(command git rev-parse original)" "$original_sha"
  if [ "$scenario" = ignored-artifact ]; then
    assert_eq 'formerly ignored files excluded from commit' \
      "$(command git ls-tree -r --name-only fix-version-labels-0.25.1 -- local-cache)" ''
    assert_eq 'local cache content preserved' "$(< local-cache/grype)" 'private cached binary'
  fi

  case "$scenario" in
    success|detached|stale-origin|local-base|bundle-preserved|bundle-malformed|literal-version|binary-only)
      assert_eq 'restored branch' "$branch" "$expected_branch"
      assert_eq 'restored original commit' "$(command git rev-parse HEAD)" "$original_sha"
      assert_eq 'clean after success' "$dirty" ''
      assert_eq 'success recorded' "${#REPOS_UPDATED[@]}" 1
      assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
      command git show "fix-version-labels-0.25.1:$first" | grep -q 'version="v0.25.1"'
      assert_eq 'compiled version matches the image version' \
        "$(command git show "fix-version-labels-0.25.1:$first" | grep -oE -- '-X main.version=[^ ]+')" \
        '-X main.version=v0.25.1'
      command git show "fix-version-labels-0.25.1:$first" | grep -qF -- '-X main.gitCommitHash=preserved'
      if [[ "$scenario" == bundle-* ]]; then
        assert_eq 'bundle metadata deferred unchanged to bundle generation' \
          "$(command git show fix-version-labels-0.25.1:bundle.Dockerfile.konflux)" \
          "$(command git show release-0.25:bundle.Dockerfile.konflux)"
      fi
      if [ "$scenario" = stale-origin ]; then
        assert_eq 'fix includes current upstream' \
          "$(command git merge-base "$upstream_sha" fix-version-labels-0.25.1)" "$upstream_sha"
      fi
      ;;
    dirty|initial-status-failure|fetch-failure)
      assert_eq 'unsafe update leaves original branch' "$branch" original
      assert_eq 'unsafe update records failure' "${#REPOS_FAILED[@]}" 1
      assert_eq 'unsafe update makes no fix branch' "$(command git branch --list fix-version-labels-0.25.1)" ''
      if [ "$scenario" = dirty ]; then
        assert_eq 'dirty status preserved' "$dirty" "$initial_status"
        assert_eq 'staged content preserved' "$(command git show :payload)" "$initial_index"
        assert_eq 'unstaged content preserved' "$(< payload)" "$initial_payload"
        assert_eq 'untracked content preserved' "$(< notes)" 'private untracked notes'
      fi
      ;;
    no-op)
      assert_eq 'no-op restored branch' "$branch" original
      assert_eq 'no-op clean' "$dirty" ''
      assert_eq 'no-op recorded' "${REPOS_SKIPPED[0]:-}" "$repo:no-changes"
      assert_eq 'no-op no failures' "${#REPOS_FAILED[@]}" 0
      if command git show-ref --verify --quiet refs/heads/fix-version-labels-0.25.1; then
        echo 'FAIL: no-op fix branch was not removed' >&2
        exit 1
      fi
      ;;
    missing-first|malformed-first|sed-first|missing-flags-first)
      assert_eq 'clean failure restored branch' "$branch" original
      assert_eq 'clean failure preserved commit' "$(command git rev-parse HEAD)" "$original_sha"
      assert_eq 'clean failure no edits' "$dirty" ''
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      assert_eq 'no success' "${#REPOS_UPDATED[@]}" 0
      ;;
    missing-later*|malformed-later|sed-later|missing-flags-later|commit-failure|stage-failure)
      assert_eq 'partial work stays on fix branch' "$branch" fix-version-labels-0.25.1
      if [ -z "$dirty" ]; then echo 'FAIL: partial changes lost' >&2; exit 1; fi
      grep -q 'version="v0.25.1"' "$first"
      grep -q 'Review and commit or stash' "$log"
      assert_eq 'failure recorded once' "${#REPOS_FAILED[@]}" 1
      assert_eq 'no success' "${#REPOS_UPDATED[@]}" 0
      ;;
    *checkout-failure|status-failure|untracked-after-commit|ignored-artifact)
      assert_eq 'failed restore keeps fix branch' "$branch" fix-version-labels-0.25.1
      if [ "$scenario" = untracked-after-commit ] || [ "$scenario" = ignored-artifact ]; then
        expected_artifact='?? hook-artifact'
        [ "$scenario" != ignored-artifact ] || expected_artifact='?? local-cache/grype'
        assert_eq 'untracked work preserved' "$dirty" "$expected_artifact"
        grep -q 'Review and commit or stash' "$log"
      else
        assert_eq 'failed restore stays clean' "$dirty" ''
        grep -Eq 'Failed to restore|Cannot inspect worktree' "$log"
      fi
      assert_eq 'restore failure recorded' "${REPOS_FAILED[0]:-}" "$repo:restore-failed"
      assert_eq 'not recorded as skipped' "${#REPOS_SKIPPED[@]}" 0
      ;;
  esac

  # A cleanup failure must remain a nonzero overall result, not mark the step done.
  get_gh_user() { :; }
  summary_rc=0
  print_summary > /dev/null || summary_rc=$?
  if [ "${#REPOS_FAILED[@]}" -gt 0 ]; then
    assert_eq 'summary reports failure' "$summary_rc" 1
  else
    assert_eq 'summary reports success' "$summary_rc" 0
  fi
  echo "  ✓ $scenario"
)

cases=(dirty stale-origin local-base fetch-failure initial-status-failure
       success detached no-op missing-first missing-later missing-later-same
       malformed-first malformed-later sed-first sed-later missing-flags-first missing-flags-later
       bundle-malformed bundle-preserved literal-version binary-only commit-failure stage-failure checkout-failure no-op-checkout-failure status-failure
       untracked-after-commit ignored-artifact)
for scenario in "${cases[@]}"; do run_case "$scenario"; done

# Exercise main against the complete repo set; only Jira is replaced by a log.
main_case() (
  local scenario="$1" repo file repo_dir rc
  SUBMARINER_BASE="$TEST_ROOT/main-$scenario"
  # shellcheck source=../update-version-labels.sh
  source "$LABEL_SCRIPT"
  mkdir -p "$SUBMARINER_BASE"
  export LABEL_TRACKER_LOG="$SUBMARINER_BASE/tracker.log"
  : > "$LABEL_TRACKER_LOG"
  TRACKER_LIB="$SUBMARINER_BASE/tracker.sh"
  cat > "$TRACKER_LIB" <<'TRACKER'
find_release_tracker() { printf 'TEST-1\n'; }
update_step() { printf '%s\n' "$3" >> "$LABEL_TRACKER_LOG"; }
TRACKER
  for repo in $COMPONENT_VERSION_REPOS; do
    [ "$scenario:$repo" != missing:subctl ] || continue
    repo_dir="$SUBMARINER_BASE/$repo"
    mkdir -p "$repo_dir/package"
    git init -q -b original "$repo_dir"
    cd "$repo_dir"
    git config user.name 'Version Label Test'
    git config user.email test@example.invalid
    git config core.hooksPath /dev/null
    git config commit.gpgsign false
    for file in ${COMPONENT_DOCKERFILES[$repo]}; do
      if [ "$scenario" = updated ]; then
        printf 'LABEL version="v0.25.0"\n' > "$file"
      else
        printf 'LABEL version="v0.25.1"\n' > "$file"
      fi
      if [ "$repo" != shipyard ]; then
        binary_version=v0.25.1
        [ "$scenario" != updated ] || binary_version='${BASE_BRANCH}'
        printf 'RUN go build -ldflags "-X main.version=%s"\n' "$binary_version" >> "$file"
      fi
    done
    git add -A
    git commit -qm base
    git branch release-0.25
    git init -q --bare "$SUBMARINER_BASE/$repo.git"
    git remote add origin "$SUBMARINER_BASE/$repo.git"
    git push -q origin release-0.25
  done
  git() {
    if [ "$scenario" = failed ] && [ "${1:-}" = fetch ] && [ "${PWD##*/}" = subctl ]; then return 1; fi
    command git "$@"
  }
  get_gh_user() { printf 'test-user\n'; }
  local -a args=(0.25.1)
  [ "$scenario" != filtered ] || args+=(submariner)
  set +e
  (set -e; main "${args[@]}") > "$SUBMARINER_BASE/output.log" 2>&1
  rc=$?
  set -e
  case "$scenario" in
    noop)
      assert_eq 'all-current succeeds' "$rc" 0
      assert_eq 'all-current completes' "$(< "$LABEL_TRACKER_LOG")" $'in_progress\ncomplete' ;;
    filtered)
      assert_eq 'filtered no-op succeeds' "$rc" 0
      assert_eq 'filtered run leaves whole tracker alone' "$(< "$LABEL_TRACKER_LOG")" '' ;;
    updated)
      assert_eq 'changed run succeeds' "$rc" 0
      assert_eq 'changed run awaits PRs' "$(< "$LABEL_TRACKER_LOG")" in_progress ;;
    missing|failed)
      assert_eq 'incomplete run fails' "$rc" 1
      assert_eq 'incomplete run cannot complete' "$(< "$LABEL_TRACKER_LOG")" in_progress ;;
  esac
  echo "  ✓ main / $scenario"
)
main_cases=(noop updated missing failed filtered)
for scenario in "${main_cases[@]}"; do main_case "$scenario"; done

semantic_case() (
  # Exercise effective build arguments, not just matching replacement strings.
  source "${LABEL_SCRIPT%/*}/lib/dockerfile-version.sh"
  local file="$TEST_ROOT/compiled.Dockerfile"
  cat > "$file" <<'DOCKERFILE'
ARG BASE_BRANCH=release-0.25
FROM scratch
ARG BASE_BRANCH
RUN go build -ldflags "-X main.version=${BASE_BRANCH} -X github.com/submariner-io/submariner-operator/api/v1alpha1.DefaultSubmarinerVersion=v0.24.2 -X=github.com/submariner-io/submariner-operator/api/v1alpha1.DefaultLighthouseVersion=v0.24.2 -X main.gitCommitHash=preserved -X example.org/dependency.Version=v9.0.0"
LABEL version="v0.25.0"
DOCKERFILE
  set_component_version "$file" 0.25.1 true
  export VERSION_FLAGS_LOG="$TEST_ROOT/effective-flags"
  go() { printf '%s\n' "$@" > "$VERSION_FLAGS_LOG"; }
  export -f go
  BASE_BRANCH=devel bash -c "$(sed -n 's/^RUN //p' "$file")"
  assert_eq 'all binary/default-image versions ignore pipeline branch overrides' \
    "$(grep -oE '[vV]ersion=v0.25.1' "$VERSION_FLAGS_LOG" | wc -l)" 3
  grep -qF 'main.gitCommitHash=preserved' "$VERSION_FLAGS_LOG"
  grep -qF 'example.org/dependency.Version=v9.0.0' "$VERSION_FLAGS_LOG"
  grep -qF 'ARG BASE_BRANCH=release-0.25' "$file"
  set_component_version "$file" 0.26.0 true
  component_version_matches "$(cat "$file")" 0.26.0 true
  assert_eq 'literal versions support the next Y-stream setup' "$?" 0
  echo '  ✓ effective build versions'
)
semantic_case

setup_case() (
  source "${LABEL_SCRIPT%/*}/lib/dockerfile-version.sh"
  # shellcheck disable=SC1090  # Load only the real function, without its main entrypoint.
  source <(awk '/^add_konflux_dockerfile\(\)/,/^}/' "${LABEL_SCRIPT%/*}/konflux-component-setup.sh")
  local repo="$TEST_ROOT/y-stream"
  mkdir -p "$repo/package"
  git init -qb original "$repo"
  cd "$repo"
  git config user.name 'Version Test'; git config user.email test@example.invalid
  git config core.hooksPath /dev/null; git config commit.gpgsign false
  printf 'ARG BASE_BRANCH=release-0.25\nLABEL version="v0.25.1"\nRUN go build -ldflags "-X main.version=v0.25.1"\n' > package/Dockerfile.subctl.konflux
  git add package; git commit -qm base
  git update-ref refs/remotes/origin/release-0.25 HEAD
  COMPONENT=subctl VERSION_MAJOR=0 VERSION_MINOR=26 PREV_VERSION=25 TARGET_BRANCH=release-0.26
  SPECIAL_FILES='' HAS_CPE=no
  declare -a TEKTON_FILES=()
  die() { echo "$*" >&2; exit 1; }
  commit_changes() { git commit -qm "$1"; }
  add_konflux_dockerfile > "$TEST_ROOT/setup.log"
  component_version_matches "$(git show HEAD:package/Dockerfile.subctl.konflux)" 0.26.0 true
  grep -qF 'ARG BASE_BRANCH=release-0.26' package/Dockerfile.subctl.konflux
  echo '  ✓ actual Y-stream Dockerfile setup'
)
setup_case

completion_case() (
  export _AUTORELEASE_TESTING=true
  source "${LABEL_SCRIPT%/*}/autorelease.sh"
  _verify_prs_merged() { echo 'All PRs merged'; return 0; }
  local mode content rc
  gh() {
    [ "$mode" != unreadable ] || return 1
    content=$'LABEL version="v0.25.1"\nRUN go build -ldflags "-X main.version=v0.25.1"'
    [ "$mode" != stale ] || content=$'LABEL version="v0.25.1"\nRUN go build -ldflags "-X main.version=${BASE_BRANCH}"'
    printf '%s\n' "$content"
  }
  for mode in correct stale unreadable; do
    rc=0; verify_versionLabels 0.25.1 TEST-1 > "$TEST_ROOT/complete-$mode" 2>/dev/null || rc=$?
    case "$mode" in correct) expected=0 ;; stale) expected=1 ;; unreadable) expected=2 ;; esac
    assert_eq "merged PR completion checks source versions: $mode" "$rc" "$expected"
  done
  local pending_evidence=$'PRs proposed:\nhttps://github.com/submariner-io/subctl/pull/123'
  _verify_prs_merged() { printf '%s\n' "$pending_evidence"; return 3; }
  local actual_evidence
  rc=0; actual_evidence=$(verify_versionLabels 0.25.1 TEST-1) || rc=$?
  assert_eq 'open version PRs still wait for review' "$rc" 3
  assert_eq 'pending version PR evidence reaches the conductor' "$actual_evidence" "$pending_evidence"

  # The actual verifier must retain evidence used by the conductor's Jira path.
  GIT_ROOT="$TEST_ROOT/pending-evidence"
  git init -q "$GIT_ROOT"
  VERSION=0.25.1 TRACKER=TEST-1
  declare -A verified_steps=()
  _add_comment() { printf '%s' "$2" > "$TEST_ROOT/pending-comment"; }
  update_subtask_description() { printf '%s' "$3" > "$TEST_ROOT/pending-description"; }
  update_step() { echo 'FAIL: pending PRs must not complete' >&2; exit 1; }
  rc=0; try_auto_verify versionLabels || rc=$?
  assert_eq 'pending version verification stops the conductor' "$rc" 3
  assert_eq 'pending PRs reach the Jira comment' "$(cat "$TEST_ROOT/pending-comment")" "$pending_evidence"
  grep -qF 'https://github.com/submariner-io/subctl/pull/123' "$TEST_ROOT/pending-description"

  # shellcheck disable=SC1090  # Load the status checks without live cluster queries.
  source <(awk '/^check_component_version\(\)/,/^}/; /^check_step_5b\(\)/,/^}/' "${LABEL_SCRIPT%/*}/release-status.sh")
  VERSION=0.25.1 MAJOR_MINOR=0.25
  gh() {
    [ "$mode" != unreadable ] || return 1
    content=$'LABEL version="v0.25.1"\nRUN go build -ldflags "-X main.version=v0.25.1"'
    [ "$mode" != stale ] || content=$'LABEL version="v0.25.1"\nRUN go build -ldflags "-X main.version=${BASE_BRANCH}"'
    printf '%s' "$content" | base64
  }
  for mode in correct stale unreadable; do
    check_step_5b > "$TEST_ROOT/status-$mode" 2>/dev/null
    case "$mode" in
      correct) assert_eq 'status accepts matching component versions' "$WRONG_COUNT:$FETCH_FAILED" 0:0 ;;
      stale) assert_eq 'status rejects all seven stale Go binaries' "$WRONG_COUNT:$FETCH_FAILED" 7:0 ;;
      unreadable) assert_eq 'status reports unavailable source without a false pass' "$WRONG_COUNT:$FETCH_FAILED" 0:8 ;;
    esac
  done
)
completion_case
echo "All $((${#cases[@]} + ${#main_cases[@]} + 3)) tests passed"
