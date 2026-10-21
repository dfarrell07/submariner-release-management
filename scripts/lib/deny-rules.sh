#!/bin/bash
# Shared helper: check a repo's .tekton/ task bundle refs against the Enterprise
# Contract trusted-task DENY rules.
#
# Why this exists: pipeline-patcher only checks that a task ref is in
# data-acceptable-bundles ("trusted"). EC additionally applies deny rules from
# quay.io/redhat-konflux/policy-data (rule_data.trusted_task_rules.deny), so a ref
# can be trusted and denied at once. Two real cases so far:
#   - task-prefetch-dependencies-oci-ta <0.7.1 (a minimum-version deny), and
#   - quay.io/konflux-ci/konflux-vanguard/* (a whole-catalog wildcard deny with a
#     message naming the replacement catalog, in the "-deprecated" group).
# Neither is visible to the patcher, so both surfaced only as an EC failure.
#
# This file is meant to be sourced, not executed. Functions:
#
#   deny_rules_load
#       Fetch policy-data once (cached). Returns 1 with a warning when it cannot
#       be fetched — callers treat that as "unchecked", never as a pass. The
#       DENY_RULES_FILE env var points at a local policy-data JSON instead
#       (used by tests, or to run offline).
#
#   deny_rules_scan <repo-dir>
#       Print one TAB-separated line per (bundle ref, matching deny rule):
#         STATUS  REPO  VERSION  FILES  GROUP  EFFECTIVE_ON  DETAIL
#       STATUS is ACTIVE (EC denies it now) or FUTURE (effective_on is ahead —
#       fix before it bites). DETAIL is the rule's message, or the version
#       constraint(s) for a minimum-version rule. Both deny groups are checked
#       because EC evaluates both.
#
#   deny_rules_rewrite_moved <repo-dir>
#       For ACTIVE denials whose message says to "use the equivalent from
#       quay.io/konflux-ci/<catalog>", repoint the bundle repo to that catalog
#       (tag kept, digest left stale). Run pipeline-patcher afterwards: it
#       re-pins the digest from the trusted list and fails loudly if the
#       replacement catalog does not carry that tag. Only quay.io/konflux-ci/
#       targets are followed, so a policy-data change cannot redirect refs to an
#       arbitrary registry. Prints one "<old> -> <new> (N files)" line per move.
#
# Requires: jq, yq (mikefarah), oras (only for the fetch), GNU sort (-V).

# Where EC reads its deny data, and the keys inside it.
DENY_POLICY_DATA_REF="${DENY_POLICY_DATA_REF:-quay.io/redhat-konflux/policy-data:latest}"

_DENY_RULES_FILE=""      # resolved path to the policy-data JSON (cache)
_DENY_RULES_TMPDIR=""

# Fetch and cache the policy-data JSON. Sets _DENY_RULES_FILE.
deny_rules_load() {
  [ -n "$_DENY_RULES_FILE" ] && return 0

  if [ -n "${DENY_RULES_FILE:-}" ]; then
    if [ ! -r "$DENY_RULES_FILE" ]; then
      echo "  ⚠ DENY_RULES_FILE not readable: $DENY_RULES_FILE" >&2
      return 1
    fi
    if ! _deny_rules_valid "$DENY_RULES_FILE"; then
      echo "  ⚠ $DENY_RULES_FILE has no trusted_task_rules.deny — EC deny rules not checked" >&2
      return 1
    fi
    _DENY_RULES_FILE="$DENY_RULES_FILE"
    return 0
  fi

  if ! command -v oras &>/dev/null; then
    echo "  ⚠ oras not installed — EC deny rules not checked" >&2
    return 1
  fi

  _DENY_RULES_TMPDIR=$(mktemp -d) || return 1
  if ! oras pull "$DENY_POLICY_DATA_REF" -o "$_DENY_RULES_TMPDIR" >/dev/null 2>&1 \
     || [ ! -s "$_DENY_RULES_TMPDIR/data.json" ]; then
    echo "  ⚠ Could not fetch $DENY_POLICY_DATA_REF — EC deny rules not checked" >&2
    rm -rf "$_DENY_RULES_TMPDIR"; _DENY_RULES_TMPDIR=""
    return 1
  fi
  if ! _deny_rules_valid "$_DENY_RULES_TMPDIR/data.json"; then
    echo "  ⚠ $DENY_POLICY_DATA_REF has no trusted_task_rules.deny — EC deny rules not checked" >&2
    rm -rf "$_DENY_RULES_TMPDIR"; _DENY_RULES_TMPDIR=""
    return 1
  fi
  _DENY_RULES_FILE="$_DENY_RULES_TMPDIR/data.json"
}

