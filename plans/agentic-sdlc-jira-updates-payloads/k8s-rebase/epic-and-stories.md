<!-- markdownlint-disable MD013 -->

# Exact payloads: epic description and five child stories for CORENET-7155

The epic description is applied; K1–K5 and their comments remain uncreated. Verified October 8, 2026. Posted text below is fixed. Pending text needs a converting client or valid ADF, current metadata and explicit approval.

CORENET Story conventions:

* Project `CORENET` (`10389`), Story (`10009`), parent `CORENET-7155`; legacy Epic Link is absent from create metadata. Assignee is the maintainer; reporter is required with a default and must be verified on read-back.
* Priority Normal (`10003`). Activity Type `customfield_10464`: Product / Portfolio Work (`10610`) or Quality / Stability / Reliability (`10608`), as specified per story.
* Story Points (`customfield_10028`) and sprint (`customfield_10020`) are writable at creation. Original story points (`customfield_10977`) and Git Pull Request (`customfield_10875`, ADF) require a later edit after the new canary confirms support. No epic PR-field edit is proposed.
* Choose points using the team's scale; all values remain placeholders. CORENET-7062 has 1 in both point fields. Automation warns about original points before In Progress/Code Review and sprint before In Progress/Code Review/Closed. Sprint 295 (`87581`, board `9839`) is active, ending October 19; confirm the selected sprint before writing.
* Preserve italic scope/acceptance headings and bullets. Set comment visibility to `Red Hat Employee` at creation. Follow [Part B's canary and read-back sequence](../../agentic-sdlc-jira-updates.md#b6-execution-order).

Current publication: #617 is draft at `1a33dafe05981ceebfaf8fe780b0c448a6310b2d` (143 changed files), with WIP, invalid-OWNERS and needs-ok-to-test labels and no returned current-head review. Direct blob comparison shows its plugin matches October 7 committed source `a477bced` except the two court-test files; the old unpublished-source conclusion is superseded. Fresh qualification of the published source/runtime remains required. No local checkout was re-read or changed by this audit.

Maintainer clarification, October 8: the original title-only epic supplied no specification or design. The architecture and workflow are the maintainer’s original work, reported fully working across all six CoreNet repositories for Kubernetes 1.34.1, 1.35.3 and 1.36.2, and now working for 1.37. The configurations confirm those earlier patch targets. This reports functional coverage; it is not a new independent matrix run or an approval of retained qualification evidence. The older audit records and upstream merge/measurement criteria remain separate.

Historical counts and trial evidence belong to the [verification log](../../agentic-sdlc-jira-updates-verification.md#kubernetes-rebase-evidence), pinned to bak42 `febb7974696e870f933e8ad3741605d31ead0b5c`. Current published-source and qualification limits are in [current work](../../current-work.md#kubernetes-plugin-qualification-and-publication).

## Epic: Create agents to automate the bump (applied)

Fixed applied record: CORENET-7155 `description`, converted to ADF from the exact approved Markdown below. Changelog `92306194`, October 8 at 11:23:37 UTC. Exact ADF and rendered text, nine bullets and two italic headings verified; all six comments, other issue fields and no-child membership preserved. Status remains In Progress. Do not repeat this edit.

```text
The original epic contained only a title, with no specification or design. I originated and implemented the entire k8s-rebase design: the state machine, scripted steps, evidence gates, hooks and repair/review workflow.

The plugin is fully working across all six CoreNet repositories for Kubernetes 1.34.1, 1.35.3 and 1.36.2, and is now working for 1.37. It automates dependency alignment, code generation, version updates and repairs, packaged for Claude Code and Codex in openshift-eng/ai-helpers.

_Scope:_

* The k8s-rebase plugin: a five-step workflow (rebase, compilation, autofix, verification, PR) with gates, scripts, hooks and design docs
* Working rebases across all six CoreNet repositories for Kubernetes 1.34.1, 1.35.3 and 1.36.2
* Evaluations that measure the workflow, including run cost and model
* Kubernetes 1.37 support and qualification
* Upstreaming the plugin to openshift-eng/ai-helpers

_Acceptance criteria:_

* The plugin performs a complete Kubernetes minor rebase of a CoreNet repository end to end, with the gates enforcing each step
* The plugin is qualified on the 1.36.2 rebases and prepared for 1.37
* Evaluations with cost and model data exist and are documented
* The plugin is merged in openshift-eng/ai-helpers
```

## Story K1: Build the k8s-rebase plugin

* Summary: `Build the k8s-rebase plugin: a gated state machine for Kubernetes rebases`
* Activity Type: Product / Portfolio Work (`10610`); Priority Normal; story points: placeholder (maintainer to choose)
* Target status: In Progress, after points and sprint are set; discover the issue's available transition.
* Git Pull Request: `https://github.com/openshift-eng/ai-helpers/pull/617`

```text
Build the plugin that automates a Kubernetes minor-version rebase of a Go project: align dependencies across modules, regenerate code, update version references, and fix build, lint and test breakage. A state machine owns progress; scripts do the repeatable work, the agent repairs, and verification gates decide when a step may advance. The design guide explains how this structure resists an agent claiming success it has not earned.

_Scope:_

* Five-step workflow (rebase, compilation, autofix, verification, PR) with shared rules
* 32 verification gates with explicit verdict rules: a gate that did not run is never passed or skipped
* Scripts for the repeatable work, and hooks
* Docs: design guide, runtime compatibility, repair patterns, Kubernetes 1.37 notes
* Unit and integration tests for the tooling

_Acceptance criteria:_

* A complete rebase of a CoreNet repository runs end to end with every gate enforced
* Verification evidence is retained and a run cannot pass with missing evidence
* Tests pass in CI
```

Progress comment (post after creation):

```text
I originated and implemented the architecture and workflow from a title-only epic with no specification. The plugin is fully working across all six CoreNet repositories for Kubernetes 1.34.1, 1.35.3 and 1.36.2, and now working for 1.37.

October 8: the five-step workflow, gates, hooks and retained-evidence contracts are published in https://github.com/openshift-eng/ai-helpers/pull/617 at 1a33dafe05981ceebfaf8fe780b0c448a6310b2d. Its plugin matches the October 7 committed source except two court-test files.

Publication does not establish installed-runtime or CI qualification of this source.
```

## Story K2: Qualify k8s-rebase on the 1.36.2 rebases

* Summary: `Qualify k8s-rebase on the Kubernetes 1.36.2 rebases of CoreNet repositories`
* Activity Type: Product / Portfolio Work (`10610`); Priority Normal; story points: placeholder
* Link: `Related` to CORENET-7062 (the closed story for the ovn-kubernetes-mcp bump, which the agent's merged PR completed)
* Target status: In Progress pending evidence/acceptance review; set points and sprint first. PR counts and legacy PASS rows do not establish both criteria below.
* Git Pull Request: `https://github.com/ovn-kubernetes/ovn-kubernetes-mcp/pull/57`

```text
Run the plugin against real Kubernetes 1.36.2 rebases of CoreNet repositories to find where it breaks and to qualify the workflow.

_Scope:_

* First runs against ovn-kubernetes, ovn-kubernetes-mcp, multus-cni, cluster-network-operator, cloud-network-config-controller and ingress-node-firewall; preserve the separate repository-delivery scope under CORENET-6983
* A larger batch of qualification runs, opened as draft PRs from a fork and closed afterwards, across five repositories
* Feed the findings back into the gates, repair patterns and docs

_Acceptance criteria:_

* The agent produces a rebase branch and PR for each target repository
* Failures found during the runs are fixed in the plugin or documented as known limits
```

Progress comment (post after creation):

```text
Recorded 1.36.2 work:

* June 9–10: [ovn-kubernetes-mcp#57](https://github.com/ovn-kubernetes/ovn-kubernetes-mcp/pull/57) merged; [ovn-kubernetes#6525](https://github.com/ovn-kubernetes/ovn-kubernetes/pull/6525), [multus-cni#305](https://github.com/openshift/multus-cni/pull/305), [cluster-network-operator#3027](https://github.com/openshift/cluster-network-operator/pull/3027), [cloud-network-config-controller#225](https://github.com/openshift/cloud-network-config-controller/pull/225) and [ingress-node-firewall#718](https://github.com/openshift/ingress-node-firewall/pull/718) closed without merging.
* July 16–23: 108 closed draft PRs across CNCC, ingress-node-firewall, Multus, MCP and CNO. These count PRs, not independently accepted runs.

Legacy PASS summaries exist for all six targets but lack the current per-run evidence archive. Per-target source/result, gates and failure dispositions remain unqualified; story acceptance is pending.
```

## Story K3: Evals and cost/model measurement

* Summary: `Add evaluations and cost and model measurement for k8s-rebase`
* Activity Type: Quality / Stability / Reliability (`10608`); Priority Normal; story points: placeholder
* Target status: In Progress, using the issue's available transition after points and sprint are set.

```text
A reviewer on the pull request asked whether the plugin has any eval, cost estimation or specific model measurement, and noted that other plugins in the marketplace use a shared eval harness. The plugin has an evaluation guide, a set of cases and test harness isolation for eval runs; this story makes the measurements explicit and decides how they relate to the marketplace harness.

_Scope:_

* Document how to run the evals, and record run duration, cost and model with each result
* Keep the evals isolated and retain evidence from interrupted runs
* Decide whether to adopt the marketplace's shared eval harness or document why the plugin's own is used, and answer the reviewer on the PR

_Acceptance criteria:_

* The eval procedure is documented and reproducible, with duration, cost and model recorded per run
* The question on the pull request is answered with data
```

Progress comment (post after creation):

```text
Source includes 16 pattern-retention cases and a runner capturing model, tokens, turns and cost. The guide's $17–27 light/$40–60 heavy estimates are not a fresh benchmark. The runner collects artifacts without executing YAML judges; missing-result zero metrics do not supply valid measurements.

Valid per-run measurements and judge outcomes, the shared-harness decision and an answer with measured data to the reviewer's cost/model question remain unfinished.
```

## Story K4: Kubernetes 1.37

* Summary: `Prepare and validate Kubernetes 1.37 rebases in k8s-rebase`
* Activity Type: Product / Portfolio Work (`10610`); Priority Normal; story points: placeholder
* Target status: In Progress, using the issue's available transition after points and sprint are set.

```text
The next Kubernetes minor changes APIs and tooling the plugin relies on. Prepare the plugin for 1.37 and validate it against the published 1.37 patch release.

_Scope:_

* 1.37 preparation and validation in the plugin, with notes in docs/k8s-1.37.md
* Tests that target the published 1.37.1 patch; plugin qualification is separate from the repository-delivery bumps already tracked under CORENET-7450
* A real 1.37 rebase of at least one CoreNet repository

_Acceptance criteria:_

* The plugin is validated for 1.37 by its tests
* A 1.37 rebase of a CoreNet repository completes end to end with the gates enforced
```

Progress comment (post after creation):

```text
October 7 retained 1.37.1 trials cover CNCC, Multus and MCP, with [source pins and limits](https://github.com/stolostron/submariner-release-management/blob/49a9f0f9d1c290bec3062af5670ec2fcaf6493fd/plans/agentic-sdlc-jira-updates-payloads/k8s-rebase/epic-and-stories.md#story-k4-kubernetes-137). CNCC needs requalification; Multus has two inconclusive gates; MCP has three failed and two inconclusive gates, incomplete lint/security coverage and CI selecting 1.36.4.

The published plugin at 1a33dafe still needs fresh source/runtime qualification. Further repository runs remain deferred while MCP is corrected and qualified.
```

## Story K5: Upstream the plugin

* Summary: `Upstream k8s-rebase into openshift-eng/ai-helpers`
* Activity Type: Product / Portfolio Work (`10610`); Priority Normal; story points: placeholder
* Target status: In Progress, using the issue's available transition after points and sprint are set.
* Git Pull Request: `https://github.com/openshift-eng/ai-helpers/pull/617`

```text
Get the plugin merged into the openshift-eng/ai-helpers marketplace.

_Scope:_

* Review the published source at 1a33dafe and reconcile any further source changes before qualification; bak42 and the October 7 commit counts are historical snapshots
* Resolve the automation blockers on the PR: the invalid OWNERS file (reported nonmembers; repair it according to repository requirements and re-run /verify-owners), needs-ok-to-test, and approvals from the file owners
* Answer reviewer questions, including the eval and cost question (see the evals story)
* Take the PR out of draft when ready

_Acceptance criteria:_

* The pull request is merged
```

Progress comment (post after creation):

```text
https://github.com/openshift-eng/ai-helpers/pull/617 remains draft at 1a33dafe05981ceebfaf8fe780b0c448a6310b2d with WIP, invalid-OWNERS and needs-ok-to-test labels at the October 8 read. No current-head review is returned. Automation reported nonmembers in OWNERS. The reviewer's eval/cost/shared-harness question remains tracked in K3.
```
