#!/bin/bash
# Exercise the real status decisions and component-readiness CLI with local fixtures.
# shellcheck disable=SC2034  # Status functions consume these globals.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/integration-tests.sh"
# shellcheck disable=SC1090  # Load function definitions without running the status entrypoint.
source <(awk '/^[a-z_0-9]+\(\) \{/,/^}/' "$SCRIPT_DIR/../release-status.sh")
PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ✓ $1"
  else FAIL=$((FAIL + 1)); echo "  ✗ $1 (got: '$2', want: '$3')"; fi
}
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then PASS=$((PASS + 1)); echo "  ✓ $1"
  else FAIL=$((FAIL + 1)); echo "  ✗ $1 (missing: '$3')"; fi
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fixture=$(jq -cn '{metadata:{name:"submariner-0-99-push",creationTimestamp:"2026-10-20T12:00:00Z",
  labels:{"pac.test.appstudio.openshift.io/event-type":"push"},
  annotations:{"test.appstudio.openshift.io/status":([{scenario:"enterprise-contract",status:"TestPassed",completionTime:"2026-10-20T12:10:00Z"}]|tojson)}},
  spec:{application:"submariner-0-99",components:(["submariner-operator","submariner-gateway","submariner-globalnet","submariner-route-agent","lighthouse-agent","lighthouse-coredns","nettest","subctl","submariner-bundle"] | map({name:(.+"-0-99")}))},
  status:{conditions:[{type:"AppStudioIntegrationStatus",status:"True",reason:"Finished"},{type:"AppStudioTestSucceeded",status:"True",reason:"Passed"}]}}')
reset_status() {
  VERSION=0.99.1 MAJOR_MINOR=0.99 MAJOR_MINOR_DASH=0-99
  IS_ZSTREAM=true RELEASE_STATE=unrecorded TRACKER_KEY=FAKE-1
  BRANCH_CHECK=all BRANCH_FETCH_FAILED=0 STAGE_PLAN=stage PROD_PLAN=prod
  MISSING_TEKTON=0 TEKTON_FETCH_FAILED=0 RELEASEPLANS_LOOKUP_FAILED=false
  TAG_EXISTS=v0.99.1 TAG_FETCH_FAILED=0 WRONG_COUNT=0 FETCH_FAILED=0
  SNAPSHOT=submariner-0-99-push SNAPSHOT_JSON="$fixture" SNAPSHOT_READY=true SNAPSHOT_LOOKUP_FAILED=false
  IMAGE_VERSION=v0.99.1 IMAGE_VERSION_FETCHED=true
  STAGE_YAML='' PROD_YAML=''
  COMPONENT_STAGE_STATUS=unknown COMPONENT_PROD_STATUS=unknown
  FBC_STAGE_SCOPE='' FBC_PROD_SCOPE='' UPSTREAM_SOURCE_TAGS_COMPLETE=false
  FBC_STAGE_YAML_COUNT=0 FBC_SUCCEEDED=0 FBC_PROD_YAML_COUNT=0 FBC_PROD_SUCCEEDED=0
}
reset_status; WRONG_COUNT=2
assert_eq 'source preparation is underway before YAML creation' "$(detect_current_phase)" upstream-release
reset_status
assert_eq 'a verified candidate without stage YAML awaits component stage' "$(detect_current_phase)" component-stage
reset_status; RELEASE_STATE=stage-recorded STAGE_YAML=stage.yaml COMPONENT_STAGE_STATUS=failed
assert_eq 'failed component stage cannot advance to FBC' "$(detect_current_phase)" component-stage
reset_status; RELEASE_STATE=prod-recorded PROD_YAML=prod.yaml COMPONENT_PROD_STATUS=failed
assert_eq 'a prod YAML is not proof of shipping' "$(detect_current_phase)" component-prod
reset_status; RELEASE_STATE=prod-recorded PROD_YAML=prod.yaml COMPONENT_PROD_STATUS=succeeded
FBC_STAGE_YAML_COUNT=2 FBC_PROD_YAML_COUNT=2 FBC_PROD_SUCCEEDED=1
assert_eq 'partial FBC production is not complete' "$(detect_current_phase)" component-prod
FBC_PROD_SUCCEEDED=2
assert_eq 'verified component and FBC production is complete' "$(detect_current_phase)" complete
reset_status; RELEASE_STATE=stage-recorded STAGE_YAML=stage.yaml COMPONENT_STAGE_STATUS=succeeded SNAPSHOT_READY=false
assert_eq 'failed integration cannot advance to FBC' "$(detect_current_phase)" upstream-release
reset_status; RELEASE_STATE=stage-recorded STAGE_YAML=stage.yaml COMPONENT_STAGE_STATUS=succeeded IMAGE_VERSION=''
assert_eq 'unknown image version cannot advance to FBC' "$(detect_current_phase)" upstream-release

