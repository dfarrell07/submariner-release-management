# CLAUDE.md

## 1. Create Upstream Release Branch (Y-stream only)

@.agents/workflows/create-release-branch.md

## 2. Configure Downstream (Y-stream only)

@/configure-downstream

**Alternative:** @.agents/workflows/configure-downstream.md (manual workflow)

## 3. Fix Tekton Config PRs - Components (Y-stream only)

@.agents/workflows/fix-tekton-prs.md

## 3b. Fix Tekton Config PRs - Bundle (Y-stream only)

@/konflux-bundle-setup

**Alternative:** @.agents/workflows/fix-tekton-bundle.md (manual workflow)

## 4. Update Tekton Tasks and Resolve EC Violations

@/konflux-ci-fix

**Alternative:** @.agents/workflows/fix-ec-violations.md (manual workflow)

## 5. Scan for CVEs

@.agents/workflows/scan-cves.md

## 5b. Update Component Version Labels (Z-stream only)

@.agents/workflows/update-version-labels.md

## 6. Cut Upstream Release

@.agents/workflows/cut-upstream-release.md

## 7. Update Bundle SHAs

@/bundle-image-update

**Alternative:** @.agents/workflows/update-bundle-shas.md (manual workflow)

## 8. Create Component Stage Release

@.agents/workflows/create-release.md

## 9. Add Release Notes

@.agents/workflows/add-release-notes.md

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

@.agents/workflows/share-with-qe.md

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

@.agents/workflows/share-with-qe.md

## 20. Update FBC Templates with Prod URLs (Optional)

@.agents/workflows/update-fbc-templates-prod.md

---

## Async / Maintenance Tasks

Tasks not tied to normal release workflow timing.

### Add FBC Support for New OCP Version

@.agents/workflows/add-fbc-ocp-version.md
