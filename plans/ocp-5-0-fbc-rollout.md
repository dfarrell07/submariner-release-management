<!-- markdownlint-disable MD013 -->

# OCP 5 release gate handoff

[ACM-48092 — onboarding automation](https://redhat.atlassian.net/browse/ACM-48092), [ACM-48200 — catalog delivery](https://redhat.atlassian.net/browse/ACM-48200) and [OPGM-364 — lifecycle publication](https://redhat.atlassian.net/browse/OPGM-364) own delivery scope. The [onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md) owns commands and verification; this note retains the unresolved cross-PR gate.

## Decision before stage

[Runbook #119](https://github.com/stolostron/submariner-release-management/pull/119) requires `verify-live` to pass before stage while describing an expected pre-GA operator TestFail and later QE installation. [Helper #120](https://github.com/stolostron/submariner-release-management/pull/120)'s `snapshot_tests_complete` and main's `fbc_tests_passed` reject completed TestFail, including optional scenarios with Finished/Passed aggregates.

Agree where installation happens and which scenario evidence permits stage; reconcile both PRs with the canonical workflow while preserving failure checks. A skipped installation is not runtime qualification. #119 also edits this document: reconcile the overlap before merge. Its proposed sequence remains blocked by this contradiction.

## Existing changes to reuse

Continue tenant/admission MR !23786, [FBC pipelines #82](https://github.com/stolostron/submariner-operator-fbc/pull/82) and helper #120; verify current heads, approvals and builds before using them. For `deploy-fbc-operator` 0.3 installation, track pending [openshift/release #87176](https://github.com/openshift/release/pull/87176) for `aws-konflux-prod` access. That prerequisite does not resolve the pre-GA gate.

OPGM-364 requires release of existing lifecycle data and published v5.0 membership or its permitted team IIB/catalog proof, without new OCP 5 compatibility statements. Keep that acceptance distinct from ACM-48200's installation, production-index and default-scope criteria. Execute the canonical rollout after resolving the gate.
