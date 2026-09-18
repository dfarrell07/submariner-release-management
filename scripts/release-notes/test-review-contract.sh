#!/bin/bash
# Offline tests for the host-neutral release-note review contract.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REVIEW_SCRIPT="$SCRIPT_DIR/review.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

while IFS= read -r git_env; do
  unset "$git_env"
done < <(git rev-parse --local-env-vars)

PASS=0
FAIL=0

pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label=$1 actual=$2 expected=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (got '$actual', expected '$expected')"
  fi
}

assert_contains() {
  local label=$1 text=$2 expected=$3
  if [[ "$text" == *"$expected"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$expected')"
  fi
}

make_tools() {
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/acli" <<'EOF'
#!/bin/bash
if [[ " $* " == *" workitem search "* ]]; then
  echo '[]'
  exit 0
fi
cat <<JSON
{
  "fields": {
    "summary": "Fix gateway reconnect handling",
    "status": {"name": "Resolved"},
    "resolution": {"name": "Done"},
    "components": [{"name": "Multicluster Networking"}],
    "labels": [],
    "fixVersions": [],
    "issuelinks": [],
    "description": {"type": "doc", "content": [{"type": "text", "text": "Reconnect gateway after transient failure"}]},
    "comment": {"comments": []}
  }
}
JSON
EOF
  cat > "$bin/gh" <<'EOF'
#!/bin/bash
if [[ ${1:-} == search ]]; then
  echo '[]'
else
  echo '{}'
fi
EOF
  chmod +x "$bin/acli" "$bin/gh"
}

new_fixture() {
  local name=$1
  shift
  local root="$TEST_ROOT/$name/repo"
  local stage="$root/releases/0.23/stage/submariner-0-23-1-stage-test.yaml"
  local data="$TEST_ROOT/$name/data.json"
  local tools="$TEST_ROOT/$name/bin"
  local home="$TEST_ROOT/$name/home"
  local tmp="$TEST_ROOT/$name/tmp"
  mkdir -p "$(dirname "$stage")" "$home" "$tmp"
  make_tools "$tools"

  {
    echo 'apiVersion: appstudio.redhat.com/v1alpha1'
    echo 'kind: Release'
    echo 'spec:'
    echo '  data:'
    echo '    releaseNotes:'
    echo '      issues:'
    if [[ $# -eq 0 ]]; then
      echo '        fixed: []'
    else
      echo '        fixed:'
    fi
    local key
    for key in "$@"; do
      printf '          - id: %s\n' "$key"
    done
  } > "$stage"

  jq -n \
    --arg version 0.23.1 \
    --arg stage_yaml "$stage" \
    '{metadata:{version:$version, stage_yaml:$stage_yaml},
      cve_issues:[{issue_key:"ACM-100"}]}' > "$data"

  git init -q -b main "$root"
  git -C "$root" config user.name 'Release Review Test'
  git -C "$root" config user.email test@example.invalid
  git -C "$root" config core.hooksPath /dev/null
  git -C "$root" config commit.gpgsign false
  git -C "$root" add -A
  git -C "$root" commit -qm base

  printf '%s\t%s\t%s\t%s\t%s\n' "$root" "$stage" "$data" "$tools" "$tmp"
}

prepare_run() {
  local root=$1 stage=$2 data=$3 tools=$4 tmp=$5
  local legacy=${6:-false}
  local output run_dir
  local -a mode=(prepare)
  [[ "$legacy" == false ]] || mode=()
  output=$(cd "$root" && \
    HOME="$TEST_ROOT/fake-home" \
    PATH="$tools:$PATH" \
    TMPDIR="$tmp" \
    RELEASE_NOTES_DATA="$data" \
    "$REVIEW_SCRIPT" "${mode[@]}" 0.23.1 --stage-yaml "$stage")
  run_dir=$(sed -n 's/^REVIEW_RUN_DIR=//p' <<< "$output")
  [[ -n "$run_dir" && -f "$run_dir/manifest.json" ]] || {
    echo "prepare failed to report a valid run directory: $output" >&2
    return 1
  }
  printf '%s\n' "$run_dir"
}

write_decision() {
  local run_dir=$1 key=$2 decision=$3 reason=$4 recorded_key=${5:-$2}
  jq -n \
    --arg issue_key "$recorded_key" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    '{issue_key:$issue_key, decision:$decision, reason:$reason}' \
    > "$run_dir/decisions/$key.json"
}

issue_count() {
  local stage=$1 key=$2
  ISSUE_KEY="$key" yq eval \
    '[.spec.data.releaseNotes.issues.fixed[]? | select(.id == strenv(ISSUE_KEY))] | length' \
    "$stage"
}

echo "=== Prepare contract ==="
IFS=$'\t' read -r repo stage data tools tmp < <(
  new_fixture 'mixed path' ACM-100 ACM-200 ACM-300 ACM-400 ACM-500 ACM-600
)
run_dir=$(prepare_run "$repo" "$stage" "$data" "$tools" "$tmp")
assert_eq 'manifest contains only non-CVE issues' \
  "$(jq -r '[.issues[].key] | join(",")' "$run_dir/manifest.json")" \
  'ACM-200,ACM-300,ACM-400,ACM-500,ACM-600'
assert_eq 'manifest uses the current contract schema' \
  "$(jq -r '.schema' "$run_dir/manifest.json")" 2
assert_eq 'manifest records excluded CVE' \
  "$(jq -r '.excluded_cve_keys | join(",")' "$run_dir/manifest.json")" ACM-100
assert_eq 'manifest records complete prepared issue set' \
  "$(jq -r '.stage_issue_keys | join(",")' "$run_dir/manifest.json")" \
  'ACM-100,ACM-200,ACM-300,ACM-400,ACM-500,ACM-600'
assert_eq 'one evidence bundle per review issue' \
  "$(find "$run_dir/bundles" -type f -name '*.md' | wc -l)" 5
if rg -q 'Pre-fetched Evidence for ACM-200' "$run_dir/bundles/ACM-200.md" && \
  rg -q '"decision": "KEEP"' "$run_dir/bundles/ACM-200.md"; then
  pass 'bundle contains evidence and decision contract'
else
  fail 'bundle contains evidence and decision contract'
fi

echo
echo "=== Fail-safe apply and resume ==="
write_decision "$run_dir" ACM-200 KEEP 'Relevant implementation evidence found'
write_decision "$run_dir" ACM-300 REMOVE 'No shipped Submariner implementation found'
write_decision "$run_dir" ACM-400 KEEP 'Key mismatch must fail' ACM-999
printf '{bad json\n' > "$run_dir/decisions/ACM-500.json"

apply_rc=0
apply_output=$(PATH="$tools:$PATH" "$REVIEW_SCRIPT" apply "$run_dir" 2>&1) || apply_rc=$?
assert_eq 'incomplete apply returns nonzero' "$apply_rc" 1
assert_contains 'summary counts all outcomes' "$apply_output" \
  'Results: 1 kept, 1 removed, 2 failed, 1 unreviewed'
assert_eq 'valid removal applied' "$(issue_count "$stage" ACM-300)" 0
for key in ACM-100 ACM-200 ACM-400 ACM-500 ACM-600; do
  assert_eq "$key retained on first apply" "$(issue_count "$stage" "$key")" 1
done
assert_eq 'one removal commit created' \
  "$(git -C "$repo" log --format=%s --grep='^Remove ACM-' | wc -l)" 1
assert_eq 'repository clean after partial apply' \
  "$(git -C "$repo" status --porcelain --untracked-files=all)" ''

write_decision "$run_dir" ACM-400 KEEP 'Relevant documentation evidence found'
write_decision "$run_dir" ACM-500 KEEP 'Uncertain evidence defaults to inclusion'
write_decision "$run_dir" ACM-600 REMOVE 'Only unrelated addon work was found'
apply_output=$(PATH="$tools:$PATH" "$REVIEW_SCRIPT" apply "$run_dir" 2>&1)
assert_contains 'resume skips completed result' "$apply_output" 'KEEP ACM-200 (already applied)'
assert_contains 'resume completes remaining decisions' "$apply_output" \
  'Results: 3 kept, 2 removed, 0 failed, 0 unreviewed'
assert_eq 'second valid removal applied' "$(issue_count "$stage" ACM-600)" 0
assert_eq 'one commit per removal' \
  "$(git -C "$repo" log --format=%s --grep='^Remove ACM-' | wc -l)" 2
assert_eq 'CVE remains after all decisions' "$(issue_count "$stage" ACM-100)" 1
if git -C "$repo" log -2 --format=%B | grep -q \
  '^Signed-off-by: Release Review Test <test@example.invalid>$'; then
  pass 'removal commits are signed off'
else
  fail 'removal commits are signed off'
fi

echo
echo "=== Interrupted-result recovery ==="
rm "$run_dir/results/ACM-600.json"
recovery_output=$(PATH="$tools:$PATH" "$REVIEW_SCRIPT" apply "$run_dir" 2>&1)
assert_contains 'committed removal recovered' "$recovery_output" 'REMOVE ACM-600 (recovered commit'
assert_eq 'recovery does not duplicate commit' \
  "$(git -C "$repo" log --format=%s --grep='^Remove ACM-' | wc -l)" 2
assert_eq 'recovery rewrites result' \
  "$(jq -r '.decision' "$run_dir/results/ACM-600.json")" REMOVE

write_decision "$run_dir" ACM-200 REMOVE 'Tampered stale result'
jq --arg commit "$(git -C "$repo" rev-parse HEAD)" \
  '. + {commit:$commit}' "$run_dir/decisions/ACM-200.json" \
  > "$run_dir/results/ACM-200.json"
consistency_rc=0
consistency_output=$(PATH="$tools:$PATH" "$REVIEW_SCRIPT" apply "$run_dir" 2>&1) || consistency_rc=$?
assert_eq 'stale result fails closed' "$consistency_rc" 1
assert_contains 'stale result identifies YAML disagreement' "$consistency_output" \
  'REMOVE result for ACM-200 disagrees with the stage YAML'

echo
echo "=== Concurrent run isolation ==="
IFS=$'\t' read -r repo2 stage2 data2 tools2 tmp2 < <(
  new_fixture concurrent ACM-100 ACM-700
)
run_a=$(prepare_run "$repo2" "$stage2" "$data2" "$tools2" "$tmp2")
run_b=$(prepare_run "$repo2" "$stage2" "$data2" "$tools2" "$tmp2" true)
if [[ "$run_a" != "$run_b" ]]; then
  pass 'concurrent preparations use unique directories'
else
  fail 'concurrent preparations use unique directories'
fi
assert_eq 'first run has isolated bundle' \
  "$(jq -r '.issues[0].key' "$run_a/manifest.json")" ACM-700
assert_eq 'second run has isolated bundle' \
  "$(jq -r '.issues[0].key' "$run_b/manifest.json")" ACM-700
if [[ -f "$run_b/manifest.json" ]]; then
  pass 'legacy review.sh VERSION invocation prepares a run'
else
  fail 'legacy review.sh VERSION invocation prepares a run'
fi

echo
echo "=== No-review terminal result ==="
IFS=$'\t' read -r repo_none stage_none data_none tools_none tmp_none < <(
  new_fixture no-issues
)
none_output=$(cd "$repo_none" && \
  PATH="$tools_none:$PATH" TMPDIR="$tmp_none" RELEASE_NOTES_DATA="$data_none" \
  "$REVIEW_SCRIPT" prepare 0.23.1 --stage-yaml "$stage_none")
assert_contains 'empty issue list returns explicit terminal status' "$none_output" \
  'REVIEW_STATUS=no-reviewable-issues'

IFS=$'\t' read -r repo_cves stage_cves data_cves tools_cves tmp_cves < <(
  new_fixture all-cves ACM-100
)
cves_output=$(cd "$repo_cves" && \
  PATH="$tools_cves:$PATH" TMPDIR="$tmp_cves" RELEASE_NOTES_DATA="$data_cves" \
  "$REVIEW_SCRIPT" prepare 0.23.1 --stage-yaml "$stage_cves")
assert_contains 'all-CVE issue list returns explicit terminal status' "$cves_output" \
  'REVIEW_STATUS=no-reviewable-issues'
assert_eq 'no-review result does not emit a run directory' \
  "$(grep -c '^REVIEW_RUN_DIR=' <<< "$cves_output" || true)" 0

echo
echo "=== Stage drift rejection ==="
IFS=$'\t' read -r repo_drift stage_drift data_drift tools_drift tmp_drift < <(
  new_fixture added-issue-drift ACM-100 ACM-710
)
drift_run=$(prepare_run "$repo_drift" "$stage_drift" "$data_drift" "$tools_drift" "$tmp_drift")
ISSUE_KEY=ACM-711 yq eval -i \
  '.spec.data.releaseNotes.issues.fixed += [{"id": strenv(ISSUE_KEY)}]' "$stage_drift"
git -C "$repo_drift" add -- "$stage_drift"
git -C "$repo_drift" commit -qm 'add issue after review preparation'
drift_rc=0
drift_output=$(PATH="$tools_drift:$PATH" "$REVIEW_SCRIPT" apply "$drift_run" 2>&1) || drift_rc=$?
assert_eq 'issue added after preparation rejects apply' "$drift_rc" 1
assert_contains 'added issue drift has explicit error' "$drift_output" \
  'Stage YAML contains issue added after review preparation: ACM-711'

IFS=$'\t' read -r repo_cve_drift stage_cve_drift data_cve_drift tools_cve_drift tmp_cve_drift < <(
  new_fixture cve-drift ACM-100 ACM-720
)
cve_drift_run=$(prepare_run \
  "$repo_cve_drift" "$stage_cve_drift" "$data_cve_drift" "$tools_cve_drift" "$tmp_cve_drift")
ISSUE_KEY=ACM-100 yq eval -i \
  'del(.spec.data.releaseNotes.issues.fixed[] | select(.id == strenv(ISSUE_KEY)))' \
  "$stage_cve_drift"
git -C "$repo_cve_drift" add -- "$stage_cve_drift"
git -C "$repo_cve_drift" commit -qm 'remove CVE after review preparation'
cve_drift_rc=0
cve_drift_output=$(PATH="$tools_cve_drift:$PATH" \
  "$REVIEW_SCRIPT" apply "$cve_drift_run" 2>&1) || cve_drift_rc=$?
assert_eq 'excluded CVE removed after preparation rejects apply' "$cve_drift_rc" 1
assert_contains 'missing excluded CVE has explicit error' "$cve_drift_output" \
  'Excluded CVE issue is missing from the stage YAML: ACM-100'

echo
echo "=== Corrupt input and manifest rejection ==="
IFS=$'\t' read -r repo3 stage3 data3 tools3 tmp3 < <(
  new_fixture corrupt-data ACM-100 ACM-800
)
jq '.cve_issues = "not-an-array"' "$data3" > "$data3.tmp"
mv "$data3.tmp" "$data3"
corrupt_rc=0
corrupt_output=$(cd "$repo3" && \
  PATH="$tools3:$PATH" TMPDIR="$tmp3" RELEASE_NOTES_DATA="$data3" \
  "$REVIEW_SCRIPT" prepare 0.23.1 --stage-yaml "$stage3" 2>&1) || corrupt_rc=$?
assert_eq 'invalid CVE exclusion data fails preparation' "$corrupt_rc" 1
assert_contains 'invalid CVE data has explicit error' "$corrupt_output" \
  'Invalid review data or CVE exclusion list'

IFS=$'\t' read -r repo_cache stage_cache data_cache tools_cache tmp_cache < <(
  new_fixture wrong-stage-cache ACM-100 ACM-810
)
jq '.metadata.stage_yaml = (.metadata.stage_yaml + ".other")' \
  "$data_cache" > "$data_cache.tmp"
mv "$data_cache.tmp" "$data_cache"
cache_run=$(prepare_run "$repo_cache" "$stage_cache" "$data_cache" "$tools_cache" "$tmp_cache")
assert_eq 'same-version cache is rebound to selected stage' \
  "$(jq -r '.metadata.stage_yaml' "$data_cache")" "$stage_cache"
assert_eq 'wrong-stage CVE cache is not trusted' \
  "$(jq -r '[.issues[].key] | join(",")' "$cache_run/manifest.json")" \
  'ACM-100,ACM-810'

IFS=$'\t' read -r repo4 stage4 data4 tools4 tmp4 < <(
  new_fixture unsafe-manifest ACM-100 ACM-900
)
unsafe_run=$(prepare_run "$repo4" "$stage4" "$data4" "$tools4" "$tmp4")
jq '.stage_relative = "../outside.yaml" |
    .stage_yaml = (.repo_root + "/../outside.yaml")' \
  "$unsafe_run/manifest.json" > "$unsafe_run/manifest.tmp"
mv "$unsafe_run/manifest.tmp" "$unsafe_run/manifest.json"
unsafe_rc=0
unsafe_output=$(PATH="$tools4:$PATH" "$REVIEW_SCRIPT" apply "$unsafe_run" 2>&1) || unsafe_rc=$?
assert_eq 'unsafe manifest path rejected' "$unsafe_rc" 1
assert_contains 'unsafe path has explicit error' "$unsafe_output" 'Manifest stage path is unsafe'

IFS=$'\t' read -r repo_partition stage_partition data_partition tools_partition tmp_partition < <(
  new_fixture incomplete-manifest ACM-100 ACM-925
)
partition_run=$(prepare_run \
  "$repo_partition" "$stage_partition" "$data_partition" "$tools_partition" "$tmp_partition")
jq 'del(.stage_issue_keys[] | select(. == "ACM-925"))' \
  "$partition_run/manifest.json" > "$partition_run/manifest.tmp"
mv "$partition_run/manifest.tmp" "$partition_run/manifest.json"
partition_rc=0
partition_output=$(PATH="$tools_partition:$PATH" \
  "$REVIEW_SCRIPT" apply "$partition_run" 2>&1) || partition_rc=$?
assert_eq 'incomplete manifest issue partition rejected' "$partition_rc" 1
assert_contains 'incomplete partition has explicit error' "$partition_output" \
  'Invalid review manifest'

IFS=$'\t' read -r repo5 stage5 data5 tools5 tmp5 < <(
  new_fixture missing-bundle ACM-100 ACM-950
)
missing_run=$(prepare_run "$repo5" "$stage5" "$data5" "$tools5" "$tmp5")
write_decision "$missing_run" ACM-950 REMOVE 'Decision must not apply without its evidence'
rm "$missing_run/bundles/ACM-950.md"
missing_rc=0
missing_output=$(PATH="$tools5:$PATH" "$REVIEW_SCRIPT" apply "$missing_run" 2>&1) || missing_rc=$?
assert_eq 'missing evidence bundle rejects apply' "$missing_rc" 1
assert_contains 'missing evidence has explicit error' "$missing_output" \
  'Evidence bundle missing or unsafe for ACM-950'

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
