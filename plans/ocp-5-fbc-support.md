<!-- markdownlint-disable MD013 -->

# OCP 5.0 FBC support: investigation handoff

The September 24 pre-implementation investigation is complete. Its full reproductions, immutable source inputs and proposed changes are
[retained in Git](https://github.com/stolostron/submariner-release-management/blob/96e1d91bdb4e3082e21036d60ba0805f38d1f931/plans/ocp-5-fbc-support.md); they are not the current implementation backlog.

Use these current documents:

| Need | Canonical source |
| --- | --- |
| Implementation and historical native image/E2E evidence | [Implementation status](ocp-5-implementation-status.md) |
| Configuration, credential, build, installation/QE and publishing gates | [OCP 5 rollout](ocp-5-0-fbc-rollout.md) |
| Existing 4.x failures and exact failed-snapshot identities | [FBC recovery](fbc-failure-recovery.md) |
| Current Jira/PR/local-work evidence | [Work map](current-work.md) |
| Reusable execution procedure | [Onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md) |

Full OCP major/minor handling, isolated/resumable preparation and target-catalog validation are implemented.
The provisional 5.0 catalog uses minimum Submariner stream 0.24, channel `stable-0.24` and existing bundles 0.24.0/0.24.1.
Do not turn those packaging inputs into a runtime support claim or activate 5.0 in default release scope before the rollout gates pass.

Retain the investigation's important boundaries: an inclusive minimum differs from the legacy drop-through cutoff;
installation can skip when no unreleased bundle is returned; a lower-version cluster fallback is not OCP 5 evidence;
and stage/prod must use the same QE-approved snapshot. The workflow and rollout plan own their current checks.
