<!-- markdownlint-disable MD013 -->

# ART builder migration: source inventory and implementation handoff

[ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) remains New, due October 15, 2026. Planning comment `18839276` already records the inventory and remaining migration. No completion or status transition follows from planning alone.

## October 15 source refresh and proposed pilot

Both addon Dockerfiles still use Brew at main `51589c4a`, release-2.15 `714a6ade`, release-2.16 `c36fa12d` and release-5.0 `aabf5d0e`. These are four refreshed samples, not a repeat of the October 8 audit. The 2.15/2.16 Konflux builds retain `CGO_ENABLED=1 GOEXPERIMENT=strictfipsruntime`; 5.0 retains its PQC runtime base.

Proposed pilot: replace main's Brew `v1.26` FROM in `Dockerfile` and `Dockerfile.konflux` with `registry.redhat.io/openshift/golang-builder:golang-builder-v1.26-rhel9`, preserving build commands, runtime and crypto settings. Update the [Brew-selecting CVE guidance](../.agents/workflows/scan-cves.md#addon-go-toolchain). Confirm deployed sources/CI access and agree maintained-stream propagation before claiming migration complete. The addon cluster session does not currently authenticate.

## Current source and coverage

The [October 8 inventory](https://github.com/stolostron/submariner-release-management/blob/74ab84e039d7ed47960b187b5a7c7ecacb1a34f5/plans/art-builder-migration.md) retains immutable source links and detailed branch/module/credential findings: nine repositories, 137 canonical refs and 136 trees. Branch existence alone does not establish active support.

| Repository/build path | Inventory result and disposition |
| --- | --- |
| lighthouse, submariner, submariner-operator | All 36 ticket-listed component Dockerfiles across 0.19–0.24 use UBI Go Toolset. No direct Brew consumer found; verify actual selected overrides before the no-change disposition |
| submariner-addon | Both Dockerfile paths consume Brew on affected branches; ordinary Prow images and Konflux builds use separate credential paths |
| subctl | UBI Go Toolset downstream; outside the ticket's named repositories. Confirm whether the accepted product scope includes it |
| shipyard | Fedora/dnf Dapper builder; nettest is a runtime-only UBI image with scripts, without a Go builder stage |
| admiral, cloud-prepare | Libraries without a separate Dockerfile/direct Brew consumer; qualify through their consumers |
| FBC | Prebuilt OPM catalog image; no Go compiler stage. External task images remain a separate input |

Review generated/predecessor inputs when onboarding a branch; 0.25's missing Konflux Dockerfiles are not evidence of an active Brew consumer. Do not add a builder to nettest or the scratch operator bundle because the repository has a Go module.

## Addon branch differences

| Sources in the historical inventory | Builder/runtime distinction |
| --- | --- |
| release-2.10 | Ordinary CI builder; Konflux Brew Go 1.23, below the recorded root Go 1.24 floor. Resolve active-source selection before choosing a replacement |
| release-2.11/2.12 | Brew Go 1.24; ordinary 2.11 CI uses a UBI8 runtime override |
| release-2.13–2.17 / 4.23 | Brew Go 1.25 generally; ordinary 2.14 uses a CI builder. Matching Brew Go 1.25 metadata declares RHEL8, not RHEL9 |
| release-5.0 / 5.1 / 5.2 / main | Brew Go 1.26/RHEL9; 5.0's Konflux runtime is PQC-minimal, while main/5.1/5.2 use ordinary UBI-minimal |
| Four appstudio copies | May be selected independently of similarly named release branches; resolve tenant/PaC selection before editing or retiring them |

The pinned historical tables own exact older branch SHAs. Refresh each accepted build source at implementation time rather than treating those values as deployed state. Preserve nested module floors: for example lighthouse 0.22 CoreDNS requires Go 1.26 despite its root's 1.25 floor.

## Builder selection and qualification

Current amd64 metadata samples report ART Go 1.26/RHEL9 as Go 1.26.7 and ART Go 1.25/RHEL8 as Go 1.25.14, matching the corresponding Brew version/family samples. They do not prove identical compilers: RPM releases/filesystem metadata differ. Brew/ART Go 1.26 declare `GOAMD64=v2`; changing a Go 1.25/RHEL8 consumer to RHEL9 would also change OS/CPU declarations. Choose the matching Go/OS family unless a separate requirement calls for a transition.

1. Confirm maintained/deployed branches, both Dockerfile consumers and effective Go/module/toolchain requirements. Keep unaffected and retired paths explicit; no blanket product migration is justified by a registry deadline.
2. Replace verified Brew references and the operational guidance. Preserve runtime bases, CGO/FIPS settings, labels, build commands, prefetch and PaC filters. Add credentials or lockfile changes only for a demonstrated requirement.
3. Verify ART pulls in the actual ordinary image-build and Konflux remote-worker contexts. Local registry metadata access, Pod imagePullSecrets and RPM subscription certificates do not prove those pulls. The [historical credential analysis](https://github.com/stolostron/submariner-release-management/blob/74ab84e039d7ed47960b187b5a7c7ecacb1a34f5/plans/art-builder-migration.md#other-build-inputs-and-full-migration-scope) identifies the two paths.
4. Qualify the changed head with Prow **images** and required Konflux platforms. Source/unit/envtest checks use different binaries and do not exercise the output image. Record resolved builder/task/catalog and output digests, actual compiler/build settings, runtime startup and existing crypto requirements. `go version -m` helps attribute the binary; addon `--version` reports application identity. Preserve required behavior under the existing deployment mode.
5. Propagate through the accepted addon branch process and record migration/no-change evidence before closure. Keep ART product adoption, PQC runtime readiness, OLMv1 and OCP 5 qualification within their separate tracking.

The older registry audit covered five ART indexes/twenty configs and two Brew indexes/eight configs. No image layers, compiler execution, migration build or runtime qualification was performed by this planning refresh. Tags float; retain resolved digests for actual qualification. Existing explicit `-mod=mod` build flags override the sampled ART `GOFLAGS=-mod=vendor`; do not invent a vendoring migration or tools prefetch without a consumer.
