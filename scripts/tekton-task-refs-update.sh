#!/bin/bash
# Bump Tekton task references across Submariner Konflux repos
#
# Usage: tekton-task-refs-update.sh <version> [repo]
#
# Arguments:
#   version: Target release version (e.g., 0.23.1)
#   repo:    Optional repo filter (submariner-operator, submariner, lighthouse,
#            shipyard, subctl, fbc)
#
# Repairs denied catalog moves in each of the 5 component repos (on
# release-<X.Y>) plus the FBC repo (on main), committing the repaired .tekton/
# pipeline files on a per-repo fix branch. It never pushes — push/PR is left to
# the human (commands are printed and appended to $AUTORELEASE_PUSH_LOG). The
# downstream ecFixes verifier confirms Enterprise Contract passes once the PRs
# merge and Konflux rebuilds.
#
# A denial whose message names a replacement catalog is rewritten and ONLY that
# moved ref is re-pinned. Unrelated refs are preserved. Other active denials need
# manual review. This source precheck does not prove signed-image EC compliance:
# managed policy can inspect bundle manifest versions rather than source tags.
#
# Exit codes:
#   0: Source checks/repairs completed (signed-image EC remains a separate gate)
#   1: Failure (prerequisites, one or more repos failed, or an EC deny rule needs
#      a manual fix)
#   2: EC repair requested, but no supported catalog move was found

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_DIR="$SCRIPT_DIR/lib"

# Source jira-tracker.sh early to provide FBC_REPO_DEFAULT before we assign
# FBC_REPO_PATH below. The include guard makes the later tracker-integration
# source inside main() a no-op.
# shellcheck source=lib/jira-tracker.sh
source "$_LIB_DIR/jira-tracker.sh" 2>/dev/null || true
# shellcheck source=lib/git-utils.sh
source "$_LIB_DIR/git-utils.sh" 2>/dev/null || true
# shellcheck source=lib/deny-rules.sh
source "$_LIB_DIR/deny-rules.sh"

# ━━━ CONSTANTS ━━━

readonly SUBMARINER_BASE="${SUBMARINER_BASE:-$HOME/go/src/submariner-io}"
# FBC lives outside the upstream Go tree (see fbc-catalog-update.sh).
# FBC_REPO_DEFAULT is the canonical path defined once in lib/jira-tracker.sh.
readonly FBC_REPO_PATH="${FBC_REPO:-$FBC_REPO_DEFAULT}"

# Ordered repo list. Component repos live under $SUBMARINER_BASE and bump on
# release-<mm>; the FBC repo lives elsewhere and bumps on main (see repo_path /
# repo_base_branch). Associative arrays don't preserve order, hence a string.
readonly REPO_ORDER="submariner-operator submariner lighthouse shipyard subctl fbc"

# ━━━ GLOBAL VARIABLES ━━━

VERSION=""
MAJOR_MINOR=""
REPO_FILTER=""
PATCHER_SCRIPT=""   # verified pipeline-patcher, downloaded once by main

declare -a REPOS_UPDATED=()
declare -a REPOS_SKIPPED=()
declare -a REPOS_FAILED=()
declare -a REPOS_DENIED=()      # repo:N-active-denials — needs a manual fix
DENY_RULES_CHECKED=0            # 1 once policy-data was loaded (else: unchecked)

# ━━━ HELPERS ━━━

die() {
  echo "❌ ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

# Filesystem path for a repo key.
repo_path() {
  case "$1" in
    fbc) echo "$FBC_REPO_PATH" ;;
    *)   echo "$SUBMARINER_BASE/$1" ;;
  esac
}


# Branch a repo's fix branch is cut from and its PR targets.
repo_base_branch() {
  case "$1" in
    fbc) echo "main" ;;
    *)   echo "release-$MAJOR_MINOR" ;;
  esac
}

# Return a repo to the ref it was on before we touched it. Passing a second
# argument also deletes that (commit-less) fix branch. Leaving a repo on the fix
# branch is the branch-inheritance hazard that misroutes a later bundleShas
# commit (see plan "Known bugs"), so every exit path restores the original ref.
#
# The checkout is forced: a patcher that fails mid-edit leaves .tekton/ dirty, and
# a plain `git checkout` would refuse ("local changes would be overwritten") and be
# swallowed by `|| true`, stranding us on the fix branch — the very misroute above.
# Any pre-existing dirty state is auto-stashed before we start, so the only
# uncommitted changes reachable here are our own partial patcher edits.
_restore_repo() {
  restore_stashed_worktree "$PWD" "$@"
}

