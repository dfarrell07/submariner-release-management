#!/usr/bin/env bash
# Shared git utilities for Submariner release scripts.

# Detect the fork remote name for a repo: find the remote whose URL contains
# "github.com/<gh_user>/". Returns the remote name (e.g. "dfarrell_op").
# Falls back to "origin" if gh is unavailable or no fork remote found.
#
# Args: $1=repo_path $2=gh_user (from `gh api user --jq .login`)
fork_remote() {
  local repo_path="$1" gh_user="$2"
  if [ -n "$gh_user" ]; then
    local remote
    remote=$(git -C "$repo_path" remote -v 2>/dev/null | \
      grep -i "github\.com[/:]${gh_user}/" | head -1 | awk '{print $1}') || remote=""
    [ -n "$remote" ] && echo "$remote" && return
  fi
  echo "origin"
}

# Get the authenticated GitHub username via gh CLI.
# Returns empty string if gh is unavailable or not authenticated.
# Callers should capture once: gh_user=$(get_gh_user)
get_gh_user() {
  gh api user --jq '.login' 2>/dev/null || true
}

# Run immediately after switching a previously clean/stashed worktree, before
# editing anything. Different ignore rules can expose local files left by stash.
check_checkout_clean() {
  local worktree_status
  if ! worktree_status=$(git status --porcelain --untracked-files=all); then
    echo "Cannot inspect the switched worktree in $PWD; no repairs were attempted." >&2
    return 1
  fi
  if [ -n "$worktree_status" ]; then
    echo "Local files became visible after switching branches in $PWD; no repairs were attempted." >&2
    printf '%s\n' "$worktree_status" >&2
    echo "Move these files outside the checkout before retrying." >&2
    return 1
  fi
}

# Refuse to carry unfinished work onto another branch. Run in the target repo.
restore_clean_ref() {
  local original_ref="$1" worktree_status
  if ! worktree_status=$(git status --porcelain --untracked-files=all); then
    echo "Cannot inspect worktree; not restoring $original_ref" >&2
    return 1
  fi
  if [ -n "$worktree_status" ]; then
    echo "Uncommitted changes remain in $(pwd); not restoring $original_ref." >&2
    echo "Review and commit or stash them before switching branches." >&2
    return 1
  fi
  git checkout --quiet "$original_ref" || {
    echo "Failed to restore $original_ref in $(pwd)." >&2
    return 1
  }
}

# Permit resetting a repair branch only when its content is already upstream.
# Patch IDs ignore meaningful whitespace; a merge must leave the upstream tree unchanged.
# Custom drivers can discard changes, so require review instead of trusting them.
# Run in the target repo. Args: repair branch, fresh upstream ref.
check_fix_branch_reusable() {
  local fix_branch="$1" base_ref="$2" merged_tree upstream_tree fix_tree driver_status=0
  git show-ref --verify --quiet "refs/heads/$fix_branch" || return 0
  git merge-base --is-ancestor "$fix_branch" "$base_ref" && return 0
  if upstream_tree=$(git rev-parse "$base_ref^{tree}") &&
     fix_tree=$(git rev-parse "$fix_branch^{tree}"); then
    [ "$fix_tree" = "$upstream_tree" ] && return 0
    git config --get-regexp '^merge\..*\.driver$' >/dev/null 2>&1 || driver_status=$?
    if [ "$driver_status" -eq 1 ] &&
       merged_tree=$(git -c merge.renormalize=false -c merge.default=text \
         merge-tree --write-tree "$base_ref" "$fix_branch" 2>/dev/null) &&
       [ "$merged_tree" = "$upstream_tree" ]; then
      return 0
    fi
  fi
  echo "Existing $fix_branch contains work not confirmed upstream; it was preserved." >&2
  echo "Inspect and resolve pending work before retrying." >&2
  printf '  git -C %q show %q\n' "$PWD" "$fix_branch" >&2
  return 1
}

