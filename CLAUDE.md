# CLAUDE.md

## Run Next Release Step

@/autorelease

Finds the next ready step and runs it. Chains consecutive auto steps, stopping at
gate, review, or manual steps. Re-run to advance.

## 0. Create Release Tracker

@/create-release-tracker

**Alternative:** `make create-release-tracker VERSION=<version>`

Usually handled automatically by `/autorelease`. Run manually only to pre-create the
tracker before running autorelease, or to recreate an accidentally deleted one.
Release scripts automatically update tracker subtasks as they complete.

## 1. Create Upstream Release Branch (Y-stream only)

@.agents/workflows/create-release-branch.md

## 2. Configure Downstream (Y-stream only)

@/configure-downstream

**Alternative:** @.agents/workflows/configure-downstream.md (manual workflow)

## 3. Fix Tekton Config PRs - Components (Y-stream only)

@/konflux-component-setup

**Alternative:** `make konflux-component-setup REPO=<repo> COMPONENT=<component> VERSION=<version>`

## 3b. Fix Tekton Config PRs - Bundle (Y-stream only)

@/konflux-bundle-setup

**Alternative:** `make konflux-bundle-setup VERSION=<version>`

## 4. Update Tekton Tasks and Resolve EC Violations

@/konflux-ci-fix

**Alternative:** @.agents/workflows/fix-ec-violations.md (manual workflow)

**Reuse completed task work only with completed policy evidence for the exact candidate.** See
@.agents/workflows/skip-completed-steps.md.

## 4b. Update RPM Lockfiles

@/rpm-lockfile-update

**Alternative:** `make rpm-lockfile-update VERSION=<version>`

Automated step: updates RPM lockfiles across Submariner component repos. Runs after
Tekton task updates, before CVE scanning.

## 5. Scan for CVEs

@.agents/workflows/scan-cves.md

**Reuse completed upstream work when tags exist on all five component repos.** Verify scan evidence for the exact
downstream candidate separately. See
@.agents/workflows/skip-completed-steps.md.

## 5b. Update Component Version Labels (Z-stream only)

@/update-version-labels

**Alternative:** `make update-version-labels VERSION=<version>`

## 6. Cut Upstream Release

@.agents/workflows/cut-upstream-release.md

**Skip if `v$VERSION` already exists** on all 5 component repos; never re-cut a tag.

## 7. Update Bundle SHAs

@/bundle-image-update

**Alternative:** `make bundle-image-update VERSION=<version>` or @.agents/workflows/update-bundle-shas.md (manual workflow)

## 8. Create Component Stage Release

@.agents/workflows/create-release.md

## 9. Add Release Notes

```bash
make add-release-notes VERSION=0.22.1
make review-release-notes VERSION=0.22.1
```

See `.agents/workflows/add-release-notes.md` for workflow details.

## 10. Apply Component Stage Release

@.agents/workflows/apply-component-release.md

## 10b. Check Component Stage Release Build

@.agents/workflows/check-component-release.md

## 11. Update FBC Catalog

@.agents/workflows/update-fbc-stage.md

## 12. Create FBC Stage Releases

@/create-fbc-release

**Alternative:** @.agents/workflows/create-fbc-stage-release.md (manual workflow)

## 13. Apply FBC Stage Releases

@.agents/workflows/apply-fbc-releases.md

## 13b. Check FBC Stage Release Builds

@.agents/workflows/check-fbc-releases.md

## 14. Share Stage FBC with QE

@/get-fbc-urls

**Alternative:** @.agents/workflows/share-with-qe.md (manual workflow)

## 15. Create Component Prod Release

@.agents/workflows/create-prod-release.md

## 16. Apply Component Prod Release

@.agents/workflows/apply-component-release.md

## 16b. Check Component Prod Release Build

@.agents/workflows/check-component-release.md

## 17. Create FBC Prod Releases

@/create-fbc-release

**Alternative:** @.agents/workflows/create-fbc-prod-release.md (manual workflow)

## 18. Apply FBC Prod Releases

@.agents/workflows/apply-fbc-releases.md

## 18b. Check FBC Prod Release Builds

@.agents/workflows/check-fbc-releases.md

## 19. Share Prod FBC with QE

@/get-fbc-urls

**Alternative:** @.agents/workflows/share-with-qe.md (manual workflow)

## 20. Update FBC Templates with Prod URLs (Optional)

@.agents/workflows/update-fbc-templates-prod.md

---

## Async / Maintenance Tasks

Tasks not tied to normal release workflow timing.

### Add FBC Support for New OCP Version

@/add-fbc-ocp-version

**Alternative:** `make add-fbc-ocp-version OCP_VERSION=5.0 MIN_SUPPORTED_SUB=0.24` or
@.agents/workflows/add-fbc-ocp-version.md (phased workflow)

---

## Settled Decisions

Decided by the maintainer. Do not re-ask or re-litigate; follow them.

### Do not redo upstream work that is already done

Once `v$VERSION` exists on all five component repos, reuse verified upstream CVE work and never re-cut tags on a retarget,
re-release or retry. Downstream scan evidence still belongs to the exact candidate. Reuse completed task work only after
checking snapshot and managed release-policy requirements, including required signed-build tasks and current trust.
Repair actual failures; do not bump unrelated tasks proactively. See `.agents/workflows/skip-completed-steps.md`.

### Sealed team entitlement bundle stays in the public repo

`secrets/entitlements.asc` (the shared Red Hat org ID and activation key, gpg-sealed with one
team password) is committed to this public repo on purpose. Priority is a one-command setup
for the team (`make setup-entitlements`); the team already shares a single key, so per-person
secrets management isn't the bar. Don't ask whether to keep the file, move it private, or
distribute it out of band. Access removal = rotate the activation key (see
`secrets/README.md`), not the password alone. Background and rationale are there too.
