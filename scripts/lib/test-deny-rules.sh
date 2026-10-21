#!/bin/bash
# Tests for deny-rules.sh (EC trusted-task deny-rule scan + moved-catalog rewrite).
# Run: ./scripts/lib/test-deny-rules.sh
#
# Uses a fixture policy-data file via DENY_RULES_FILE and a frozen clock via
# DENY_RULES_NOW, so no network is touched and results do not drift with the date.
# Needs jq and yq (the same tools the library uses).
# shellcheck disable=SC1090,SC2034  # the library is sourced per-subshell via $LIB;
#                                   # DENY_RULES_FILE is read by the sourced library
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/deny-rules.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1"; echo "    got:  '$2'"; echo "    want: '$3'"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if ! grep -qF -- "$3" <<< "$2"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}

for tool in jq yq; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DENY_RULES_NOW="2026-09-28T00:00:00Z"

# ── Fixture policy-data ────────────────────────────────────────────────────────
POLICY="$TMP/policy.json"
cat > "$POLICY" <<'EOF'
{"rule_data":{"trusted_task_rules":{"deny":{
  "konflux-defaults":[
    {"pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-buildah","versions":["<0.9"]},
    {"effective_on":"2026-08-13T06:00:00Z","pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-prefetch-dependencies-oci-ta","versions":["<0.7.1"]},
    {"effective_on":"2099-01-01T00:00:00Z","pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-soonbad","versions":["<2.0"]},
    {"pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-alwaysbad"}
  ],
  "konflux-defaults-deprecated":[
    {"effective_on":"2026-09-24T00:00:00Z","message":"Tasks under konflux-vanguard are no longer trusted. Use the equivalent from quay.io/konflux-ci/tekton-catalog instead.\n","pattern":"oci://quay.io/konflux-ci/konflux-vanguard/*"},
    {"message":"Use the equivalent from quay.io/evil/elsewhere instead.","pattern":"oci://quay.io/evil-catalog/*"}
  ]
}}}}
EOF

DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"
# Build a fixture repo whose .tekton/ carries the given "repo:tag" bundle refs.
mk_repo() {  # $1=dir, rest="repo:tag" refs (one task each, in one file)
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir/.tekton"
  {
    echo "apiVersion: tekton.dev/v1"
    echo "kind: PipelineRun"
    echo "spec:"
    echo "  pipelineSpec:"
    echo "    tasks:"
    local i=0 ref
    for ref in "$@"; do
      i=$((i + 1))
      cat <<EOF
    - name: t$i
      taskRef:
        resolver: bundles
        params:
          - name: name
            value: t$i
          - name: bundle
            value: ${ref}@${DIGEST}
          - name: kind
            value: task
EOF
    done
  } > "$dir/.tekton/pipe.yaml"
}

# Run a snippet with the library sourced against the fixture policy, in a
# subshell so the library's cached state never leaks between cases.
run() { ( DENY_RULES_FILE="$POLICY"; source "$LIB"; eval "$1" ); }

echo "=== version comparison ==="
vlt() { ( source "$LIB"; _deny_ver_lt "$1" "$2" && echo lt || echo ge ); }
assert_eq "0.3 < 0.7.1"                     "$(vlt 0.3 0.7.1)"        "lt"
assert_eq "0.9 < 0.10 (numeric, not lexical)" "$(vlt 0.9 0.10)"       "lt"
assert_eq "0.10 !< 0.9"                     "$(vlt 0.10 0.9)"         "ge"
assert_eq "0.10.0-123 == 0.10.0 (suffix ignored)" "$(vlt 0.10.0-123 0.10.0)" "ge"
assert_eq "0.2 == 0.2.0 (padded)"           "$(vlt 0.2 0.2.0)"        "ge"
assert_eq "0.2.1 < 0.2.2"                   "$(vlt 0.2.1 0.2.2)"      "lt"
assert_eq "equal is not less"               "$(vlt 0.9 0.9)"          "ge"

echo ""
echo "=== scan: minimum-version rules ==="
mk_repo "$TMP/r1" \
  "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8" \
  "quay.io/konflux-ci/tekton-catalog/task-prefetch-dependencies-oci-ta:0.3" \
  "quay.io/konflux-ci/tekton-catalog/task-clamav-scan:0.3"