# A usable policy-data file carries a non-empty deny object. An absent one must
# read as "unchecked", never as "nothing is denied".
_deny_rules_valid() {
  jq -e '(.rule_data.trusted_task_rules.deny | type) == "object"
    and (.rule_data.trusted_task_rules.deny | length) > 0
    and (.rule_data.trusted_task_rules.deny | all(.[];
      type == "array" and all(.[];
        (.pattern | type == "string" and length > 0) and
        ((has("versions") | not) or (.versions | type == "array" and length > 0 and
          all(.[]; type == "string" and test("^<[0-9]+([.][0-9]+){0,2}$")))) and
        ((has("effective_on") | not) or
          (.effective_on | fromdateiso8601 | type == "number")) and
        ((has("message") | not) or (.message | type == "string")))))' "$1" >/dev/null 2>&1
}

# True (0) when version $1 sorts strictly below $2. Compares numeric X.Y.Z
# components (missing ones = 0) and ignores any "-suffix" build tag, so 0.3 < 0.7.1,
# 0.10.1 > 0.9.0 (numeric, not lexicographic) and 0.10.0-123 == 0.10.0.
_deny_ver_lt() {
  local a="${1%%-*}" b="${2%%-*}"
  local a3 b3
  a3=$(printf '%s' "$a" | awk -F. '{printf "%d.%d.%d", $1, $2, $3}')
  b3=$(printf '%s' "$b" | awk -F. '{printf "%d.%d.%d", $1, $2, $3}')
  [ "$a3" != "$b3" ] && [ "$(printf '%s\n%s\n' "$a3" "$b3" | sort -V | head -n1)" = "$a3" ]
}

# Bundle refs (without digest) referenced by .tekton/*.yaml resolvers, one
# "repo:tag" per line. Same yq query pipeline-patcher uses, so we see exactly
# the refs it (and EC) sees, not refs that only appear in comments.
_deny_bundle_refs() {
  local dir="$1" files
  files=$(find "$dir/.tekton" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)
  [ -z "$files" ] && return 0
  # shellcheck disable=SC2086  # intentional word-splitting over the file list
  yq '... | select(has("resolver")) | .params // [] | .[] | select(.name == "bundle") | .value' $files 2>/dev/null \
    | grep -v -- '---' | sed 's/@sha256:.*$//' | sort -u | grep -E '^quay\.io/' || true
}

