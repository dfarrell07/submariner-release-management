<!-- markdownlint-disable MD013 -->

# Work queue

0.25.0 reached the OCP 4.16–4.22 and 5.0 catalogs November 4; tracker fix [#141](https://github.com/stolostron/submariner-release-management/pull/141) merged November 6. Evidence checked November 5; plan reviewed November 6.

## Do first

1. [ ] Publish the prepared one-file scope fix (`9e9f9b0`): add `5-0` to `FBC_OCP_VERSIONS` so verification, status, URLs and automatic closure include the 5.0 catalog. Retain existing per-release filtering.
2. [ ] Publish the one-line 0.25.0 template correction to its verified production digest. Generated catalogs already contain that image; omit ordering-only changes.
3. [ ] Rebase the historical-record checkout onto current main, then commit the six prepared, already-applied 0.23.4 FBC manifests ([receipt/handoff](https://github.com/stolostron/submariner-release-management/blob/d91e7a6/plans/current-work.md#existing-release-work)). Run existing repository checks; do not regenerate or reapply releases. Delivery and Jira closeout are complete.

## 4.x and future 5.x compatibility

Retain the existing full-version helpers for normalization, generation, exact snapshot/index selection, status and closure; mixed-major offline checks already cover these paths.

- [ ] Release-management PR: fix onboarding's 4.x empty/null channel handling and acceptance of channel omission after migration. Preserve inherited required/optional test policy for later 5.x minors; keep the shared parameter layout. Extend existing contract tests and replace fixed-count skill guidance.
- [ ] FBC PR: validate configured/applicable outputs from `drop-versions.json` and its cutoffs; missing expected catalogs/bundles must fail. Replace 4-only workflow staging globs with configured target paths and extend existing fixtures. Both compatibility PRs can be prepared offline.

Extend existing offline fixtures for 4.22, 5.0, 5.1, numeric 5.10 ordering and those failure cases. Keep configured build targets separate from active release scope: future catalogs activate only after onboarding. Synthetic coverage does not prove image/runtime availability. No new version framework or upstream task upgrade is indicated.

## Tooling follow-ups

- Implement the reviewed [CVE advisory contract](https://github.com/stolostron/submariner-release-management/blob/1ab5773/plans/cve-advisory-reconciliation.md): check/refresh modes and product-RHSA closure coverage remain absent.
- [ACM-39732](https://redhat.atlassian.net/browse/ACM-39732) requires standalone conversion, a skill and conductor wiring. Reuse existing conversion/publication checks and the upstream-template verifier; use reviewed branches. Avoid snapshot reselection, new releases or verification frameworks.
- Finish [konflux-ci-fix portability](https://github.com/stolostron/submariner-release-management/blob/77c856ee43238a92a4c88a3b4be2f5e2bd24b5c4/plans/claude-codex-skill-compatibility.md): five known compatibility debt categories remain.

## Conditional or deferred

- [ACM-48213](https://redhat.atlassian.net/browse/ACM-48213) is 4.x CI maintenance, not a blocker to the delivered 0.25.0 release. When access returns, refresh [!23841](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/23841) and live configuration first. If still needed, reuse its upstream wrapper/credentials and 5.0's channel-removal pattern; preserve parameter layout and rendered 5.0 behavior. For remaining changes, regenerate and check reconciliation plus ordinary PR/push CI, reusing matching provisioning evidence and expected skips. Stack/profile prerequisites are merged. No new tooling, fork, candidate, forced installation or product QE.
- [ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) waits until the OCP 5 release window ends. Then recheck addon PRs #2856–2860 and Tide’s `acknowledge-security-fixes-only` gate.
- Next 0.22 release, when needed: use a fresh target/tracker and CI, EC, scan, bundle and QE evidence. Do not inherit completed-step flags from [ACM-45070](https://redhat.atlassian.net/browse/ACM-45070), now Closed/Obsolete; existing upstream tags remain immutable.
- Leave OCP 5 test policy unchanged. When GitLab access returns, refresh [!24509](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/24509) and retire it if still superseded.
- Parent-artifact refresh under [ACM-39730](https://redhat.atlassian.net/browse/ACM-39730)/[39731](https://redhat.atlassian.net/browse/ACM-39731) is optional: existing step records and manual parent summaries suffice. Correct the stale template promise instead of implementing a refresher.