mkdir "$TMP/bin"
cat > "$TMP/bin/oc" <<'STUB'
#!/bin/bash
[ "$1:$2" = get:snapshots ] || exit 99
cat "$STATUS_SNAPSHOTS"
STUB
chmod +x "$TMP/bin/oc"
export STATUS_SNAPSHOTS="$TMP/snapshots.json"
run_verifier() {
  jq -n --argjson snapshot "$1" '{items:[$snapshot]}' > "$STATUS_SNAPSHOTS"
  verifier_rc=0
  verifier_output=$(PATH="$TMP/bin:$PATH" "$SCRIPT_DIR/../verify-component-release.sh" 0.99.1 2>&1) || verifier_rc=$?
}
run_verifier "$fixture"
assert_eq 'completed component integration passes the CLI' "$verifier_rc" 0
for mutation in 'del(.metadata.annotations)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"]="[]"' \
  '.metadata.annotations["test.appstudio.openshift.io/status"]="invalid"' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | map(.scenario="unit-tests") | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | . + . | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | . + [{scenario:"other",status:"TestFail",completionTime:"2026-10-20T12:00:00Z"}] | tojson)' \
  'del(.status)' \
  '.status.conditions[1].status="False"' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | map(del(.completionTime)) | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | map(.status="BuildPLRInProgress" | del(.completionTime)) | tojson)'; do
  run_verifier "$(jq "$mutation" <<< "$fixture")"
  assert_eq "component gate rejects incomplete evidence: $mutation" "$verifier_rc" 1
done
run_verifier "$(jq '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | map(.status="BuildPLRInProgress") | tojson)' <<< "$fixture")"
assert_eq 'completed retained marker remains accepted' "$verifier_rc" 0
run_verifier "$(jq '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | map(.status="TestWarning") | tojson)' <<< "$fixture")"
assert_eq 'completed warning remains accepted' "$verifier_rc" 0

# Newer PR builds and PR retests cannot displace branch builds. Ordering is by
# timestamp, and an unrelated application cannot qualify by its name alone.
pr=$(jq '.metadata.name="submariner-0-99-pr" | .metadata.creationTimestamp="2026-10-20T15:00:00Z" | .metadata.labels["pac.test.appstudio.openshift.io/event-type"]="pull_request"' <<< "$fixture")
retest=$(jq '.metadata.labels["pac.test.appstudio.openshift.io/event-type"]="retest-all-comment" | .metadata.labels["pac.test.appstudio.openshift.io/original-prname"]="operator-on-pull-request"' <<< "$pr")
newer=$(jq '.metadata.name="submariner-0-99-newer" | .metadata.creationTimestamp="2026-10-20T14:00:00Z"' <<< "$fixture")
other=$(jq '.spec.application="submariner-0-98"' <<< "$pr")
list=$(jq -cn --argjson old "$fixture" --argjson pr "$pr" --argjson retest "$retest" --argjson other "$other" --argjson newer "$newer" '{items:[$pr,$newer,$retest,$other,$old]}')
assert_eq 'selector sorts and rejects PR builds, retests and other applications' \
  "$(latest_component_snapshot submariner-0-99 <<< "$list" | jq -r '.metadata.name')" submariner-0-99-newer
