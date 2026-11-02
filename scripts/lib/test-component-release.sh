#!/usr/bin/env bash
# Tests for create-component-release.sh's snapshot selection and gates.
# Run: ./scripts/lib/test-component-release.sh
#
# Sources the REAL assert_bundle_rebuilt / _bundle_digest (main is guarded by
# BASH_SOURCE != $0, so sourcing runs no release flow). oc, get_step, and
# update_step are stubbed; spy files survive command-substitution subshells so
# read-only / short-circuit claims are checkable.
# shellcheck disable=SC2034  # VERSION/RELEASE_TYPE/TRACKER/SNAPSHOT_NAME are read by the sourced gate
# shellcheck disable=SC2329  # stubs are called by the sourced main
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../create-component-release.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}

# --- Spies (files, so subshell writes survive) + stubs ---
CLUSTER_SPY=$(mktemp); TRACKER_SPY=$(mktemp); WRITE_SPY=$(mktemp)
trap 'rm -f "$CLUSTER_SPY" "$TRACKER_SPY" "$WRITE_SPY"' EXIT
_GS_OUT='{}'; _GS_RC=0

# oc get snapshot <snap> -n ... -o jsonpath=... → a submariner-bundle image whose
# digest is keyed by snapshot name. snap-unrelated shares snap-stale's digest to
# model an intervening non-bundle push (new snapshot, bundle NOT rebuilt).
oc() {
  echo x >>"$CLUSTER_SPY"
  case "$3" in
    snap-rebuilt)   echo "quay.io/rh/submariner-bundle-0-99@sha256:aaaa111100000000000000000000000000000000000000000000000000000000" ;;
    snap-stale)     echo "quay.io/rh/submariner-bundle-0-99@sha256:bbbb222200000000000000000000000000000000000000000000000000000000" ;;
    snap-unrelated) echo "quay.io/rh/submariner-bundle-0-99@sha256:bbbb222200000000000000000000000000000000000000000000000000000000" ;;
    *) echo "" ;;   # unknown / garbage-collected snapshot → no image
  esac
}
get_step() { echo x >>"$TRACKER_SPY"; printf '%s' "$_GS_OUT"; return "$_GS_RC"; }
update_step() { echo x >>"$WRITE_SPY"; }   # the gate must NEVER call this

# Run the gate, capturing merged output (GATE_OUT) and exit code (GATE_RC). The
# gate's `exit 1` fires inside the command-substitution subshell; the `||` on the
# assignment catches its non-zero rc so the parent (under set -e) survives.
GATE_RC=0; GATE_OUT=""
run_gate() {
  : >"$CLUSTER_SPY"; : >"$TRACKER_SPY"
  GATE_RC=0
  GATE_OUT=$(assert_bundle_rebuilt 2>&1) || GATE_RC=$?
}

# Per-test defaults
VERSION="0.99.1"; RELEASE_TYPE="stage"; TRACKER="ACM-1"; SNAPSHOT_NAME="snap-rebuilt"

echo "=== _bundle_digest Tests ==="

assert_eq "digest extracted from image" "$(_bundle_digest snap-rebuilt submariner-bundle-0-99)" "sha256:aaaa111100000000000000000000000000000000000000000000000000000000"
assert_eq "digest empty for unknown snapshot" "$(_bundle_digest snap-gone submariner-bundle-0-99)" ""

echo ""
echo "=== assert_bundle_rebuilt Tests ==="

# 1: Rebuilt (chosen digest ≠ recorded) → pass.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-rebuilt"
run_gate
assert_eq       "rebuilt bundle → rc 0" "$GATE_RC" "0"
assert_contains "rebuilt bundle → freshness line" "$GATE_OUT" "Bundle freshness: submariner-bundle rebuilt"

# 2: Stale, same snapshot chosen and recorded → STOP.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-stale"
run_gate
assert_eq       "stale (same snapshot) → rc 1" "$GATE_RC" "1"
assert_contains "stale (same snapshot) → error" "$GATE_OUT" "Stale bundle"

