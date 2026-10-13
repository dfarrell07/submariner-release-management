<!-- markdownlint-disable MD013 -->

# ART builder migration: source inventory and implementation handoff

Rechecked October 8, 2026: 137 canonical branch/ref reads across nine Submariner/addon/FBC repositories and 136 immutable source trees, plus the previously inspected shared CI builder/catalog, OpenShift CI configuration and ACM remote-build task source. ACM-45318 remains New and requests migration by October 15; planning comment `18839276` posted and verified October 8 at 15:37 UTC.
This plan turns the [current work map](current-work.md)'s deadline into a source-backed change inventory.
The source audit makes no implementation change; the posted planning comment does not complete the migration.

## Current source and coverage

The three ticket-listed independent-product repositories have downstream builders in `release-0.19`–`release-0.24`; the detailed module-floor samples below cover 0.22–0.24.
Their devel Dockerfiles use the shared Shipyard Dapper builder and Fedora/scratch output; these are separate upstream build paths.
The ticket targets Brew/OSBS consumers of ART Go builders. Its parent lists floating `registry.redhat.io/openshift/golang-builder:golang-builder-vX.YY-rhelZ` replacements on both RHEL8 and RHEL9, with internal registry entitlement. Fresh metadata reads confirm Go 1.23–1.26 on RHEL9 and Go 1.25 on RHEL8, each on four platforms. Select the Go version **and existing builder OS family** for each consumer; the registry migration does not by itself require an OS-family change. Supported source selection, CI access and build qualification remain pending.
The downstream component Dockerfiles use UBI Go Toolset, not the named ART builder; no replacement is justified by the deadline alone. Inspect shared/transitive build inputs before identifying an affected component path.
The rows below read an immutable branch head's Go directive and sample Konflux Dockerfile; that directive is a module floor, not the observed build compiler.

