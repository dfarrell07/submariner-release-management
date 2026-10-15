<!-- markdownlint-disable MD013 -->

# OCP 5 release gate handoff

Daniel owns [ACM-48092 — onboarding automation](https://redhat.atlassian.net/browse/ACM-48092), [ACM-48200 — catalog delivery](https://redhat.atlassian.net/browse/ACM-48200) and [OPGM-364 — lifecycle publication](https://redhat.atlassian.net/browse/OPGM-364), checked October 15, 2026. Their Jira criteria own delivery scope. The [onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md) owns commands and verification; this note retains the unresolved cross-PR gate.

## Decision before stage

[Runbook #119](https://github.com/stolostron/submariner-release-management/pull/119) requires `verify-live` to pass before stage while describing an expected pre-GA operator TestFail and later QE installation. [Helper fixes #120](https://github.com/stolostron/submariner-release-management/pull/120)'s `snapshot_tests_complete` and main's `fbc_tests_passed` reject completed TestFail, including optional scenarios with Finished/Passed aggregates.

Reconcile where installation happens and which scenario evidence is required before stage across both PRs. Preserve the existing failure checks while agreeing a supported path. A skipped installation is not runtime qualification. #119 edits this same document; reconcile that overlap before merging. The proposed runbook is not executable until the contradiction is resolved.

## Existing changes to reuse

Reuse tenant/admission MR !23786 and [FBC pipelines #82](https://github.com/stolostron/submariner-operator-fbc/pull/82). Review generation, approvals, builds and reconciliation through those existing repositories and the canonical workflow; their mutable heads and check results belong with the changes.

OPGM-364 requires release of existing lifecycle data and published v5.0 membership or its permitted team IIB/catalog proof, without new OCP 5 compatibility statements. Keep that acceptance distinct from ACM-48200's installation, production-index and default-scope criteria. Follow the canonical workflow once the gate decision is resolved.