OUT=$(run "deny_rules_scan $TMP/r1")
assert_contains "buildah 0.8 denied (<0.9)"          "$OUT" "task-buildah	0.8"
assert_contains "prefetch 0.3 denied (<0.7.1)"       "$OUT" "task-prefetch-dependencies-oci-ta	0.3"
assert_not_contains "unlisted task not flagged"      "$OUT" "clamav-scan"
assert_eq "both are ACTIVE"                          "$(printf '%s\n' "$OUT" | grep -c '^ACTIVE')" "2"

mk_repo "$TMP/r2" \
  "quay.io/konflux-ci/tekton-catalog/task-buildah:0.10" \
  "quay.io/konflux-ci/tekton-catalog/task-buildah-remote:0.1"
OUT=$(run "deny_rules_scan $TMP/r2")
assert_eq "0.10 is not below 0.9 (no false hit)"     "$OUT" ""

echo ""
echo "=== scan: rule with no version list denies every version ==="
mk_repo "$TMP/r3" "quay.io/konflux-ci/tekton-catalog/task-alwaysbad:9.9"
OUT=$(run "deny_rules_scan $TMP/r3")
assert_contains "no-versions rule matches any tag"   "$OUT" "task-alwaysbad	9.9"
assert_contains "detail says all versions"           "$OUT" "denied: versions all"

echo ""
echo "=== scan: future-dated vs active ==="
mk_repo "$TMP/r4" "quay.io/konflux-ci/tekton-catalog/task-soonbad:1.0"
OUT=$(run "deny_rules_scan $TMP/r4")
assert_contains "future rule reported as FUTURE"     "$OUT" "FUTURE	quay.io/konflux-ci/tekton-catalog/task-soonbad"
assert_contains "effective date carried"             "$OUT" "2099-01-01T00:00:00Z"
assert_eq "FUTURE is not counted as active"          "$(run "deny_rules_count_active \"\$(deny_rules_scan $TMP/r4)\"")" "0"
OUT=$(DENY_RULES_NOW="2100-01-01T00:00:00Z" run "deny_rules_scan $TMP/r4")
assert_contains "same rule ACTIVE once its date passes" "$OUT" "ACTIVE	quay.io/konflux-ci/tekton-catalog/task-soonbad"

echo ""
echo "=== scan: wildcard rule with a message (and empty versions field) ==="
mk_repo "$TMP/r5" "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
OUT=$(run "deny_rules_scan $TMP/r5")
assert_contains "wildcard matches vanguard task"     "$OUT" "ACTIVE	quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan"
# Regression: an empty versions field once shifted every later field (tab is IFS
# whitespace), losing the effective date and message.
assert_contains "effective date not shifted"         "$OUT" "2026-09-24T00:00:00Z"
assert_contains "message survives empty versions"    "$OUT" "no longer trusted"
assert_contains "group reported"                     "$OUT" "konflux-defaults-deprecated"

echo ""
echo "=== scan: refs only in comments are ignored; file counts ==="
mk_repo "$TMP/r6" "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8"
printf '# old: quay.io/konflux-ci/tekton-catalog/task-alwaysbad:1.0@%s\n' "$DIGEST" >> "$TMP/r6/.tekton/pipe.yaml"
cp "$TMP/r6/.tekton/pipe.yaml" "$TMP/r6/.tekton/pipe-2.yaml"
OUT=$(run "deny_rules_scan $TMP/r6")
assert_not_contains "comment-only ref not flagged"   "$OUT" "alwaysbad"
assert_contains "counts files referencing the ref"   "$OUT" "0.8	2	konflux-defaults"

echo ""
echo "=== scan: edge cases ==="
rm -rf "$TMP/none"; mkdir -p "$TMP/none"
RC=0; OUT=$(run "deny_rules_scan $TMP/none") || RC=$?
assert_eq "no .tekton dir → empty, rc 0"             "$RC:$OUT" "0:"
RC=0; ( DENY_RULES_FILE="$TMP/does-not-exist"; source "$LIB"; deny_rules_load ) 2>/dev/null || RC=$?
assert_eq "unreadable DENY_RULES_FILE → rc 1"        "$RC" "1"
echo '{"rule_data":{}}' > "$TMP/nodeny.json"
RC=0; ( DENY_RULES_FILE="$TMP/nodeny.json"; source "$LIB"; deny_rules_scan "$TMP/r1" ) >/dev/null 2>&1 || RC=$?
# A file with no deny section must not silently look like "nothing denied".
assert_eq "policy without deny rules is an error, not a pass" "$([ "$RC" -ne 0 ] && echo err || echo pass)" "err"

