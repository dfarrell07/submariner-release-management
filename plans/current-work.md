<!-- markdownlint-disable MD013 -->

# Current work and planning handoffs

Refreshed October 15, 2026. The [Jira queue](jira-update-queue.md) owns issue dispositions, assignment and proposed updates. This map routes engineering work to its maintained plan; historical evidence and completed writes remain in the [audit index](jira-audit-records.md). Older work maps are retained in Git.

## Release recovery and time-sensitive work

| Priority | Current state and next action | Plan |
| --- | --- | --- |
| ART builders, ACM-45318 | Due October 15; New. Addon samples still use Brew. Agree active streams and prepare the main pilot in both Dockerfiles, then qualify the actual image builds and runtime | [Builder inventory and pilot](art-builder-migration.md) |
| 0.23.4, ACM-44527 | Six applicable OCP 4.16–4.21 stage Releases succeeded; catalog/stage children are Resolved. QE acceptance and production remain pending. ACM-44539 already reports the 14-failure summary also in ACM-48176; both nettest reports need logs and exact artifact attribution | [Recovery evidence](fbc-failure-recovery.md), [QE handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) |
| Durable FBC recovery | FBC #85/#86 remain open at `02ac47d1` / `7c963da2`; required checks pass, Tide is pending. Their publication is separate from the completed recovery Releases | [Recovery plan](fbc-failure-recovery.md) |
| OCP 5 catalog, ACM-48200 | In Progress; tenant MR !23786 and FBC #82 remain prerequisites. Resolve the pre-GA install/readiness conflict before a stage run is executable | [Rollout gates](ocp-5-0-fbc-rollout.md) |
| OCP onboarding automation, ACM-48092 | In Progress; description now separates automation from catalog delivery. Draft #120 remains to land; #119 proposes the operational runbook | [Onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md) |
| Lifecycle publication, OPGM-364 | In Progress; existing lifecycle data needs target publication or allowed IIB/catalog proof, without new 5.0 compatibility claims. Successful 4.x no-op task execution does not fulfill this | [Rollout boundaries](ocp-5-0-fbc-rollout.md) |
| CVE/advisory handoff | Separate fork proposal at `1832181`, with no upstream PR. Review stream-specific coverage, closure policy and post-stage metadata correction with Product Security/RelEng; implementation and policy decisions remain open | [Reconciliation proposal](https://github.com/dfarrell07/submariner-release-management/blob/1832181e8d0892615a680b844a3d0ed7e3274957/plans/cve-advisory-reconciliation.md) |
| 0.22.2, ACM-45070 | In Progress; reconcile the recorded EC snapshot and the later unselected candidate before selecting bundle/operand identity or changing step status | [Candidate reconciliation](#0222-candidate-reconciliation) |

0.24.1 parent ACM-40644 is Resolved. Its previously verified production bundle is `sha256:a8bb318b8afa37daf2ce9394d80c46224e872b593934fbb68fd89e20e6665f84`; this refresh does not repeat index, installation or closure qualification. Earlier October 15 Submariner cluster and GitLab source reads succeeded; the latest live read returned Unauthorized, and the addon session also lacked authentication. Historical DNS/credential failures are not current blockers without a fresh failed read.

## 0.22.2 candidate reconciliation

The September 24 EC completion receipt names `submariner-0-22-20260923-230555-000`; later empty in-progress receipts do not overturn it. ACM-45077 still has no selected bundle-SHA snapshot/PR. The later inspected candidate `submariner-0-22-20261002-125823-000-lz` is not selected by the tracker. Its bundle labels/CSV say 0.22.2, but seven embedded related-image digests differ from mapped snapshot operands. Manifest conversion can change digests; mismatch alone does not establish wrong content. The [dated extraction record](https://github.com/stolostron/submariner-release-management/blob/d01a14fdea6315c69fd46c3a435b4ab79a675e60/plans/current-work.md#release-recovery-and-time-sensitive-work) retains exact image/source identities and the then-failed production pull.

First recover candidate-specific snapshot/scenario, bundle CSV and per-platform operand evidence, or the release owner's intended selection. Compare image content/provenance across registry copies before choosing reuse, bundle rebuild or retargeting. Refresh parent artifacts and only affected steps after that decision. Unavailable live reads justify neither rerunning EC nor selecting the newest snapshot.

## Upstream audit and upgrade tests

The eight FIND-006 Shipyard drafts #2566–2573 are closed without merging. Fresh source reads find the original unverified installer pipe (`get-subctl.sh`, blob `f3c9548e`) on devel and 0.18–0.24; an equivalent fix has not landed in those files. The `subctl-devel` release now publishes `subctl-checksums.txt`, so the old blanket checksum-prerequisite blocker is stale. Reconcile exact release-tag/runtime inputs, supported branches and the finding's accepted disposition before proposing a reviewed fix. Keep this separate from upgrade-test repairs; no retrospective Jira split is selected.

[Upgrade recovery](upgrade-ci-recovery.md) owns the current dependency/runtime sequence and maintained-stream backports. Shipyard #2654 is open, subctl #1944 remains draft, and issue #2635 remains the acceptance tracker. Shipyard #2656 has merged; #2618 still has a failing scan at its unchanged head and needs a refresh against that remedy, plus fresh OCP SCC admission evidence as a separate gate. Do not repeat the already fixed formatting work or bypass dependency/runtime guards.

## Release tooling and Jira payloads

Release-management #111 and #114–118 are merged. Use main's completed EC/FBC and exact-artifact gates. ACM-39730/39731 already record those merges; tracker retargeting and parent-artifact refresh remain follow-ups. The [autorelease roadmap](autorelease-step-automation.md) owns implementation risks and missing wiring; [skill compatibility](claude-codex-skill-compatibility.md) owns the remaining konflux-ci-fix portability and installed-host checks.

Shipyard #2582 merged October 14 and is already recorded on ACM-39729/39739. The separate go-fix-cves ai-helpers contribution still needs its original generalization/merge acceptance; the agent contribution additionally needs non-Submariner validation. Knowledge transfer ACM-39736 still requires multiple independent releasers completing full releases and reporting gaps.

The old S/K payload sequence is historical. ACM-48092 already tracks onboarding automation; ACM-48200 separately tracks actual 5.0 delivery. Do not create duplicates or replay old comments. The epic's additional Release tooling/Glasswing sections remain an unselected scope decision. The personal Jira triage skill is read-only and does not fulfill ACM-39734's continuous incoming GitHub scrub automation.

## Unpublished production URL tooling

ACM-39732 has an existing fork candidate at `3cabf0e1`, with no returned PR for that head. It adds a script, tests and conductor wiring, but no standalone skill. Main's verifier can false-pass local template text; neither candidate nor verifier establishes release publication. The [implementation handoff](autorelease-step-automation.md#production-url-conversion) owns the required correction and validation.

## Kubernetes plugin qualification and publication

[ai-helpers #617](https://github.com/openshift-eng/ai-helpers/pull/617) remains draft at `1a33dafe`; CORENET-7155 is In Progress. The maintainer originated the design and reports working rebases across six CoreNet repositories through Kubernetes 1.37. That report and published source do not replace the epic's measured evaluations, selected-runtime qualification and upstream merge criteria.

The [historical qualification record](https://github.com/stolostron/submariner-release-management/blob/f071c65c288e2bf1b2fd8f2470e70d819ad2031a/plans/agentic-sdlc-jira-updates-verification.md#kubernetes-rebase-evidence) retains the trial source identities and limits. Current CNCC #276 and Multus #369 still have failing hosted checks. No rebase or model evaluation was rerun here. #617 also has five unresolved, outdated review threads and an invalid-OWNERS bot notice. Reconcile each with the current source and maintainers; outdated does not mean resolved. Preserve the push/PR handoff while agreeing how post-push CI findings and repairs are retained/reviewed. Finish measured evaluations with model/cost data and selected-runtime evidence before claiming the epic complete.

Related [fork macOS PR #1](https://github.com/dfarrell07/ai-helpers/pull/1) remains open at `105da21b`, targeting the plugin branch. Its history diverges from #617's `1a33dafe`; direct tree comparison differs well beyond the three files advertised in its body, including current 1.37 and CVE-evidence paths absent from the fork tree. Reconcile the intended platform fixes onto the current plugin and qualify them there before merging; its reported macOS run does not qualify the current plugin/runtime matrix.

## Adjacent work with separate ownership and scope

| Work | Current handoff |
| --- | --- |
| EGA planning, CORENET-7615 | In Progress. PR #14 is now ready for review at `8b7c5caf`, with images/verify passing. Jira's dated paragraph still says draft; original review/merge acceptance remains. The description now explicitly separates decision recording from closure criteria |
| EGA lint, CORENET-7664 | In Progress. Draft #15 at `be5ff8b3` supersedes closed-unmerged #11. Preserve the earlier-tool-PR requirement when reviewing its combined tool/consumer scope |
| EGA source proposals | Collection #7 merged; #3 closed unmerged. Image #16 is open; #6 remains an on-hold alternative. Planning/runtime choices stay with their owners; no AWS qualification is inferred |
| MCN CI | CORENET-7171 research is Closed; the 27 children under CORENET-7086 remain To Do. Confirm target repository, header/API coverage and GHA/Prow responsibilities before selecting the first existing child. CORENET-7196–7198 specify post-merge AI workflows; retain that correction |
| PQC, ACM-41119 | New. Inventory applicable operator/operand/must-gather images and their actual 5.0 build sources. The addon base is partial evidence; retain the original built-image DEFAULT:PQ CI check and inclusion in the target build |
| OLMv1, ACM-37426 | New; title and description already target ACM 5.1. Plan fresh-install/migration scope, complete RBAC and prove installation; no repeated milestone correction |
| ART consumption, ACM-45508 | Other-owned, New; linked to ACM-48200. Keep addon consumption/runtime acceptance separate from builder registry migration and lifecycle-only publication |
| Build catalog, ACM-25779 | New, pending ownership decision. Addon adoption does not require migrating independently released components/FBC from inline pipelines; the receiving team must choose the integration before implementation |
| Upstream release, ACM-39733 | Other-owned, In Progress. Releases #1444 is open/ready at `7f67ec02`; review its stage prerequisites and final-artifact verification with its owner. A downstream tag-existence verifier does not deliver upstream orchestration |
| AI bug-fixing trial, ACM-39735 | Unassigned, New. Original scope is three varied sustenance bugs through ready-to-solve/solve, with findings and an investment recommendation; owner/bug selection remains a decision |
| Diagnostics, ACM-39737 | Other-owned, New. Coordinate its original PIA/local-workflow/structured-upload scope with the owner. Diagnostics #19 is an open analyzer change, not approval to process customer logs |
| Maintenance review | Release-0.20 [Lighthouse #2322](https://github.com/submariner-io/lighthouse/pull/2322) has failed build/test checks; [Admiral #1424](https://github.com/submariner-io/admiral/pull/1424) has passing returned checks. Confirm maintained-stream scope and dependency/build compatibility before pursuing either |
| Metrics review | [Submariner #4216](https://github.com/submariner-io/submariner/pull/4216) is open for GitHub issue #4217. Reconcile its reviews and exact-head checks with the owner; a source proposal is not an accepted bug fix |

Private research, restricted issue content and credentials remain outside this repository.
