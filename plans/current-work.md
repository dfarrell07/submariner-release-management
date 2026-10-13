<!-- markdownlint-disable MD013 -->

# Current work and planning handoffs

Jira planning reverified October 8, 2026: all 703 assigned keys/statuses, 234 non-Vulnerability/related full views and 88 complete comment/changelog histories. The [queue](jira-update-queue.md) covers all 76 active non-Vulnerability issues; private security follow-up stays separate. Cluster, registry, source and runtime observations below retain their own cutoffs.

Next review is [Submariner description edits 4 → 3 → 5](agentic-sdlc-jira-updates-payloads/submariner-sustenance/epic-description-edits.md), then optional 1/2. Ten comments and the Kubernetes description are complete; [verified ids](agentic-sdlc-jira-updates.md#a5-execution-order). The 0.22.2 note remains on hold and EVPN is deferred. QE validation of the completed FBC stage candidates, private CVE triage and the October 15 builder deadline retain engineering priority.

[PR #111](https://github.com/stolostron/submariner-release-management/pull/111) publishes this planning work. The October 12 history repair added sign-offs to all 60 same-author commits while preserving their file tree; the published DCO check passes. The October 8 review edits are retained here as dated records, with current release evidence kept separate. The [verification log](agentic-sdlc-jira-updates-verification.md) retains dated audits and receipts.

## October 12 FBC recovery update

Konflux access was restored, the existing registry credential was validated and
linked to the integration runner, and all six original operator checks completed
successfully. The first 4.19 stage attempt then exposed a missing required lifecycle
task. Fresh signed builds with that task and unchanged bundle/operand pins passed
completed snapshot tests and managed release policy; all six applicable 0.23.4
stage Releases for OCP 4.16–4.21 succeeded. The last, 4.16, completed at 20:02 UTC.
QE handoff uses channel `stable-0.23` and CSV `submariner.v0.23.4`; installation
remains unqualified because the integration runs skipped it. Production is pending QE.

[FBC #85](https://github.com/stolostron/submariner-operator-fbc/pull/85) and
[release-management #115](https://github.com/stolostron/submariner-release-management/pull/115)
carry the corrected workflows. [FBC #86](https://github.com/stolostron/submariner-operator-fbc/pull/86) supplies the required lifecycle task; all seven PR builds and completed snapshot tests pass. Release-management [#117](https://github.com/stolostron/submariner-release-management/pull/117) adds exact completion/publication gates, [#116](https://github.com/stolostron/submariner-release-management/pull/116) records the six successful stage candidates, and [#118](https://github.com/stolostron/submariner-release-management/pull/118) fixes reproduced validation races. All six release-management proposals passed a combined full suite. Durable credentials remain separately prepared. GitLab
remains unreachable; the declarative tenant draft still needs a fresh base.
The retained release-0.22 upgrade patch is prepared as draft [Shipyard #2657](https://github.com/submariner-io/shipyard/pull/2657) and [subctl #1947](https://github.com/submariner-io/subctl/pull/1947). Their focused regressions pass; merge/runtime ordering and current baseline vulnerability failures remain gates. No maintenance runtime or Release is published by these proposals.
October 13: release-management #118, #114, #117, #115 and #116 are merged after sequential rebase, full tests and hosted CI.
The completed-evidence helpers, recovery workflows and historical stage handoff are now on main. Use those implementations;
actual QE installation and testing remain pending. Jira statuses and fixed posted records were not updated by these merges.

The October 7/8 Jira statuses below are historical observations, not claims that
the tracker has been updated to match the October 12 cluster results.

## Release recovery and time-sensitive work

| Work | Observed reality | Next action and completion evidence |
| --- | --- | --- |
| 0.23.4, ACM-44527 | Parent In Progress; component stage and all prerequisites through release notes Resolved; FBC catalog In Progress; FBC stage, QE and production steps New | October 12 cluster recovery and all six stage Releases are complete. Hand off the verified artifacts to QE; reconcile tracker status separately and wait for actual installation/QE evidence |
| FBC 4.16–4.21 | Each retained snapshot matches `2e6b489e65620738d68504d9158418fe463e2073`; aggregate tests Failed and operator scenarios TestFail, finished September 30/October 1 | Historical failure is superseded by the October 12 verified replacements and successful stage Releases; retain both attempt identities under the [recovery record](fbc-failure-recovery.md) |
| ART Go builder migration, ACM-45318 | New, unchanged; planning comment 18839276 posted and verified October 8 at 15:37 UTC; migration remains due October 15 | Use the [pinned source inventory](art-builder-migration.md): all 36 ticket-listed component Dockerfiles on 0.19–0.24 use UBI Go Toolset; addon Brew consumers and the CVE builder-selection guidance need migration. Confirm supported/deployed sources; cached 5.1/5.2 builds select main, matching their filters. Preserve builder OS family: current Brew Go 1.25 declares RHEL8 and has a matching ART candidate. Verify both CI credential paths, ordinary Prow images checks and required Konflux platforms. Verify the output binary’s compiler/build settings, runtime compatibility and existing CGO/FIPS behavior in the required deployment mode; bind each platform’s evidence to its published image digest. Carry both Dockerfile changes through the addon branch process. Require a disposition for every repo/active build source, including libraries, shared tools, FBC and generated inputs. This deadline can proceed independently of FBC credentials and Jira story creation |
| 0.24.1, ACM-40644 | Parent In Progress; all 15 subtasks terminal. Exact production bundle tag resolves with version v0.24.1; seven index probes time out and recorded component Release CRs are NotFound | Bundle publication is confirmed. Recover catalog/QE/release evidence for actual 4.16–4.22 scope before authorized closeout; missing retained CRs and timed-out probes are not proof of absence |
| 0.22.2, ACM-45070 | Retained candidate snapshot passes aggregate integration with warnings; its bundle CSV/version is 0.22.2, but embedded operand identity remains unreconciled. EC and bundle SHAs remain In Progress; stage onward New | Verify source/operand mapping before accepting this candidate or updating parent artifacts. Give the two additional test items their own disposition |
| Lifecycle publication, OPGM-364 | In Progress at the October 8 read; status answer posted as comment 18829498, publication still pending | Reconcile tenant resources, merge lifecycle injection and record release/catalog proof under the rollout plan’s existing lifecycle-only scope. The posted answer does not complete the release work |
| Task trust maintenance | October 7 current data retains three #82 pins expiring October 30 and lifecycle injection October 31; deprecated-image-check now expires November 6 | Re-read current allowlist and deny rules; keep any repo-wide refresh separate. Expiry is not the demonstrated cause of today's FBC failures |

The October 7/8 authenticated `submariner-tenant` reads found the registry secret unlinked from both runner credential lists and OCP 5 Application, Component and build account absent.
The October 7/8 namespace read returned zero PipelineRuns and 741 retained snapshots (the earlier read returned 746); all six documented FBC failure associations remain present.
The recorded 0.23.4 component-stage Release is now NotFound; its archived October 7 success remains evidence.
The October 8 posting preflight finds Konflux authentication expired; live snapshot re-verification is unavailable.
Release Submariner 0.23.4 now has verified restricted recovery-map comment 18830594. It links recorded identities and makes no fresh test or release claim.
Release Submariner 0.22.2’s candidate comment remains unposted and on hold.
This establishes snapshot verdicts/identities, not fresh task diagnosis or credential usability. Those historical credential/test failures are superseded by the October 12 recovery above; GitLab fresh-base access remains unavailable.

0.24.1 artifact read: `registry.redhat.io/rhacm2/submariner-operator-bundle:v0.24.1` resolves to
`sha256:a8bb318b8afa37daf2ce9394d80c46224e872b593934fbb68fd89e20e6665f84` with label `version=v0.24.1`.
Local FBC production records enumerate OCP 4.16–4.22. Each direct index extraction timed out at 100 seconds;
index membership remains unknown. All three recorded September component production Release names are NotFound in the authenticated tenant.
Their repository YAMLs are retained intent, not a current success verdict. No install, QE or release execution was repeated.

The inspected 0.22.2 candidate is `submariner-0-22-20261002-125823-000-lz`, with nine components and aggregate TestSucceeded=True.
Its completed combined EC/standard scenario reports warnings, despite retained `BuildPLRInProgress` labels. The bundle digest
`sha256:cdbc25da3eb5bea32ee537a2fee2a943f7cd8a16507fb9dbfdc9d7f4e0d2a9d3` has version label v0.22.2 and CSV version 0.22.2;
the bundle source is `da81d438c0456f367bc5e83e671362181a47ab63`. All seven CSV related-image digests differ from their mapped snapshot operands.
Registry copying can change manifest digests, so this comparison is not proof of invalid content. The snapshot operator inspects as v0.22.2 at source
`b416904aa589f54ff8ba0b270e80968cd5872218`, distinct from the bundle source. The freshly extracted CSV matches both source trees.
The embedded production operator returns
`manifest unknown` at the October 8 registry read. These checks do not establish all-platform operand identity. Reconcile production operand identity before treating this candidate as release-ready.
The candidate is absent from the complete release-target histories; it is not selected by this inspection.
Snapshot `AutoReleased=True` records a skipped automatic release. No tracker step or artifact is advanced from this partial evidence.

## Prepared release-data and OCP 5 work

All four inspected release-data checkouts are clean. Cached main is `8c18efee295889f5d86b03d16930a2f11977fd58`.

| Draft | Exact local head | Scope and next handoff |
| --- | --- | --- |
| Registry repair | `3edd2876d3c3eaa31c573ada703fce1fe6c3f858` | Three tenant files; refresh base, validate live credential and GitOps/controller field ownership, submit when authorized |
| OCP 5 tenant | `47eda9c5b11c6f57fb7a4f7fb9be2e0fd42be588` | Sixteen configuration files plus an extra documentation rewrite; separate that rewrite before submission. Component reconciliation provisions the build account |
| OCP 5 admissions | `860aa737d01120c47d7b474d8119657dada5d08b` | Two managed RPA additions for later release matching; not a prerequisite for creating the build account |

[FBC #82](https://github.com/stolostron/submariner-operator-fbc/pull/82) remains open at
`1e8b3c26137b49db60a0d93853f144990770f304`. Actions and DCO pass; the published Konflux run still fails before tasks start because
`build-pipeline-submariner-fbc-5-0` is missing. Fresh cluster reads also find the 5.0 Application and Component absent; the failed run itself is no longer retained. The PR is not marked draft. Its description still incorrectly calls the lifecycle pin non-expiring and bundles tenant/admission prerequisites together.
Correct those statements when an external PR update is authorized. Preserve its executable pipelines and reconcile the duplicate planning file after review.

Catalog/tooling PRs #76 and #81 are merged. The September implementation records are historical local evidence, not a current statement that no catalog or PR exists.
Configuration, exact-head build, authenticated index rendering, conditional install, QE, publishing and default-scope activation remain distinct gates.
See the [rollout plan](ocp-5-0-fbc-rollout.md) for their order and evidence requirements.

## Upstream audit and upgrade tests

The September 113-PR audit inventory remains historical: 105 merged, eight FIND-006 drafts then open.
Direct October 7 API reads of shipyard #2566 and #2567–2573 find all eight **closed without merging on October 3**.
The #2566 timeline attributes closure to GitHub Actions following its stale warning; do not infer every draft's closure reason from that one timeline.
The previous verification document's October 6 claim that these drafts remained open was incorrect.

The download-integrity finding needs a current prerequisite and supported-branch review, then an explicit remediation/re-triage decision.
Reopening or replacing the drafts is a separate external action. Preserve their source identities; closure is not evidence that their fixes shipped.

| Work | Current evidence | Required sequence |
| --- | --- | --- |
| [shipyard #2654](https://github.com/submariner-io/shipyard/pull/2654) | Open at `557bb9977cd4e2dcb9f8526620423faa20c4c1fb`; all returned checks pass or skip. Selects/verifies branch-appropriate upgrade baselines | Review/merge, then verify publication of the updated Shipyard Dapper runtime before enabling the consumer |
| [subctl #1944](https://github.com/submariner-io/subctl/pull/1944) | October 12 draft at `f6a97c7a`: formatting and local prerequisite checks pass; dependency/runtime and hosted upgrade gates still block | Merge/publish the approved Shipyard runtime first, then qualify the consumer. The focused scan fix is separate [#1946](https://github.com/submariner-io/subctl/pull/1946); do not bypass the guard |
| [shipyard #2635](https://github.com/submariner-io/shipyard/issues/2635) | Still open; #2633 is closed | Keep open until coordinated fixes, runtime publication, consumer CI and applicable backports satisfy its criteria |
| [shipyard #2618](https://github.com/submariner-io/shipyard/pull/2618) | October 12 at `98b5416c`: exactly three UID removals; deployment/E2E/unit checks pass, old-base scan fails | Integrate the separately tested dependency remedy [#2656](https://github.com/submariner-io/shipyard/pull/2656), refresh this branch and retain fresh OCP SCC admission as a distinct gate |

Upgrade PR descriptions report local kind validation and cached-image limitations. This planning audit did not repeat those runs.
Do not treat upgrade-test repair as proof that FIND-006 download-integrity fixes shipped.

## Release tooling and Jira payloads

ACM-39728 still has ten direct children. CORENET-7155 has no children; its approved description was applied and verified October 8 at 11:23 UTC (changelog `92306194`), recording the maintainer’s original design and working coverage. Submariner epic edits and all new stories remain pending.
Both epics remain In Progress. The first four ACM comments were posted and verified; their ids are recorded in the execution plan. The three contribution targets remain New with comment totals 0/2/2 on ACM-39738/39739/39740. The two approved child updates were posted and verified October 8 at 11:48 UTC as comments `18831845` (agent) and `18831852` (fix); the duplicate parent rollup is deferred.
Submariner Sprint 2026-59 (87579) and CORENET Sprint 295 (87581) remain active in the inspected records.
Both projects' create metadata and existing targets' edit/transition metadata were read successfully; actual creates, transitions and write canaries remain untested.

* [Upstream release PR #1444](https://github.com/submariner-io/releases/pull/1444) remains open at `7f67ec02b571d1cb46189814a74b5996a2cc07f8`. Keep ACM-39733 with its existing owner; no progress or comment is attributed to the maintainer by this refresh.
* October 7 maintainer report: another team member has begun using the CVE and autorelease tooling. This is initial adoption evidence for ACM-39729/39731/39736; completed full releases and feedback are not established by that report.
* October 12: [release-management #114](https://github.com/stolostron/submariner-release-management/pull/114) is open at `31ae1e50`, with hosted validation passing. It now requires completed EC evidence and exact tags across all five component repos while preserving downstream scan checks; the proposal is not on main.
* `make test-skills` passes 19 checks while retaining five overlapping compatibility debt entries in `konflux-ci-fix`. The proposed S3 now names the delivered discovery/contract scope. The [compatibility plan](claude-codex-skill-compatibility.md) retains remaining execution and host-matrix work.
* [shipyard #2582](https://github.com/submariner-io/shipyard/pull/2582) is open at `603ac03b63b5e985deaa4f984d127323cdddedcd` in the latest October 8 read. All 46 returned check runs pass or skip, plus one successful commit status. Complete pagination finds 47 reviews and 50 threads: two unresolved/current, seven unresolved/outdated, and no current-head review or approval. The latest changes-requested review is on `8bdf850e`. Rewritten history makes the earlier comparison/probes unsuitable for qualifying this new head.
* The earlier six configuration/detection probes and 26 selected existing-source checks remain dated evidence for the inspected earlier source, including offline workspace build/vendor rollback. No CVE-fix test or installed-runtime qualification is repeated on `603ac03b` by this planning review.
* Project-level `.cve-fix.yaml` overrides and configurable repository registries are implemented in the open PR. The builder-image fallback for unconfigured Shipyard consumers still uses a hardcoded Submariner value; project configuration and environment overrides take precedence. Resolve the fallback for the general contribution against its original criterion. The merged CVE agent still binds component/image mappings, version rules, Jira scope and triage helpers to Submariner/RHACM. Both ai-helpers contributions and the agent’s non-Submariner CVE validation remain pending.

Before writes, settle the story split/status and CORENET points/sprint, refresh descriptions and PR evidence, then read back one canary at a time.
No new stories for ordinary release steps or unrelated product work are proposed by this refresh.

## Unpublished tooling and stale roadmap entries

The remote fork branch `acm-39732-fbcProdUrls-automation` points to `3cabf0e1f7526d3ef554571ffbb0a95db33bf013`.
GitHub's PR query for that head returns none. Its three-file delta adds `scripts/update-fbc-prod-urls.sh` and wiring/tests;
current main has no such script or `STEP_SCRIPT` entry for `fbcProdUrls`. ACM-39732 remains New. This is an existing implementation candidate, not shipped automation.

Before proposing it for review:

* Rebase/reconcile against current main and use an isolated clean worktree, including untracked files; the draft only warns on tracked dirt before running update/build commands and committing on main.
* Replace its assumption that one OCP production release establishes completion for every target. Require the actual applicable scope, QE-approved snapshot and index evidence; transient/auth failures must not become absence or completion.
* Separate conversion of the released bundle's URL from selecting a new bundle snapshot; verify the current FBC `update-bundle` contract before reusing that operation.
* Preserve original checkout and unrelated work, compare final catalog contents/digests, and keep tracker completion with the existing verifier. The draft writes an In Progress record before its branch/cleanliness checks.
* Reconcile timing: the old workflow calls conversion optional/deferred, while the conductor's linear closeout treats `fbcProdUrls` as its final required completion check. Do not revive a deferred-next-release closeout assumption from the draft.

No candidate script was executed or modified. Any branch push/PR or Jira progress comment remains a separate external action.

The [autorelease roadmap](autorelease-step-automation.md) now contains the current 19-step wiring and remaining work.
Current source has review-level build-readiness/component scripts, external verifiers on several scripted steps,
an extracted/tested `run_conductor`, tag-age snapshot warnings and original-ref restoration.
Completed-phase pseudocode and shelved apply/parallel designs are retired; historical implementation remains in Git.
Remaining write acknowledgement and recovery risks need focused follow-up. A synthetic probe reproduces the FBC helper accepting two
`BuildPLRInProgress` markers without completion evidence; it does not reproduce a complete release-verifier failure. The [recovery gate](fbc-failure-recovery.md#rerun-the-same-release-snapshots)
now requires finished verdicts and exact snapshot-name comparisons alongside verification, including generated stage YAMLs.

## Kubernetes plugin qualification and publication

October 8 maintainer clarification: the original epic supplied no specification or design. The maintainer originated and implemented the architecture and workflow, and reports it fully working across all six CoreNet repositories for Kubernetes 1.34.1, 1.35.3 and 1.36.2, and now working for 1.37. This functional-coverage report is distinct from the retained per-run audit and upstream acceptance records below.

October 8: [PR #617](https://github.com/openshift-eng/ai-helpers/pull/617) is draft at
`1a33dafe05981ceebfaf8fe780b0c448a6310b2d`, with 143 changed files and WIP, invalid-OWNERS and needs-ok-to-test labels.
No returned review is on this head. Direct plugin blob comparisons show 99 differences from the old PR head,
46 from bak42, and only two court-test files differing from October 7 committed source `a477bced`.
The old unpublished-source conclusion is superseded; commit counts across these divergent/squashed histories do not measure source coverage.
The current local checkout and dirty state were not re-read. Keep those October 7 observations in the historical evidence.

Fresh qualification must use the exact published/installed source and runtime. No plugin test, model call or rebase trial was run here.
The [verification log](agentic-sdlc-jira-updates-verification.md#kubernetes-rebase-evidence) and preceding trial records retain detailed evidence:
K2's legacy 1.36.2 PASS summaries lack the current per-run archive; K3 needs valid measured outcomes and the shared-harness decision;
K4's CNCC/Multus/MCP trials retain their dependency, coverage and security limits. Publication does not resolve those acceptance gates.

## Adjacent work with separate ownership and scope

| Work | Observed state | Planning treatment |
| --- | --- | --- |
| Submariner ART strategy | Local October 6 assessment and Jira drafts exist; they describe a conditional pilot and ownership decisions | Preserve this as a proposal. Existing builder migration and ACM-integrated addon consumption are distinct from adopting ART for the independently released product; no migration epic is created here |
| ART dev/test consumption, ACM-45508 | New | Keep the proposed S1 related-issue link; prove addon consumption separately from FBC catalog/runtime support |
| PQC image readiness, ACM-41119 | New; updated October 5, targets OCP 5 GA. Addon release-5.0 already selects a PQC-minimal Konflux runtime base; main/5.1 does not | Verify actual image policy/build evidence and approved scope. Existing source configuration is partial evidence, not shipped-image proof; see [branch inventory](art-builder-migration.md#addon-branch-differences) |
| Addon OLMv1, ACM-37426 | New; description says ACM 5.0, July 24 comment targets 5.1. Private research has ClusterExtension/installer prototypes; least-privilege RBAC explicitly lacks two required parts | Preserve preparation; apply the prepared title/description correction only after target confirmation, then confirm current API before addon integration, complete/review RBAC and prove install behavior. Do not count templates as implementation or inherit the old 5.0 deadline |
| EVPN delivery plan, CORENET-7615 | October 7 maintainer report: another planning PR iteration is WIP and CI PRs will start soon. To Do / no comments in the verified Jira snapshot. Planning #2 merged; its [October 1 discussion](https://github.com/openshift/evpn-gateway-appliance/pull/2#issuecomment-5936707328) records preliminary artifact-graph review, FRR/exporter selection and the transit-VIF resolution | Defer the Jira comment to the end of the queue. Reconcile the public index with the recorded outcomes and prepared branch amendments, preserving owner/date/evidence. Reviewer confirmation or requested changes for release gates/responsibilities, and owner-attributed criteria reconciliation, remain; pending product-home/cluster/AMI decisions need not all be settled |
| Older route-agent build, ACM-34593 | October 2 hosted route-agent push build succeeds at `82adbacd`; its later EC scenario fails | Review closure of the original DNF/RPM build issue against that exact source/build; keep EC failure as separate compliance evidence. See the [queue](jira-update-queue.md) |
| Pre-merge automation, CORENET-7086 | To Do in the current assigned-work query | 28 children: research plus 27 implementation subtasks. Reconcile header/API-compatibility coverage and GHA/Prow scope; preserve existing tracking |
| MCN CI tooling, CORENET-7171 and implementation stories | Research In Progress with two May comments and verified October 7 correction 18824859; all 27 implementation subtasks To Do, no comments | Linked proposal contains recommendations/rationale and post-merge AI scope. Research acceptance is separate from implementation; planned GHA/Prow responsibilities need reconciliation with CORENET-7083/7087 |

EVPN main is `306b8fe8a68cd878a9b8272b5329e5a6b8ac1e92` (October 5). Its current `make verify` runs the planning/public-safety checks, not appliance build or AWS qualification.
[Appliance #6](https://github.com/openshift/evpn-gateway-appliance/pull/6) remains open at `d5fb9fdad3d4bc486ba5f4c145806d64d09a39cb` in the latest October 8 read; verify passes and Tide is pending. Its pinned draft index still calls RHEL 10 host-FRR packaging settled, differing from #2's recorded image choice and CORENET-7621's unchanged image criterion. Reconcile that choice with the owners. Earlier fork amendments and this open PR remain proposals, not accepted replacements for the merged plan.
[Ansible #7](https://github.com/openshift/evpn-gateway-appliance/pull/7) fails verify at `55d471e0336fa3c6812fdf88a4ce38732bb7533b`.
[Earlier Ansible #3](https://github.com/openshift/evpn-gateway-appliance/pull/3) is also open; reconcile the overlapping import scope with its owners rather than assuming supersession.
Keep these other-contributor handoffs outside assigned-issue totals and the Kubernetes plugin epic.

Private research exports, teammate identities, credential contents and internal links are not copied into this public plan.
