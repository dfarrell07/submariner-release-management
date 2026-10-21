#!/bin/bash
# Select the newest branch-build snapshot from a SnapshotList on stdin.
# PR retests need provenance too: an event name alone does not identify a push.
latest_component_snapshot() {
  jq -ce --arg app "$1" '
    if (.items | type) != "array" then error("invalid SnapshotList") else
      [.items[] | select(.spec.application == $app) |
       select(.metadata.labels["pac.test.appstudio.openshift.io/pull-request"] == null) |
       select(.metadata.labels["pac.test.appstudio.openshift.io/event-type"] as $event |
         $event == "push" or $event == "incoming" or
         ($event == "retest-all-comment" and
          (.metadata.labels["pac.test.appstudio.openshift.io/original-prname"] // "" | endswith("-on-push"))))] |
      sort_by(.metadata.creationTimestamp) | last // empty
    end'
}

# A full component snapshot needs finished aggregate and scenario evidence,
# including exactly one enterprise-contract result. Missing/malformed data fails.
component_tests_passed() {
  jq -e '
    def condition($kind; $reason):
      [.status.conditions[]? | select(.type == $kind)] |
      length == 1 and .[0].status == "True" and .[0].reason == $reason;
    condition("AppStudioIntegrationStatus"; "Finished") and
    condition("AppStudioTestSucceeded"; "Passed") and
    (.metadata.annotations["test.appstudio.openshift.io/status"] | fromjson |
      type == "array" and length > 0 and
      all(.[];
        (.scenario | type == "string" and length > 0) and
        (.completionTime | type == "string" and length > 0) and
        (.status == "TestPassed" or .status == "TestWarning" or .status == "BuildPLRInProgress")) and
      ([.[].scenario] | length == (unique | length)) and
      ([.[] | select(.scenario | contains("enterprise-contract"))] | length == 1))
  ' >/dev/null 2>&1
}

# Read a complete Snapshot and report its enterprise-contract result. A retained
# marker is only usable with completion evidence and a successful aggregate verdict.
ec_status_from_snapshot() {
  jq -r '
    def condition($kind; $reason):
      [.status.conditions[]? | select(.type == $kind)] |
      length == 1 and .[0].status == "True" and .[0].reason == $reason;
    . as $snapshot |
    (.metadata.annotations["test.appstudio.openshift.io/status"] // "[]" | fromjson |
      [.[] | select(.scenario | contains("enterprise-contract"))]) as $ec |
    if ($ec | length) != 1 then "no-ec-result"
    elif ($ec[0].status != "TestPassed" and $ec[0].status != "TestWarning" and
          $ec[0].status != "BuildPLRInProgress") then $ec[0].status
    elif ($snapshot | condition("AppStudioIntegrationStatus"; "Finished") and
          condition("AppStudioTestSucceeded"; "Passed")) and
         ($ec[0].completionTime | type == "string" and length > 0)
    then $ec[0].status else "not-finished" end
  ' 2>/dev/null || echo "parse-error"
}
