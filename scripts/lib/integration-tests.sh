#!/bin/bash
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
