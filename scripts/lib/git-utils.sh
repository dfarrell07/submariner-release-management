#!/bin/bash
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