# 3: Robustness — intervening UNRELATED snapshot (different name, same bundle
# digest, i.e. bundle NOT rebuilt) must still be caught, not false-pass.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-unrelated"
run_gate
assert_eq       "stale (unrelated newer snapshot) → rc 1" "$GATE_RC" "1"
assert_contains "stale (unrelated newer snapshot) → error" "$GATE_OUT" "Stale bundle"

# 4: Prod short-circuits BEFORE any cluster/tracker read (reuses stage snapshot).
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
RELEASE_TYPE="prod"; SNAPSHOT_NAME="snap-stale"
run_gate
assert_eq "prod → rc 0"               "$GATE_RC" "0"
assert_eq "prod → no cluster read"    "$(wc -c <"$CLUSTER_SPY")" "0"
assert_eq "prod → no tracker read"    "$(wc -c <"$TRACKER_SPY")" "0"
RELEASE_TYPE="stage"

# 5: No tracker → fail open, no tracker read.
TRACKER=""; SNAPSHOT_NAME="snap-stale"
run_gate
assert_eq "no tracker → rc 0"            "$GATE_RC" "0"
assert_eq "no tracker → no tracker read" "$(wc -c <"$TRACKER_SPY")" "0"
TRACKER="ACM-1"

# 6: bundleShas recorded no snapshot (data {}) → fail open with skip notice.
_GS_OUT='{"data":{}}'; _GS_RC=0
SNAPSHOT_NAME="snap-rebuilt"
run_gate
assert_eq       "no recorded snapshot → rc 0" "$GATE_RC" "0"
assert_contains "no recorded snapshot → skip notice" "$GATE_OUT" "no bundleShas snapshot recorded"

# 7: Tracker READ failure (get_step non-zero) → fail open (never conflate a Jira
# blip with staleness).
_GS_OUT=''; _GS_RC=1
run_gate
assert_eq       "tracker read failure → rc 0 (fail open)" "$GATE_RC" "0"
assert_contains "tracker read failure → skip notice" "$GATE_OUT" "no bundleShas snapshot recorded"

# 8: Chosen snapshot's bundle digest unreadable (e.g. GC'd) → fail open.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-gone"
run_gate
assert_eq       "unreadable digest → rc 0 (fail open)" "$GATE_RC" "0"
assert_contains "unreadable digest → skip notice" "$GATE_OUT" "could not read submariner-bundle digest"

# 9: Read-only across every case above — the write sentinel stayed clean.
assert_eq "gate is strictly read-only (no update_step)" "$(wc -c <"$WRITE_SPY")" "0"

assert_lacks() {
  if grep -qF -- "$3" <<< "$2"; then echo "  ✗ $1 (found: '$3')"; FAIL=$((FAIL + 1))
  else echo "  ✓ $1"; PASS=$((PASS + 1)); fi
}

# --- Fixtures: a fake oc over a snapshot list, run by the real scripts ---
FIX=$(mktemp -d)
trap 'rm -f "$CLUSTER_SPY" "$TRACKER_SPY" "$WRITE_SPY"; rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/root/releases/0.99/stage"
export OC_LOG="$FIX/oc.log" FAKE_SNAPSHOTS="$FIX/snapshots.json"
cat >"$FIX/bin/oc" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2 $3" >>"$OC_LOG"
case "$1 $2" in
  "get snapshots") cat "$FAKE_SNAPSHOTS" ;;
  "get snapshot")
    [ -z "${FAKE_OC_FAIL_GET:-}" ] || exit 1
    snap=$(jq -e --arg n "$3" '.items[] | select(.metadata.name == $n)' "$FAKE_SNAPSHOTS") || exit 1
    case "$*" in
      *jsonpath*) jq -r '.spec.components[] | select(.name | startswith("submariner-bundle")) | .containerImage' <<<"$snap" ;;
      *) echo "$snap" ;;
    esac
    ;;
  "get release") [ -z "${FAKE_RELEASED:-}" ] || echo True ;;
  "image extract")
    [ -z "${FAKE_OC_FAIL_EXTRACT:-}" ] || exit 1
    for arg in "$@"; do
      case "$arg" in --path=*) dir="${arg#--path=/manifests/:}" ;; esac
    done
    cat "$FAKE_CSV" >"${dir}submariner.clusterserviceversion.yaml"
    ;;