bad=$(jq '.metadata.labels["pac.test.appstudio.openshift.io/pull-request"]="123"' <<< "$newer")
assert_eq 'push-like event with a PR label is excluded' \
  "$(jq -cn --argjson s "$bad" '{items:[$s]}' | latest_component_snapshot submariner-0-99 || true)" ''

# Exercise real candidate lookup against controlled transport responses.
OC_RC=0 OC_CALLS="$TMP/oc-calls" GS_RC=0 GS_DATA='{}'
oc() { echo "$*" >> "$OC_CALLS"; [ "$OC_RC" = 0 ] || return "$OC_RC"; cat "$STATUS_SNAPSHOTS"; }
get_step() { printf '%s' "$GS_DATA"; return "$GS_RC"; }
reset_status; OC_AVAILABLE=false; : > "$OC_CALLS"
load_component_snapshot
assert_eq 'unauthed lookup remains unknown' "$SNAPSHOT_LOOKUP_FAILED" true
assert_eq 'unauthed lookup makes no cluster call' "$(cat "$OC_CALLS")" ''
reset_status; OC_AVAILABLE=true; OC_RC=1
load_component_snapshot
assert_eq 'failed snapshot query remains unknown' "$SNAPSHOT_LOOKUP_FAILED" true
OC_RC=0
printf '{"items":null}\n' > "$STATUS_SNAPSHOTS"
load_component_snapshot
assert_eq 'malformed snapshot list remains unknown' "$SNAPSHOT_LOOKUP_FAILED" true
printf '{"items":[]}\n' > "$STATUS_SNAPSHOTS"
load_component_snapshot
assert_eq 'successful empty list proves absence, not lookup failure' "$SNAPSHOT_LOOKUP_FAILED:$SNAPSHOT" 'false:'
printf '%s' "$list" > "$STATUS_SNAPSHOTS"
GS_DATA='{"data":{"snapshot":"submariner-0-99-push"}}'
load_component_snapshot
assert_eq 'recorded bundle candidate wins over newer snapshots' "$SNAPSHOT" submariner-0-99-push
GS_DATA='{"data":{"snapshot":"missing-recorded-candidate"}}'
load_component_snapshot >/dev/null
assert_eq 'missing pinned candidate does not fall back' "$SNAPSHOT_LOOKUP_FAILED:$SNAPSHOT" 'true:'
GS_RC=1; GS_DATA='{}'; : > "$OC_CALLS"
load_component_snapshot
assert_eq 'failed tracker read cannot change the candidate' "$SNAPSHOT_LOOKUP_FAILED:$SNAPSHOT" 'true:'
assert_eq 'failed tracker read stops before cluster selection' "$(cat "$OC_CALLS")" ''
GS_RC=0
reset_status; OC_AVAILABLE=true; STAGE_YAML="$TMP/stage.yaml"
printf 'spec:\n  snapshot: submariner-0-99-push\n' > "$STAGE_YAML"
load_component_snapshot
assert_eq 'stage record pins the exact snapshot' "$SNAPSHOT" submariner-0-99-push
reset_status; OC_AVAILABLE=true
bad=$(jq '.status.conditions[1].status="False"' <<< "$newer")
jq -cn --argjson old "$fixture" --argjson newer "$bad" '{items:[$newer,$old]}' > "$STATUS_SNAPSHOTS"
load_component_snapshot
assert_eq 'newest failed build is reported, not replaced by older green build' "$SNAPSHOT:$SNAPSHOT_READY" 'submariner-0-99-newer:false'

