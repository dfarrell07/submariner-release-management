<!-- markdownlint-disable MD013 -->

# OCP 5.0 FBC Rollout Plan (Release Management Runbook)

Updated 2026-10-16. Consolidates release management planning and execution gates for onboarding Submariner's File-Based Catalog (FBC) to OpenShift 5.0.

> [!NOTE]
> This runbook covers release management for OCP 5.0. Release management owns the automated install test; QE follows the normal stage handoff. The reusable procedure is the [add-fbc-ocp-version workflow](../.agents/workflows/add-fbc-ocp-version.md).

---

## 1. Evidence & Current State (as of October 16, 2026)

| Area | Status | Active Gate / Immediate Action |
| :--- | :--- | :--- |
| **Catalog & Tooling** | Merged on FBC `main` ([PR #81](https://github.com/stolostron/submariner-operator-fbc/pull/81)). Pinned to Submariner 0.24 (0.24.0/0.24.1), which matches ACM 2.17: ART targets ACM 2.17 at OCP 5.0, only ACM 2.17.x is in the v5.0 production index, and the 2.17 and 5.0 addons subscribe to `stable-0.24`. | Catalog passes `make validate-catalogs` and `make test-image` against OCP 5.0 base. |
| **Tekton Pipelines** | Open Draft ([FBC PR #82](https://github.com/stolostron/submariner-operator-fbc/pull/82)). Four platforms, RHEL9 registry base, lifecycle injection. | Blocked on `build-pipeline-submariner-fbc-5-0` SA creation from Phase 1. |
| **Tenant & Admission GitOps** | Submitted on branch `submariner-fbc-5-0` ([MR !23786](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/23786), Jira [ACM-48200](https://redhat.atlassian.net/browse/ACM-48200)). | Merge !23786 to reconcile tenant resources via ArgoCD. |
| **Registry Access** | Live cluster verification: `submariner-konflux-registry-redhat-io` is already linked in `secrets:` on `konflux-integration-runner`. | Prevents 401 Unauthorized errors during `get-unreleased-bundle` on push. |
| **Install-Test Cluster Access** | Open Draft ([openshift/release #87176](https://github.com/openshift/release/pull/87176)) grants `submariner-tenant` the `aws-konflux-prod` cluster profile. | Merge before expecting a push install (Phase 3). |
| **Install-Test OCP Channel** | The upstream `deploy-fbc-operator` 0.3 pipeline always requests the OCP `stable` channel. `stable-5.0` is empty until GA; 4.19 through 4.22 each got x.y.0 in `stable` on GA day. | No change needed: rerun the install test after GA. If the stage release is needed before GA, point the 5-0 operator ITS at a temporary pipeline copy that requests `candidate` (as cost-management did), and remove it at GA. |
| **Task Trust** | `policy-data` enables `trusted_task_rules`, so Conforma trusts `tekton-catalog` tasks by version rule; acceptable-bundle digest expiry dates are not enforced. | No pin deadline. Recheck deny rules if task versions change. |
| **Lifecycle Data** | Lifecycle data is a release gate since October 1 ([OPGM-364](https://redhat.atlassian.net/browse/OPGM-364)). #82 runs `fbc-inject-lifecycle`; the Phase 5 production release satisfies OPGM-364's v5.0 criterion. | Lifecycle data must not list 5.0 compatibility before October 20 (OPGM-261). |
| **Release Scope** | Current default scope in `scripts/lib/fbc-scope.sh` remains `4-16` through `4-22`. | Activate `5-0` only after Phase 5 production index publication. |

---

## 2. Phase 1: Reconcile Tenant & Admission GitOps (`konflux-release-data`)

> **Working Directory:** `konflux-release-data` repository root  
> **Merge Request:** [!23786](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/23786) (Branch `submariner-fbc-5-0`)  
> **Tracking Jira:** [ACM-48200](https://redhat.atlassian.net/browse/ACM-48200)

The MR adds the 5-0 overlay, its seven generated tenant objects and the 5-0 entries in both shared RPAs. A Submariner CODEOWNER other than the author must approve. ArgoCD reconciliation creates the Component, and build-service then provisions `build-pipeline-submariner-fbc-5-0`. Expect a build-service bot PR for the 5-0 pipelines; close it, because #82 carries the reviewed pair.

**Exit Gate:** `oc get sa build-pipeline-submariner-fbc-5-0 -n submariner-tenant` returns successfully.

---

## 3. Phase 2: Unblock and Merge FBC Pipelines (`submariner-operator-fbc`)

> **Working Directory:** `submariner-operator-fbc` repository root

Once the build service account is live from Phase 1:

1. Mark PR #82 ready (`gh pr ready 82`) and comment `/retest` to rerun the Konflux build.
2. Verify the four-platform build and all required checks pass at the PR head, and get review.
3. Merge PR #82.

**Exit Gate:** PR #82 merged to `main`; `submariner-fbc-5-0-on-push` pipeline triggers automatically on `main`.

---

## 4. Phase 3: Push Pipeline & Snapshot Verification

> **Working Directory:** `submariner-release-management` repository root

1. **Push PipelineRun**:
   * The push pipeline builds all four architectures against base image `registry.redhat.io/openshift5/ose-operator-registry-rhel9:v5.0`.
   * Executes `fbc-inject-lifecycle-oci-ta` and forwards results.
2. **Integration Test Scenarios**:
   * The `operator` scenario runs with the linked `submariner-konflux-registry-redhat-io` secret.
   * The `get-unreleased-bundle` step pulls and renders `registry.redhat.io/redhat/redhat-operator-index:v5.0` without 401s.
   * `provision-cluster` needs `aws-konflux-prod` access ([openshift/release #87176](https://github.com/openshift/release/pull/87176)) and a release in `stable-5.0`, expected on GA day (see the table above). Until both are in place, the push install fails. PR events skip installation.
   * Once both are in place, rerun the scenario on the newest `submariner-fbc-5-0` push snapshot at the merged SHA instead of rebuilding (initial tests finished, no rerun pending), and wait for the new run to complete before `verify-live`:

     ```bash
     oc label snapshot <push-snapshot> -n submariner-tenant \
       test.appstudio.openshift.io/run=submariner-fbc-operator-5-0
     ```

3. **Provenance & Verification**:
   * Run the onboarding verification helper:

     ```bash
     ./scripts/add-fbc-ocp-version.sh 5.0 --phase verify-live --expected-commit <merged-SHA>
     ```

   * Confirms matched admissions, account bindings, push provenance, completed passing tests (including the operator scenario), and that all platform catalog contents match merged source.
   * Requires [PR #120](https://github.com/stolostron/submariner-release-management/pull/120): without it, verify-live rejects the standard scenario's retained `BuildPLRInProgress` marker and #82's upstream-style build-image-index params.

**Exit Gate:** The operator scenario passes on the merged-source push snapshot and `verify-live` passes across all four architectures. Record that snapshot; Phase 4 releases it.

---

## 5. Phase 4: Stage Release Creation & QE Handoff

> **Working Directory:** `submariner-release-management` repository root

1. **Create Stage Release Manifest**:
   * Issue the Stage Release for the verified snapshot (requires `oc login` authentication on `main` branch):

     ```bash
     FBC_EXPECTED_SNAPSHOTS='{"5-0":"<push-snapshot>"}' FBC_EXPECTED_COMMIT=<merged-SHA> \
       ./scripts/create-fbc-releases.sh 0.24.1 stage --ocp 5.0
     ```

   * The script requires every test scenario to have passed, so a failed operator install blocks this step.
   * Pinning keeps a later merge's snapshot from being released. This verifies snapshot readiness, validates enterprise contracts, and generates/commits `releases/fbc/5-0/stage/submariner-fbc-5-0-0-24-1-stage-<date>-<seq>.yaml`.
2. **Apply Stage Release & Monitor Execution**:
   * Apply the Release custom resource to the Konflux cluster:

     ```bash
     STAGE_YAML=$(ls -t releases/fbc/5-0/stage/submariner-fbc-5-0-0-24-1-stage-*.yaml | head -1)
     make apply FILE="$STAGE_YAML"
     make watch NAME="$(basename "$STAGE_YAML" .yaml)"
     ```

   * Stage releases intentionally do not publish to the index (`mustPublishIndexImage=false`).
3. **QE Handoff**:
   * Share the stage fragment from the successful 5-0 stage Release using the [QE handoff workflow](../.agents/workflows/share-with-qe.md).

**Exit Gate:** Stage release completed with 0 policy violations; QE approves the staged artifacts.

---

## 6. Phase 5: Production Release & Default Scope Activation

> **Working Directory:** `submariner-release-management` repository root

1. **Verify Pyxis Opt-In**:
   * Ensure `rhacm2/submariner-operator-bundle` has active Pyxis `fbc_opt_in` (requires active Kerberos ticket for Red Hat Pyxis SSO):

     ```bash
     kinit
     curl -s --negotiate -u : "https://pyxis.engineering.redhat.com/v1/repositories/registry/registry.redhat.io/repository/rhacm2/submariner-operator-bundle" | jq '.fbc_opt_in'
     ```

2. **Create Production Release Manifest**:
   * Issue production release (executed on `main`; reuses verified stage snapshot without cluster calls):

     ```bash
     ./scripts/create-fbc-releases.sh 0.24.1 prod --ocp 5.0
     ```

   * Generates and commits `releases/fbc/5-0/prod/submariner-fbc-5-0-0-24-1-prod-<date>-<seq>.yaml`.
3. **Apply Prod Release & Monitor Execution**:
   * Apply the Release custom resource to the Konflux cluster:

     ```bash
     PROD_YAML=$(ls -t releases/fbc/5-0/prod/submariner-fbc-5-0-0-24-1-prod-*.yaml | head -1)
     make apply FILE="$PROD_YAML"
     make watch NAME="$(basename "$PROD_YAML" .yaml)"
     ```

   * Read the `prepare-fbc-parameters` task log to confirm:
     * `Must Publish Index: true`
     * `Must Sign Index: true`
     * `Must Overwrite From Index: true`
4. **Confirm Published Index**:
   * Confirm bundle presence in the published index:

     ```bash
     ./scripts/get-fbc-urls.sh 0.24.1 --ocp 5.0 --prod-index
     ```

5. **Activate Default Scope**:
   * Update `scripts/lib/fbc-scope.sh` to include `5-0`:

     ```bash
     : "${FBC_OCP_VERSIONS:=4-16 4-17 4-18 4-19 4-20 4-21 4-22 5-0}"
     ```

   * From this point forward, standard release commands (`autorelease.sh`, `create-fbc-releases.sh`) will automatically include OCP 5.0.
