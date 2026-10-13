# OCP 5 FBC implementation status

October 7 navigation: the dated preparation and validation records below are historical.
Use [current work](current-work.md) and the [consolidated rollout plan](ocp-5-0-fbc-rollout.md)
for current PR/configuration state and execution order. Catalog/tooling #76/#81 are merged;
pipeline #82 remains open with a missing build-account failure.
The original "nothing pushed" and "no catalog/PR" statements describe September 24, not current reality.

Updated 2026-09-24. **The reusable skill and real OCP 5.0 local preparation are
complete**, including the catalog, tenant, admissions and build pipelines. The user
authorized provisional existing inputs: minimum stream **0.24**, default channel
`stable-0.24`, head **0.24.1**. The actual catalog passed complete preparation and
an OCP 5.0 native image test. Deployment and runtime compatibility remain unverified.
Nothing was pushed or applied.

## Review locations and commits

| Change | Checkout | Commit |
| --- | --- | --- |
| Complete skill flow | `ocp-5-skill-work/release-management` | `11eb87f` |
| Contract validation and source preservation | `ocp-5-skill-work/release-management` | `36e706a` |
| Live provenance/content checks and 5.x ITS migration | `ocp-5-skill-work/release-management` | `4549e64` |
| Target metadata validation | `ocp-5-skill-work/release-management` | `8203868` |
| FBC build/test safety foundation | `ocp-5-skill-work/fbc-tooling` | `8b6e990` |
| Requested-catalog image CI and workflow | `ocp-5-skill-work/fbc-tooling` | `8eac46a`, `f641fb9` |
| Real 5.0 push/PR pipeline pair | `ocp-5-work/fbc` | `0641db0` |
| Real 5.0 catalog with provisional 0.24 input | `ocp-5-work/fbc` | `87172cc` |
| Real 5.0 tenant, including the 0.3 install path | `ocp-5-work/tenant` | `ae77531d74`, `47eda9c5b1` |
| Real 5.0 stage/prod admission entries | `ocp-5-work/admission` | `82ff6f2fc5` |

Paths are relative to `/home/dfarrell07/konflux`. Release-tooling commits are also
available from the original `submariner-release-management` checkout. Original FBC
feature and operator checkouts remain intact. Configuration uses cached main
`8c18efee295889f5d86b03d16930a2f11977fd58`; fetching GitLab still fails because
`gitlab.cee.redhat.com` does not resolve. Refresh/rebase before remote review.

## Completed skill behavior

- Plan/add/resume guidance, installed-copy execution and canonical workflow lookup;
  independent immutable repository refs and predecessor selection; policy-free
  configuration preparation; complete prepare, verify, target-image and live phases.
- Explicit authorization to use provisional defaults selects the existing template's
  populated default-channel stream/head, records the assumption and digest, and
  completes preparation and image testing without another policy question.
- Full major/minor identities; inclusive minimum versus legacy drop-through cutoff;
  preflight checks for channels, Kustomize, supported pipeline structure and base
  architectures before creating worktrees. Overrides must retain the release
  filter's requested `:vX.Y` tag; registry ports and overriding target-version labels
  need upstream support review.
- Scratch generation and checked publication preserve unrelated files and Git index
  entries. YAML edits preserve comments and handle block/flow lists. Both RPAs and
  both pipelines are validated before either pair is written. Conflicting resumes
  fail without overwriting their output.
- Fresh tenant rendering must match all seven stored resources. RPA destinations,
  credentials and pipeline/account contracts are checked. New 5.x overlays use
  the reviewed upstream 0.3 install pipeline wrapper, default catalog channel and
  explicit `.dockerconfigjson` secret key. Existing 4.x overlays are unchanged.
- Catalog verification derives its minimum from the map even without a CLI minimum;
  package, channels, upgrade graph, bundle versions and digests must match the source
  template. Preparation renders only the requested catalog and validates the full
  candidate; the real OCP-base image is validated and served through gRPC.
- Pipeline checks cover the reviewed OCI task family, effective source context,
  enabled checks, build arguments, platform matrix, image index and result forwarding.
  Unknown or unresolved definitions cannot pass as locally ready.
- Live verification separates configuration, build and runtime claims. It checks
  actual RPAs, account/secret bindings, merged-main ancestry, original push provenance,
  complete snapshot tests, source/image linkage and four platform base annotations.
  Every platform's extracted catalog must match the pinned Git files and catalog
  contract. Runtime remains unverified until installation and cluster evidence exist.
- Image CI retains `Image Build & Test`, selecting changed catalogs or all catalogs
  for shared build changes. Public CI's upstream OPM is separate from the explicit
  authenticated OCP-base test. The workflow checks both effective rulesets and
  legacy protection at the exact PR head, including required app identities.

## Validation

Passed in this completion:

