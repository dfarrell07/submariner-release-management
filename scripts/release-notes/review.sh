#!/bin/bash
# Prepare host-agent release-note reviews and apply validated decisions.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR=$(cd "$SCRIPT_DIR/../lib" && pwd)

# shellcheck source=../lib/release-notes-common.sh
source "$LIB_DIR/release-notes-common.sh"

usage() {
  cat >&2 <<EOF
Usage:
  $0 [prepare] VERSION [--stage-yaml PATH]
  $0 apply RUN_DIR
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

absolute_path() {
  local path=$1 directory base
  directory=$(dirname "$path")
  base=$(basename "$path")
  printf '%s/%s\n' "$(cd "$directory" && pwd -P)" "$base"
}

write_result() {
  local run_dir=$1 key=$2 decision=$3 reason=$4 commit=${5:-}
  local result_file="$run_dir/results/$key.json" temporary
  temporary=$(mktemp "$run_dir/results/.${key}.XXXXXX")
  jq -n \
    --arg issue_key "$key" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    --arg commit "$commit" \
    '{issue_key:$issue_key, decision:$decision, reason:$reason,
      commit:(if $commit == "" then null else $commit end)}' > "$temporary"
  mv "$temporary" "$result_file"
}

prepare_reviews() {
  local version="" stage_yaml_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage-yaml)
        [[ $# -ge 2 ]] || die "--stage-yaml requires a path"
        stage_yaml_arg=$2
        shift 2
        ;;
      -*) die "Unknown option: $1" ;;
      *)
        [[ -z "$version" ]] || die "Multiple positional arguments are not supported"
        version=$1
        shift
        ;;
    esac
  done

  [[ -n "$version" ]] || { usage; exit 1; }
  if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    version="${version}.0"
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid version: $version"

  VERSION=$version
  calculate_acm_version
  find_stage_yaml "$VERSION" "$stage_yaml_arg"

  local repo_root stage_yaml stage_relative branch base_commit status
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Not in a Git repository"
  repo_root=$(cd "$repo_root" && pwd -P)
  stage_yaml=$(absolute_path "$STAGE_YAML")
  [[ "$stage_yaml" == "$repo_root/"* ]] || die "Stage YAML is outside the repository: $stage_yaml"
  [[ ! -L "$stage_yaml" ]] || die "Stage YAML must not be a symbolic link"
  stage_relative=${stage_yaml#"$repo_root/"}
  git -C "$repo_root" ls-files --error-unmatch -- "$stage_relative" >/dev/null 2>&1 || \
    die "Stage YAML is not tracked: $stage_relative"
  branch=$(git -C "$repo_root" branch --show-current)
  [[ -n "$branch" ]] || die "Detached HEAD is not supported"
  status=$(git -C "$repo_root" status --porcelain --untracked-files=all)
  [[ -z "$status" ]] || die "Repository worktree must be clean before preparing reviews"
  base_commit=$(git -C "$repo_root" rev-parse HEAD)

  banner "Prepare Release Notes Reviews: $VERSION"
  echo "Version: $VERSION"
  echo "ACM Version: $ACM_VERSION"
  echo "Stage YAML: $stage_yaml"

  local review_data data_version data_stage data_stage_absolute
  review_data=${RELEASE_NOTES_DATA:-/tmp/release-notes-${VERSION}-data.json}
  data_version=""
  data_stage=""
  data_stage_absolute=""
  if [[ -f "$review_data" ]]; then
    data_version=$(jq -r '.metadata.version // ""' "$review_data" 2>/dev/null || true)
    data_stage=$(jq -r '.metadata.stage_yaml // ""' "$review_data" 2>/dev/null || true)
    if [[ -n "$data_stage" && -f "$data_stage" ]]; then
      data_stage_absolute=$(absolute_path "$data_stage")
    fi
  fi
  if [[ "$data_version" != "$VERSION" || "$data_stage_absolute" != "$stage_yaml" ]]; then
    echo "Data file missing or does not match $VERSION and $stage_yaml; re-collecting..."
    if ! RELEASE_NOTES_DATA="$review_data" \
      "$SCRIPT_DIR/collect.sh" "$VERSION" --stage-yaml "$stage_yaml" >/dev/null; then
      die "collect.sh failed; refusing to review without a current CVE exclusion list"
    fi
  fi
  jq -e --arg version "$VERSION" '
    .metadata.version == $version and
    (.metadata.stage_yaml | type == "string" and length > 0) and
    (.cve_issues | type == "array") and
    ([.cve_issues[]?.issue_key |
      type == "string" and test("^[A-Z][A-Z0-9]+-[0-9]+$")] | all)
  ' "$review_data" >/dev/null || \
    die "Invalid review data or CVE exclusion list: $review_data"
  data_stage=$(jq -r '.metadata.stage_yaml' "$review_data")
  [[ -f "$data_stage" ]] || die "Review data stage YAML not found: $data_stage"
  data_stage_absolute=$(absolute_path "$data_stage")
  [[ "$data_stage_absolute" == "$stage_yaml" ]] || \
    die "Review data does not match the selected stage YAML: $review_data"
  yq eval -e \
    '.spec.data.releaseNotes.issues.fixed | type == "!!seq"' \
    "$stage_yaml" >/dev/null || die "Stage YAML has no valid fixed-issues list: $stage_yaml"

  mapfile -t all_keys < <(
    yq eval '.spec.data.releaseNotes.issues.fixed[]?.id // ""' "$stage_yaml" |
      sed '/^$/d'
  )
  if [[ ${#all_keys[@]} -eq 0 ]]; then
    echo "No issues found in the stage YAML; nothing to review."
    echo "REVIEW_STATUS=no-reviewable-issues"
    return 0
  fi

  mapfile -t cve_keys < <(jq -r '.cve_issues[]?.issue_key // empty' "$review_data")
  local -A cve_set=() seen=()
  local key
  for key in "${cve_keys[@]}"; do
    [[ "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || die "Invalid CVE issue key in data: $key"
    cve_set["$key"]=1
  done

  local -a review_keys=()
  for key in "${all_keys[@]}"; do
    [[ "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || die "Invalid issue key in stage YAML: $key"
    [[ -z "${seen[$key]:-}" ]] || die "Duplicate issue key in stage YAML: $key"
    seen["$key"]=1
    if [[ -n "${cve_set[$key]:-}" ]]; then
      echo "Skipping $key (CVE issue; always included)"
    else
      review_keys+=("$key")
    fi
  done

  if [[ ${#review_keys[@]} -eq 0 ]]; then
    echo "No non-CVE issues to review."
    echo "REVIEW_STATUS=no-reviewable-issues"
    return 0
  fi

  local run_dir run_parent manifest issues_json cve_json stage_keys_json created_at
  run_parent=${TMPDIR:-/tmp}
  [[ -d "$run_parent" ]] || die "Temporary directory does not exist: $run_parent"
  run_dir=$(mktemp -d "$run_parent/release-notes-review.XXXXXX")
  mkdir "$run_dir/bundles" "$run_dir/decisions" "$run_dir/results"
  echo "REVIEW_RUN_DIR=$run_dir"

  local current=0 total=${#review_keys[@]} bundle decision
  for key in "${review_keys[@]}"; do
    current=$((current + 1))
    bundle="$run_dir/bundles/$key.md"
    decision="$run_dir/decisions/$key.json"
    echo "[$current/$total] Collecting evidence for $key"
    if ! "$SCRIPT_DIR/review-issue.sh" \
      "$key" "$VERSION" "$stage_yaml" "$bundle" "$decision"; then
      die "Evidence collection failed for $key; partial run retained at $run_dir"
    fi
  done

  issues_json=$(printf '%s\n' "${review_keys[@]}" | jq -Rsc '
    split("\n")[:-1] |
    map({key:., bundle:("bundles/" + . + ".md"),
         decision:("decisions/" + . + ".json"),
         result:("results/" + . + ".json")})')
  cve_json=$(printf '%s\n' "${cve_keys[@]}" | jq -Rsc 'split("\n")[:-1]')
  stage_keys_json=$(printf '%s\n' "${all_keys[@]}" | jq -Rsc 'split("\n")[:-1]')
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  manifest="$run_dir/manifest.json"
  jq -n \
    --argjson schema 2 \
    --arg version "$VERSION" \
    --arg repo_root "$repo_root" \
    --arg stage_yaml "$stage_yaml" \
    --arg stage_relative "$stage_relative" \
    --arg branch "$branch" \
    --arg base_commit "$base_commit" \
    --arg created_at "$created_at" \
    --argjson issues "$issues_json" \
    --argjson excluded_cve_keys "$cve_json" \
    --argjson stage_issue_keys "$stage_keys_json" \
    '{schema:$schema, version:$version, repo_root:$repo_root,
      stage_yaml:$stage_yaml, stage_relative:$stage_relative, branch:$branch,
      base_commit:$base_commit, created_at:$created_at, issues:$issues,
      excluded_cve_keys:$excluded_cve_keys,
      stage_issue_keys:$stage_issue_keys}' > "$manifest"

  echo
  echo "Prepared ${#review_keys[@]} review bundles."
  echo "Manifest: $manifest"
  echo "Criteria: $SCRIPT_DIR/review-prompt.md"
  echo "Write one decision JSON file per manifest entry, then run:"
  printf '  %q apply %q\n' "$0" "$run_dir"
}

apply_reviews() {
  [[ $# -eq 1 ]] || { usage; exit 1; }
  local run_dir manifest
  run_dir=$1
  [[ -d "$run_dir" ]] || die "Review run directory not found: $run_dir"
  run_dir=$(cd "$run_dir" && pwd -P)
  manifest="$run_dir/manifest.json"
  [[ -f "$manifest" ]] || die "Review manifest not found: $manifest"

  jq -e '
    ([.issues[].key]) as $review_keys |
    .schema == 2 and
    (.version | type == "string") and
    (.repo_root | type == "string") and
    (.stage_yaml | type == "string") and
    (.stage_relative | type == "string") and
    (.branch | type == "string") and
    (.base_commit | test("^[0-9a-f]{40}$")) and
    (.issues | type == "array" and length > 0) and
    ($review_keys | length == (unique | length)) and
    ([.issues[] | .key | test("^[A-Z][A-Z0-9]+-[0-9]+$")] | all) and
    (.excluded_cve_keys | type == "array") and
    ([.excluded_cve_keys[] |
      type == "string" and test("^[A-Z][A-Z0-9]+-[0-9]+$")] | all) and
    (.stage_issue_keys | type == "array" and length > 0) and
    ([.stage_issue_keys[]] | length == (unique | length)) and
    ([.stage_issue_keys[] |
      type == "string" and test("^[A-Z][A-Z0-9]+-[0-9]+$")] | all) and
    (($review_keys - .stage_issue_keys) | length == 0) and
    ((.stage_issue_keys - ($review_keys + .excluded_cve_keys)) | length == 0) and
    (($review_keys - .excluded_cve_keys) | length == ($review_keys | length))
  ' "$manifest" >/dev/null || die "Invalid review manifest: $manifest"

  local version repo_root stage_yaml stage_relative branch base_commit
  version=$(jq -r '.version' "$manifest")
  repo_root=$(jq -r '.repo_root' "$manifest")
  stage_yaml=$(jq -r '.stage_yaml' "$manifest")
  stage_relative=$(jq -r '.stage_relative' "$manifest")
  branch=$(jq -r '.branch' "$manifest")
  base_commit=$(jq -r '.base_commit' "$manifest")

  [[ -d "$repo_root/.git" || -f "$repo_root/.git" ]] || die "Review repository not found: $repo_root"
  [[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || \
    die "Review repository root no longer matches the manifest"
  [[ "$stage_relative" != /* && "$stage_relative" != .. && \
    "$stage_relative" != ../* && "$stage_relative" != */../* && \
    "$stage_relative" != */.. ]] || die "Manifest stage path is unsafe"
  [[ "$stage_yaml" == "$repo_root/$stage_relative" ]] || die "Manifest stage path is inconsistent"
  [[ -f "$stage_yaml" ]] || die "Stage YAML not found: $stage_yaml"
  [[ ! -L "$stage_yaml" ]] || die "Stage YAML must not be a symbolic link"
  [[ "$(absolute_path "$stage_yaml")" == "$stage_yaml" ]] || die "Stage YAML path is not canonical"
  git -C "$repo_root" ls-files --error-unmatch -- "$stage_relative" >/dev/null 2>&1 || \
    die "Stage YAML is no longer tracked: $stage_relative"
  [[ "$(git -C "$repo_root" branch --show-current)" == "$branch" ]] || \
    die "Review branch changed; expected $branch"
  git -C "$repo_root" merge-base --is-ancestor "$base_commit" HEAD || \
    die "Review base commit is not an ancestor of HEAD"

  local status
  status=$(git -C "$repo_root" status --porcelain --untracked-files=all)
  [[ -z "$status" ]] || die "Repository worktree must be clean before applying decisions"

  yq eval -e '.spec.data.releaseNotes.issues.fixed | type == "!!seq"' \
    "$stage_yaml" >/dev/null || die "Stage YAML has no valid fixed-issues list: $stage_yaml"
  local -A original_set=() current_set=()
  local original_key current_key excluded_key
  while IFS= read -r original_key; do
    original_set["$original_key"]=1
  done < <(jq -r '.stage_issue_keys[]' "$manifest")
  while IFS= read -r current_key; do
    [[ -n "$current_key" ]] || continue
    [[ "$current_key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || \
      die "Invalid issue key in current stage YAML: $current_key"
    [[ -z "${current_set[$current_key]:-}" ]] || \
      die "Duplicate issue key in current stage YAML: $current_key"
    [[ -n "${original_set[$current_key]:-}" ]] || \
      die "Stage YAML contains issue added after review preparation: $current_key"
    current_set["$current_key"]=1
  done < <(yq eval '.spec.data.releaseNotes.issues.fixed[]?.id // ""' "$stage_yaml")
  while IFS= read -r excluded_key; do
    if [[ -n "${original_set[$excluded_key]:-}" && -z "${current_set[$excluded_key]:-}" ]]; then
      die "Excluded CVE issue is missing from the stage YAML: $excluded_key"
    fi
  done < <(jq -r '.excluded_cve_keys[]' "$manifest")

  local kept=0 removed=0 failed=0 unreviewed=0 recovered=0
  local key bundle_rel decision_rel result_rel bundle_file decision_file result_file
  local decision_key verdict reason count commit expected_subject found_commit

  while IFS=$'\t' read -r key bundle_rel decision_rel result_rel; do
    [[ "$bundle_rel" == "bundles/$key.md" ]] || die "Invalid bundle path for $key"
    [[ "$decision_rel" == "decisions/$key.json" ]] || die "Invalid decision path for $key"
    [[ "$result_rel" == "results/$key.json" ]] || die "Invalid result path for $key"
    if jq -e --arg key "$key" '.excluded_cve_keys | index($key) == null' \
      "$manifest" >/dev/null; then
      :
    else
      die "Manifest attempts to review excluded CVE issue $key"
    fi

    bundle_file="$run_dir/$bundle_rel"
    [[ -f "$bundle_file" && ! -L "$bundle_file" ]] || \
      die "Evidence bundle missing or unsafe for $key: $bundle_file"
    decision_file="$run_dir/$decision_rel"
    result_file="$run_dir/$result_rel"
    count=$(ISSUE_KEY="$key" yq eval \
      '[.spec.data.releaseNotes.issues.fixed[]? | select(.id == strenv(ISSUE_KEY))] | length' \
      "$stage_yaml")
    if [[ -f "$result_file" ]]; then
      verdict=$(jq -r --arg key "$key" '
        if .issue_key == $key and
          (.decision == "KEEP" or .decision == "REMOVE") and
          (.reason | type == "string" and length > 0) and
          ((.decision == "KEEP" and .commit == null) or
           (.decision == "REMOVE" and (.commit | test("^[0-9a-f]{40}$"))))
        then .decision else empty end' "$result_file" 2>/dev/null || true)
      [[ -n "$verdict" ]] || die "Invalid existing result for $key"
      if [[ "$verdict" == KEEP ]]; then
        [[ "$count" -eq 1 ]] || die "KEEP result for $key disagrees with the stage YAML"
        kept=$((kept + 1))
      else
        [[ "$count" -eq 0 ]] || die "REMOVE result for $key disagrees with the stage YAML"
        removed=$((removed + 1))
      fi
      echo "  = $verdict $key (already applied)"
      continue
    fi

    if [[ "$count" -eq 0 ]]; then
      expected_subject="Remove $key from $version release notes"
      found_commit=$(git -C "$repo_root" log --format='%H%x09%s' \
        "$base_commit..HEAD" -- "$stage_relative" |
        awk -F '\t' -v subject="$expected_subject" '$2 == subject {print $1; exit}')
      if [[ -n "$found_commit" ]]; then
        write_result "$run_dir" "$key" REMOVE "Recovered previously committed removal" "$found_commit"
        removed=$((removed + 1))
        recovered=$((recovered + 1))
        echo "  = REMOVE $key (recovered commit $found_commit)"
        continue
      fi
      echo "  ! KEEP $key - issue is absent without a recorded review removal" >&2
      failed=$((failed + 1))
      continue
    elif [[ "$count" -ne 1 ]]; then
      echo "  ! KEEP $key - expected one stage entry, found $count" >&2
      failed=$((failed + 1))
      continue
    fi

    if [[ ! -f "$decision_file" ]]; then
      echo "  ? KEEP $key - decision missing: $decision_file"
      unreviewed=$((unreviewed + 1))
      continue
    fi
    if ! jq -e '
      type == "object" and
      (.issue_key | type == "string") and
      (.decision == "KEEP" or .decision == "REMOVE") and
      (.reason | type == "string" and length > 0 and
        (test("[\\r\\n]") | not))
    ' "$decision_file" >/dev/null 2>&1; then
      echo "  ! KEEP $key - malformed decision" >&2
      failed=$((failed + 1))
      continue
    fi
    decision_key=$(jq -r '.issue_key' "$decision_file")
    verdict=$(jq -r '.decision' "$decision_file")
    reason=$(jq -r '.reason' "$decision_file")
    if [[ "$decision_key" != "$key" ]]; then
      echo "  ! KEEP $key - decision issue key is $decision_key" >&2
      failed=$((failed + 1))
      continue
    fi
    if [[ "$reason" == *$'\n'* || "$reason" == *$'\r'* ]]; then
      echo "  ! KEEP $key - decision reason must be one line" >&2
      failed=$((failed + 1))
      continue
    fi

    if [[ "$verdict" == KEEP ]]; then
      write_result "$run_dir" "$key" KEEP "$reason"
      kept=$((kept + 1))
      echo "  ✓ KEEP $key - $reason"
      continue
    fi

    status=$(git -C "$repo_root" status --porcelain --untracked-files=all)
    [[ -z "$status" ]] || die "Worktree became dirty before applying $key"
    local backup
    backup=$(mktemp "$run_dir/.stage-backup.XXXXXX")
    cp "$stage_yaml" "$backup"
    if ! ISSUE_KEY="$key" yq eval -i \
      'del(.spec.data.releaseNotes.issues.fixed[] | select(.id == strenv(ISSUE_KEY)))' \
      "$stage_yaml" || ! yq eval '.' "$stage_yaml" >/dev/null; then
      cp "$backup" "$stage_yaml"
      rm -f "$backup"
      echo "  ! KEEP $key - failed to produce valid YAML" >&2
      failed=$((failed + 1))
      continue
    fi
    rm -f "$backup"
    git -C "$repo_root" add -- "$stage_relative"
    if ! git -C "$repo_root" commit -s \
      -m "Remove $key from $version release notes" \
      -m "${reason:0:78}"; then
      die "Commit failed for $key; changes remain for inspection"
    fi
    commit=$(git -C "$repo_root" rev-parse HEAD)
    write_result "$run_dir" "$key" REMOVE "$reason" "$commit"
    removed=$((removed + 1))
    echo "  ✗ REMOVE $key - $reason"
  done < <(jq -r '.issues[] | [.key, .bundle, .decision, .result] | @tsv' "$manifest")

  banner "Review Decision Summary"
  echo "Results: $kept kept, $removed removed, $failed failed, $unreviewed unreviewed"
  [[ "$recovered" -eq 0 ]] || echo "Recovered committed removals: $recovered"
  echo "Run directory: $run_dir"

  if [[ "$failed" -gt 0 || "$unreviewed" -gt 0 ]]; then
    echo "No undecided or invalid issue was removed. Fix decisions and rerun apply." >&2
    return 1
  fi
}

mode=prepare
if [[ ${1:-} == prepare || ${1:-} == apply ]]; then
  mode=$1
  shift
fi

case "$mode" in
  prepare) prepare_reviews "$@" ;;
  apply) apply_reviews "$@" ;;
esac