# Save tracked/index and untracked work before an automated branch switch.
# Prints only the new stash SHA (or nothing for a clean repo). On failure the
# caller MUST stop before any checkout, particularly forced cleanup.
stash_worktree() {
  local repo_path="$1" label="$2" worktree_status stash_ref
  if ! worktree_status=$(git -C "$repo_path" status --porcelain --untracked-files=all); then
    echo "Cannot inspect $repo_path; not stashing or switching branches." >&2
    return 1
  fi
  [ -n "$worktree_status" ] || return 0
  if ! git -C "$repo_path" stash push --include-untracked -m "$label" >&2; then
    echo "Failed to stash $repo_path; not switching branches. Inspect git status and git stash list." >&2
    return 1
  fi
  if ! stash_ref=$(git -C "$repo_path" rev-parse --verify refs/stash); then
    echo "Cannot identify the saved stash in $repo_path; inspect git stash list before retrying." >&2
    return 1
  fi
  if ! worktree_status=$(git -C "$repo_path" status --porcelain --untracked-files=all); then
    echo "Cannot verify $repo_path after stashing; not switching branches. Saved stash: $stash_ref" >&2
    return 1
  fi
  if [ -n "$worktree_status" ]; then
    echo "Worktree still dirty in $repo_path; not switching branches. Saved stash: $stash_ref" >&2
    return 1
  fi
  printf '%s\n' "$stash_ref"
}

# Only call after stash_worktree succeeds. Discard the tool's tracked partial
# edits, restore the original ref, then restore exactly the saved index/worktree.
# Never pop onto the wrong branch or conceal a restore failure. Stashes remain
# available for manual recovery on failure; no branch is deleted in that case.
# Pass "safe" as the fifth argument when local or tool edits must be preserved.
restore_stashed_worktree() {
  local repo_path="$1" original_ref="$2" drop_branch="${3:-}" stash_ref="${4:-}"
  local stash_idx
  local -a checkout_options=(-f)
  # A normal checkout preserves newly exposed files and unfinished child edits.
  [ "${5:-}" != safe ] || checkout_options=(--quiet --no-overwrite-ignore)
  if ! git -C "$repo_path" checkout "${checkout_options[@]}" "$original_ref" >/dev/null; then
    echo "Failed to restore $original_ref in $repo_path; saved stash: ${stash_ref:-none}." >&2
    echo "Inspect git status and move conflicting local files outside the checkout before restoring the branch." >&2
    [ -z "$stash_ref" ] || echo "Then apply the saved stash with --index." >&2
    return 1
  fi
  if [ -n "$stash_ref" ]; then
    # Consume the complete list: exiting awk early can SIGPIPE git under
    # pipefail and turn a valid match into an intermittent cleanup failure.
    if ! stash_idx=$(git -C "$repo_path" stash list --format='%H %gd' |
      awk -v sha="$stash_ref" '$1==sha && !found {print $2; found=1}'); then
      echo "Cannot locate stash $stash_ref in $repo_path; inspect git stash list." >&2
      return 1
    fi
    # Older Git (2.43) exits 0 from `stash pop --index` when it refuses to apply
    # ("Index was not unstashed"), leaving the stash in place. A successful pop
    # drops the entry, so also require that the stash is gone.
    if [ -z "$stash_idx" ] || ! git -C "$repo_path" stash pop --index "$stash_idx" >/dev/null ||
      [ "$(git -C "$repo_path" stash list --format='%H' |
        awk -v sha="$stash_ref" '$1==sha {found=1} END {print found+0}')" != 0 ]; then
      echo "Failed to restore stash $stash_ref in $repo_path; inspect git status and git stash list." >&2
      echo "Resolve any conflicts before retrying git stash apply --index $stash_ref." >&2
      return 1
    fi
  fi
  if [ -n "$drop_branch" ] && [ "$drop_branch" != "$original_ref" ]; then
    git -C "$repo_path" branch -D "$drop_branch" >/dev/null || return 1
  fi
}