esac
STUB
chmod +x "$FIX/bin/oc"

R=registry.redhat.io/rhacm2
cat >"$FIX/good.csv" <<CSV
spec:
  relatedImages:
  - {name: submariner-operator, image: $R/submariner-rhel9-operator@sha256:a100000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-gateway, image: $R/submariner-gateway-rhel9@sha256:a200000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-routeagent, image: $R/submariner-route-agent-rhel9@sha256:a300000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-globalnet, image: $R/submariner-globalnet-rhel9@sha256:a400000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-lighthouse-agent, image: $R/lighthouse-agent-rhel9@sha256:a500000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-lighthouse-coredns, image: $R/lighthouse-coredns-rhel9@sha256:a600000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-nettest, image: $R/nettest-rhel9@sha256:a700000000000000000000000000000000000000000000000000000000000000}
  - {name: submariner-metrics-proxy, image: $R/nettest-rhel9@sha256:a700000000000000000000000000000000000000000000000000000000000000}
CSV
export FAKE_CSV="$FIX/good.csv"

# snaps <name:operator digest:bundle digest:test status>...: the snapshot list,
# newest first. Every other component matches the CSV.
snaps() {
  local spec n op b t i=0
  for spec in "$@"; do
    IFS=: read -r n op b t <<<"$spec"
    printf -v op '%-64s' "$op"; op="${op// /0}"
    printf -v b '%-64s' "$b"; b="${b// /0}"
    jq -n --arg n "submariner-0-99-$n" --arg ts "2026-01-01T00:00:$((50 - i))Z" \
      --arg op "$op" --arg b "$b" --arg t "$t" --arg q quay.io/rh '
      {metadata: {name: $n, creationTimestamp: $ts,
         labels: {"pac.test.appstudio.openshift.io/event-type": "push"},
         annotations: {"test.appstudio.openshift.io/status":
           ([{scenario: "enterprise-contract", status: $t, completionTime:"2026-01-01T01:00:00Z"}] | tojson)}},
       status:{conditions:[{type:"AppStudioIntegrationStatus",status:"True",reason:"Finished"},{type:"AppStudioTestSucceeded",status:"True",reason:"Passed"}]},
       spec: {application:"submariner-0-99",components: ([
         ["submariner-operator", $op], ["submariner-gateway", "a2"], ["submariner-route-agent", "a3"],
         ["submariner-globalnet", "a4"], ["lighthouse-agent", "a5"], ["lighthouse-coredns", "a6"],
         ["nettest", "a7"], ["subctl", "a8"], ["submariner-bundle", $b]]
         | map({name: "\(.[0])-0-99", containerImage: "\($q)/\(.[0])-0-99@sha256:\(.[1] + ("0" * (64 - (.[1] | length))))"}))}}'
    i=$((i + 1))
  done | jq -s '{items: .}' >"$FAKE_SNAPSHOTS"
}

VAL_RC=0; VAL_OUT=""
run_validator() {
  VAL_RC=0
  VAL_OUT=$(PATH="$FIX/bin:$PATH" "$SCRIPT_DIR/validate-bundle-images.sh" "$@" 2>&1) || VAL_RC=$?
}

echo ""
echo "=== validate-bundle-images.sh --snapshot Tests ==="