| Repository | Stream | Root Go floor | Sample builder | Exact source |
| --- | --- | --- | --- | --- |
| lighthouse | 0.22 | `1.25.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/lighthouse/blob/2cd528f6a2289f3179f6fcf223602486d45ff8f6/package/Dockerfile.lighthouse-agent.konflux) |
| lighthouse | 0.23 | `1.25.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/lighthouse/blob/3a3dc0eb7beb25aa25034f81f784198fff1e669e/package/Dockerfile.lighthouse-agent.konflux) |
| lighthouse | 0.24 | `1.25.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/lighthouse/blob/228b141caf956fbfcacdc5dc986edc5070f0f9ed/package/Dockerfile.lighthouse-agent.konflux) |
| submariner | 0.22 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/submariner/blob/ed38953ef65f2103d86f922a4f94bb83d9c6667b/package/Dockerfile.submariner-gateway.konflux) |
| submariner | 0.23 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/submariner/blob/6b37e846544e3def0b180afefc680854e05401c9/package/Dockerfile.submariner-gateway.konflux) |
| submariner | 0.24 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/submariner/blob/e9b4dec4944cbbf8d630603904fb6e0f82a2b566/package/Dockerfile.submariner-gateway.konflux) |
| submariner-operator | 0.22 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/submariner-operator/blob/41333ee509b4ca75135984e6bc75ea632f2615ff/package/Dockerfile.submariner-operator.konflux) |
| submariner-operator | 0.23 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/submariner-operator/blob/524fe6e71666672533298e53caed03b4076c1b17/package/Dockerfile.submariner-operator.konflux) |
| submariner-operator | 0.24 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/submariner-operator/blob/1e41f5c71977e2b47875d02d47bddafaaf7bc175/package/Dockerfile.submariner-operator.konflux) |
| subctl | 0.22 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/subctl/blob/252b24e8de3b1bd615b102ff9b64a482569e5d18/package/Dockerfile.subctl.konflux) |
| subctl | 0.23 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/subctl/blob/3e2f1fab0347ffcb8f027b8a66934b69ae9a2ab3/package/Dockerfile.subctl.konflux) |
| subctl | 0.24 | `1.26.0` | UBI9 Go Toolset `latest` | [Dockerfile](https://github.com/submariner-io/subctl/blob/8a2d1298c2489dae7832cfc5dac7b2c489b2e9ad/package/Dockerfile.subctl.konflux) |

All 18 ticket-listed component Dockerfiles across 0.22–0.24 and their push/PR pipeline selections were read: both lighthouse components, all three submariner components and the operator use UBI9 Go Toolset. No direct Brew/ART builder reference was found in those source trees or their devel trees; registry contents and transitive task inputs remain unqualified.
Module floors can differ inside a repository: [0.22 CoreDNS](https://github.com/submariner-io/lighthouse/blob/2cd528f6a2289f3179f6fcf223602486d45ff8f6/coredns/go.mod) requires Go 1.26.0 despite the root's 1.25.0. Its pipeline prefetches `./coredns` and builds in that directory. Retain each compiled module's floor, including operator tools/controller-gen, rather than selecting a compiler from the root alone.

The CLI is outside the four repositories named by the ticket but inside the independently released product. Its `subctl` rows above identify the same builder family;
confirm whether the ticket's accepted scope includes that image before silently declaring all product builders migrated.
Nettest is different: `package/Dockerfile.nettest.konflux` on all three inspected Shipyard streams has one pinned UBI9 runtime stage and copies scripts;
it has no Go builder stage. The root Shipyard Go floor alone is not evidence that this container needs a new compiler stage.
The operator bundle uses `FROM scratch`; assess its build tasks separately rather than adding a Go builder to the bundle Dockerfile.

## Coverage of every Submariner repository

The expanded source scan covers all returned canonical release branches plus devel/main and the four addon appstudio branches: 137 refs, 136 trees, 27,547 owned text files, 442 vendored build inputs and 328 Dockerfile paths. Temporary bot/reference/feature branches are not automatically active build sources; resolve any selected by the actual CI/tenant configuration before closure. Branch existence does not establish support or an obligation to backport.

| Repository | Canonical refs checked | Source disposition |
| --- | --- | --- |
| lighthouse | devel; 0.11–0.25 (16) | Agent/CoreDNS Konflux stages on 0.19–0.24 use UBI Go Toolset; current ordinary builds use Shipyard. No direct Brew Go consumer found. |
| submariner | devel; 0.11–0.25 (16) | Gateway/globalnet/route-agent Konflux stages on 0.19–0.24 use UBI Go Toolset. No direct Brew Go consumer found. |
| submariner-operator | devel; 0.11–0.25 (16) | Operator Konflux stages on 0.19–0.24 use UBI Go Toolset; bundle uses scratch. No direct Brew Go consumer found. |
| subctl | devel; 0.13–0.25 (14) | CLI Konflux stages on 0.19–0.24 use UBI Go Toolset. Include its accepted no-change disposition in the product-wide result. |
| shipyard | devel; 0.9, 0.11–0.25 (17) | Dapper base uses Fedora/dnf; nettest Konflux is runtime-only. Shared test/build tooling needs a disposition alongside shipped images. |
| admiral | devel; 0.11–0.25 (16) | Library repo, no Dockerfile or direct Brew Go reference found. Its compiled dependencies are qualified through consumers. |
| cloud-prepare | devel; 0.11–0.25 (16) | Same library disposition; no separate image-builder migration established. |
| submariner-addon | main; 2.2–2.17, 4.23, 5.0–5.2; four appstudio branches (25) | Verified Brew consumers in both Dockerfile paths; resolve active sources and migrate as detailed below. |
| submariner-operator-fbc | [main](https://github.com/stolostron/submariner-operator-fbc/tree/2e6b489e65620738d68504d9158418fe463e2073) (1) | Catalog stages run the prebuilt OPM image (default v1.65.0); no Go compiler stage or direct Brew Go reference found. Check resolved external tasks separately. |

The six ticket-listed component builders across 0.19–0.24 total **36 Konflux Dockerfiles** using UBI Go Toolset. Product 0.25 branches exist but currently lack Konflux Dockerfiles; the setup script copies those from the preceding release. Review that generated source when 0.25 is onboarded. The scan finds no literal Brew/OSBS Go-builder consumer outside addon in these trees; `enable-package-registry-proxy` is a package-prefetch option, not a Brew image reference. This source result supports no-change decisions; it does not qualify deployed overrides or external task-image contents.

The release-management [CVE workflow](../.agents/workflows/scan-cves.md#addon-go-toolchain) still selects addon Go builders from Brew. Update that operational guidance to the accepted floating ART family and both used Dockerfile paths, preserving compiler/security/OS requirements. Include scripts, templates and documented update commands in the final reference check so the next security fix or branch setup does not restore a Brew consumer. Historical receipts and unrelated operator-index registry-proxy references need no rewrite.

## Addon branch differences

Addon belongs to the ACM artifact path and has its own release branches. Source reads distinguish its ordinary and Konflux Dockerfiles:

| Branch | Root Go floor | Ordinary Dockerfile | Konflux Dockerfile | Pinned source |
| --- | --- | --- | --- | --- |
| release-2.10 | 1.24.0 | CI `stolostron/builder:go1.23-linux` | Brew `rhel_9_1.23` | [e1d3198b](https://github.com/stolostron/submariner-addon/tree/e1d3198b81b8b44d9881898caa2a4200e35229cc) |
| release-2.11 | 1.24.0 | Brew `v1.24.6` | Brew `v1.24.6` | [7299448b](https://github.com/stolostron/submariner-addon/tree/7299448bfed1df125955bef08e8bc21d267ce1f1) |
| release-2.12 | 1.24.0 | Brew `v1.24.6` | Brew `v1.24.6` | [35ede4a6](https://github.com/stolostron/submariner-addon/tree/35ede4a6fb8a346db26c2a47144e798a6f741de2) |
| release-2.13 | 1.25.0 | Brew `v1.25` | Brew `v1.25` | [95ba831f](https://github.com/stolostron/submariner-addon/tree/95ba831f529d8dd824f84e3e95d1d56cd4a08b4a) |
| release-2.14 | 1.25.8 | CI `stolostron/builder:go1.24-linux` | Brew `openshift-golang-builder:v1.25` | [546eaf0c](https://github.com/stolostron/submariner-addon/tree/546eaf0cb95c1433e27d00fa8d4b1bb84e00610f) |
| release-2.15 | 1.25.8 | Brew `v1.25` | Brew `v1.25` | [77383385](https://github.com/stolostron/submariner-addon/tree/77383385f14254be6db8264b38393fdc0400e6fe) |
| release-2.16 | 1.25.8 | Brew `v1.25` | Brew `v1.25` | [19532bd7](https://github.com/stolostron/submariner-addon/tree/19532bd70d7014013ca9490bc1d52ca4b51a41c6) |
| release-2.17 | 1.25.13 | Brew `v1.25` | Brew `v1.25` | [e27719e3](https://github.com/stolostron/submariner-addon/tree/e27719e321260f1b50fdbace59a8a09a48e71e00) |
| release-4.23 | 1.25.8 | Brew `v1.25` | Brew `v1.25` | [f9e62785](https://github.com/stolostron/submariner-addon/tree/f9e627854f63038ff99fa39d417eeda4b08379b9) |
| release-5.0 | 1.26.0 | Brew `v1.26` | Brew `v1.26`; PQC-minimal runtime base | [cd2fbb77](https://github.com/stolostron/submariner-addon/tree/cd2fbb7714ca8be7052dc239569449e33d7a1598) |
| release-5.1 / release-5.2 | 1.26.0 | Brew `v1.26` | Brew `v1.26`; ordinary UBI-minimal runtime base | [1805dcb1](https://github.com/stolostron/submariner-addon/tree/1805dcb1166ad331097f0379c1a1d3b27f0ae12e) |
| main | 1.26.0 | Brew `v1.26` | Brew `v1.26`; ordinary UBI-minimal runtime base | [6ec4f450](https://github.com/stolostron/submariner-addon/tree/6ec4f450b90feceeca8dfa6017b908ee7d02dd2e) |

At the inspected heads, both 2.10 builder tags and the 2.14 ordinary builder tag advertise an older Go minor than the root directive. Actual toolchain auto-download or compiler behavior
was not measured; do not infer either a working build or a universal failure solely from the tag. Verify the actual compiler and required patch level.
The extended audit also reads every published addon `release-X.Y` and appstudio branch. Releases 2.2–2.9 have no Konflux Dockerfile: 2.2 uses `docker.io/openshift/origin-release`, and 2.3–2.9 use CI `stolostron/builder` images. Release-2.9 advertises Go 1.22 against its 1.24.0 root floor. Branch existence does not choose the supported stream set; preserve or retire these paths according to actual support/build use rather than migrating every archived branch.
The separate [appstudio 2.14 source](https://github.com/stolostron/submariner-addon/tree/8270d50dd684a3936b9693a52220130e75d1d902) has a 1.23.0 root floor and Brew `rhel_9_1.23` Konflux builder. Task-ref PR #2792 targets that branch, not release-2.14, and does not implement the builder migration. Include that build source in the owner’s scope decision.

Inspected addon pipelines select `Dockerfile.konflux`; push definitions request four architectures while PR definitions request only x86_64, except the appstudio 2.14 pair, which requests only x86_64 for both. Release-2.10 has no returned `.tekton` pipeline files. A successful PR build alone does not qualify all push platforms.

PaC filters match `release-2.11`–`release-2.17` and `release-5.0` on those branches. The 5.1/5.2 branch copies filter for `main`; the 4.23 copies also filter for `main`. The separate appstudio 2.14 branch’s pair filters for `release-2.14`, although #2792 targets the appstudio branch. Cached release-data at `8c18efee` selects `Dockerfile.konflux`, release-2.11–2.17 and release-5.0 for those components, and **main for both ACM 5.1 and 5.2**. Their filters therefore agree with the cached component source and are not established defects. Resolve the deployed component revision and PaC source before changing filters or editing an appstudio/branch copy; the cached configuration is not a current deployment read.

Three additional appstudio branches retain Brew Konflux references, while their ordinary Dockerfiles use CI builders:

| Appstudio source | Root floor | Brew builder tag | Pinned source |
| --- | --- | --- | --- |
| ACM 2.11 | 1.22.0 | `rhel_9_1.22` | [fb3c0f6e](https://github.com/stolostron/submariner-addon/tree/fb3c0f6e5f04f1fccd40627953d3d3c959e81102) |
| ACM 2.12 | 1.22.0 | `rhel_9_1.21` | [c8b99692](https://github.com/stolostron/submariner-addon/tree/c8b996925e4c3965b509ca6135a44a73ca5c89a3) |
| ACM 2.13 | 1.22.0 | `rhel_9_1.22` | [d95c0520](https://github.com/stolostron/submariner-addon/tree/d95c0520d17c6666fa67c2d7f444639f59241585) |

Their PaC filters target the corresponding release branches, which the cached components also select. Do not treat these appstudio copies as active consumers without deployment evidence. The 2.12 builder/root mismatch is another source-level discrepancy to resolve if that source is still used. The latest refresh advances main for a SARIF action update and 2.17 for removal of deployment resource limits. Their Dockerfiles, modules and build/test commands remain unchanged; use the refreshed deployment settings for runtime checks.

Release-2.15 and 2.16 explicitly set `CGO_ENABLED=1 GOEXPERIMENT=strictfipsruntime` in `Dockerfile.konflux`. Preserve and exercise that contract when replacing their compiler; the other addon paths do not establish the same explicit settings. Keep this separate from release-5.0’s PQC runtime base. The [Go 1.25 FIPS fork guidance](https://github.com/golang-fips/go/blob/324439098c6a5b6a90d30a78e11a94e92627c9ef/README.md) describes runtime `dlopen` of OpenSSL and strict startup checks when FIPS is active. A dependency listing or startup on a non-FIPS host does not establish that behavior. Exercise the output image in the existing supported FIPS deployment context, including its runtime OpenSSL/provider configuration and actual crypto operations. Preserve the existing CGO, strict-FIPS and crypto-backend contract when diagnosing migration failures.

The PQC runtime base on release-5.0 is existing configuration evidence relevant to ACM-41119, not proof of the released image's crypto policy.
Main/5.1 differs; avoid carrying a generic "PQC is absent everywhere" or "all streams are covered" claim forward.

## ART replacement metadata checked October 8

Fresh reads resolve these five parent-documented tags and all twenty architecture-specific configs by digest. Each has Linux amd64, arm64, ppc64le and s390x; Tekton calls amd64 `x86_64`. Config `GO_VERSION` and the image version label agree across each tag’s platforms:

| Tag in `registry.redhat.io/openshift/golang-builder` | Declared Go version | Source floor to assess |
| --- | --- | --- |
| `golang-builder-v1.23-rhel9` | `1.23.10` | Separate appstudio 2.14 source (`1.23.0`); not sufficient for release-2.10’s `1.24.0` floor |
| `golang-builder-v1.24-rhel9` | `1.24.13` | 2.10–2.12 roots (`1.24.0`) |
| `golang-builder-v1.25-rhel8` | `1.25.14` | Candidate preserving the current Brew `v1.25` OS family on 2.13–2.17/4.23; roots up to `1.25.13` |
| `golang-builder-v1.25-rhel9` | `1.25.14` | Use for an established RHEL9 consumer or separately required OS-family transition; root Go floors alone do not choose RHEL9 |
| `golang-builder-v1.26-rhel9` | `1.26.7` | 5.0–5.2/main roots and tools (`1.26.0`) |

These are metadata observations and candidate families, not measured compiler execution or approved stream/tag selections. Preserve all compiled-module floors and existing toolchain requirements. Local index/config access does not establish CI entitlement, layer pulls, builds or crypto behavior; verify those in the actual build context. Tags float by policy, so retain resolved image digests and compiler evidence for each qualification run. Runtime-base selection remains independent.

The current Brew `v1.25` index and all four configs declare **RHEL8**, Go 1.25.14, and no explicit `GOAMD64`; the RHEL8 ART candidate preserves those declarations and the declared Go RPM build. Its filesystem metadata differs, so it still needs build qualification. The RHEL9 candidate declares a different OS/RPM family and adds `GOAMD64=v2`. Prefer the matching RHEL8 family unless an existing requirement calls for RHEL9; do not silently combine registry migration with an OS/CPU baseline change. Brew `v1.26` and ART RHEL9 both declare Go 1.26.7 and `GOAMD64=v2`, but their Go RPM release and filesystem metadata differ. Matching Go version strings do not prove identical builders.

All five ART tags declare `GOFLAGS=-mod=vendor`. The addon Makefile and Konflux build command pass `-mod=mod` explicitly; [Go command-line flags override GOFLAGS](https://pkg.go.dev/cmd/go#hdr-Environment_variables), so this default does not establish a new vendoring requirement. The Dockerfile’s `make build` compiles the root command; tools-module compilation belongs to targets that actually invoke those tools. Keep prefetch aligned with those targets rather than adding tools prefetch to the image build without a consumer. Measure effective CPU feature settings and check the built binary in its unchanged runtime image, including dynamic loader/libraries where CGO is used. The ordinary 2.11 CI image uses a UBI8 runtime override; retain that context in runtime qualification.

## Other build inputs and full migration scope

The [OpenShift CI configuration](https://github.com/openshift/release/tree/8dc32b0f7b22122ad82bed2511fdec40419429a7/ci-operator/config/stolostron/submariner-addon) selects the ordinary `Dockerfile` for ten addon branch configurations. Its build root is separate: CI `stolostron/builder` Go 1.25 for 2.11–2.13 and Go 1.26 for 2.14–2.17, 5.0/5.1 and main. Both Dockerfiles therefore need a disposition on each accepted stream; replacing only `Dockerfile.konflux` leaves the ordinary Brew path where present. The addon Makefile also defaults image builds to `./Dockerfile`.

That shared CI builder is [UBI-based](https://github.com/stolostron/image-builder/blob/363bb4685ebf964821f67d8405481dd498eb1bdc/Dockerfile.go1.26-linux), with [Go downloaded directly](https://github.com/stolostron/image-builder/blob/363bb4685ebf964821f67d8405481dd498eb1bdc/build/setup-go.sh); no named Brew builder consumer is found in its source. Its Go 1.26 Dockerfile specifies **1.26.8**, while both the current Brew and ART artifact builders declare **1.26.7**. This is a difference between build paths, not evidence that migration downgrades the artifact compiler or that 1.26.8 is an accepted minimum. Compare the actual old/new artifact compilers and retain required patch/security levels. The Shipyard Dapper base uses Fedora and installs its Go package through dnf; its inspected source and vendored build inputs add no direct Brew consumer.

Addon release pipelines resolve [ACM common.yaml](https://github.com/stolostron/konflux-build-catalog/blob/d6b74add90f5717bd2858cb8b7d1cd6aec32c09e/pipelines/common.yaml) through mutable `main`. It carries hermetic mode, root-module prefetch and platform parameters into digest-pinned build tasks. The remote build task’s OCI manifest identifies [this immutable task source](https://github.com/konflux-ci/container-build-catalog/blob/cab160f4afed001a6ad32f4b0e1ee3067d1b8547/task/buildah-remote-oci-ta/buildah-remote-oci-ta.yaml). Record the catalog revision actually resolved in each qualification run and verify registry access in its remote build context. Local registry login, registry pull entitlement and RPM subscription certificates are separate evidence; do not add RPM entitlement configuration merely to pull the ART image.

The pinned Prow jobs for main, 2.11 and 2.15 pass `--image-import-pull-secret` and distinguish `--target=[images]` from build/unit targets. The latter use CI-root binaries; the build test itself runs `true` in `bin`. Require the corresponding **images** check on each changed ordinary Dockerfile, plus the required Konflux image/platform checks. A green source build/unit check alone does not exercise the replacement Dockerfile stage.

All ten inspected Prow configurations run integration tests from `test-bin`, not the addon output image. The main [integration target](https://github.com/stolostron/submariner-addon/blob/6ec4f450b90feceeca8dfa6017b908ee7d02dd2e/test/integration-test.mk) compiles and runs an envtest binary. Its source-test success and the postsubmit image-mirror workflow do not establish startup of the rebuilt addon image. Keep source tests, Dockerfile image builds and runtime checks as separate verdicts.

| CI context | Credential path to verify |
| --- | --- |
| OpenShift ordinary image build | Follow the job’s pull-secret input to the generated Build’s `spec.strategy.dockerStrategy.pullSecret`; [CI Operator passes that secret to the image build](https://github.com/openshift/ci-tools/blob/c02a7676f479a22cebbc56fddb841cae73c123e1/pkg/steps/source.go). A credential mounted in an unrelated test container is insufficient evidence. Verify the exact ART repository’s internal entitlement. |
| Konflux task and remote worker | [Tekton merges credentials from the service account’s secrets](https://konflux-ci.dev/docs/troubleshooting/registries/) into `~/.docker/config.json`; Pod imagePullSecrets serve a different pull context. The inspected task rsyncs this Docker configuration to the remote worker and mounts it in the build container. Verify the selected credential’s repository/path match and entitlement along that actual path; preserve existing links. |

These source paths identify where to check access; they do not establish deployed credential contents or a successful build. Do not add or rotate secrets solely because the registry hostname changes.

| Area | Work needed before closure |
| --- | --- |
| Build sources and Dockerfiles | Confirm supported/deployed revisions; replace both verified Brew consumers where used. Give appstudio copies and archived branches an explicit disposition. Preserve matching PaC filters. |
| CI registry access | Verify OpenShift image-build pull credentials and Konflux task/remote-worker credentials against the exact repository. Change credentials or policy only for an identified missing requirement. |
| Compiler, runtime and crypto | Preserve builder OS family, module/toolchain and required patch/CPU levels, runtime compatibility, CGO and the 2.15/2.16 strict-FIPS settings. Measure the actual artifact compiler. |
| Hermetic builds and release platforms | Retain root prefetch and offline build behavior; check toolchain switching as well as dependencies. No addon RPM lockfiles were found, so regenerate only inputs actually affected. Qualify every required platform and the resulting image/provenance. |
| Future branches and completion | Carry both Dockerfile changes through the addon’s accepted branch process; its setup is separate from the eight-component wrapper. Update the Brew-selecting CVE guidance and review generated/predecessor inputs. Retain one disposition per repo/build source and qualified consumer evidence before closure. |

[Go toolchain selection](https://go.dev/doc/toolchain) can use another compiler from PATH or download one; repackaged toolchains can change the default. Record effective `GOTOOLCHAIN` in the actual build, including its configured defaults. Qualify the selected downstream compiler and its crypto support; a stock downloaded toolchain is not equivalent solely because its Go version satisfies the module floor. Inspect the exact output binary with [`go version -m`](https://pkg.go.dev/cmd/go#hdr-Print_Go_version) for compiler/build settings and compare them with the build log. The addon’s `--version` reports application identity, not compiler identity. Inspect a copy from the output image using external tooling; do not add Go to the runtime image for this check. Binary metadata alone does not prove the crypto backend or runtime policy.

## Prepare a reviewable change

1. Confirm supported/deployed source revisions across every repository in the coverage table and refresh their heads. Record each active build path as migrated, unaffected with evidence, or retired; resolve CI/tenant-selected branch copies and overrides before accepting a no-change disposition. For each used Dockerfile, record the current builder, module/toolchain floor, declared and measured compiler/RPM/OS/CPU settings, runtime base and CI source selection. Choose a parent-documented floating tag that preserves the applicable contract; the current Brew `v1.25` paths have a matching RHEL8 candidate.
2. Verify the two credential paths above, then prepare isolated replacements of verified Brew references in both used addon Dockerfiles. Retain build commands, runtime bases, labels, crypto settings and prefetch. Add credential, dependency or lock changes only when required by that consumer; no addon RPM lockfiles are present. Give unaffected product paths and unused branch copies an explicit disposition.
3. Qualify the proposed head through ordinary Prow images checks and the required Konflux platforms, preserving hermetic mode. Record source SHA, resolved catalog/task and base-image digests, binary compiler/build settings and separate source/build/runtime verdicts per context/platform. For multi-platform release builds, match each Konflux matrix result to its child image digest in the published index; bind runtime evidence to that child digest. The catalog builds the index from matrix IMAGE_REF results, so inspect actual index coverage rather than relying only on requested platforms. Use `/submariner --version` in the output image for a basic executable/loader check; [the command exits 1 without arguments by design](https://github.com/stolostron/submariner-addon/blob/6ec4f450b90feceeca8dfa6017b908ee7d02dd2e/cmd/submariner/main.go). That basic check does not prove controller readiness or crypto behavior: retain those checks under the existing deployment context and settings. A PR’s x86_64 build does not qualify every release platform.
4. Carry changes through the accepted addon branch process and update the Brew-selecting CVE workflow; the eight-component setup wrapper excludes addon. Check active build references, overrides and future-copy inputs for Brew/OSBS aliases or pinned Go-builder NVRs. Close only after reviewed changes are merged, each used replacement has passing pull/build/runtime/platform evidence, and every repo/build-source row has an accepted migrated/no-change/retired disposition. No unresolved active source may be omitted from the result. ART ownership transfer, PQC runtime state, OLMv1 and OCP 5 compatibility retain their existing criteria.

## Validation boundary and immediate next action

The expanded read covers all 137 canonical refs in the coverage table; the earlier addon source advances above leave build inputs unchanged. Earlier October 8 checks cover five ART indexes/twenty configs, two Brew indexes/eight configs, six pinned Prow job documents and CI Operator credential code. This follow-up checks version-specific FIPS guidance, output-binary inspection and the catalog’s matrix-to-index path. No image layers, container execution or migration build was used; execution and CI qualification remain unestablished.
The next handoff is supported/deployed addon source and CI-access confirmation, then isolated changes to verified Brew consumers and compiler/runtime/crypto/platform qualification. Keep no-change dispositions for unaffected paths. Local registry metadata access does not establish CI access; the latest read-only Konflux authentication check is Unauthorized, so cached tenant configuration cannot establish the deployed source.