# Parse every pipeline first: malformed YAML or missing bundle refs must not be
# mistaken for a clean no-op. Preserve the full digest when identifying moves.
task_bundle_refs() {
  local dir="${1:-.}" data
  local -a files=()
  local f
  for f in "$dir"/.tekton/*.yaml "$dir"/.tekton/*.yml; do
    [ ! -f "$f" ] || files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  data=$(yq -o=json -I=0 '[... | select(has("resolver") and .resolver == "bundles")]' \
    "${files[@]}") || return 1
  printf '%s\n' "$data" | jq -ers 'add |
    map([.params[]? | select(.name == "bundle") | .value]) |
    if length > 0 and all(.[]; length == 1) then map(.[0]) | unique
    else error("Missing or duplicate bundle parameters") end |
    if all(.[]; type == "string" and
      test("^quay[.]io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}$"))
    then .[] else error("Missing or unsupported pinned bundle refs") end'
}

repair_moved_task_refs() {
  local before after moved ref replacement escaped
  before=$(task_bundle_refs .) || return 1
  deny_rules_scan . >/dev/null || return 1
  moved=$(deny_rules_rewrite_moved .) || return 1
  [ -z "$moved" ] || printf '%s\n' "$moved"
  after=$(task_bundle_refs .) || return 1
  # A move may collapse into an existing full ref. Set comparison would then
  # skip its re-pin; changing the existing pin needs manual review instead.
  if [ "$(printf '%s\n' "$before" | wc -l)" != "$(printf '%s\n' "$after" | wc -l)" ]; then
    echo "Catalog repair collides with an existing task ref; review manually" >&2
    return 1
  fi
  while IFS= read -r ref; do
    # The catalog rewrite is the only reason to select a ref. Never refresh an
    # unrelated digest merely because the patcher offers a newer one.
    if printf '%s\n' "$before" | grep -qxF -- "$ref"; then continue; fi
    replacement=$(printf '%s' "$PATCHER_SCRIPT" | bash -s task-ref "$ref") || {
      printf '%s\n' "$replacement" >&2
      return 1
    }
    if ! [[ "$replacement" =~ ^quay\.io/konflux-ci/tekton-catalog/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}$ ]] ||
       [ "${replacement%@*}" != "${ref%@*}" ]; then
      echo "Invalid replacement task ref: $replacement" >&2
      return 1
    fi
    escaped="${ref//./\\.}"
    local f
    for f in .tekton/*.yaml .tekton/*.yml; do
      [ ! -f "$f" ] || sed -i "s|$escaped|$replacement|g" "$f" || return 1
    done
  done <<< "$after"
}

# ━━━ PREREQUISITES ━━━

check_prerequisites() {
  local MISSING_TOOLS=()

  # git for repo ops; curl to fetch the patcher; oras + yq are required by
  # pipeline-patcher itself (it never checks, so we do).
  command -v git &>/dev/null || MISSING_TOOLS+=("git")
  command -v curl &>/dev/null || MISSING_TOOLS+=("curl")
  command -v oras &>/dev/null || MISSING_TOOLS+=("oras")
  command -v yq &>/dev/null || MISSING_TOOLS+=("yq")
  command -v jq &>/dev/null || MISSING_TOOLS+=("jq")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    die "Missing required tools: ${MISSING_TOOLS[*]}"
  fi

  echo "✓ Prerequisites verified: git, curl, oras, yq, jq"
}

# ━━━ ARGUMENT PARSING ━━━

parse_arguments() {
  local VERSION_ARG="${1:-}"
  local REPO_ARG="${2:-}"

  if [ -z "$VERSION_ARG" ]; then
    echo "Usage: $0 <version> [repo]"
    echo "Example: $0 0.23.1"
    echo "Example: $0 0.23.1 fbc"
    exit 1
  fi

  [ $# -gt 2 ] && die "Too many arguments"

  # Validate version format (X.Y.Z; the conductor passes X.Y.0 for Y-stream)
  if ! [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid version format: $VERSION_ARG" \
        "Expected: X.Y.Z (e.g., 0.23.1)"
  fi

  VERSION="$VERSION_ARG"
  MAJOR_MINOR="${VERSION%.*}"

  # Parse optional repo filter (validated against REPO_ORDER)
  if [ -n "$REPO_ARG" ]; then
    if [[ " $REPO_ORDER " != *" $REPO_ARG "* ]]; then
      die "Unknown repo: $REPO_ARG" \
          "Valid repos: ${REPO_ORDER}"
    fi
    REPO_FILTER="$REPO_ARG"
  fi

  echo ""
  echo "============================================"
  echo "Update Tekton Task References"
  echo "============================================"
  echo "Version: $VERSION"
  if [ -n "$REPO_FILTER" ]; then
    echo "Repo:    $REPO_FILTER"
  else
    echo "Repos:   all (6: 5 components + FBC)"
  fi
  echo ""
}

# ━━━ UPDATE LOGIC ━━━

update_repo() {
  local REPO="$1"
  local REPO_PATH BASE_BRANCH FIX_BRANCH
  REPO_PATH="$(repo_path "$REPO")"
  BASE_BRANCH="$(repo_base_branch "$REPO")"
  FIX_BRANCH="fix-tekton-tasks-${VERSION}"

  echo "━━━ $REPO ━━━"

  # Check repo exists
  if [ ! -d "$REPO_PATH" ]; then
    echo "  ✗ Repo not found: $REPO_PATH"
    REPOS_FAILED+=("$REPO:repo-not-found")
    echo ""
    return
  fi

  cd "$REPO_PATH" || {
    REPOS_FAILED+=("$REPO:cd-failed")
    echo ""
    return
  }

  # Remember where the repo was so we can leave it exactly as found. On a branch
  # this is the branch name (so we return *to the branch*, not a detached commit).
  # On a detached HEAD `--abbrev-ref` prints the literal "HEAD" (exit 0), so fall
  # back to the raw SHA — otherwise `git checkout HEAD` at restore time would
  # strand the repo on the fix branch's tip, the very branch-misroute we prevent.
  local ORIGINAL_REF
  ORIGINAL_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$ORIGINAL_REF" ] || [ "$ORIGINAL_REF" = "HEAD" ]; then
    # `|| true` so a degenerate/unborn HEAD marks just this repo failed downstream
    # rather than aborting the whole run mid-loop under set -e.
    ORIGINAL_REF="$(git rev-parse HEAD 2>/dev/null || true)"
  fi

  git fetch origin || {
    REPOS_FAILED+=("$REPO:fetch-failed")
    return
  }

  # Resolve base branch (prefer origin/, fall back to local)
  local BRANCH_REF="origin/$BASE_BRANCH"
  if ! git show-ref --verify --quiet "refs/remotes/$BRANCH_REF"; then
    BRANCH_REF="$BASE_BRANCH"
    if ! git show-ref --verify --quiet "refs/heads/$BRANCH_REF"; then
      echo "  ✗ Branch $BASE_BRANCH not found (run: git fetch origin $BASE_BRANCH)"
      # A missing base branch means this repo could NOT be processed — a failure
      # (needs a git fetch), not a benign skip, so the step is not marked done.
      REPOS_FAILED+=("$REPO:branch-not-found")
      echo ""
      return
    fi
  fi

  # A retry must not reset unpublished repairs or review corrections. Rebase
  # merges change commit IDs, so accept patches already applied upstream too.
  # git cherry omits merges; unique merge commits still need manual review.
  if git show-ref --verify --quiet "refs/heads/$FIX_BRANCH" &&
     ! git merge-base --is-ancestor "$FIX_BRANCH" "$BRANCH_REF"; then
    local pending_patches pending_merges
    if ! pending_patches=$(git cherry "$BRANCH_REF" "$FIX_BRANCH") ||
       ! pending_merges=$(git rev-list --merges "$BRANCH_REF..$FIX_BRANCH") ||
       [[ "$pending_patches" == +\ * || "$pending_patches" == *$'\n'+\ * ]] ||
       [ -n "$pending_merges" ]; then
      echo "  ✗ Existing $FIX_BRANCH contains work not confirmed upstream."
      echo "    Inspect this branch and resolve pending work before retrying; it was preserved."
      printf '    git -C %q show %q\n' "$REPO_PATH" "$FIX_BRANCH"
      REPOS_FAILED+=("$REPO:existing-fix-branch")
      return
    fi
  fi

  # Resolve prerequisites before stashing; every later exit must restore it.
  local STASH_REF
  if ! STASH_REF=$(stash_worktree "$PWD" "tekton-task-refs auto-stash"); then
    REPOS_FAILED+=("$REPO:stash-failed")
    return
  fi

  # Create fix branch from base branch (still on ORIGINAL_REF if this fails)
  if ! git checkout -B "$FIX_BRANCH" "$BRANCH_REF" >/dev/null 2>&1; then
    echo "  ✗ Failed to create branch $FIX_BRANCH"
    REPOS_FAILED+=("$REPO:branch-create-failed")
    _restore_repo "$ORIGINAL_REF" "" "$STASH_REF" || true
    echo ""
    return
  fi

  if [ ! -d .tekton ]; then
    echo "  ✗ No .tekton/ directory on $BASE_BRANCH"
    REPOS_FAILED+=("$REPO:no-tekton")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
    echo ""
    return
  fi

  # Missing policy data must stop before any edits or source-check completion.
  if [ "$DENY_RULES_CHECKED" -ne 1 ]; then
    REPOS_FAILED+=("$REPO:deny-rules-unchecked")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
    return
  fi

  local moved_out="" moved_summary=""
  if moved_out=$(repair_moved_task_refs 2>&1); then
    [ -n "$moved_out" ] && printf '%s\n' "$moved_out"
    # Two short lines per move: gitlint (enforced by the component repos' CI)
    # rejects body lines over 80 characters.
    moved_summary=$(printf '%s\n' "$moved_out" \
      | sed -E '/^$/d; s#quay\.io/konflux-ci/##g; s/^ *↻ ([^ ]+) -> ([^ ]+) \(.*$/- \1\n  -> \2/')
  else
    echo "  ✗ Task repair failed:"
    printf '%s\n' "$moved_out" | sed 's/^/      /'
    if printf '%s' "$moved_out" | grep -q "Can't find"; then
      echo "    Hint: a task ref is missing from the trusted list — often a denied or"
      echo "    moved catalog. Check EC deny rules (scripts/lib/deny-rules.sh)."
    fi
    REPOS_FAILED+=("$REPO:patcher-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
    echo ""
    return
  fi

  # EC deny-rule check on the patched tree: the patcher only knows the trusted
  # list. ACTIVE denials that survive need a manual fix; FUTURE ones only warn.
  local deny_scan="" deny_active=0
  if [ "$DENY_RULES_CHECKED" -eq 1 ]; then
    if ! deny_scan=$(deny_rules_scan "."); then
      REPOS_FAILED+=("$REPO:deny-scan-failed")
      _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
      return
    fi
    deny_active=$(deny_rules_count_active "$deny_scan")
    [ -n "$deny_scan" ] && deny_rules_report "$deny_scan" "  "
  fi

  # Stage only .tekton changes. Skip the commit if the patcher was a no-op (refs
  # already latest, or a re-run) — an unconditional commit would fail.
  if ! git add .tekton/; then
    REPOS_FAILED+=("$REPO:stage-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
    return
  fi
  if git diff --cached --quiet; then
    if [ "$deny_active" -gt 0 ]; then
      echo "  ✗ No automatic fix for the EC deny rule(s) above — manual change needed"
      REPOS_DENIED+=("$REPO:$deny_active")
    elif _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF"; then
      echo "  - No catalog repair needed; signed-image EC remains required"
      REPOS_SKIPPED+=("$REPO:no-changes")
    else
      REPOS_FAILED+=("$REPO:restore-failed")
    fi
    [ "$deny_active" -gt 0 ] && { _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || REPOS_FAILED+=("$REPO:restore-failed"); }
    echo ""
    return
  fi

  # Commit
  local commit_msg="Repair denied Tekton task catalog references

Replaces denied catalog references while preserving unrelated task pins.
The rebuilt images still require Enterprise Contract validation."
  if [ -n "$moved_summary" ]; then
    commit_msg="${commit_msg}

Replaces task refs that EC denies because their catalog moved (the deny
rule's message names the replacement); the patcher re-pinned the digest:
${moved_summary}"
  fi
  if git commit -s -m "$commit_msg" >/dev/null 2>&1; then
    echo "  ✓ Committed"
    REPOS_UPDATED+=("$REPO#$FIX_BRANCH#$BASE_BRANCH")
    if [ "$deny_active" -gt 0 ]; then
      echo "  ⚠ Committed refresh does NOT clear the EC deny rule(s) above"
      REPOS_DENIED+=("$REPO:$deny_active")
    fi
    # Keep the fix branch (it holds the commit); restore the original ref.
    _restore_repo "$ORIGINAL_REF" "" "$STASH_REF" || REPOS_FAILED+=("$REPO:restore-failed")
  else
    echo "  ✗ Commit failed"
    REPOS_FAILED+=("$REPO:commit-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
  fi

  echo ""
}

update_all() {
  local ORIGINAL_DIR
  ORIGINAL_DIR=$(pwd)

  for REPO in $REPO_ORDER; do
    if [ -n "$REPO_FILTER" ] && [ "$REPO" != "$REPO_FILTER" ]; then
      continue
    fi
    update_repo "$REPO"
  done

  cd "$ORIGINAL_DIR"
}

# ━━━ SUMMARY ━━━

print_section() {
  local title="$1"
  local symbol="$2"
  local -n entries="$3"
  local show_reason="${4:-false}"

  [ "${#entries[@]}" -eq 0 ] && return

  echo ""
  echo "$title (${#entries[@]}):"
  for entry in "${entries[@]}"; do
    if [ "$show_reason" = "true" ]; then
      echo "  $symbol ${entry%%:*} (${entry##*:})"
    else
      echo "  $symbol ${entry%%#*}"
    fi
  done
}

print_summary() {
  echo ""
  echo "Summary"

  print_section "Updated" "✓" REPOS_UPDATED
  print_section "Skipped" "-" REPOS_SKIPPED true
  print_section "Failed" "✗" REPOS_FAILED true

  local UPDATED_COUNT=${#REPOS_UPDATED[@]}
  local FAILED_COUNT=$(( ${#REPOS_FAILED[@]} + ${#REPOS_DENIED[@]} ))

  if [ "${#REPOS_DENIED[@]}" -gt 0 ]; then
    echo ""
    echo "EC deny rules need a manual fix (${#REPOS_DENIED[@]}):"
    local d
    for d in "${REPOS_DENIED[@]}"; do
      echo "  ✗ ${d%%:*} (${d##*:} active denial(s))"
    done
    echo "  Details are printed per repo above. Edit the .tekton/ refs, then re-run."
  fi
  if [ "$DENY_RULES_CHECKED" -eq 0 ]; then
    echo ""
    echo "✗ EC deny rules were NOT checked (policy-data unavailable)."
  fi

  if [ "$UPDATED_COUNT" -gt 0 ]; then
    echo ""
    echo "Next Steps"
    # Get GitHub username once for fork remote detection across all repos.
    local gh_user
    gh_user=$(get_gh_user)
    for entry in "${REPOS_UPDATED[@]}"; do
      local repo="${entry%%#*}"
      local rest="${entry#*#}"
      local fix_branch="${rest%%#*}"
      local base_branch="${rest#*#}"
      local path fork
      path="$(repo_path "$repo")"
      fork="$(fork_remote "$path" "$gh_user")"
      echo ""
      echo "# $repo"
      printf 'git -C %q show %q\n' "$path" "$fix_branch"
      # FBC has no ready-to-test label; all variable command arguments are quoted.
      local label_flag=" --label ready-to-test"
      [ "$repo" = fbc ] && label_flag=""
      local head_ref="$fix_branch" pr_filter push_commands
      [ -n "$gh_user" ] && head_ref="${gh_user}:${fix_branch}"
      pr_filter="[.[] | select(.headRepositoryOwner.login == \"$gh_user\")] | .[0].url // empty"
      printf -v push_commands '\n  cd %q\n  git push --force-with-lease %q %q\n  PR_URL=$(gh pr list --base %q --head %q --state open --json url,headRepositoryOwner --jq %q)\n  if [ -z "$PR_URL" ]; then\n    PR_URL=$(gh pr create --base %q --head %q --title %q --body %q --assignee @me%s)\n  fi\n  gh pr merge --auto --rebase "${PR_URL##*/}"\n' \
        "$path" "$fork" "$fix_branch" "$base_branch" "$fix_branch" "$pr_filter" \
        "$base_branch" "$head_ref" "Repair denied Tekton task catalogs" \
        "Replace denied task catalogs and preserve unrelated pins. Rebuilt images require Enterprise Contract verification." "$label_flag"
      printf '%s' "$push_commands"
      if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
        printf '%s' "$push_commands" >> "$AUTORELEASE_PUSH_LOG"
      fi
    done
  fi

  echo ""
  [ "$FAILED_COUNT" -eq 0 ] && [ "$DENY_RULES_CHECKED" -eq 1 ]
}