- **55 focused regression tests**, Ruff, YAML/Shell/Markdown checks and skill metadata
  validation. The normal commit hook ran the full release-management `make test`.
- Installed-skill E2E using real Kustomize, OPM, Podman and the OCP 5.0 base: complete
  preparation, native image validation/gRPC serving, reruns, conflicting-policy
  rejection, source bytes/modes/Git-index preservation and 4.23 → 5.0 → 5.1 reuse.
  The final run includes the 5.x install-path migration and target-only rendering.
- Full authenticated FBC suite, all ten catalog validations and linting;
  executable CI selection probes for a changed major, existing minor and shared
  Dockerfile. E2E fixture suites explicitly skip their separate authenticated-fetch
  tests; the authenticated suite was run independently.
- Pinned build-task utility probes accept 5.0/5.1 and correctly cross from 5.0
  to predecessor 4.22. The actual 5.0 base passes the tightened metadata check.
- Real tenant builder and fresh seven-object validation after ITS migration; both
  real admissions pass the complete contract. The post-commit
  `tox -e tenants-config-test` passed **60,108 tests**, including full regeneration
  of all 2,180 directories, attribution and allowed-onboarding checks.
- Real-workspace complete preparation using minimum 0.24, followed by the actual
  `catalog-5-0` native amd64 build on the OCP 5.0 base, in-image OPM validation and
  gRPC package serving. Both pipelines retain all four platforms. Post-commit local
  verification checks the real catalog and unchanged tenant/admission resources.

The real catalog now reuses bundles 0.24.0 and 0.24.1 as **provisional inputs**.
Its 0.24.1 head retains the template's digest
`sha256:a8bb318b8afa37daf2ce9394d80c46224e872b593934fbb68fd89e20e6665f84`.
The inspected bundle declares `v4.15-v4.19`; its metadata is unchanged. Catalog
validation establishes the catalog/build behavior, not installation compatibility.
The first completion E2E attempt failed on `/tmp` quota; the successful runs use a
task-owned `TMPDIR` on the workspace disk. No unrelated temporary data was removed.

Full release-data `tox` is **not green**: the updated tenant passed **133,513** main tests,
Ruff, YAML lint, ShellCheck and CODEOWNERS. Its sole failing environment remains
`warnings` (6,256 passed; one unrelated failure).
The existing warnings failure for missing policy
`registry-red-hat-desktop-extensions-prod` was also reproduced on the untouched
original checkout during the earlier review. It was not changed by this task.

## Remaining real rollout gates

The [remaining execution plan](ocp-5-skill-completion-plan.md) contains reproduction
commands and remote rollout gates. No catalog-input question blocks local work.
A bundle update is needed if compatibility testing or release policy requires a
different initial bundle; a pending component snapshot is not a universal
prerequisite to catalog onboarding.

The last live verification against merged FBC main reported no 5.0 Application
and no merged 5.0 catalog. No original push build, four-platform 5.0
artifact, installation or release is claimed. No OCP 5 onboarding PR was open at
inspection. GitHub's effective ruleset requires six Actions checks (app 15368)
and DCO (app 1861), despite the legacy protection endpoint returning 404.

Before rollout, refresh configuration, review and merge/reconcile changes, verify
the merged 5.0 build and run installation/QE on an observed 5.0.x cluster.
Confirm access to the selected install profile; the generic
ITS can skip a released bundle and then needs an explicit-bundle QE procedure.
Stage/prod release and public-index membership remain separate gates. The default
release scope remains 4.16–4.22 until those gates pass.

## Reproducible records

Current logs are under `/tmp/ocp5-skill-implementation.se7efhg9/`:

- `batch2-commit.log`, `batch3-commit.log`, `completion-commit.log`: full release hook checks.
- `batch3-tests.log`: focused regressions.
- `final-skill-e2e.log`: final installed-skill E2E.
- `fbc-final-checks.log`, `fbc-ci-lint.log`: authenticated FBC suite and lint.
- `real-tenant-build.log`, `real-tenant-tox.log`, `real-tenant-postcommit.log`:
  tenant regeneration and repository checks.
- `final-live-readiness.json` and `.log`: actual live non-readiness evidence.
- `real-config-resume.json`, `real-onboarding-plan.json`: clean real configuration
  resume and the historical minimum-stream blocker, now resolved provisionally.

Real-catalog completion logs are under
`/home/dfarrell07/konflux/ocp-5-skill-work/completion.LL7g6wD6/`:
`prepare.json`/`.log`, `test-image.json`/`.log`, `verify.json`/`.log`,
`fbc-lint.log`, `fbc-commit.log`, and `release-commit.log`.

These local logs are temporary evidence. Committed tests and the
[canonical workflow](../.agents/workflows/add-fbc-ocp-version.md) provide reproduction.
Earlier implementation/review details remain in this file's Git history.