snaps snap:a1:b1:TestPassed
run_validator --snapshot submariner-0-99-snap
assert_eq "digests match → rc 0" "$VAL_RC" "0"
for edit in 's/sha256:a100000000000000000000000000000000000000000000000000000000000000/sha256:ee00000000000000000000000000000000000000000000000000000000000000/' '/submariner-gateway/d' '/metrics-proxy/s/a7/ee/' 's/@sha256:a200000000000000000000000000000000000000000000000000000000000000/:v0.99/' 'd'; do
  sed "$edit" "$FIX/good.csv" >"$FIX/variant.csv"
  FAKE_CSV="$FIX/variant.csv" run_validator --snapshot submariner-0-99-snap
  assert_eq "CSV edit '$edit' → rc 1" "$VAL_RC" "1"
done
FAKE_OC_FAIL_EXTRACT=1 run_validator --snapshot submariner-0-99-snap
assert_eq "unreadable bundle → rc 2 (retry, not mismatch)" "$VAL_RC" "2"
mkdir -p "$FIX/cache"; : >"$OC_LOG"
BUNDLE_CACHE_DIR="$FIX/cache" run_validator --snapshot submariner-0-99-snap
BUNDLE_CACHE_DIR="$FIX/cache" run_validator --snapshot submariner-0-99-snap
assert_eq "same bundle → extracted once" "$(grep -c '^image extract' "$OC_LOG")" "1"

echo ""
echo "=== create-component-release main Tests ==="

# The real main and gates, with tag lookups, tracker writes and the YAML steps
# stubbed. get_step returns the bundleShas snapshot in _BS_SNAP, if any.
GIT_ROOT="$FIX/root"
MAIN_SPY="$FIX/main.spy"
_git_ls_remote() {
  [ "$_LS_MODE" = missing ] && [ "${2##*/}" = shipyard ] || printf 'abc\t%s\n' "$3"
}
MAIN_RC=0; MAIN_OUT=""; MAIN_CALLS=""
run_main() {  # <stage|prod> [--snapshot name]
  : >"$MAIN_SPY"
  MAIN_RC=0
  MAIN_OUT=$(
    _TYPE="$1" _SNAP_ARG="${3:-}" TRACKER_LIB=/nonexistent PATH="$FIX/bin:$PATH" SCRIPTS_DIR="$SCRIPT_DIR"
    unset -f oc  # the gate tests' stub; main uses the fake oc on PATH
    parse_arguments() { VERSION=0.99.0; RELEASE_TYPE="$_TYPE"; SNAPSHOT_ARG="$_SNAP_ARG"; }
    check_prerequisites() { :; }
    find_release_tracker() { echo ACM-1; }
    update_step() { echo "update_step $3" >>"$MAIN_SPY"; }
    get_step() { jq -cn --arg s "${_BS_SNAP:-}" '{status: "complete", data: {snapshot: $s}}'; }
    generate_yaml() { echo "generate_yaml $SNAPSHOT_NAME" >>"$MAIN_SPY"; }
    validate_yaml() { :; }
    commit_changes() { :; }
    main 2>&1
  ) || MAIN_RC=$?
  MAIN_CALLS=$(cat "$MAIN_SPY")
}
stage_yaml() {  # <snapshot> <fixed issues as YAML flow>
  printf 'spec:\n  snapshot: %s\n  data:\n    releaseNotes:\n      issues:\n        fixed: %s\n      cves: []\n' \
    "$1" "$2" >"$FIX/root/releases/0.99/stage/submariner-0-99-0-stage-20260101-01.yaml"
}
stage_yaml submariner-0-99-old '[]'

_LS_MODE=missing run_main stage
assert_eq "stage, tag missing → stops before any work" "$MAIN_RC:$MAIN_CALLS" "1:"
_LS_MODE=tagged

snaps new:a1:b1:TestPassed old:a1:b1:TestPassed
run_main stage
assert_contains "newest matches → released" "$MAIN_CALLS" "generate_yaml submariner-0-99-new"
assert_contains "newest matches → no skips" "$MAIN_OUT" "Chose snapshot submariner-0-99-new (skipped 0 newer)"