# ━━━ MAIN ━━━

main() {
  check_prerequisites
  parse_arguments "$@"

  # Download + verify the pipeline-patcher once (shared helper: pinned SHA +
  # checksum). Reused per-repo in update_repo.
  # shellcheck source=/dev/null
  source "$_LIB_DIR/pipeline-patcher.sh"
  PATCHER_SCRIPT=$(download_and_verify_patcher) || \
    die "Failed to download/verify pipeline-patcher" \
      "Check network connectivity and GitHub access"
  echo "✓ Pipeline-patcher checksum verified"

  if deny_rules_load; then
    DENY_RULES_CHECKED=1
    echo "✓ EC deny rules loaded"
  else
    die "EC deny rules NOT loaded; no task repairs attempted"
  fi

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$_LIB_DIR/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  # AUTORELEASE_TRACKER_STEP lets the conductor call this script for ecFixes
  # (same operation — bump task refs — just tracked under a different step key).
  local TRACKER_STEP="${AUTORELEASE_TRACKER_STEP:-tektonTasks}"
  # Only move tracker state on a full run. A filtered (single-repo) run is a manual
  # partial retry: guarding in_progress the same way as completion (below) keeps it
  # from flipping an already-complete step back to in_progress and never restoring it.
  [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] && update_step "$VERSION" "$TRACKER_STEP" "in_progress" '{}' "$TRACKER"

  update_all

  print_summary || return $?

  if [ "$TRACKER_STEP" = ecFixes ] && [ "${#REPOS_UPDATED[@]}" -eq 0 ]; then
    echo "No denied catalog move was repaired. Inspect the exact snapshot's EC report"
    echo "and address its reported failures; unrelated task pins were preserved."
    return 2
  fi

  # A full no-op checked every fresh base. Updates and incomplete work stay pending.
  local clean_count=0 entry
  local -a all_repos
  read -ra all_repos <<< "$REPO_ORDER"
  for entry in "${REPOS_SKIPPED[@]}"; do
    [ "${entry##*:}" != no-changes ] || clean_count=$((clean_count + 1))
  done
  if [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] &&
     [ "$TRACKER_STEP" = tektonTasks ] && [ "${#REPOS_UPDATED[@]}" -eq 0 ] && [ "${#REPOS_FAILED[@]}" -eq 0 ] &&
     [ "${#REPOS_DENIED[@]}" -eq 0 ] && [ "$clean_count" -eq "${#all_repos[@]}" ]; then
    # The merge verifier may have deferred to this fresh-base check because a
    # repo needed no PR. Clear its old "PRs open" description before completing.
    update_subtask_description "$VERSION" "$TRACKER_STEP" \
      "$(printf '## Status\n\nFresh upstream task-source checks passed for all six repositories. No catalog repair or new PR is needed.\n\nChecked repositories: %s.\n\nSee parent tracker comments for PR history. Signed-image Enterprise Contract validation remains a separate release gate.' "$REPO_ORDER")" \
      "$TRACKER" || return 1
    update_step "$VERSION" "$TRACKER_STEP" complete '{}' "$TRACKER"
  fi
}

# Guard so tests can source helpers without running a release.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
