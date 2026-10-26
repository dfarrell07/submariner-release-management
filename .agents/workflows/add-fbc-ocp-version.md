# Add an OCP version to Submariner FBC

Use the existing `add-fbc-ocp-version` skill or `scripts/add-fbc-ocp-version.sh`.
It accepts full OCP identities such as `4.22`, `4-22`, `5.0`, and `5-0`.
Python 3 with PyYAML, Git, jq, yq, Kustomize, and the FBC build prerequisites are
required. Repository paths are explicit options, not assumptions about cwd.
For an installed skill, its wrapper's `--workflow` returns this document's path
in the verified `RELEASE_MANAGEMENT_REPO` checkout.

## Plan and inputs

```bash
./scripts/add-fbc-ocp-version.sh 5.0 --min-supported-sub 0.24
```

This command is read-only. The minimum is inclusive: `0.24` includes streams
0.24 and newer. `drop-versions.json` retains its existing exclusive semantics,
so the equivalent map entry is `"5.0": "0.23"`. A legacy positional `0.23`
remains a cutoff and emits a warning. If the supported stream is undecided,
omit it for planning and configuration. When the user explicitly authorizes
provisional defaults, choose the populated default-channel stream and its head
from the selected template; pass that minimum explicitly and record the bundle
digest and provisional status in the change description. Reuse real catalog
inputs and complete preparation and image testing. This does not establish
product compatibility or require changing the bundle's compatibility metadata.

