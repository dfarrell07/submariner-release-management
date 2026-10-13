<!-- markdownlint-disable MD013 -->

# OCP onboarding: implemented workflow and remaining handoffs

The September 24 workflow investigation is complete. Its [full original design and reproductions](https://github.com/stolostron/submariner-release-management/blob/96e1d91bdb4e3082e21036d60ba0805f38d1f931/plans/ocp-5-onboarding-workflows.md)
remain in Git. The preparation helper, full-version plumbing and skill/workflow changes have since shipped.
Do not treat the old “components to build” or proposed flags as a second implementation contract.

[add-fbc-ocp-version.sh](../scripts/add-fbc-ocp-version.sh) delegates to [fbc-onboard.py](../scripts/fbc-onboard.py).
The [skill](../skills/add-fbc-ocp-version/SKILL.md) and [canonical workflow](../.agents/workflows/add-fbc-ocp-version.md)
own accepted inputs, phases, resume behavior and checks. Preparation preserves source worktrees and does not commit, push or apply.
Supply the requested version and explicit inputs; keep catalog preparation, actual build provenance and runtime qualification separate.

[Implementation status](ocp-5-implementation-status.md) records the dated installed-skill/native-image evidence.
[Local reproduction](ocp-5-skill-completion-plan.md#reproduce-local-preparation) retains the historical pinned workspace;
refresh source/configuration before using it for a new rollout.
[OCP 5 rollout](ocp-5-0-fbc-rollout.md) owns the active configuration, exact-head build, conditional install/QE, release and index gates.
[Current work](current-work.md) owns live prerequisites and pending PRs.

No new framework, duplicate onboarding story or additional catalog-input decision is required merely to repeat the completed preparation.
Product/runtime acceptance and default-scope activation remain unfinished work.