# Number of .tekton files that reference "repo:tag".
_deny_ref_file_count() {
  local dir="$1" ref="$2"
  grep -lF -- "${ref}@" "$dir"/.tekton/*.y*ml 2>/dev/null | wc -l | tr -d ' '
}

# Deny rules, one per line, fields joined by the ASCII unit separator (0x1f):
#   GROUP PATTERN VERSIONS(comma) EFFECTIVE_ON MESSAGE(one line)
# Not a tab: `read` treats tab as IFS whitespace and collapses runs of it, which
# would shift every field after an empty one (a rule with no versions/effective_on).
_DENY_SEP=$'\x1f'
_deny_rules_records() {
  jq -r '.rule_data.trusted_task_rules.deny | to_entries[] | .key as $g | .value[] |
    [$g, .pattern, ((.versions // []) | join(",")), (.effective_on // ""),
     ((.message // "") | gsub("[\n\t]+"; " ") | sub("[ ]+$"; ""))] | join("\u001f")' "$_DENY_RULES_FILE"
}

deny_rules_scan() {
  local dir="${1:-.}"
  [ -n "$_DENY_RULES_FILE" ] || deny_rules_load || return 1

  local now="${DENY_RULES_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local rules refs ref repo tag group pattern versions eff msg status detail hit v files
  rules=$(_deny_rules_records) || return 1
  refs=$(_deny_bundle_refs "$dir")
  [ -z "$refs" ] && return 0

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    repo="${ref%:*}"; tag="${ref##*:}"
    files=$(_deny_ref_file_count "$dir" "$ref")
    while IFS="$_DENY_SEP" read -r group pattern versions eff msg; do
      [ -z "$pattern" ] && continue
      # Glob match (pattern wildcards like task-* and vanguard/*); unquoted RHS.
      # shellcheck disable=SC2053
      [[ "oci://$repo" == $pattern ]] || continue

      hit=false
      if [ -z "$versions" ]; then
        hit=true                         # no version list = deny every version
      else
        for v in ${versions//,/ }; do
          case "$v" in
            "<"*) _deny_ver_lt "$tag" "${v#<}" && hit=true ;;
            *)    ;;                     # only "<X" occurs in policy-data today
          esac
        done
      fi
      $hit || continue

      status=ACTIVE
      [ -n "$eff" ] && [[ "$eff" > "$now" ]] && status=FUTURE
      detail="$msg"
      [ -z "$detail" ] && detail="denied: versions ${versions:-all}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$repo" "$tag" "$files" "$group" "${eff:--}" "$detail"
    done <<< "$rules"
  done <<< "$refs"
}

# Human-readable report for deny_rules_scan output ($1); indent in $2.
# Prints nothing for empty input. Returns 0 always; use deny_rules_count_active.
deny_rules_report() {
  local scan="$1" ind="${2:-  }" status repo tag files group eff detail
  [ -z "$scan" ] && return 0
  while IFS=$'\t' read -r status repo tag files group eff detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "ACTIVE" ]; then
      echo "${ind}✗ DENIED by EC: ${repo##*/}:${tag} (${files} file(s)) [${group}]"
    else
      echo "${ind}⚠ Will be denied from ${eff}: ${repo##*/}:${tag} (${files} file(s)) [${group}]"
    fi
    echo "${ind}    ${repo}"
    echo "${ind}    ${detail}"
  done <<< "$scan"
}

# Count ACTIVE lines in deny_rules_scan output ($1).
deny_rules_count_active() {
  printf '%s\n' "$1" | grep -c '^ACTIVE' || true
}

deny_rules_rewrite_moved() {
  local dir="${1:-.}"
  [ -n "$_DENY_RULES_FILE" ] || deny_rules_load || return 0

  local scan status repo tag files group eff detail catalog new_repo moved=0
  scan=$(deny_rules_scan "$dir") || return 0

  while IFS=$'\t' read -r status repo tag files group eff detail; do
    [ "$status" = "ACTIVE" ] || continue
    catalog=$(printf '%s' "$detail" \
      | grep -oE 'equivalent from (quay\.io/konflux-ci/[A-Za-z0-9._/-]+)' \
      | head -n1 | sed 's/^equivalent from //' | sed 's|/*$||' || true)
    [ -z "$catalog" ] && continue

    new_repo="${catalog}/${repo##*/}"     # keep the task-NAME component
    [ "$new_repo" = "$repo" ] && continue

    local f
    for f in "$dir"/.tekton/*.y*ml; do
      [ -f "$f" ] || continue
      grep -qF -- "${repo}:${tag}@" "$f" || continue
      # '|' delimiter: refs contain '/' and ':'. Repo/tag contain no '|' or regex
      # specials beyond '.', which is escaped.
      local old_esc
      old_esc=$(printf '%s' "${repo}:${tag}@" | sed 's/[.[\*^$|]/\\&/g')
      sed -i "s|${old_esc}|${new_repo}:${tag}@|g" "$f"
    done
    echo "  ↻ ${repo} -> ${new_repo}:${tag} (${files} file(s); denial message names the replacement)"
    moved=$((moved + 1))
  done <<< "$scan"

  return 0
}
