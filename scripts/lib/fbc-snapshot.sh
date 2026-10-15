#!/bin/bash
# Read a complete Snapshot from stdin. Require finished aggregate conditions and
# completed results for both configured scenarios. Retained BuildPLRInProgress
# markers are only usable with completion evidence and a successful aggregate verdict.
fbc_tests_passed() {
  local version="$1"
  jq -e --arg standard "submariner-fbc-standard-$version" --arg operator "submariner-fbc-operator-$version" '
    def nonempty_string: type == "string" and length > 0;
    def condition($kind; $reason):
      [.status.conditions[]? | select(.type == $kind)] |
      length == 1 and .[0].status == "True" and .[0].reason == $reason;
    type == "object" and
    condition("AppStudioIntegrationStatus"; "Finished") and
    condition("AppStudioTestSucceeded"; "Passed") and
    (.metadata.annotations["test.appstudio.openshift.io/status"] | fromjson |
      type == "array" and length >= 2 and
      all(.[];
        (.scenario | nonempty_string) and
        (.completionTime | nonempty_string) and
        (.status == "TestPassed" or .status == "TestWarning" or .status == "BuildPLRInProgress")) and
      ([.[].scenario] | length == (unique | length)) and
      any(.[]; .scenario == $standard) and any(.[]; .scenario == $operator))
  ' >/dev/null 2>&1
}

# Bundle digest that catalog-<ocp> lists for bundle-v<version> at <ref> (default: main).
# Prints the 64-hex digest. Prints nothing and returns 0 on HTTP 404 (the bundle is not in
# this catalog, so the OCP version does not apply). Returns 1 on any other failure, so a
# transient error is never read as "absent".
# Args: $1=ocp (e.g. 4-21) $2=version (X.Y.Z) $3=ref (branch or 40-hex commit; omit for main)
fbc_catalog_bundle_digest() {
  local ocp="$1" version="$2" ref="${3-main}" file code digest
  [ -n "$ref" ] || return 1   # an empty ref must not silently mean main
  file=$(mktemp) || return 1
  code=$(curl -s --connect-timeout 10 --max-time 30 -o "$file" -w '%{http_code}' \
    "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/${ref}/catalog-${ocp}/bundles/bundle-v${version}.yaml") || code=000
  case "$code" in
    200)
      digest=$(grep "^image:" "$file" | head -1 | grep -oP 'sha256:\K[a-f0-9]{64}' || true)
      rm -f "$file"
      [ -n "$digest" ] || return 1
      echo "$digest" ;;
    404) rm -f "$file" ;;
    *) rm -f "$file"; return 1 ;;
  esac
}

# Event names alone cannot establish main-branch provenance: retests can be PRs.
declare -A _FBC_MERGED_REVISIONS=()
fbc_revision_on_main() {
  local revision="$1" comparison
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "${_FBC_MERGED_REVISIONS[$revision]:-}" != yes ] || return 0
  # Authenticate when possible to avoid the anonymous rate limit. The header goes
  # through curl's stdin config so the token stays out of the process list.
  local token="${GITHUB_TOKEN:-}"
  if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
    token=$(gh auth token 2>/dev/null || true)
  fi
  comparison=$(printf '%s\n' "${token:+header = \"Authorization: Bearer $token\"}" |
    curl --config - -fsS --connect-timeout 10 --max-time 30 \
      "https://api.github.com/repos/stolostron/submariner-operator-fbc/compare/${revision}...main?per_page=1") || return 1
  jq -e --arg revision "$revision" '
    .base_commit.sha == $revision and .merge_base_commit.sha == $revision and
    (.status == "ahead" or .status == "identical")
  ' <<< "$comparison" >/dev/null || return 1
  _FBC_MERGED_REVISIONS[$revision]=yes
}
