<!-- markdownlint-disable MD013 -->

# Current work and planning handoffs

Refreshed October 15, 2026. The [Jira queue](jira-update-queue.md) owns issue dispositions, assignment and proposed updates. This map routes engineering work to its maintained plan; dated evidence and completed writes remain in the [verification log](agentic-sdlc-jira-updates-verification.md). Older work maps are retained in Git.

## Release recovery and time-sensitive work

| Priority | Current state and next action | Plan |
| --- | --- | --- |
| ART builders, ACM-45318 | Due October 15; New. Addon samples still use Brew. Agree active streams and prepare the main pilot in both Dockerfiles, then qualify the actual image builds and runtime | [Builder inventory and pilot](art-builder-migration.md) |
| 0.23.4, ACM-44527 | Six applicable OCP 4.16–4.21 stage Releases succeeded; catalog/stage children are Resolved. QE installation and production remain pending. Nettest reports ACM-48176 and ACM-48194 need primary logs and artifact attribution | [Recovery evidence](fbc-failure-recovery.md), [QE handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) |
| Durable FBC recovery | FBC #85/#86 remain open at `02ac47d1` / `7c963da2`; required checks pass, Tide is pending. Their publication is separate from the completed recovery Releases | [Recovery plan](fbc-failure-recovery.md) |
| OCP 5 catalog, ACM-48200 | In Progress; tenant MR !23786 and FBC #82 remain prerequisites. Resolve the pre-GA install/readiness conflict before a stage run is executable | [Rollout gates](ocp-5-0-fbc-rollout.md) |
| OCP onboarding automation, ACM-48092 | In Progress; description now separates automation from catalog delivery. Draft #120 remains to land; #119 proposes the operational runbook | [Onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md) |
| Lifecycle publication, OPGM-364 | In Progress; existing lifecycle data needs target publication or allowed IIB/catalog proof, without new 5.0 compatibility claims. Successful 4.x no-op task execution does not fulfill this | [Rollout boundaries](ocp-5-0-fbc-rollout.md) |
| 0.22.2, ACM-45070 | In Progress; retain the September EC-success receipt and later empty progress records. Reconcile the intended bundle/operand identity before selecting a candidate or changing step status | [Candidate evidence](https://github.com/stolostron/submariner-release-management/blob/d01a14fdea6315c69fd46c3a435b4ab79a675e60/plans/current-work.md#release-recovery-and-time-sensitive-work) |

0.24.1 parent ACM-40644 is Resolved. Its previously verified production bundle is `sha256:a8bb318b8afa37daf2ce9394d80c46224e872b593934fbb68fd89e20e6665f84`; this refresh does not repeat index, installation or closure qualification. Earlier October 15 Submariner cluster and GitLab source reads succeeded; the latest live read returned Unauthorized, and the addon session also lacked authentication. Historical DNS/credential failures are not current blockers without a fresh failed read.

## Upstream audit and upgrade tests

The eight FIND-006 Shipyard drafts #2566–2573 were closed without merging; their fixes are not established as shipped. Keep remediation/re-triage separate from upgrade-test repairs.

[Upgrade recovery](upgrade-ci-recovery.md) owns the current dependency/runtime sequence and maintained-stream backports. Shipyard #2654 is open, subctl #1944 remains draft, and issue #2635 remains the acceptance tracker. Shipyard #2656 has merged; #2618 still has a failing scan at its unchanged head and needs a refresh against that remedy, plus fresh OCP SCC admission evidence as a separate gate. Do not repeat the already fixed formatting work or bypass dependency/runtime guards.

## Release tooling and Jira payloads

Release-management #111 and #114–118 are merged. Use main's completed EC/FBC and exact-artifact gates. ACM-39730/39731 already record those merges; tracker retargeting and parent-artifact refresh remain follow-ups. The [autorelease roadmap](autorelease-step-automation.md) owns implementation risks and missing wiring; [skill compatibility](claude-codex-skill-compatibility.md) owns the remaining konflux-ci-fix portability and installed-host checks.

Shipyard #2582 merged October 14 and is already recorded on ACM-39729/39739. The separate go-fix-cves ai-helpers contribution still needs its original generalization/merge acceptance; the agent contribution additionally needs non-Submariner validation. Knowledge transfer ACM-39736 still requires multiple independent releasers completing full releases and reporting gaps.

The old S/K payload sequence is historical. ACM-48092 already tracks onboarding automation; ACM-48200 separately tracks actual 5.0 delivery. Do not create duplicates or replay old comments. The epic's additional Release tooling/Glasswing sections remain an unselected scope decision. The personal Jira triage skill is read-only and does not fulfill ACM-39734's continuous incoming GitHub scrub automation.

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

## Kubernetes plugin qualification and publication

[ai-helpers #617](https://github.com/openshift-eng/ai-helpers/pull/617) remains draft at `1a33dafe`; CORENET-7155 is In Progress. The maintainer originated the design and reports working rebases across six CoreNet repositories through Kubernetes 1.37. That report and published source do not replace the epic's measured evaluations, selected-runtime qualification and upstream merge criteria.

The [historical qualification record](agentic-sdlc-jira-updates-verification.md#kubernetes-rebase-evidence) retains the trial source identities and limits. Current CNCC #276 and Multus #369 still have failing hosted checks. No rebase or model evaluation was rerun here; K1–K5 are unselected retrospective splits.

## Adjacent work with separate ownership and scope

| Work | Current handoff |
| --- | --- |
| EGA planning, CORENET-7615 | In Progress. PR #14 is now ready for review at `8b7c5caf`, with images/verify passing. Jira's dated paragraph still says draft; original review/merge acceptance remains. The description now explicitly separates decision recording from closure criteria |
| EGA lint, CORENET-7664 | In Progress. Draft #15 at `be5ff8b3` supersedes closed-unmerged #11. Preserve the earlier-tool-PR requirement when reviewing its combined tool/consumer scope |
| EGA source proposals | Collection #7 merged; #3 closed unmerged. Image #16 is open; #6 remains an on-hold alternative. Planning/runtime choices stay with their owners; no AWS qualification is inferred |
| MCN CI | CORENET-7171 research is Closed; the 27 implementation subtasks remain To Do. Reconcile header/API coverage and GHA/Prow responsibilities within existing tracking |
| PQC, ACM-41119 | New. The 5.0 addon runtime base is partial source evidence; original acceptance requires built-image DEFAULT:PQ, CI and all applicable operator/operand/must-gather coverage |
| OLMv1, ACM-37426 | New; title and description already target ACM 5.1. Plan fresh-install/migration scope, complete RBAC and prove installation; no repeated milestone correction |
| ART consumption, ACM-45508 | Other-owned, New; linked to ACM-48200. Keep addon consumption/runtime acceptance separate from builder registry migration and lifecycle-only publication |

Private research, restricted issue content and credentials remain outside this repository.
