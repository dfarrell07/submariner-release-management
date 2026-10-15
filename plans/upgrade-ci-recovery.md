<!-- markdownlint-disable MD013 -->

# Upgrade CI repair: diagnosed failures and review handoff

Refreshed October 15, 2026. Draft [subctl #1944](https://github.com/submariner-io/subctl/pull/1944) remains at `f6a97c7a`; its formatting fix is already present. Dependency/runtime and hosted upgrade checks still fail. The [current work map](current-work.md) routes related work; no local kind or hosted rerun was performed by this audit.

## Historical failure diagnosis (October 7)

| Check | Published evidence | Required action |
| --- | --- | --- |
| [Dependencies](https://github.com/submariner-io/subctl/actions/runs/37503764685/job/112407092769) | Reports one unmerged PR; the consumer explicitly depends on Shipyard #2654 | Review/merge the dependency and verify its updated Dapper image is published; preserve dependency enforcement |
| [Go](https://github.com/submariner-io/subctl/actions/runs/37503764672/job/112407090322) | `cmd/subctl/upgrade_test.go:135:1` fails `gofumpt`; this is a formatting check, not a reported compile error | Fixed in the current head; do not repeat this as pending work |
| [Upgrade command](https://github.com/submariner-io/subctl/actions/runs/37503764579/job/112407090491) and [Globalnet/Lighthouse](https://github.com/submariner-io/subctl/actions/runs/37503764579/job/112407089939) | The failed step runs `make deploy-latest` followed by `test -x output/released-subctl/bin/subctl`. Both logs complete deployment/connectivity and then exit 1 before the later upgrade stage | Confirm the isolated baseline executable exists after deployment in the published runtime. This matches the deliberate old-runtime guard; it does not establish that the later upgrade passes |
| [Vulnerability scanning](https://github.com/submariner-io/subctl/actions/runs/37503764672/job/112407090444) | Grype scans module metadata and fails the high-severity threshold for gRPC and x/crypto findings | Compare against the exact base and existing remediation work, then validate the agreed dependency fixes separately. Runtime publication will not resolve this scan by itself |

The upgrade job's deployment success and final shell failure support the baseline-file assertion as the immediate failure; the log does not print a separate assertion diagnostic.
The post-mortem contains transient Kubernetes scheduling/resource warnings after failure. Do not promote those warnings into the primary failure without evidence.

The scan records gRPC `v1.82.1` high findings GHSA-2v4p-qf9q-27wj and GHSA-vp52-pcj8-j9qc, and x/crypto `v0.55.0` high findings GO-2026-6354/6355.
Its report lists fixes through gRPC 1.83.1 and x/crypto 0.56.0; these are the scanner's suggestions, not qualified dependency choices.
It also includes lower-severity findings. A module match does not establish call reachability. The PR reports unchanged go.mod/go.sum versus upstream;
verify the exact base before attributing these findings to this repair or treating them as newly introduced.

## Completion sequence

1. Devel formatting is fixed. Reconcile current scan findings with [subctl #1946](https://github.com/submariner-io/subctl/pull/1946), open at `48762ade` with passing technical checks; Shipyard #2656 has merged. #1946 still has an open standard-library review: its x/net fix does not qualify the Dapper compiler or rebuilt binaries. Resolve builder remediation/artifact evidence separately without raising the module language floor to conceal that distinction. Refresh affected branches rather than bypassing the scan.
2. Review [Shipyard #2654](https://github.com/submariner-io/shipyard/pull/2654) at `557bb9977cd4e2dcb9f8526620423faa20c4c1fb`, then verify publication and use of the updated Dapper runtime.
   Its passing/skipped checks do not publish the unmerged consumer dependency.
3. Verify baseline isolation, the exact built CLI version/checksum, selected operator/component images, completed rollouts, connectivity and service discovery in both consumer variants.
   Record the new consumer head and all required hosted results; a passing deployment cannot substitute for the upgrade stage.
4. Existing release-0.22 backports [Shipyard #2657](https://github.com/submariner-io/shipyard/pull/2657) (`0cdc2a19`) and [subctl #1947](https://github.com/submariner-io/subctl/pull/1947) (`0934c8d4`) remain draft with failing hosted checks. Complete applicable maintained-stream backports and their branch-specific evidence before closing [issue #2635](https://github.com/submariner-io/shipyard/issues/2635).
   Their current descriptions separately identify unchanged Go lint findings and x/net/toolchain scan constraints: the maintenance base declares Go 1.25, while the proposed fixed x/net requires 1.26. Agree maintained scope and a qualified branch-specific remediation before merging; do not fold an unreviewed toolchain jump or ignore into this CI backport. Merge Shipyard source before publishing its runtime, then qualify the consumer; runtime publication is not a circular precondition for merging Shipyard itself.
   Keep the FIND-006 download-integrity disposition separate; this upgrade repair does not ship those closed-unmerged drafts.

Review, publication and hosted reruns remain external handoffs. This plan diagnoses and sequences them; it does not authorize those actions.