To resolve the stream, compare with the ACM release that ships it (Submariner
0.N pairs with ACM 2.(N-7); ACM 5.0 follows 2.17). ART's FBC targets are
`OCP_TARGET_VERSIONS` in `group.yml` on the `acm-<X.Y>` branch of
[ocp-build-data](https://github.com/openshift-eng/ocp-build-data), and that
ACM branch's submariner-addon `defaultCatalogChannel` is the channel it subscribes
to. Include a stream only where its ACM release targets the OCP version, and keep
that channel present. Check the production index too, for example
`registry.redhat.io/redhat/redhat-operator-index:v5.0`: ACM packages there and
missing `submariner` show a gap for the addon.

The plan reports the local base commits and explicitly does not claim remote
freshness. Fetch both repositories before preparation. A failed fetch blocks
claims of freshness; cached bases can still support a clearly identified draft.
Review the base-image tag and architectures with registry inspection. OCP 5.0
uses `registry.redhat.io/openshift5/ose-operator-registry-rhel9:v5.0`; do not
change the RHEL generation merely because the OCP major changes.
An override must retain the requested `:vX.Y` tag without a registry port: the deployed release filter
derives the index version from the base annotation. A digest-only override cannot
establish the release version with the current Dockerfile. Target-version labels
also need review: they override the base in release, and the pinned pruning task
does not consume their array format. The helper rejects that unreviewed path.
For another major transition, inspect the pinned build-task helpers as well as
base availability. The [reviewed helper][version-helper] accepts 4.x/5.x and explicitly maps the
predecessor of 5.0 to 4.22; a later major can require an upstream task update.

Pin the repositories independently with `--release-data-ref` and `--fbc-ref`.
Both default to `origin/main`; `--base` is a shorthand only when the same ref name
works in both repositories. A shared commit SHA normally cannot. The plan reports
resolved SHAs, independently selected overlay/pipeline predecessors, and blockers.
Use `--overlay-previous`/`--pipeline-previous` only to select a reviewed predecessor.
Select the release-data-required Kustomize version with `--kustomize` if needed.

## Complete an add or resume request

After reviewing the plan and resolving the minimum stream, run the complete local
sequence with the same repository paths, immutable refs and workspace:

```bash
./scripts/add-fbc-ocp-version.sh 5.0 --min-supported-sub 0.24 \
  --release-data-ref <release-data-sha> --fbc-ref <fbc-sha> \
  --workspace /path/to/ocp-5-work --phase prepare
./scripts/add-fbc-ocp-version.sh 5.0 \
  --workspace /path/to/ocp-5-work --phase test-image
```

`prepare` runs configuration, catalog preparation and local verification. The image
phase explicitly selects the requested catalog and OCP base. Progress goes to stderr;
successful phases emit JSON on stdout. Run repository checks, review the three diffs,
and commit when authorized. An add request continues beyond a read-only plan.
Reruns use the same workspace/refs; a base mismatch requires reviewing and rebasing
the existing work or selecting a fresh workspace. No automated reset or overwrite.
The separate phases below remain useful when policy or a repository is unavailable.

## Prepare configuration

```bash
./scripts/add-fbc-ocp-version.sh 5.0 --phase prepare-config \
  --workspace /path/to/ocp-5-work \
  --release-data-repo /path/to/konflux-release-data
```

This creates separate `tenant` and `admission` worktrees. It never switches the
source checkout, deletes an existing branch, commits, pushes, or applies. Reruns
reuse only matching worktrees and validate existing output instead of overwriting
it. Choose a different workspace if an unrelated branch already exists.
This phase needs no FBC checkout or minimum Submariner stream.

The tenant change adds eight overlay files, registers the overlay, runs the
repository's `build-manifests.sh` for this tenant, and validates seven generated
resource identities and their application/image/test relationships. The new
operator ITS uses the package default channel, avoiding the nonexistent `stable`
channel. New 5.x overlays omit the entire `CHANNEL_NAME` parameter to inherit
the reviewed 0.3 pipeline's empty default. An explicit empty ITS value becomes
null during integration-service materialization and Tekton rejects the run.
New 5.x overlays use the upstream `deploy-fbc-operator` 0.3 pipeline via
`pipelineruns/deploy-fbc-operator/0.2/deploy-fbc-operator-run.yaml`, which supplies
its workspace. They explicitly select the image-push secret's `.dockerconfigjson`
key. The existing 4.x overlays keep their selected install path. Both release plans
retain manual release. Admissions add the application
to the existing stage/prod RPAs without changing shared policy or destinations.

Follow `konflux-release-data/AGENTS.md`: run `tox` and the tenant checks in the
appropriate worktrees, review CODEOWNERS coverage, and keep the tenant and managed
admission changes separately reviewable. Merge/reconcile configuration before
expecting service accounts, image-push secrets, PAC, or release-plan matching.
Confirm both live release plans match their admissions and retain autorelease off.

## Prepare catalog and pipelines

The FBC safety changes (isolated tests and staged builds) must be present in the
selected `--fbc-ref`. Use a populated supported stream already in the template.

```bash
SKIP_AUTH_TESTS=true ./scripts/add-fbc-ocp-version.sh 5.0 \
  --min-supported-sub 0.24 --phase prepare-catalog \
  --workspace /path/to/ocp-5-work
```

This phase needs no release-data checkout. It checks the selected base's four
platforms before creating worktrees. For the final validation run authenticated
FBC tests as well; explicitly skipped authentication tests are not evidence of access.

The `fbc` worktree contains the cutoff map, rendered catalog, and push/PR pipeline
pair, with all four build platforms, the exact catalog INPUT_DIR, matching
service account, event-specific tags/expiry, and both pipeline files in CEL
triggers. Generation validates a populated default channel and runs the FBC
checks. No fixed file/commit count is assumed.
Preparation renders only the requested catalog, validates the complete candidate,
and publishes only the requested files. Tenant generation runs in scratch space;
fresh rendering must match the stored seven objects. Unrelated files and index
entries remain intact. Unknown pipeline task families or unresolved references
require review; they cannot be reported as locally ready.

PAC may create an onboarding PR, but this has failed for prior versions. Search
for an existing PR by component, branch, and contents; do not guess its title or
number. Either adapt that PR or use the helper's manual pipeline pair copied from
the preceding merged pipeline. Preserve `pipelineRef` versus `pipelineSpec`.
Do not overwrite an existing pipeline pair: validate it and reconcile differences.
Check a known catalog file through the GitHub contents API; directory responses
are arrays, not objects with a `.name` field.

For the selected PR, record `headRefOid` with `gh pr view`, then inspect both
effective rules and legacy protection:

```bash
gh api repos/stolostron/submariner-operator-fbc/rules/branches/main
gh api repos/stolostron/submariner-operator-fbc/branches/main/protection/required_status_checks
gh api --paginate repos/stolostron/submariner-operator-fbc/commits/<head-sha>/check-runs
gh api --paginate repos/stolostron/submariner-operator-fbc/commits/<head-sha>/statuses
```

Compare required contexts and their `integration_id`/`app_id` with the current
head's check-run app IDs. A legacy protection 404 alone does not establish that
there are no required checks; an inaccessible rules endpoint leaves this unknown.
Recheck the head after updates. The `Image Build & Test` context exercises changed
catalogs (all catalogs for shared build changes) with public upstream OPM. The
skill's explicit target-base test and Konflux build provide the OCP-base evidence.

## Verify evidence

`--phase verify --workspace ... --min-supported-sub ...` checks local artifacts.
It explicitly reports deployment, multiarch build, and runtime status as unverified.
After deployment, run the read-only live checks with the expected merged SHA:

```bash
./scripts/add-fbc-ocp-version.sh 5.0 --phase verify-live \
  --expected-commit <40-character-merged-commit> \
  --expected-lifecycle /path/to/reviewed/lifecycle.json
```

This checks live resource relationships, actual matched RPA contracts, build-account
ownership and secret bindings, completed snapshot tests, and merged-main ancestry.
Completed tests use the same rule as `fbc_tests_passed`: finished passing aggregate
conditions and a completion time for every scenario. The tenant's standard scenario
retains `BuildPLRInProgress` after passing, so that marker counts only with this
completion evidence.
It links the original push build to its snapshot and image, checks effective build
arguments and all four base annotations, then extracts each platform's catalog and
compares every source catalog file with the pinned merged source and template/cutoff
contract. For OCP 5+, the required injection task adds `lifecycle.json`. Supply
`--expected-lifecycle` with a separately reviewed reference from that original
build's digest-pinned lifecycle `SOURCE_ARTIFACT`. Confirm the TaskRun belongs to
the expected push PipelineRun, succeeded, reports successful injection in
`TEST_OUTPUT`, and uses the reviewed task/image pins. Record its artifact digest
and the reference file's SHA256 with the rollout evidence. Do not create the
reference by extracting it from the catalog image being verified: that would only
compare the image with itself.

The pinned artifact utility stores a gzip tar **blob**, identified as
`oci:<repository>@sha256:<archive-digest>` ([archive creation][ta-create],
[restoration][ta-use]). Use an existing ORAS registry login with pull access to
that repository; set `REGISTRY_AUTH_FILE` to its authentication file and
`SOURCE_ARTIFACT` to the checked TaskRun's output URI. Run this Bash recipe to
verify the archive digest and copy only the expected regular-file member:

```bash
(
set -euo pipefail
[[ "$SOURCE_ARTIFACT" =~ ^oci:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]
EVIDENCE=$(mktemp -d)
oras blob fetch --registry-config "$REGISTRY_AUTH_FILE" \
  --output "$EVIDENCE/lifecycle-source.tar.gz" "${SOURCE_ARTIFACT#oci:}"
printf '%s  %s\n' "${SOURCE_ARTIFACT##*@sha256:}" \
  "$EVIDENCE/lifecycle-source.tar.gz" | sha256sum --check -
python3 - "$EVIDENCE/lifecycle-source.tar.gz" "$EVIDENCE/lifecycle.json" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = [m for m in archive.getmembers()
               if m.name == "./catalog-5-0/lifecycle.json"]
    if len(members) != 1 or not members[0].isfile():
        raise SystemExit("Expected one regular ./catalog-5-0/lifecycle.json")
    with archive.extractfile(members[0]) as source:
        pathlib.Path(sys.argv[2]).write_bytes(source.read())
PY
sha256sum "$EVIDENCE/lifecycle.json"
printf 'Retain evidence and review reference: %s\n' "$EVIDENCE"
)
```

This member path follows the current 5.0 build's source root and Dockerfile;
recheck it if executed context/build arguments change. Retain the archive and
TaskRun evidence, review the reference, then pass its path to
`--expected-lifecycle`. Authenticated extraction from a qualifying original 5.0
build remains to be verified when that build exists.

[ta-create]: https://github.com/konflux-ci/build-trusted-artifacts/blob/215356989cc461d435a3147819f0637b29357702/create-oci.sh#L72
[ta-use]: https://github.com/konflux-ci/build-trusted-artifacts/blob/215356989cc461d435a3147819f0637b29357702/use-oci.sh#L71

The verifier checks the reference's Submariner schema/package, records its SHA256,
and requires the exact reference bytes on all four platforms. Every other file
still has to match Git exactly; missing lifecycle data, additional files and
symlinks fail. The reference is an explicit reviewed input; the verifier does not
authenticate its external provenance or establish lifecycle support policy.
Configuration and build results remain separate when one check is unavailable.
It still reports runtime compatibility as unverified. For scoped release creation,
set `FBC_EXPECTED_COMMIT` to that merged SHA and pass `--ocp 5.0`.
For remote readiness, record distinct evidence:

- Configuration: live Application, Component, ImageRepository, both ITS objects,
  both matched ReleasePlans, service account, and image-push secret exist.
- PR: required checks exist and succeed for the exact current head SHA. Pending,
  skipped, cancelled, failed, and absent required checks are not success.
- Build: merged-main push PipelineRun succeeds for the expected commit; all four
  manifest platforms exist; each catalog image preserves the base-image annotation
  consumed by the deployed release-service filter; `opm validate /configs` and the
  gRPC health probe succeed using the OCP-specific base.
- Release: snapshot has the intended bundle digest and completed passing tests;
  source SHA matches the expected merged commit. Use `--ocp 5.0` for a scoped
  initial release. Prod must reuse the exact stage snapshot QE validated.
- Runtime: operator installation actually ran with the intended bundle/channel,
  and the provisioned cluster reports 5.0. A fallback 4.x cluster or no-op install
  does not establish OCP 5 support. Record QE evidence separately.

Initial 5.x preparation keeps the operator scenario optional while the install
prerequisites are unavailable. Once installation is required, change its label to
`test.appstudio.openshift.io/optional: "false"` and regenerate the manifests.
Both states are accepted for 5.x configuration verification; completed passing
snapshot results and actual installation evidence remain separate gates. The
standard scenario and 4.x operator scenarios must remain required.

For the 0.3 install path, confirm access to its configured OpenShift CI cluster
profile (the upstream default is `aws-konflux-prod`) before provisioning.
A tenant that is not an owner of the profile in `openshift/release`
(`cluster-profiles-config.yaml`) is rejected at once, but `provision-cluster`
keeps polling the `InitializationFailed` phase for its full 2-hour timeout and
then exits 255. The claim status dumped at the end of the step log shows the
cause, for example `konflux cluster "kflux-prd-rh02" and tenant
"submariner-tenant" don't own the cluster profile "aws-konflux-prod"`
(`EphemeralClusterValidationFailure`). Fix ownership first; the OCP release
check below only matters after it.
The upstream pipeline requests the OCP `stable` channel for the fragment's
version, which gets its first release (x.y.0) on GA day. Check
`https://api.openshift.com/api/upgrades_info/v1/graph?channel=stable-5.0&arch=multi`.
While it has no nodes, provisioning fails: rerun the scenario after GA. If a
release is needed sooner, point the ITS at a temporary pipeline copy that
requests `candidate`, and remove it at GA.
Provisioning and deployment run only on push events, so retrigger a push
snapshot; a PR-event pass skips all of it. The test and build PipelineRuns are
pruned within hours, so save the `provision-cluster` step log and the claim
status from the Konflux UI before they disappear.
Inspect the resolved PipelineRun and TaskRuns for `get-unreleased-bundle`,
`pick-cluster-params`, `provision-cluster` and `deploy-operator`: the selected bundle
digest/channel must be the approved one and `deploy-operator` must have executed
successfully. Use the provisioned cluster's `oc get clusterversion version -o json`
to record its actual `status.desired.version`, alongside the installed CSV and
bundle digest. The upstream pipeline still skips installation for PR events or
when it finds no unreleased bundle. For an approved released bundle, use the
existing explicit-bundle QE installation procedure on an observed 5.0.x cluster.
Neither an aggregate ITS pass nor the requested provisioning version replaces
that evidence. See the upstream [0.3 migration](https://github.com/konflux-ci/tekton-integration-catalog/blob/1251d2990cee3f562325b48fe3404bce4f8c857f/pipelines/deploy-fbc-operator/0.3/MIGRATION.md).

Only after readiness is established, add `5-0` to the active list in
`scripts/lib/fbc-scope.sh`. Syntax support alone must not activate release scope.
Use `get-fbc-urls.sh --prod-index` to verify bundle membership before advertising
public index URLs. Registry reachability and bundle-tag existence alone are
insufficient.

## Reproduce the onboarding E2E test

The runner uses disposable repositories and 0.24 as explicit test data. It reads
release-data from the selected Git ref, includes the FBC candidate's uncommitted
changes, and enters through a copied installed skill. It runs complete preparation,
image testing and repeat verification. It verifies source file and Git-index preservation,
byte-for-byte repeatability, seven tenant objects, both admissions, both pipelines,
real target catalog rendering, mixed-major validation, and image validation plus gRPC serving.
It also rejects a conflicting minimum and verifies without the source repos.
Synthetic 4.23, 5.0 and 5.1 generation checks reuse without asserting availability.
Registry access, Podman, Kustomize >=5.7.1, and FBC build prerequisites are needed.

```bash
python3 scripts/tests/e2e_fbc_onboarding.py \
  --release-data-repo /path/to/konflux-release-data \
  --release-data-ref <release-data-sha> \
  --fbc-repo /path/to/submariner-operator-fbc \
  --kustomize /path/to/kustomize
```

Do not edit the two input repositories while this runs: the test checks their
complete file state afterward. Fixture commits and the temporary image are local
and disposable. This test does not establish supported Submariner stream policy
or operator compatibility on a running OCP 5 cluster.

[version-helper]: https://github.com/konflux-ci/konflux-test/blob/2cd9f355216aebb72213c14118243ce9d66c181e/test/utils.sh
