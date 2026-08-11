---
name: learn-release
description: Teach the 20-step Submariner release process including Y-stream setup, build validation, stage/prod releases, and FBC catalog management. Use when user asks about release steps, workflows, Konflux concepts, or "how do we release Submariner?"
version: 1.0.0
argument-hint: "[overview|step N|all]"
user-invocable: true
allowed-tools: Read, Grep, Glob
---

# Learn Submariner Release Process

Teach users about the Submariner release process. Use $ARGUMENTS to determine what to explain.

$ARGUMENTS

---

## What to Teach

| Argument | Content |
| -------- | ------- |
| (none) | Show this menu with examples |
| `overview` | The big picture below |
| `step N` | Explain one step (1-20, including 3b, 5b, 10b, 13b, 16b, 18b) |
| `all` | Walk through all steps briefly |

## The Big Picture

Submariner releases 9 container images through Konflux to Red Hat's registry. The process has 4 phases:

1. **Setup** (Y-stream only): Create release branch, configure Konflux pipelines
2. **Build**: Fix policy violations, scan for CVEs, cut upstream release, update bundle
3. **Stage**: Create release, add notes, publish to stage registry, QE tests
4. **Prod**: After QE approval, publish to production registry

**Y-stream** (0.21→0.22): New minor version. Run all steps starting from Step 1.
**Z-stream** (0.21.1→0.21.2): Patch release. Skip to Step 4 (branch already exists).

**Gates:** Setup (Y-stream) → Builds + EC → CVE triage → Release notes →
**Stage:** Stage release → FBC update + builds + EC → FBC stage releases → QE approval →
**Prod:** Prod release (same snapshot) → FBC prod releases

## Key Concepts

**Build:**

- **Component**: Konflux build unit. Each produces one container image. Submariner has 9 components across 5 repos.
- **Hermetic**: Isolated builds with pre-fetched dependencies (Go mods, RPMs). Required by EC for reproducibility.
- **SBOM**: Software Bill of Materials. Lists all dependencies. Required by EC for security/compliance.
- **Multi-arch**: Builds for x86_64, aarch64, ppc64le, s390x. Requires Customer Portal activation key for RPM access.

**Release artifacts:**

- **Snapshot**: Immutable component references (image SHAs). Event types: `push` (merge) or `pull_request`.
- **Bundle**: Container with operator metadata (CSV, CRDs). References 7 component images via `relatedImages`.
- **FBC**: File-Based Catalog. Operator index for OLM. See FBC section below.

**FBC (File-Based Catalog):**

- **Purpose**: Makes Submariner installable via OLM. Publishes to Red Hat's operator index (appears in OperatorHub).
- **Template**: `catalog-template.yaml` is source of truth. `make build-catalogs` generates 7 `catalog-4-XX/` directories.
- **Bundles**: Version entries (e.g., `submariner.v0.22.0`) containing bundle image SHA and `relatedImages` (7 components).
- **Channels**: Update paths (e.g., `stable-0.22`). Users subscribe to a channel and get upgrades within it.
- **Version pruning**: `drop-versions.json` maps OCP versions to minimum Submariner versions (e.g., OCP 4.20 drops anything before 0.20).
- **Image lifecycle**: Bundles use temporary `quay.io` URLs (~90 day TTL). Step 20 updates to `registry.redhat.io`.

**Konflux resources (K8s CRDs):**

- **Application**: Groups components. `submariner-0-X` has 9 components; 7 `submariner-fbc-4-XX` apps each have 1 catalog.
- **Snapshot**: Immutable component references (image SHAs). Created after builds complete. Query with `oc get snapshots`.
- **ReleasePlan**: Links application to RPA. Lives in tenant namespace (submariner-tenant). Referenced by Release CRs.
- **RPA**: ReleasePlanAdmission. Defines release pipeline, EC policy, registry config. Lives in managed namespace (rhtap-releng-tenant).
- **Release CR**: Triggers publishing. References snapshot + releasePlan. Contains releaseNotes for advisories.
- **EC Policy**: Enterprise Contract policy. Checks labels, hermetic builds, CVEs, signatures, provenance. Violations block releases.
- **activation-key Secret**: Enables RPM prefetch in hermetic builds. Contains Customer Portal org ID and activation key.

**Reference:**