# Summary text must agree with its evidence, including unavailable reads.
reset_status; WRONG_COUNT=2
summary=$(print_current_phase)
assert_contains 'summary directs review of existing version work' "$summary" 'Review existing version PRs'
assert_eq 'summary does not recut an existing tag' "$(grep -c 'Cut upstream\|Create upstream\|missing v0.99.1 tags' <<< "$summary" || true)" 0
reset_status; SNAPSHOT='' SNAPSHOT_LOOKUP_FAILED=true
assert_contains 'unavailable candidate is not reported absent' "$(print_current_phase)" 'Candidate snapshot unverified'
reset_status; FETCH_FAILED=1
assert_contains 'unknown Dockerfiles do not imply a rebuild' "$(print_current_phase)" 'Source verification unavailable'
reset_status; TAG_FETCH_FAILED=1
assert_contains 'unknown tags do not imply absence' "$(print_current_phase)" 'Source verification unavailable'
reset_status; RELEASE_STATE=prod-recorded PROD_YAML=prod.yaml COMPONENT_PROD_STATUS=succeeded
assert_eq 'unknown FBC production scope cannot prove full completion' "$(detect_current_phase)" component-prod
FBC_STAGE_SCOPE='4-20 4-21' FBC_PROD_SCOPE='4-21 4-22'
FBC_STAGE_YAML_COUNT=2 FBC_PROD_YAML_COUNT=2 FBC_PROD_SUCCEEDED=2
assert_eq 'equal-sized but different FBC scopes are incomplete' "$(detect_current_phase)" component-prod

# Failed/absent cluster reads never turn prepared YAML into successful shipping.
reset_status; OC_AVAILABLE=true; OC_RC=1
prod_bundle_shipped() { PROD_BUNDLE_VERDICT=unreachable; }
COMPONENT_PROD_STATUS=succeeded
check_component_release_status prepared prod > "$TMP/release-status"
out=$(cat "$TMP/release-status")
assert_contains 'release lookup errors remain unknown' "$out" 'cluster status unknown'
assert_eq 'failed release lookup cannot imply success' "$COMPONENT_PROD_STATUS" unknown
OC_RC=0
printf '{"status":{"conditions":[{"type":"Released","status":"False","reason":"Failed"}]}}' > "$STATUS_SNAPSHOTS"
check_component_release_status prepared prod >/dev/null
assert_eq 'failed release remains failed' "$COMPONENT_PROD_STATUS" failed
printf '{"status":{"conditions":[{"type":"Released","status":"True","reason":"Succeeded"}]}}' > "$STATUS_SNAPSHOTS"
check_component_release_status prepared prod >/dev/null
assert_eq 'successful job alone does not verify production shipping' "$COMPONENT_PROD_STATUS" unknown
prod_bundle_shipped() { PROD_BUNDLE_VERDICT=shipped; }
check_component_release_status prepared prod >/dev/null
assert_eq 'successful release plus registry evidence verifies shipping' "$COMPONENT_PROD_STATUS" succeeded
: > "$STATUS_SNAPSHOTS"
prod_bundle_shipped() { PROD_BUNDLE_VERDICT=unreachable; }
check_component_release_status archived prod >/dev/null
assert_eq 'archived release and unreachable registry remain unknown' "$COMPONENT_PROD_STATUS" unknown
prod_bundle_shipped() { PROD_BUNDLE_VERDICT=shipped; }
check_component_release_status archived prod >/dev/null
assert_eq 'archived prod release can use exact registry evidence' "$COMPONENT_PROD_STATUS" succeeded

