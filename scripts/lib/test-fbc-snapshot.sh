#!/bin/bash
# Tests for fbc-snapshot.sh (fbc_catalog_bundle_digest, fbc_tests_passed).
# Run: ./scripts/lib/test-fbc-snapshot.sh
#
# fbc_catalog_bundle_digest fetches raw.githubusercontent.com; a stub `curl` on PATH
# stands in for it, so no network is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fbc-snapshot.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
# Stub curl: writes $STUB_BODY to the -o file, records the URL, prints $STUB_CODE
# (as -w '%{http_code}' would). STUB_CODE=000 simulates a network failure (exit 6).
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) echo "$1" > "$STUB_URL_FILE"; shift ;;
    *) shift ;;
  esac
done
[ "$STUB_CODE" = "000" ] && exit 6
printf '%s' "${STUB_BODY:-}" > "$out"
printf '%s' "$STUB_CODE"
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" STUB_URL_FILE="$TMP/url"

DIGEST=$(printf 'a%.0s' {1..64})
BODY=$'schema: olm.bundle\nname: submariner.v0.23.4\nimage: registry.redhat.io/rhacm2/submariner-operator-bundle@sha256:'"$DIGEST"

digest_of() { # returns "<stdout>|<rc>"
  local out rc=0
  out=$(fbc_catalog_bundle_digest "$@") || rc=$?
  echo "$out|$rc"
}

echo "=== fbc_catalog_bundle_digest Tests ==="

assert_eq "200 -> digest, rc 0" \
  "$(STUB_CODE=200 STUB_BODY="$BODY" digest_of 4-21 0.23.4)" "$DIGEST|0"
assert_eq "404 -> empty (not applicable), rc 0" \
  "$(STUB_CODE=404 digest_of 4-22 0.23.4)" "|0"
assert_eq "429 (rate limit) -> rc 1, never read as absent" \
  "$(STUB_CODE=429 digest_of 4-21 0.23.4)" "|1"
assert_eq "500 -> rc 1" \
  "$(STUB_CODE=500 digest_of 4-21 0.23.4)" "|1"
assert_eq "network failure -> rc 1" \
  "$(STUB_CODE=000 digest_of 4-21 0.23.4)" "|1"
assert_eq "200 without a sha256 image -> rc 1 (malformed)" \
  "$(STUB_CODE=200 STUB_BODY="image: quay.io/x:latest" digest_of 4-21 0.23.4)" "|1"

assert_eq "explicitly empty ref -> rc 1 (never falls back to main)" \
  "$(STUB_CODE=200 STUB_BODY="$BODY" digest_of 4-21 0.23.4 "")" "|1"

STUB_CODE=404 fbc_catalog_bundle_digest 4-21 0.23.4 >/dev/null
assert_eq "default ref is main" \
  "$(cat "$TMP/url")" \
  "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-21/bundles/bundle-v0.23.4.yaml"
REV=$(printf 'b%.0s' {1..40})
STUB_CODE=404 fbc_catalog_bundle_digest 5-0 0.24.1 "$REV" >/dev/null
assert_eq "explicit ref is used" \
  "$(cat "$TMP/url")" \
  "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/$REV/catalog-5-0/bundles/bundle-v0.24.1.yaml"

echo "=== fbc_tests_passed Tests ==="

tests_json() { # $1=standard status $2=operator status
  jq -cn --arg standard "$1" --arg operator "$2" '
    {metadata: {annotations: {"test.appstudio.openshift.io/status": ([
      {scenario: "submariner-fbc-standard-4-21", status: $standard, completionTime: "2026-10-12T12:00:00Z"},
      {scenario: "submariner-fbc-operator-4-21", status: $operator, completionTime: "2026-10-12T12:00:00Z"}
    ] | tojson)}}, status: {conditions: [
      {type: "AppStudioIntegrationStatus", status: "True", reason: "Finished"},
      {type: "AppStudioTestSucceeded", status: "True", reason: "Passed"}
    ]}}'
}
passes() { if printf '%s' "$1" | fbc_tests_passed 4-21; then echo pass; else echo reject; fi; }

assert_eq "both TestPassed" "$(passes "$(tests_json TestPassed TestPassed)")" pass
assert_eq "completed warnings accepted" "$(passes "$(tests_json TestWarning TestPassed)")" pass
assert_eq "completed retained standard marker with aggregate pass" "$(passes "$(tests_json BuildPLRInProgress TestPassed)")" pass
assert_eq "completed retained operator marker with aggregate pass" "$(passes "$(tests_json TestPassed BuildPLRInProgress)")" pass
assert_eq "TestFail rejected" "$(passes "$(tests_json TestFail TestPassed)")" reject
assert_eq "InProgress rejected" "$(passes "$(tests_json TestPassed InProgress)")" reject
assert_eq "missing scenario rejected" \
  "$(passes '[{"scenario":"submariner-fbc-operator-4-21","status":"TestPassed"}]')" reject
assert_eq "empty rejected" "$(passes '')" reject

snapshot=$(tests_json TestPassed TestPassed)
for mutation in \
  'del(.status)' \
  'del(.status.conditions[0])' \
  'del(.status.conditions[1])' \
  '.status.conditions[0].status = "False"' \
  '.status.conditions[0].reason = "InProgress"' \
  '.status.conditions[1].status = "False"' \
  '.status.conditions += [.status.conditions[1]]' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] = "invalid"' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | del(.[0].completionTime) | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | .[1].completionTime = "" | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | .[1].completionTime = 123 | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | .[0].scenario = .[1].scenario | tojson)' \
  '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | .[0].scenario = "unrelated" | tojson)'; do
  assert_eq "reject $mutation" "$(passes "$(jq -c "$mutation" <<< "$snapshot")")" reject
done
markers=$(tests_json BuildPLRInProgress BuildPLRInProgress)
markers=$(jq -c '.metadata.annotations["test.appstudio.openshift.io/status"] |= (fromjson | map(del(.completionTime)) | tojson)' <<< "$markers")
assert_eq "two unfinished markers rejected even with aggregate pass" "$(passes "$markers")" reject
assert_eq "annotation array alone cannot prove completion" \
  "$(passes "$(jq -r '.metadata.annotations["test.appstudio.openshift.io/status"]' <<< "$snapshot")")" reject

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
