<!-- markdownlint-disable MD013 -->

# Addon Tekton setup: deferred implementation proposal

Checked October 7, 2026. No `tektonAddon` step or backing setup script exists in the current release graph.
The [original design](https://github.com/stolostron/submariner-release-management/blob/96e1d91bdb4e3082e21036d60ba0805f38d1f931/plans/addon-tekton-setup.md) remains in Git. Its old Submariner-to-ACM arithmetic and copy/edit walkthrough are unsuitable as a current 5.x execution recipe.

The ACM-integrated addon has a separate artifact/release path from independently released Submariner components.
Confirm current ownership and whether an additional setup command is needed before adding conductor wiring.
Existing builder migration, PQC runtime, OLMv1 work and ART consumption retain their own Jira scope in the [assigned-work queue](jira-update-queue.md).
Addon task-ref PR #2792 targets an older ACM stream and does not implement this proposal.

If the setup is approved, prepare one reviewable helper with these inputs and boundaries:

* Explicit supported addon release branch, predecessor, component identity and target tenant/application. Confirm them from current source/ownership; derive none from Submariner patch/minor arithmetic.
* Current pipeline/catalog conventions, actual `DOCKERFILE`/build arguments, registry access and immutable task trust. Reusing predecessor files must preserve intended product scope and required architecture/runtime policy.
* An isolated worktree, validated inputs and preserved unrelated/untracked work. Reject ambiguous/conflicting resumes; inspect final file selection before cleanup or commit.
* An explicit review handoff. Branch push, PR creation, cluster reconciliation and release remain separately authorized actions.

Acceptance would require a reviewed branch-specific configuration, meaningful contract checks, exact-head hosted multiarchitecture builds and verified tenant/component matching.
Only after those are established should any shared-step integration be proposed. Source preparation is not addon publication or a full release by another engineer.

Current branch/build differences belong to [ART builder inventory](art-builder-migration.md#addon-branch-differences),
release-step integration to the [autorelease roadmap](autorelease-step-automation.md#remaining-work-in-order).
No implementation or hosted rerun was performed by this plan refresh.
