#!/bin/bash
# Bump Tekton task versions and SHAs across all Submariner component repos.
#
# For each repo: queries Quay for the latest available version of every task
# referenced in .tekton/*.yaml, bumps version strings where outdated, then runs
# pipeline-patcher to update SHA references. Commits per-repo and emits push
# commands for the user.
#
# When all repos are already current (no version or SHA changes): checks for a
# downloaded EC log in ~/Downloads/ matching the failing snapshot. If found,
# parses it with scripts/lib/parse-ec-log.sh and emits diagnostic output so the
# user knows what rule is failing and whether a task-version bump can fix it.
# Exits 2 to signal to the autorelease conductor "nothing to update — stop and
# wait for manual action".
#
# Usage:
#   tekton-task-version-bump.sh <version> [--repo <name>]
#
# Arguments:
#   version  — Submariner release version, e.g. 0.24.1
#   --repo   — Optional: limit to one repo (operator|submariner|lighthouse|
#              shipyard|subctl|fbc). Default: all 6 repos.
#
# Also checks the result against the EC trusted-task DENY rules
# (scripts/lib/deny-rules.sh) — pipeline-patcher only checks the trusted list, so
# a ref can be trusted yet denied. A denial whose message names a replacement
# catalog is rewritten before the patcher re-pins it; any other active denial is
# reported for a manual fix and makes the run fail, so the conductor never treats
# a still-denied repo as fixed. Future-dated denials only warn.
#
# Exit codes:
#   0 — one or more repos committed updates (user must push PRs)
#   1 — hard failure (prereq, repo, patcher, parse error) or an EC deny rule that
#       needs a manual fix (commits for other changes are still kept)
#   2 — no updates found; EC log diagnostic emitted (or no log present yet)
#
# Branch naming: fix-tekton-tasks-<major.minor>[-vN]
#   Uses -vN suffix (v2, v3, …) when the branch already exists locally or
#   remotely, preserving prior branches instead of force-recreating them.
#   verify_ecFixes PR-open guard searches by base branch name pattern and
#   catches all -vN variants naturally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/jira-tracker.sh
source "$_LIB_DIR/jira-tracker.sh" 2>/dev/null || true
# shellcheck source=lib/git-utils.sh
source "$_LIB_DIR/git-utils.sh" 2>/dev/null || true
# shellcheck source=lib/pipeline-patcher.sh
source "$_LIB_DIR/pipeline-patcher.sh"
# shellcheck source=lib/deny-rules.sh
source "$_LIB_DIR/deny-rules.sh"

# ── Prerequisites ──────────────────────────────────────────────────────────────

check_prerequisites() {
  local missing=()
  command -v git  &>/dev/null || missing+=("git")
  command -v curl &>/dev/null || missing+=("curl")
  command -v jq   &>/dev/null || missing+=("jq")
  command -v oras &>/dev/null || missing+=("oras")
  command -v yq   &>/dev/null || missing+=("yq")
  command -v flock &>/dev/null || missing+=("flock")
  [ "${#missing[@]}" -gt 0 ] && die "Missing required tools: ${missing[*]}"
  echo "✓ Prerequisites verified: git, curl, jq, oras, yq, flock"
}

# ── Globals ────────────────────────────────────────────────────────────────────
VERSION=""
MAJOR_MINOR=""
REPO_FILTER=""

declare -a REPOS_UPDATED=()
declare -a REPOS_SKIPPED=()
declare -a REPOS_FAILED=()
declare -a REPOS_DENIED=()      # repo:N-active-denials — needs a manual fix
declare -a DENY_REPORTS=()      # "repo\nreport" blocks for the summary
DENY_RULES_CHECKED=0            # 1 once policy-data was loaded (else: unchecked)

SUBMARINER_BASE="${SUBMARINER_BASE:-$HOME/go/src/submariner-io}"
readonly FBC_REPO_PATH="${FBC_REPO:-${FBC_REPO_DEFAULT:-$HOME/konflux/submariner-operator-fbc}}"

# Cache for acceptable-bundles data (fetched once, reused per-task)
_ACCEPTABLE_BUNDLES_DATA=""

# ── Helpers ────────────────────────────────────────────────────────────────────

