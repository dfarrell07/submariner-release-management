<!-- markdownlint-disable MD013 -->

# Release-management work

Jira owns assignment, priority, status and acceptance. This index links the implementation handoffs maintained in this repository. Refresh the linked tracker and current PRs before starting; dated source or release records do not establish current ownership or completion.

## Release tooling

[ACM-39732 — production URL conversion](https://redhat.atlassian.net/browse/ACM-39732), [ACM-39730 — Jira tracking](https://redhat.atlassian.net/browse/ACM-39730) and [ACM-39731 — autorelease](https://redhat.atlassian.net/browse/ACM-39731) own acceptance. The [implementation handoff](autorelease-step-automation.md) retains the conversion candidate, merged verification/retry safeguards and remaining version/candidate-selection concerns, plus [unfinished skill execution portability](autorelease-step-automation.md#skill-execution-portability). Check current main and open PRs before implementing a finding.

## Existing release work

[0.23.4 — ACM-44527](https://redhat.atlassian.net/browse/ACM-44527) owns release coordination; the [merged QE handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) retains successful stage identities. The component production Release succeeded October 19 as RHSA-2026:85227; [#123](https://github.com/stolostron/submariner-release-management/pull/123) records its applied notes.

The October 19 production audit also verified all six OCP 4.16–4.21 FBC Releases and 24 platform catalogs. Refresh [component production ACM-44540](https://redhat.atlassian.net/browse/ACM-44540), [FBC production ACM-44541](https://redhat.atlassian.net/browse/ACM-44541) and [URL conversion ACM-44542](https://redhat.atlassian.net/browse/ACM-44542) from that evidence before closeout. Publication of the applied FBC release records and source URL conversion are separate from successful production delivery; stale Jira alone does not justify rerunning Releases. Maintainer-local receipt: `~/konflux/release-readiness-0.23.4-20261019/PRODUCTION-FBC-VERIFICATION.md`; the six applied FBC YAMLs are on unpublished local branch `release/0.23.4-fbc-prod-20261019` at `721ac98267f4c91bfd77f122ef4340f600ad4806`.

For [0.22.2 — ACM-45070](https://redhat.atlassian.net/browse/ACM-45070), the September EC receipt identifies `submariner-0-22-20260923-230555-000`. The later inspected `submariner-0-22-20261002-125823-000-lz` was unselected and its embedded operand identity unreconciled at the October 15 review. The [dated investigation](https://github.com/stolostron/submariner-release-management/blob/d01a14fdea6315c69fd46c3a435b4ab79a675e60/plans/current-work.md) retains historical context. Recover intended candidate/operand evidence before choosing reuse, rebuild or retargeting; an empty later receipt alone does not justify an EC rerun.

## OCP 5 and lifecycle delivery

[ACM-48092 — onboarding automation](https://redhat.atlassian.net/browse/ACM-48092), [ACM-48200 — catalog delivery](https://redhat.atlassian.net/browse/ACM-48200) and [OPGM-364 — lifecycle publication](https://redhat.atlassian.net/browse/OPGM-364) own scope. Use the [rollout runbook](ocp-5-0-fbc-rollout.md) and [onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md), refreshing the dated prerequisites and selecting the current release candidate. Installation, QE, production-index publication and lifecycle acceptance require their own evidence.

## Builder guidance

[ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) owns the addon consumer migration. Use the [addon builder checks](../.agents/workflows/scan-cves.md#addon-go-toolchain) and normal repository review. Identify the effective Dockerfile, ART source/builder override and supported branch before selecting a replacement. Preserve the compiler lineage, runtime base, OS/CPU and crypto requirements of each build path; qualify actual output image digests before backporting.

Historical investigations and portfolio payloads were removed from this planning tree. Their dated contents remain in Git; release records, canonical workflows and owning trackers are the maintained handoffs.