- **Stage vs Prod**: Stage publishes to registry.stage.redhat.io; prod to registry.redhat.io.
- **Version formats**: `0.21` (branch), `0-21` (Konflux names), `v0.21.2` (Dockerfile labels), `0.21.2` (commits/PRs).
- **ACM mapping**: Submariner 0.X → ACM 2.(X-7). Example: 0.21 → 2.14, 0.22 → 2.15.
- **Advisory types**: RHSA (security/CVEs), RHBA (bug fixes), RHEA (enhancements). Type determines release notes format.

## Steps

| Step | What happens | Y/Z |
| ---- | ------------ | --- |
| 1 | Create `release-0.Y` branches across all upstream repos | Y |
| 2 | Add Konflux components, ReleasePlans, and RPAs in konflux-release-data | Y |
| 3 | Customize bot-generated Tekton configs, set version labels | Y |
| 3b | Update bundle SHAs from component builds, set up bundle pipeline | Y |
| 4 | Fix Enterprise Contract violations in component and FBC repos | Y/Z |
| 5 | Scan and fix CVEs: iterative fix→rebuild→rescan across components and libraries | Y/Z |
| 5b | Bump Dockerfile version labels for the new patch version | Z |
| 6 | Create git tags and publish images to quay.io/submariner | Y/Z |
| 7 | Update bundle CSV with final component SHAs from snapshot | Y/Z |
| 8 | Create stage Release CR YAML (no notes yet) | Y/Z |
| 9 | Query Jira for CVEs (automatic) and issues (user selects), build releaseNotes | Y/Z |
| 10 | Apply stage release to cluster via `make apply` | Y/Z |
| 10b | Check Released=True, debug failures, retry if infra issue | Y/Z |
| 11 | Update FBC catalogs with bundle SHA from stage registry | Y/Z |
| 12 | Create 7 FBC stage release YAMLs (one per OCP 4.16-4.22) | Y/Z |
| 13 | Apply all 7 FBC stage releases to cluster | Y/Z |
| 13b | Verify all 7 FBC pipelines succeeded | Y/Z |
| 14 | Create Jira ticket with stage catalog URLs for QE | Y/Z |
| 15 | Copy stage YAML to prod, change releasePlan to prod | Y/Z |
| 16 | Apply prod release to cluster | Y/Z |
| 16b | Verify prod pipeline succeeded | Y/Z |
| 17 | Copy 7 FBC stage YAMLs to prod, change releasePlans | Y/Z |
| 18 | Apply all 7 FBC prod releases to cluster | Y/Z |
| 18b | Verify all 7 FBC prod pipelines succeeded | Y/Z |
| 19 | Share prod index URLs with QE - release complete | Y/Z |
| 20 | Update FBC templates to use registry.redhat.io URLs | Y/Z |

## Step Details