die() { echo "❌ ERROR: $1" >&2; [ -n "${2:-}" ] && echo "   $2" >&2; exit 1; }

repo_path() {
  case "$1" in
    fbc) echo "$FBC_REPO_PATH" ;;
    *)   echo "$SUBMARINER_BASE/$1" ;;
  esac
}

repo_base_branch() {
  case "$1" in
    fbc) echo "main" ;;
    *)   echo "release-$MAJOR_MINOR" ;;
  esac
}

# Fetch and cache the data-acceptable-bundles content from the same source
# pipeline-patcher uses (tekton-catalog only: the konflux-vanguard catalog is
# denied by EC, so its refs must not be offered as "latest"). Called once;
# subsequent calls return from cache.
_load_acceptable_bundles() {
  [ -n "$_ACCEPTABLE_BUNDLES_DATA" ] && return 0

  local catalog="quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles"
  local blob_digest data
  blob_digest=$(oras manifest fetch "${catalog}:latest" 2>/dev/null \
    | jq -r '.layers[0].digest' 2>/dev/null) || blob_digest=""
  if [ -n "$blob_digest" ] && [ "$blob_digest" != "null" ]; then
    data=$(oras blob fetch "${catalog}@${blob_digest}" --output - 2>/dev/null) || data=""
  fi

  if [ -z "${data:-}" ]; then
    echo "  ⚠ Could not fetch data-acceptable-bundles (check oras/network)" >&2
    return 1
  fi

  _ACCEPTABLE_BUNDLES_DATA="$data"
}

# Return the latest acceptable version for a task by querying the
# data-acceptable-bundles OCI artifact — the same authoritative source
# pipeline-patcher uses. Handles X.Y and X.Y.Z version strings correctly,
# unlike the Quay v2 tags API which only has clean X.Y tags for some tasks.
# Returns empty string on failure.
latest_task_version() {
  local task="$1"

  _load_acceptable_bundles 2>/dev/null || return 0

  printf '%s\n' "$_ACCEPTABLE_BUNDLES_DATA" \
    | grep "task-${task}:" \
    | grep -oP "(?<=task-${task}:)[0-9]+\.[0-9]+(\.[0-9]+)?" \
    | grep -E "^[0-9]+\.[0-9]+(\.[0-9]+)?$" \
    | sort -Vu \
    | tail -1 \
    || true
}

# Find an available branch name: fix-tekton-tasks-<mm> if free, else -v2, -v3…
# Checks both local and remote refs.
find_available_branch() {
  local base_branch="$1" repo_path="$2"
  local candidate="$base_branch"
  local n=1
  while true; do
    local local_ref="refs/heads/$candidate"
    local remote_ref="refs/remotes/origin/$candidate"
    if git -C "$repo_path" show-ref --verify --quiet "$local_ref" 2>/dev/null || \
       git -C "$repo_path" show-ref --verify --quiet "$remote_ref" 2>/dev/null; then
      n=$((n + 1))
      candidate="${base_branch}-v${n}"
    else
      echo "$candidate"
      return
    fi
  done
}

# Restore repo to original ref; optionally delete a branch, and pop a stash.
# Uses -f to discard any uncommitted changes left by a partial patcher run;
# without -f, git checkout refuses when .tekton/ is dirty and the || true
# swallows the error, leaving the repo stranded on the fix branch.
# stash_ref is the SHA of the stash entry to pop (found via stash@{N} lookup).
_restore_repo() {
  restore_stashed_worktree "$PWD" "$@"
}

# ── Argument parsing ───────────────────────────────────────────────────────────

