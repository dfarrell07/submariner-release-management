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
  [[ "$scenario" == no-op* ]] && initial_version="$VERSION"
  read -ra files <<< "${REPO_DOCKERFILES[$repo]}"
  first="${files[0]}"
  second="${files[1]:-$first}"
  for file in "${files[@]}"; do
    printf 'FROM scratch\nLABEL version="v%s"\n' "$initial_version" > "$file"
  done
  if [ "$repo" = submariner-operator ]; then
    printf 'FROM scratch\nLABEL csv-version="0.25.0"\nLABEL release="v0.25.0"\nLABEL version="v0.25.0"\n' \
      > bundle.Dockerfile.konflux
  fi
  git add -A
  git commit -qm base
  git checkout -qb "$RELEASE_BRANCH"

  case "$scenario" in
    missing-first) git rm -q -- "$first" ;;
    missing-later*) git rm -q -- "$second" ;;
    malformed-first) printf 'LABEL version="vlatest"\n' > "$first" ;;
    malformed-later) printf 'LABEL version="vlatest"\n' > "$second" ;;
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
    if [[ "$scenario" == *checkout-failure ]] &&
       [ "${1:-}" = checkout ] && [ "${3:-}" = original ]; then
      echo 'Injected checkout failure' >&2
      return 1
    fi
    if [ "$scenario" = status-failure ] && [ "${1:-}" = status ]; then
      echo 'Injected status failure' >&2
      return 1
    fi
    command git "$@"
  }
  sed() {
    case "$scenario:${*: -1}" in
      "sed-first:$first"|"sed-later:$second"|bundle-sed:bundle.Dockerfile.konflux)
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

  case "$scenario" in
    success|detached)
      assert_eq 'restored branch' "$branch" "$expected_branch"
      assert_eq 'restored original commit' "$(command git rev-parse HEAD)" "$original_sha"
      assert_eq 'clean after success' "$dirty" ''
      assert_eq 'success recorded' "${#REPOS_UPDATED[@]}" 1
      assert_eq 'no failures' "${#REPOS_FAILED[@]}" 0
      command git show "fix-version-labels-0.25:$first" | grep -q 'version="v0.25.1"'
      ;;
    no-op)
      assert_eq 'no-op restored branch' "$branch" original
      assert_eq 'no-op clean' "$dirty" ''
      assert_eq 'no-op recorded' "${REPOS_SKIPPED[0]:-}" "$repo:no-changes"
      assert_eq 'no-op no failures' "${#REPOS_FAILED[@]}" 0
      if command git show-ref --verify --quiet refs/heads/fix-version-labels-0.25; then
        echo 'FAIL: no-op fix branch was not removed' >&2
        exit 1
      fi
      ;;
    missing-first|malformed-first|sed-first)
      assert_eq 'clean failure restored branch' "$branch" original
      assert_eq 'clean failure preserved commit' "$(command git rev-parse HEAD)" "$original_sha"
      assert_eq 'clean failure no edits' "$dirty" ''
      assert_eq 'failure recorded' "${#REPOS_FAILED[@]}" 1
      assert_eq 'no success' "${#REPOS_UPDATED[@]}" 0
      ;;
    missing-later*|malformed-later|sed-later|bundle-*|commit-failure)
      assert_eq 'partial work stays on fix branch' "$branch" fix-version-labels-0.25
      if [ -z "$dirty" ]; then echo 'FAIL: partial changes lost' >&2; exit 1; fi
      grep -q 'version="v0.25.1"' "$first"
      grep -q 'Review and commit or stash' "$log"
      assert_eq 'failure recorded once' "${#REPOS_FAILED[@]}" 1
      assert_eq 'no success' "${#REPOS_UPDATED[@]}" 0
      ;;
    *checkout-failure|status-failure|untracked-after-commit)
      assert_eq 'failed restore keeps fix branch' "$branch" fix-version-labels-0.25
      if [ "$scenario" = untracked-after-commit ]; then
        assert_eq 'untracked work preserved' "$dirty" '?? hook-artifact'
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

cases=(success detached no-op missing-first missing-later missing-later-same
       malformed-first malformed-later sed-first sed-later bundle-malformed
       bundle-sed commit-failure checkout-failure no-op-checkout-failure status-failure
       untracked-after-commit)
for scenario in "${cases[@]}"; do run_case "$scenario"; done
echo "All ${#cases[@]} tests passed"