| Step | Details |
| ---- | ------- |
| 1 | Use releases repo tooling to create `release-0.Y` branches across 9 upstream repos. |
| 2 | Add overlays (app, 9 components, ReleasePlans) and RPAs in konflux-release-data. ArgoCD syncs; triggers bot PRs. |
| 3 | Customize Tekton configs: hermetic builds (Go mods, RPM lockfiles), multi-arch, SBOM. Version labels. 8 components, 5 repos. |
| 3b | Two parts: (1) update bundle CSV with component SHAs from snapshot, (2) set up bundle Tekton pipeline. Components must build first. |
| 4 | Enterprise Contract validates Red Hat release policies. Fix violations in component repos (9 images) and FBC repo (7 catalogs). |
| 5 | Grype scans Go (7 repos), clair scans images. Fix→rebuild→rescan loop. Go stdlib CVEs fixed in Shipyard (base image for others). |
| 5b | Bump version labels in 9 Dockerfiles across 5 repos. Bundle has 3 labels (csv-version, release, version). Rebuild triggers. |
| 6 | Run releases repo tooling to create git tags and publish images to quay.io/submariner. Official upstream release. |
| 7 | Update bundle CSV `relatedImages` with SHAs from latest passing Konflux snapshot. Must use registry.redhat.io URLs for EC. |
| 8 | Create Release CR YAML: copy previous, update name/snapshot. Save to `releases/0.X/stage/`. Don't add notes yet. |
| 9 | Query Jira: CVEs automatic, user selects other issues. RHSA/RHBA/RHEA based on content. Exclude submariner-addon. |
| 10 | Run `make apply` to create Release CR on cluster. Pipeline publishes 9 images to registry.stage.redhat.io. |
| 10b | Check `Released` condition. If failed: check ManagedPipelineProcessed, get log URL, determine retry vs fix. Increment suffix. |
| 11 | Update FBC catalogs in submariner-operator-fbc repo with bundle SHA from stage registry. Wait ~15-30 min for rebuilds. |
| 12 | Find passing FBC snapshots (push events only). Verify bundle SHA matches across all 7 catalogs. Create 7 Release YAMLs. |
| 13 | Apply 7 FBC releases with `make apply`. Each publishes catalog to stage index for its OCP version. |
| 13b | Check all 7 Released conditions. Same debug process as 10b. All must succeed before QE handoff. |
| 14 | Extract catalog URLs from snapshots. Create Jira ticket for QE with 7 URLs. **Wait for QE approval before prod.** |
| 15 | Copy stage YAML to prod directory. Change name (stage→prod) and releasePlan (stage-0-X→prod-0-X). Same snapshot/notes. |
| 16 | Apply prod release. Pipeline publishes to registry.redhat.io (production). Same 9 images as stage. |
| 16b | Verify prod pipeline succeeded. Same debug process as 10b. |
| 17 | Copy 7 FBC stage YAMLs to prod directories. Change names and releasePlans. Same snapshots - catalog URLs work for both. |
| 18 | Apply 7 FBC prod releases. Publishes catalogs to production indices (registry.redhat.io/redhat/redhat-operator-index). |
| 18b | Verify all 7 succeeded. Release is now live in production OperatorHub. |
| 19 | Extract index URLs from release status. Notify QE. **Submariner 0.X.Y production release complete.** |
| 20 | Optional cleanup: update FBC templates to use registry.redhat.io URLs. Prevents breakage when quay.io images expire. |

## Repos

Each step's workflow is in `.agents/workflows/<step-name>.md`. When it says "follow docs in X repo", read that repo's workflow docs.

**Note:** Branch in parentheses (`devel` for submariner-io repos, `main` for others).

| Repo | Local | Docs | Purpose |
| ---- | ----- | ---- | ------- |
| [This repo](https://github.com/stolostron/submariner-release-management) | `~/konflux/submariner-release-management` | `.agents/workflows/` (main) | Release orchestration |
| [submariner-io/releases](https://github.com/submariner-io/releases) | `~/go/src/submariner-io/releases` | `README.md` (devel) | Branch creation, tags |
| [submariner-io/submariner-operator](https://github.com/submariner-io/submariner-operator) | `~/go/src/submariner-io/submariner-operator` | `.agents/workflows/` (devel) | Operator + bundle |
| [submariner-io/submariner](https://github.com/submariner-io/submariner) | `~/go/src/submariner-io/submariner` | `.agents/workflows/` (devel) | Gateway, globalnet, route-agent |
| [submariner-io/lighthouse](https://github.com/submariner-io/lighthouse) | `~/go/src/submariner-io/lighthouse` | `.agents/workflows/` (devel) | Agent, coredns |
| [submariner-io/shipyard](https://github.com/submariner-io/shipyard) | `~/go/src/submariner-io/shipyard` | `.agents/workflows/` (devel) | Nettest |
| [submariner-io/subctl](https://github.com/submariner-io/subctl) | `~/go/src/submariner-io/subctl` | `.agents/workflows/` (devel) | Subctl CLI |
| [stolostron/submariner-operator-fbc](https://github.com/stolostron/submariner-operator-fbc) | `~/konflux/submariner-operator-fbc` | `.agents/workflows/` (main) | FBC catalogs (7 OCP) |
| [konflux-release-data](https://gitlab.cee.redhat.com/releng/konflux-release-data) (GitLab) | `~/konflux/konflux-release-data` | `tenants-config/.../CLAUDE.md` (main) | Konflux tenant config |
| [konflux-ci/docs](https://github.com/konflux-ci/docs) | `~/konflux/konflux-ci/docs` | `modules/` (main) | Konflux platform docs |
| [rhtap-ec-policy](https://github.com/release-engineering/rhtap-ec-policy) | `~/konflux/konflux-ci/rhtap-ec-policy` | `data/` (main) | EC policy definitions |
| [users-docs](https://gitlab.cee.redhat.com/konflux/docs/users) (GitLab) | `~/konflux/users-docs` | `docs/modules/` (main) | Konflux user guides |