parse_arguments() {
  local version_arg="" repo_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo_arg="${2:-}"; shift 2 ;;
      -*)     die "Unknown flag: $1" "Usage: $0 <version> [--repo <name>]" ;;
      *)      version_arg="$1"; shift ;;
    esac
  done

  [ -z "$version_arg" ] && die "Version required" "Usage: $0 <version> [--repo <name>]"

  if ! [[ "$version_arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid version: $version_arg" "Expected X.Y.Z (e.g. 0.24.1)"
  fi

  VERSION="$version_arg"
  MAJOR_MINOR="${VERSION%.*}"

  local valid_repos="operator submariner lighthouse shipyard subctl fbc"
  if [ -n "$repo_arg" ]; then
    # Normalise: "operator" → "submariner-operator" for path lookup
    case "$repo_arg" in
      operator) repo_arg="submariner-operator" ;;
    esac
    local found=0
    for r in $valid_repos submariner-operator; do
      [ "$repo_arg" = "$r" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && die "Unknown repo: $repo_arg" "Valid: $valid_repos"
    REPO_FILTER="$repo_arg"
  fi
}

# ── Per-repo processing ────────────────────────────────────────────────────────

update_repo() {
  local REPO="$1"
  local REPO_PATH BASE_BRANCH FIX_BRANCH_BASE
  REPO_PATH=$(repo_path "$REPO")
  BASE_BRANCH=$(repo_base_branch "$REPO")
  FIX_BRANCH_BASE="fix-tekton-tasks-${MAJOR_MINOR}"

  echo "━━━ $REPO ━━━"

  if [ ! -d "$REPO_PATH" ]; then
    echo "  ✗ Repo not found: $REPO_PATH" >&2
    REPOS_FAILED+=("$REPO:repo-not-found")
    echo ""; return
  fi

  cd "$REPO_PATH" || { REPOS_FAILED+=("$REPO:cd-failed"); echo ""; return; }

  # This script switches branches and edits the repository worktree. Serialize
  # concurrent invocations for this repository so a second run cannot commit an
  # intermediate state between the version bump and pipeline-patcher steps.
  # The descriptor stays open until process exit; flock releases it even if the
  # process is terminated, so no stale lock cleanup is needed.
  local GIT_COMMON_DIR LOCK_FILE LOCK_FD
  if ! GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    echo "  ✗ Could not locate the Git common directory" >&2
    REPOS_FAILED+=("$REPO:git-dir-failed")
    echo ""; return
  fi
  LOCK_FILE="$GIT_COMMON_DIR/tekton-task-version-bump.lock"
  if ! exec {LOCK_FD}>"$LOCK_FILE"; then
    echo "  ✗ Could not open task-version-bump lock" >&2
    REPOS_FAILED+=("$REPO:lock-open-failed")
    echo ""; return
  fi
  if ! flock -n "$LOCK_FD"; then
    echo "  ✗ Another task-version bump is already updating this repository" >&2
    REPOS_FAILED+=("$REPO:busy")
    echo ""; return
  fi

  local ORIGINAL_REF
  ORIGINAL_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$ORIGINAL_REF" ] || [ "$ORIGINAL_REF" = "HEAD" ]; then
    ORIGINAL_REF="$(git rev-parse HEAD 2>/dev/null || true)"
  fi

  # Resolve base branch ref (prefer origin/)
  local BRANCH_REF="origin/$BASE_BRANCH"
  if ! git show-ref --verify --quiet "refs/remotes/$BRANCH_REF" 2>/dev/null; then
    BRANCH_REF="$BASE_BRANCH"
    if ! git show-ref --verify --quiet "refs/heads/$BRANCH_REF" 2>/dev/null; then
      echo "  ✗ Branch $BASE_BRANCH not found (run: git fetch origin $BASE_BRANCH)" >&2
      REPOS_FAILED+=("$REPO:branch-not-found")
      echo ""; return
    fi
  fi

  # Find a free branch name (-vN if base already exists)
  local FIX_BRANCH
  FIX_BRANCH=$(find_available_branch "$FIX_BRANCH_BASE" "$REPO_PATH")

  local STASH_REF
  if ! STASH_REF=$(stash_worktree "$PWD" "tekton-task-bump auto-stash"); then
    REPOS_FAILED+=("$REPO:stash-failed")
    return
  fi

  if ! git checkout -b "$FIX_BRANCH" "$BRANCH_REF" >/dev/null 2>&1; then
    echo "  ✗ Failed to create branch $FIX_BRANCH" >&2
    REPOS_FAILED+=("$REPO:branch-create-failed")
    _restore_repo "$ORIGINAL_REF" "" "$STASH_REF" || true
    echo ""; return
  fi

  # Check .tekton/ AFTER switching to the fix branch (which is cut from
  # $BRANCH_REF), so we test the state of the actual target branch, not whatever
  # branch the repo happened to be on when the script started.
  if [ ! -d .tekton ]; then
    echo "  ✗ No .tekton/ directory on $BASE_BRANCH" >&2
    REPOS_FAILED+=("$REPO:no-tekton")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
    echo ""; return
  fi

  # ── Step 0: Follow denial messages that name a replacement catalog ──────────
  # Runs first so the version bump and the patcher below see the replacement
  # catalog's refs (the patcher cannot re-pin a ref from a catalog it no longer
  # knows, and aborts the whole run on it).
  local moved_out="" moved_summary=""
  if [ "$DENY_RULES_CHECKED" -eq 1 ]; then
    moved_out=$(deny_rules_rewrite_moved ".")
    [ -n "$moved_out" ] && printf '%s\n' "$moved_out"
    # Commit-message form of the same lines. Two short lines per move, without
    # the common quay.io/konflux-ci/ prefix: gitlint (which the component repos
    # enforce in CI) rejects body lines over 80 characters, and a single
    # "old -> new" line easily reaches 128.
    moved_summary=$(printf '%s\n' "$moved_out" \
      | sed -E '/^$/d; s#quay\.io/konflux-ci/##g; s/^ *↻ ([^ ]+) -> ([^ ]+) \(.*$/- \1\n  -> \2/')
  fi

  # ── Step 1: Version bump ────────────────────────────────────────────────────
  # Extract unique task names referenced in .tekton/ (strips -oci-ta suffix
  # is NOT done — oci-ta variants are separate Quay repos with the full name).
  local tasks_in_tekton
  tasks_in_tekton=$(grep -rh "quay.io/konflux-ci/tekton-catalog/task-" .tekton/ 2>/dev/null \
    | grep -oP "(?<=task-)[a-z0-9-]+(?=:[0-9])" \
    | sort -u || true)

  local version_bumped=0
  for task in $tasks_in_tekton; do
    local current_ver latest_ver
    # Extract full version (X.Y or X.Y.Z) from .tekton/ YAML
    current_ver=$(grep -rh "task-${task}:" .tekton/ 2>/dev/null \
      | head -1 | grep -oP "(?<=task-${task}:)[0-9]+\.[0-9]+(\.[0-9]+)?" || true)
    [ -z "$current_ver" ] && continue

    latest_ver=$(latest_task_version "$task")
    if [ -z "$latest_ver" ]; then
      echo "  ⚠ $task: not in data-acceptable-bundles (skipping version check)" >&2
      continue
    fi

    # Only upgrade — never downgrade. Skip if acceptable-bundles latest is not
    # strictly higher than what's already in the repo. Use sort -Vu to compare:
    # if the highest version when both are sorted together is NOT latest_ver, then
    # current_ver is already higher (or equal) and we leave it alone.
    local highest
    highest=$(printf '%s\n%s\n' "$current_ver" "$latest_ver" | sort -Vu | tail -1)
    if [ "$current_ver" = "$latest_ver" ] || [ "$highest" != "$latest_ver" ]; then
      [ "$current_ver" != "$latest_ver" ] && \
        echo "  = $task: $current_ver (acceptable-bundles: $latest_ver — already at or above latest, skipping)" >&2
      continue
    fi

    echo "  ↑ $task: $current_ver → $latest_ver"
    # sed -i.bak for BSD/GNU portability; matches full X.Y or X.Y.Z version string
    for yaml_file in .tekton/*.yaml; do
      [ -f "$yaml_file" ] || continue
      if grep -q "task-${task}:${current_ver}" "$yaml_file" 2>/dev/null; then
        if ! sed -i.bak "s|task-${task}:${current_ver}|task-${task}:${latest_ver}|g" "$yaml_file"; then
          REPOS_FAILED+=("$REPO:sed-failed")
          _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
          return
        fi
        rm -f "${yaml_file}.bak"
      fi
    done
    version_bumped=$((version_bumped + 1))
  done

  # ── Step 2: SHA bump via pipeline-patcher ──────────────────────────────────
  local patcher_out
  if ! patcher_out=$(printf '%s' "$PATCHER_SCRIPT" | bash -s bump-task-refs 2>&1); then
    echo "  ✗ pipeline-patcher failed:" >&2
    printf '%s\n' "$patcher_out" | sed 's/^/      /' >&2
    if printf '%s' "$patcher_out" | grep -q "Can't find"; then
      echo "    Hint: a task ref is missing from the trusted list — often a denied or" >&2
      echo "    moved catalog. Check EC deny rules (scripts/lib/deny-rules.sh)." >&2
    fi
    REPOS_FAILED+=("$REPO:patcher-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
    echo ""; return
  fi

  # ── EC deny-rule check on the patched tree ──────────────────────────────────
  # The patcher only knows the trusted list; EC also applies deny rules. ACTIVE
  # denials that survive the steps above need a manual fix. FUTURE ones warn.
  local deny_scan="" deny_active=0
  if [ "$DENY_RULES_CHECKED" -eq 1 ]; then
    deny_scan=$(deny_rules_scan "." 2>/dev/null || true)
    deny_active=$(deny_rules_count_active "$deny_scan")
    if [ -n "$deny_scan" ]; then
      deny_rules_report "$deny_scan" "  "
      DENY_REPORTS+=("$REPO"$'\n'"$(deny_rules_report "$deny_scan" "    ")")
    fi
  fi

  # ── Commit if changed ──────────────────────────────────────────────────────
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
      echo "  - Already current (no version or SHA changes)"
      REPOS_SKIPPED+=("$REPO:no-changes")
    else
      REPOS_FAILED+=("$REPO:restore-failed")
    fi
    [ "$deny_active" -gt 0 ] && { _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || REPOS_FAILED+=("$REPO:restore-failed"); }
    echo ""; return
  fi

  local msg="Update Tekton task refs to latest versions"
  if [ "$version_bumped" -gt 0 ]; then
    msg="Bump Tekton task versions and SHAs

Updates task version strings and SHA references in .tekton/ pipelines
so Konflux builds pass Enterprise Contract validation."
  fi
  if [ -n "$moved_summary" ]; then
    msg="${msg}

Replaces task refs that EC denies because their catalog moved (the deny
rule's message names the replacement); the patcher re-pinned the digest:
${moved_summary}"
  fi

  if git commit -s -m "$msg" >/dev/null 2>&1; then
    echo "  ✓ Committed ($FIX_BRANCH)"
    REPOS_UPDATED+=("$REPO#$FIX_BRANCH#$BASE_BRANCH")
    if [ "$deny_active" -gt 0 ]; then
      echo "  ⚠ Committed refresh does NOT clear the EC deny rule(s) above"
      REPOS_DENIED+=("$REPO:$deny_active")
    fi
    _restore_repo "$ORIGINAL_REF" "" "$STASH_REF" || REPOS_FAILED+=("$REPO:restore-failed")
  else
    echo "  ✗ Commit failed" >&2
    REPOS_FAILED+=("$REPO:commit-failed")
    _restore_repo "$ORIGINAL_REF" "$FIX_BRANCH" "$STASH_REF" || true
  fi

  echo ""
}

# ── EC log diagnosis (when nothing to update) ──────────────────────────────────

ec_log_diagnosis() {
  local version="$1"
  local parse_script="$_LIB_DIR/parse-ec-log.sh"

  echo "" >&2
  echo "ℹ️  All task versions and SHAs already current across all repos." >&2
  echo "   EC is failing for a reason other than stale task references." >&2
  echo "" >&2

  # Surface the Konflux UI URL from the failing snapshot if oc is available
  if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    local dash_mm="${MAJOR_MINOR//./-}"
    local snap_name ec_status test_plr app_name ui_url
    snap_name=$(oc get snapshots -n submariner-tenant \
      --sort-by=.metadata.creationTimestamp -o json --request-timeout=30s 2>/dev/null \
      | jq -r --arg p "submariner-${dash_mm}-" \
        '[.items[] | select(.metadata.name | startswith($p)) |
          select(.metadata.labels["pac.test.appstudio.openshift.io/event-type"] == "push" or
                 .metadata.labels["pac.test.appstudio.openshift.io/event-type"] == "incoming" or
                 .metadata.labels["pac.test.appstudio.openshift.io/event-type"] == "retest-all-comment")] |
          last | .metadata.name // empty' 2>/dev/null) || snap_name=""

    if [ -n "$snap_name" ] && [ "$snap_name" != "null" ]; then
      app_name="submariner-${dash_mm}"
      test_plr=$(oc get snapshot "$snap_name" -n submariner-tenant \
        -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' 2>/dev/null \
        | jq -r '.[0].testPipelineRunName // empty' 2>/dev/null) || test_plr=""
      ec_status=$(oc get snapshot "$snap_name" -n submariner-tenant \
        -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' 2>/dev/null \
        | jq -r '[.[] | select(.scenario | contains("enterprise-contract"))][0].status // "unknown"' \
        2>/dev/null) || ec_status="unknown"

      # BuildPLRInProgress is a normal transient status (not a failure), so
      # don't label such a snapshot as "Failing" — the EC verdict just hasn't
      # been finalized on the annotation yet.
      if [ "$ec_status" = "BuildPLRInProgress" ] || [ "$ec_status" = "TestPassed" ]; then
        echo "  Latest snapshot: $snap_name (EC: $ec_status)" >&2
      else
        echo "  Failing snapshot: $snap_name (EC: $ec_status)" >&2
      fi
      echo "" >&2

      if [ -n "$test_plr" ] && [ "$test_plr" != "null" ]; then
        ui_url="https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/submariner-tenant/applications/${app_name}/pipelineruns/${test_plr}/logs"
        echo "  EC log URL: $ui_url" >&2
        echo "" >&2
        echo "  To diagnose:" >&2
        echo "    1. Open the URL above and click 'Download'" >&2
        echo "    2. Save to ~/Downloads/" >&2
        echo "    3. Re-run: /autorelease $version" >&2
      else
        echo "  ⚠  testPipelineRunName not found on snapshot (may have been GC'd)" >&2
        local fallback_url="https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/submariner-tenant/applications/${app_name}/snapshots/${snap_name}"
        echo "  View snapshot: $fallback_url" >&2
      fi

      # Check for an already-downloaded EC log and parse it if present
      if [ -f "$parse_script" ]; then
        local log_file=""
        # Glob for downloaded EC logs in ~/Downloads; newest first.
        # Use a bash glob sorted by modification time rather than find|xargs ls
        # to avoid shellcheck SC2038 (non-alphanumeric filenames in xargs).
        local _latest_mtime=0 _f _fmtime
        for _f in "$HOME/Downloads"/submariner-enterprise-*.log; do
          [ -f "$_f" ] || continue
          _fmtime=$(stat -c '%Y' "$_f" 2>/dev/null || stat -f '%m' "$_f" 2>/dev/null || echo 0)
          if [ "$_fmtime" -gt "$_latest_mtime" ]; then
            _latest_mtime="$_fmtime"
            log_file="$_f"
          fi
        done

        if [ -n "$log_file" ]; then
          echo "" >&2
          echo "  Found EC log: $(basename "$log_file")" >&2
          echo "  Parsing..." >&2
          echo "" >&2
          local parse_out parse_rc=0
          parse_out=$("$parse_script" "$log_file" 2>/dev/null) || parse_rc=$?
          if [ "$parse_rc" -eq 0 ] || [ "$parse_rc" -eq 2 ]; then
            printf '%s\n' "$parse_out" | sed 's/^/  /' >&2
            # A deny rule is not a stale-ref problem: the ref can be current and
            # trusted yet still denied. Say so instead of blaming a stale log.
            if printf '%s' "$parse_out" | grep -q "^DENY_REASONS:"; then
              echo "" >&2
              echo "  ⚠  The EC log reports deny rule(s) — a refresh cannot fix these:" >&2
              printf '%s\n' "$parse_out" | sed -n '/^DENY_REASONS:/,/^$/p' | grep -v '^$' \
                | sed 's/^/    /' >&2
              echo "     This script checks deny rules per repo (see above). If it did not" >&2
              echo "     flag them, policy-data may be unreachable or the ref is outside" >&2
              echo "     .tekton/ bundle params — fix the ref manually." >&2
            fi
            # If fixable and tasks named, there's a mismatch between "already
            # current" and what the log says. Surface that contradiction.
            if printf '%s' "$parse_out" | grep -q "FIXABLE_BY_VERSION_BUMP: yes"; then
              echo "" >&2
              echo "  ⚠  Log says task version bump should fix this, but all versions" >&2
              echo "     appear current. The log may be stale (from a previous run)." >&2
              echo "     Download a fresh log from the URL above and re-run." >&2
            fi
            # A confirmed-clean log (empty violations[], not just unparseable)
            # means this downloaded log is NOT evidence EC is still failing —
            # it's evidence a passing run already happened. The "failing
            # snapshot" named above is independently picked as the latest
            # push/incoming build, so it can be a *different, older* snapshot
            # than the one this log is for; don't tell the user EC is still
            # broken when the log they just downloaded says otherwise.
            if printf '%s' "$parse_out" | grep -q "FIXABLE_BY_VERSION_BUMP: n/a"; then
              echo "" >&2
              echo "  ✓ This log shows a clean run (no violations) — EC passed here." >&2
              echo "    If the conductor still reports EC failing, this log may be for" >&2
              echo "    a different/newer snapshot than the one named above. Re-run" >&2
              echo "    /autorelease $version to let verify_ecFixes re-check the cluster." >&2
            fi
            if printf '%s' "$parse_out" | grep -q "NON_TASK_RULES"; then
              local non_task_section
              non_task_section=$(printf '%s' "$parse_out" | sed -n '/NON_TASK_RULES/,/^$/p' | grep -v "^$")
              if printf '%s' "$non_task_section" | grep -qv "(none"; then
                echo "" >&2
                echo "  ⚠  Non-task violations require manual fixes:" >&2
                printf '%s\n' "$non_task_section" | grep "^  " | sed 's/^/    /' >&2
              fi
            fi
          fi
        fi
      fi
    fi
  else
    echo "  (oc not logged in — cannot retrieve snapshot details)" >&2
    echo "  Log in first: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/" >&2
  fi
}

# ── Summary and push log ───────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "Summary"

  local gh_user
  gh_user=$(get_gh_user)

  if [ "${#REPOS_UPDATED[@]}" -gt 0 ]; then
    echo ""
    echo "Updated (${#REPOS_UPDATED[@]}):"
    echo ""
    echo "Next Steps"
    for entry in "${REPOS_UPDATED[@]}"; do
      local repo fix_branch base_branch path fork head_ref
      repo="${entry%%#*}"
      fix_branch="${entry#*#}"; fix_branch="${fix_branch%#*}"
      base_branch="${entry##*#}"
      path=$(repo_path "$repo")
      fork=$(fork_remote "$path" "$gh_user")
      head_ref="$fix_branch"
      [ -n "$gh_user" ] && head_ref="${gh_user}:${fix_branch}"

      local _deny_note=""
      if [ "${#REPOS_DENIED[@]}" -gt 0 ]; then
        local _d
        for _d in "${REPOS_DENIED[@]}"; do
          [ "${_d%%:*}" = "$repo" ] && _deny_note="  ⚠ still denied by EC — manual fix needed before merging"
        done
      fi
      # Component PRs need the ready-to-test label for Konflux to build them (as in
      # tekton-task-refs-update.sh); the FBC repo has no such label.
      local label_flag="--label ready-to-test"
      [ "$repo" = "fbc" ] && label_flag=""

      echo ""
      echo "  ✓ $repo ($fix_branch)${_deny_note}"
      echo "  # $repo"
      echo "  cd $path"
      echo "  git show"
      echo "  git push $fork $fix_branch"
      echo "  gh pr create --base $base_branch --head $head_ref \\"
      echo "    --title \"Bump Tekton task versions and SHAs\" \\"
      echo "    --body \"Updates task versions and SHA references to pass Enterprise Contract.\" \\"
      echo "    --assignee @me${label_flag:+ $label_flag}"
      echo "  gh pr merge --auto --rebase $fix_branch"

      if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
        printf '\n  cd %s\n  git push %s %s\n  gh pr create --base %s --head %s --title "Bump Tekton task versions and SHAs" --body "Updates task versions and SHA references to pass Enterprise Contract." --assignee @me%s\n  gh pr merge --auto --rebase %s\n' \
          "$path" "$fork" "$fix_branch" "$base_branch" "$head_ref" "${label_flag:+ $label_flag}" "$fix_branch" \
          >> "$AUTORELEASE_PUSH_LOG"
      fi
    done
  fi

  if [ "${#REPOS_SKIPPED[@]}" -gt 0 ]; then
    echo ""
    echo "Already current (${#REPOS_SKIPPED[@]}):"
    for entry in "${REPOS_SKIPPED[@]}"; do
      echo "  - ${entry%%:*}"
    done
  fi

  if [ "${#REPOS_DENIED[@]}" -gt 0 ]; then
    echo ""
    echo "EC deny rules need a manual fix (${#REPOS_DENIED[@]}):"
    for entry in "${REPOS_DENIED[@]}"; do
      echo "  ✗ ${entry%%:*} (${entry##*:} active denial(s))"
    done
    echo "  Details are printed per repo above. Edit the .tekton/ refs, then re-run:"
    echo "  /autorelease $VERSION"
  fi

  if [ "$DENY_RULES_CHECKED" -eq 0 ]; then
    echo ""
    echo "⚠ EC deny rules were NOT checked (policy-data unavailable): a clean run"
    echo "  here does not prove EC will pass."
  fi

  if [ "${#REPOS_FAILED[@]}" -gt 0 ]; then
    echo ""
    echo "Failed (${#REPOS_FAILED[@]}):"
    for entry in "${REPOS_FAILED[@]}"; do
      echo "  ✗ ${entry%%:*} (${entry##*:})"
    done
    echo ""
    echo "Fix failures then re-run: /autorelease $VERSION"
  fi

  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  check_prerequisites
  parse_arguments "$@"

  if ! command -v oc &>/dev/null; then
    die "oc not installed" "Install OpenShift CLI first"
  fi
  if ! oc whoami &>/dev/null 2>&1; then
    die "Not logged into Konflux cluster" \
      "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/"
  fi

  echo ""
  echo "============================================"
  echo "Tekton Task Version + SHA Bump"
  echo "============================================"
  echo "Version: $VERSION  (release-${MAJOR_MINOR})"
  [ -n "$REPO_FILTER" ] && echo "Repo filter: $REPO_FILTER"
  echo ""

  # download_and_verify_patcher is provided by lib/pipeline-patcher.sh (sourced at top).
  PATCHER_SCRIPT=$(download_and_verify_patcher) || \
    die "Failed to download/verify pipeline-patcher" \
      "Check network connectivity and GitHub access"
  echo "✓ Pipeline-patcher checksum verified"

  if deny_rules_load; then
    DENY_RULES_CHECKED=1
    echo "✓ EC deny rules loaded"
  else
    echo "⚠ EC deny rules NOT loaded — refs will not be checked against them"
  fi
  echo ""

  # Tracker integration (lib/jira-tracker.sh already sourced at top; no re-source needed).
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  local TRACKER_STEP="${AUTORELEASE_TRACKER_STEP:-ecFixes}"
  [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ] && \
    update_step "$VERSION" "$TRACKER_STEP" "in_progress" '{}' "$TRACKER"

  # Save CWD; update_repo cd's into each repo.
  local ORIGINAL_DIR
  ORIGINAL_DIR=$(pwd)

  # Process repos
  local all_repos="submariner-operator submariner lighthouse shipyard subctl fbc"
  for repo in $all_repos; do
    if [ -n "$REPO_FILTER" ] && [ "$repo" != "$REPO_FILTER" ]; then
      continue
    fi
    update_repo "$repo"
  done

  cd "$ORIGINAL_DIR"

  print_summary

  local updated_count=${#REPOS_UPDATED[@]}
  local failed_count=${#REPOS_FAILED[@]}

  if [ "$failed_count" -gt 0 ] || [ "${#REPOS_DENIED[@]}" -gt 0 ]; then
    exit 1
  fi

  if [ "$updated_count" -eq 0 ]; then
    # Nothing to update — EC is failing for a different reason.
    # Emit diagnosis (Konflux UI URL, EC log parse if available) and exit 2
    # so the conductor stops without re-running this script endlessly.
    if [ -n "${TRACKER:-}" ] && [ -z "$REPO_FILTER" ]; then
      update_step "$VERSION" "$TRACKER_STEP" "in_progress" \
        '{"needsEcLog":true}' "$TRACKER" || true
    fi
    ec_log_diagnosis "$VERSION"
    exit 2
  fi

  # Commits made — conductor will stop for review (push PRs, wait for rebuild).
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