snaps new:06:b1:TestPassed mid:a1:b1:TestPassed old:a1:b1:TestPassed
: >"$OC_LOG"
run_main stage
assert_contains "newest mismatches → older match released" "$MAIN_CALLS" "generate_yaml submariner-0-99-mid"
assert_contains "newest mismatches → skip reported" "$MAIN_OUT" "(skipped 1 newer)"
assert_contains "newest mismatches → skip explained" "$MAIN_OUT" \
  "    submariner-0-99-new: component digests don't match its bundle CSV"
assert_eq "auto pick → digests checked once per candidate, bundle extracted once" \
  "$(grep -c '^image extract' "$OC_LOG"):$(grep -c 'get snapshot submariner-0-99-mid' "$OC_LOG")" "1:2"

snaps new:06:b1:TestPassed mid:07:b1:TestPassed
run_main stage
assert_eq       "none match → stops, nothing generated" "$MAIN_RC:$MAIN_CALLS" "1:"
assert_contains "none match → newest candidate's validator output" "$MAIN_OUT" \
  "Newest mismatching candidate submariner-0-99-new:"
assert_contains "none match → points at the operator file filters" "$MAIN_OUT" "submariner-operator#4325"

snaps new:06:b1:TestPassed mid:a1:b1:TestPassed
FAKE_OC_FAIL_EXTRACT=1 run_main stage
assert_contains "unreadable bundle → stops to retry, never skips" "$MAIN_OUT" "re-run to retry"
snaps new:a1:b1:TestFail old:a1:b1:TestPassed
run_main stage
assert_contains "failing tests → skipped" "$MAIN_CALLS" "generate_yaml submariner-0-99-old"
snaps new:06:b2:TestPassed old:a1:b1:TestPassed
run_main stage
assert_eq       "earlier bundle build → never a fallback" "$MAIN_RC:$MAIN_CALLS" "1:"

snaps new:06:b1:TestPassed old:a1:b1:TestPassed
run_main stage --snapshot submariner-0-99-old
assert_contains "explicit match → released as given" "$MAIN_CALLS" "generate_yaml submariner-0-99-old"
run_main stage --snapshot submariner-0-99-new
assert_eq       "explicit mismatch → stops, never replaced" "$MAIN_RC:$MAIN_CALLS" "1:"
assert_contains "explicit mismatch → explains" "$MAIN_OUT" "failed the bundle digest check"

# Respin before the new bundle rebuild: newer snapshots don't match the old
# bundle, so selection falls back to the one already released. That is a stale
# bundle, not a completed step.
FAKE_RELEASED=1 _BS_SNAP=submariner-0-99-new run_main stage
assert_eq       "respin before rebuild → stops" "$MAIN_RC" "1"
assert_contains "respin before rebuild → stale bundle" "$MAIN_OUT" "Stale bundle"
assert_lacks    "respin before rebuild → step not completed" "$MAIN_CALLS" "update_step complete"

echo ""
echo "=== Prod Tests ==="

run_main prod
assert_eq       "prod, empty stage notes → stops" "$MAIN_RC:$MAIN_CALLS" "1:"
assert_contains "prod, empty stage notes → names the override" "$MAIN_OUT" "ALLOW_EMPTY_RELEASE_NOTES=true"
ALLOW_EMPTY_RELEASE_NOTES=true run_main prod
assert_contains "prod, notes override → warns" "$MAIN_OUT" "WARNING: continuing with no release notes"
assert_contains "prod, notes override → stage snapshot released" "$MAIN_CALLS" "generate_yaml submariner-0-99-old"
stage_yaml submariner-0-99-new '[{id: ACM-1, source: issues.redhat.com}]'
run_main prod
assert_eq       "prod, digest mismatch → stops" "$MAIN_RC:$MAIN_CALLS" "1:"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "All $PASS tests passed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$FAIL of $((PASS + FAIL)) tests FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