# The real FBC status aggregator counts only confirmed success, including archived
# production releases whose exact bundle remains in the relevant operator index.
get_component_yaml_date() { echo 20261020; }
find_fbc_yaml_by_date() { echo "$TMP/fbc.yaml"; }
printf 'metadata:\n  name: fbc-release\n' > "$TMP/fbc.yaml"
prod_index_has_bundle() { echo "$INDEX_VERDICT"; }
INDEX_VERDICT=unreachable
check_fbc_release_status prod '4-20'
assert_eq 'unreachable archived FBC is unknown' "$FBC_PROD_SUCCEEDED:$FBC_PROD_UNKNOWN" '0:1'
INDEX_VERDICT=present
check_fbc_release_status prod '4-20'
assert_eq 'exact production index entry verifies archived FBC' "$FBC_PROD_SUCCEEDED:$FBC_PROD_UNKNOWN" '1:0'
OC_RC=1 INDEX_VERDICT=unreachable
check_fbc_release_status prod '4-20'
assert_eq 'failed FBC API read remains unknown' "$FBC_PROD_SUCCEEDED:$FBC_PROD_UNKNOWN" '0:1'

OC_RC=0 INDEX_VERDICT=absent
printf '{"status":{"conditions":[{"type":"Released","status":"True","reason":"Succeeded"}]}}' > "$STATUS_SNAPSHOTS"
check_fbc_release_status prod '4-20'
assert_eq 'successful FBC job cannot hide an absent production index entry' "$FBC_PROD_SUCCEEDED:$FBC_PROD_NOT_APPLIED" '0:1'

OC_AVAILABLE=false INDEX_VERDICT=present
check_component_release_status archived prod >/dev/null
assert_eq 'registry can verify component shipping without cluster access' "$COMPONENT_PROD_STATUS" succeeded
check_fbc_release_status prod '4-20'
assert_eq 'registry can verify FBC shipping without cluster access' "$FBC_PROD_SUCCEEDED" 1

reset_status; IS_ZSTREAM=false BRANCH_CHECK='' BRANCH_FETCH_FAILED=1
assert_contains 'Y-stream unavailable branches do not imply creation' "$(print_current_phase)" 'verification unavailable'
reset_status; IS_ZSTREAM=false OC_AVAILABLE=false STAGE_PLAN='' PROD_PLAN=''
assert_contains 'Y-stream unavailable plans do not imply missing configuration' "$(print_current_phase)" 'verify deployed ReleasePlans'
reset_status; IS_ZSTREAM=false MISSING_TEKTON=5 TEKTON_FETCH_FAILED=2
assert_contains 'Y-stream unavailable Tekton does not imply repair' "$(print_current_phase)" 'Tekton configuration unverified'
reset_status
SNAPSHOT_JSON=$(jq 'del(.status)' <<< "$fixture")
assert_contains 'unfinished EC is not reported as a policy violation' "$(check_step_4)" 'EC unverified or unfinished'

reset_status; UPSTREAM_SOURCE_TAGS_COMPLETE=true
stale_fixture='{"steps":{"cveFixes":{"title":"CVE fixes","freshness":"stale","stepData":{"status":"complete"}}}}'
assert_eq 'tagged completed CVE work uses the actual Jira summary schema' "$(stale_step_titles <<< "$stale_fixture")" ''
UPSTREAM_SOURCE_TAGS_COMPLETE=false
assert_eq 'unverified upstream source still shows age advisory' "$(stale_step_titles <<< "$stale_fixture")" 'CVE fixes'
COMPONENT_PROD_STATUS=succeeded
stale_fixture=$(jq '.steps.rpmLockfiles={title:"RPM",freshness:"stale",stepData:{status:"complete"}} | .steps.ecFixes={title:"EC",freshness:"stale",stepData:{status:"complete"}}' <<< "$stale_fixture")
assert_eq 'delivered source age does not hide snapshot-dependent warnings' "$(stale_step_titles <<< "$stale_fixture")" EC
stale_fixture=$(jq '.steps.cveFixes.stepData.status="in_progress"' <<< "$stale_fixture")
assert_contains 'incomplete source work remains visible' "$(stale_step_titles <<< "$stale_fixture")" 'CVE fixes'
reset_status; STAGE_YAML=stage.yaml
assert_contains 'recorded releases do not suggest reverting current branch versions' "$(check_step_5b)" 'current branch versions may have advanced'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
