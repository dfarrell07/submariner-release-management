# Create FBC stage releases

Run the existing release helper from this repository:

```bash
make create-fbc-releases VERSION=0.24.1
# Initial onboarding can select a complete OCP version explicitly:
make create-fbc-releases VERSION=0.24.1 OCP=5.0
```

Without `OCP`, candidates come from `FBC_OCP_VERSIONS` in
`scripts/lib/fbc-scope.sh`; the verifier narrows them to catalogs containing the
requested bundle. Retained retired catalogs are not release targets. A missing
bundle is distinct from an unreachable registry or GitHub fetch error. A new
major remains outside the active list until onboarding readiness is established.
Set `FBC_EXPECTED_COMMIT` to pin the expected merged FBC commit when needed.

## Verify the candidate before generating YAML

The helper checks source, catalog, bundle and component identities. Independently
confirm these identities and completion evidence; older checkouts lack strict gates:

- Its JSON names the exact intended snapshot for each applicable target, with
  the expected source revision and immutable image digest. Older checkouts can prefer
  an older PaC push over a manual replacement at the same commit. Where supported,
  set `FBC_EXPECTED_SNAPSHOTS` to a JSON map of OCP IDs to exact snapshot names.
  This constrains selection without relaxing source or push-pipeline provenance.
- Each snapshot has `AppStudioIntegrationStatus=True/Finished` and
  `AppStudioTestSucceeded=True/Passed`, plus completed results for its configured
  standard/operator scenarios. Require completion timestamps. Completed warnings
  can be accepted with the aggregate pass; `BuildPLRInProgress` alone proves
  neither completion nor success; older checkouts accept that marker alone.
- The successful signed build and actual catalog contents match the approved
  source, bundle and operand pins. Check policy-required tasks in the build's
  attestations; local tests and passing snapshot scenarios do not prove release
  policy will accept the image.

Generated filenames include the full OCP ID and Submariner version. The helper
validates and commits YAMLs, then prints push/apply commands. Review exact files,
snapshot identities and stage ReleasePlan/admission before application. Follow
[apply](apply-fbc-releases.md), [completion checks](check-fbc-releases.md) and
[QE handoff](share-with-qe.md); generation is not publication.

## Recover a policy-rejected image

Inspect the exact failed Release's managed pipeline and policy violations before
retrying. A missing required task needs a fresh signed build, not another Release
of the same image or a weaker policy. For a missing `fbc-inject-lifecycle-oci-ta`,
use the approved pinned task between clone and OPM, forwarding its
`SOURCE_ARTIFACT`. A successful no-op for an ineligible OCP version still records
the required task execution; verify the result and unchanged catalog content.
Keep push/PR definitions and the onboarding task contract consistent.

For an explicitly reviewed manual recovery build, retain actual source/build
provenance and all checks; do not fabricate PaC labels to satisfy the helper.
If the helper selects a different snapshot, use independent verification of the
exact replacement, then `scripts/generate-fbc-release.sh` with that snapshot and
a distinct stage Release name. Validate the YAML with `make test-remote FILE=...`
and repository checks before application. Preserve failed-attempt evidence.

Build/test success does not prove installation or operator compatibility. Inspect
whether installation ran, which bundle/channel it selected and the cluster version;
see [onboarding evidence](add-fbc-ocp-version.md). Keep production release separate.
