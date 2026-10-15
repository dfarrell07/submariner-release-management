<!-- markdownlint-disable MD013 -->

# OCP 5.0 FBC rollout plan

Tracking refreshed October 15, 2026: [ACM-48200](https://redhat.atlassian.net/browse/ACM-48200) owns catalog delivery; [ACM-48092](https://redhat.atlassian.net/browse/ACM-48092) owns reusable onboarding automation. Both are assigned to the maintainer and In Progress. The [canonical workflow](../.agents/workflows/add-fbc-ocp-version.md) owns reusable commands; [PR #119](https://github.com/stolostron/submariner-release-management/pull/119) proposes a phased runbook. Review it with [#120](https://github.com/stolostron/submariner-release-management/pull/120); neither is merged. #119 edits this same plan; reconcile its runbook against the gate correction below before merging. The four superseded preparation documents are retired here as in #119.

The [retained earlier rollout](https://github.com/stolostron/submariner-release-management/blob/3dd4626065d2f1036606e20692ef7784288c28ce/plans/ocp-5-0-fbc-rollout.md) preserves source-level investigation and dated task/index observations. Its DNS failures, missing registry binding, task-pin deadlines and proposed story creation are not a current execution queue.

## Evidence and current boundaries

| Area | Verified state and next gate |
| --- | --- |
| Catalog | FBC #81 merged. Provisional 0.24 catalog contains 0.24.0/0.24.1, channel stable-0.24. Jira/PRs now record ACM 2.17 alignment; packaging does not establish OCP 5 runtime acceptance |
| Pipelines | [FBC #82](https://github.com/stolostron/submariner-operator-fbc/pull/82) is draft at `cc76c0dd`; Actions/DCO pass, Konflux fails at missing build account. Its description now links the actual tenant MR and removes the non-expiring-pin claim |
| Configuration | Existing tenant/admission MR !23786 remains at `1ffa5b06` with an 18-file delta. Latest main `f1613839` merges with it without Git conflicts; regeneration, approvals/CI and live reconciliation remain unverified. Reuse this MR |
| Live state | Earlier October 15 reads found no 5-0 Application, Component or build account. A later read returned Unauthorized; no new absence/reconciliation claim follows from it |
| Registry | The October 12 recovery restored access for the existing 4.x scenarios. Preserve the established binding; the old secret-link command is not pending work without current evidence |
| Trust | Current PR/Jira text says policy uses trusted task version rules. Acceptable-bundle digest expiry alone is not proof of a release deadline; verify the policy actually resolved by the selected build/release, including deny rules |
| Scope | Main still defaults to OCP 4.16–4.22. Activate 5.0 only after its accepted delivery/publication gates |

## 1. Refresh and reconcile configuration

Review the existing MR against current release-data main and current CODEOWNERS. Its tenant resources provision the build account through Component reconciliation; admission entries serve later release matching. Confirm generated Application, Component, image repository, both ITS objects and stage/prod matching rather than relying only on the service account's presence. Follow that repository's validation and review requirements.

After an authorized merge, verify actual reconciliation and usable registry/account bindings. Reconcile any build-service-generated pipeline PR with #82 instead of merging duplicate pairs. Source access does not establish MR approval or deployed resources.

## 2. Establish registry access and determine whether installation will run

PR events skip installation; push behavior depends on bundle discovery and the configured provisioning channel. The proposed runbook states that the 0.3 installer cannot provision from stable-5.0 before GA and delegates actual installation to QE on a candidate cluster. This is an engineering path to resolve, not evidence that such an install ran.

**Open gate inconsistency:** #119 requires `verify-live` to pass before stage, while describing an expected failed operator scenario. #120's `snapshot_tests_complete` and main's `fbc_tests_passed` both reject completed `TestFail`, even with Finished/Passed aggregates and an optional ITS. An isolated predicate probe reproduces that rejection; it is not a new hosted failure. Establish a supported install/qualification path and consistent readiness gates before declaring the pre-GA stage procedure executable. Keep failures visible and preserve the existing checks while reviewing the remedy.

## 3. Reconcile #82 and verify its build

After configuration reconciliation, review the exact #82 head and required contexts/app IDs, source/push provenance, lifecycle task ordering and SOURCE_ARTIFACT forwarding, target catalog/base and all four platforms. Hosted Konflux success is separate from local native-image tests. Retain the merged push PipelineRun, snapshot, resolved policy/task inputs and output digests.

The `verify-live` helper also needs #120's wrapper/secret-key fixes, idempotent configuration handling and completed-warning/marker support. These proposed fixes do not accept an operator TestFail or prove installation. Use the canonical workflow's checks after merge; do not treat an unmerged helper's behavior as main's capability.

## 4. Installation, stage, production and activation

1. Resolve the pre-GA gate above and select the approved bundle/channel and intended OCP 5 cluster. Plan the installation evidence; actual stage-artifact installation and QE follow the stage handoff below. A green skipped-install scenario is insufficient.
2. Verify current stage/prod RP/RPA matching, destinations, Pyxis opt-in and actual publishing decisions. A successful stage Release intentionally does not prove public-index publication; lifecycle injection in a 4.x no-op build does not prove target 5.0 publication.
3. Prepare/review the exact stage manifest and apply only when authorized. Select it by its recorded Release/snapshot identity, not by newest filename. Hand off verified fragments and mirrors to QE through the existing procedure, then retain actual cluster version, installed CSV/digests and installation/functional results.
4. Production must reuse the actual QE-approved stage snapshot. Verify the resulting 5.0 index contains the exact approved bundle, then review default-scope activation. No release version is selected by this planning refresh.

OPGM-364 retains its distinct original acceptance: release existing valid lifecycle data without new OpenShift 5 compatibility statements; published v5.0 membership or permitted team IIB/catalog proof. Link evidence between the existing issues without substituting full runtime support acceptance for lifecycle publication or using the 4.x recovery as its proof.