echo ""
echo "=== report ==="
SCAN=$(run "deny_rules_scan $TMP/r5; deny_rules_scan $TMP/r4")
REP=$( ( source "$LIB"; deny_rules_report "$SCAN" "  " ) )
assert_contains "active denial headline"             "$REP" "DENIED by EC: task-rpms-signature-scan:0.2"
assert_contains "future denial headline"             "$REP" "Will be denied from 2099-01-01T00:00:00Z"
assert_contains "message shown to operator"          "$REP" "no longer trusted"
assert_eq "empty scan → empty report"                "$( ( source "$LIB"; deny_rules_report "" ) )" ""

echo ""
echo "=== rewrite_moved ==="
mk_repo "$TMP/m1" \
  "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2" \
  "quay.io/konflux-ci/tekton-catalog/task-clamav-scan:0.3"
cp "$TMP/m1/.tekton/pipe.yaml" "$TMP/m1/.tekton/pipe-b.yaml"
OUT=$(run "deny_rules_rewrite_moved $TMP/m1")
assert_contains "move reported"                      "$OUT" "konflux-vanguard/task-rpms-signature-scan -> quay.io/konflux-ci/tekton-catalog/task-rpms-signature-scan:0.2"
assert_contains "file count reported"                "$OUT" "2 file(s)"
for f in pipe.yaml pipe-b.yaml; do
  C=$(cat "$TMP/m1/.tekton/$f")
  assert_contains "$f: repointed to tekton-catalog, tag kept, digest untouched" "$C" "quay.io/konflux-ci/tekton-catalog/task-rpms-signature-scan:0.2@$DIGEST"
  assert_not_contains "$f: no vanguard ref left"     "$C" "konflux-vanguard"
  assert_contains "$f: unrelated ref untouched"      "$C" "tekton-catalog/task-clamav-scan:0.3@$DIGEST"
done
assert_eq "after rewrite the scan is clean"          "$(run "deny_rules_scan $TMP/m1")" ""
BEFORE=$(cksum "$TMP/m1/.tekton/"*.yaml)
OUT=$(run "deny_rules_rewrite_moved $TMP/m1")
assert_eq "second rewrite reports nothing"           "$OUT" ""
assert_eq "second rewrite leaves files byte-identical (idempotent)" "$(cksum "$TMP/m1/.tekton/"*.yaml)" "$BEFORE"

# A denial whose message points outside quay.io/konflux-ci/ must NOT be followed:
# policy-data cannot be allowed to redirect pipeline refs to an arbitrary registry.
mk_repo "$TMP/m2" "quay.io/evil-catalog/task-thing:1.0"
OUT=$(run "deny_rules_rewrite_moved $TMP/m2")
assert_eq "non-konflux-ci replacement is not followed" "$OUT" ""
assert_contains "ref left as-is"                     "$(cat "$TMP/m2/.tekton/pipe.yaml")" "quay.io/evil-catalog/task-thing:1.0@$DIGEST"
assert_contains "and it is still reported as denied" "$(run "deny_rules_scan $TMP/m2")" "ACTIVE"

# Version-only denials carry no replacement, so nothing is rewritten for them.
mk_repo "$TMP/m3" "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8"
OUT=$(run "deny_rules_rewrite_moved $TMP/m3")
assert_eq "minimum-version denial is not rewritten"  "$OUT" ""
assert_contains "ref unchanged"                      "$(cat "$TMP/m3/.tekton/pipe.yaml")" "task-buildah:0.8@$DIGEST"

# Reject malformed/unsupported rule data rather than silently omitting a denial.
for bad_case in wrong-group missing-pattern unsupported-version malformed-date; do
  case "$bad_case" in
    wrong-group) bad='{"deny":{"g":{}}}' ;;
    missing-pattern) bad='{"deny":{"g":[{}]}}' ;;
    unsupported-version) bad='{"deny":{"g":[{"pattern":"oci://quay.io/task","versions":[">=1"]}]}}' ;;
    malformed-date) bad='{"deny":{"g":[{"pattern":"oci://quay.io/task","effective_on":"tomorrow"}]}}' ;;
  esac
  printf '%s' "$bad" | jq '{rule_data:{trusted_task_rules:.}}' > "$TMP/bad.json"
  RC=0; (DENY_RULES_FILE="$TMP/bad.json"; source "$LIB"; deny_rules_load) >/dev/null 2>&1 || RC=$?
  assert_eq "$bad_case: rejected as unchecked" "$RC" 1
done

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "All $PASS tests passed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$FAIL/$((PASS + FAIL)) tests FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
