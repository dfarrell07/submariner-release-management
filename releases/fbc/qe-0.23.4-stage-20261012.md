<!-- markdownlint-disable MD013 -->

# Submariner 0.23.4 staged FBCs for QE

Verified 2026-10-12T20:03:50.980655+00:00. All six exact stage Releases report `Released=True/Succeeded`. These are the independently verified released FBC fragments to use as the CatalogSource image for the matching OCP version.

| OCP | QE catalog image |
| --- | --- |
| 4.16 | `quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-16@sha256:8ea98909dbd4f030eaa447610e1cb5de80c1e0ee92e7ad402d301ae29d3ba391` |
| 4.17 | `quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-17@sha256:7da744d3107e490b13fa8b6a041420bf296f33003583514e92bd232f16d3df89` |
| 4.18 | `quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-18@sha256:f8713931d47d06f3c3efeb1469d946e98b37d3041f1ed77dcc25b37e86427898` |
| 4.19 | `quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-19@sha256:154bba93658ca69ae2a7933a19b04247f2d276cf6baed2f12dfbffba1123f5f7` |
| 4.20 | `quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-20@sha256:d3a1b39abdebb5a135191d8810d795dd3b8a3dd16c92ec2628fa133c9ec317cd` |
| 4.21 | `quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-21@sha256:9c06ca0f9524f76254ffcc1d46aba73b7fdf8a822eab70707af87d387ede911c` |

Use package `submariner`, channel `stable-0.23`, and starting CSV `submariner.v0.23.4`. The channel head is 0.23.4 in all six catalogs. The package default is `stable-0.24`, which selects a different release.

Apply the approved [ImageDigestMirrorSet](https://github.com/stolostron/submariner-operator-fbc/blob/2e6b489e65620738d68504d9158418fe463e2073/.tekton/images-mirror-set.yaml) on the QE cluster and configure authorized Quay pull credentials for catalog, bundle and operand pulls. The catalog contains registry.redhat.io pullspecs; this stage mirror configuration redirects the approved digests to Quay.

Approved bundle: `quay.io/redhat-user-workloads/submariner-tenant/submariner-bundle-0-23@sha256:b83d0f0f158e8b7ad1fc749f2a2b69de30aac8b1b7ca0a62ad19b1b0e9359960`. The physical CSV is version 0.23.4; the bundle and seven operand digests match component-stage snapshot `submariner-0-23-20260930-064533-000`. All eight mirror manifests were freshly checked for accessibility and digest equality.

| OCP | Exact successful Release | Exact snapshot | IIB stage build |
| --- | --- | --- | --- |
| 4.16 | `submariner-fbc-4-16-0-23-4-stage-20261012-01` | `submariner-fbc-4-16-20261012-192048-000` | `1228286` |
| 4.17 | `submariner-fbc-4-17-0-23-4-stage-20261012-01` | `submariner-fbc-4-17-20261012-192048-000` | `1228283` |
| 4.18 | `submariner-fbc-4-18-0-23-4-stage-20261012-01` | `submariner-fbc-4-18-20261012-192049-000` | `1228285` |
| 4.19 | `submariner-fbc-4-19-0-23-4-stage-20261012-02` | `submariner-fbc-4-19-20261012-184702-000` | `1228243` |
| 4.20 | `submariner-fbc-4-20-0-23-4-stage-20261012-01` | `submariner-fbc-4-20-20261012-192050-000` | `1228282` |
| 4.21 | `submariner-fbc-4-21-0-23-4-stage-20261012-01` | `submariner-fbc-4-21-20261012-192050-000` | `1228284` |

Verification: all six replacement builds are successful and signed, with the required lifecycle task executed successfully. Both snapshot scenarios have finished passing results. Every catalog YAML matches source commit `2e6b489e65620738d68504d9158418fe463e2073`, with unchanged approved bundle/operand pins. Each release policy run passed 700 checks with zero violations and ten accepted warnings. The released fragment matches its exact snapshot, and all six manifest digests and four platforms (amd64, arm64, ppc64le, s390x) were freshly verified. Completed build, snapshot, policy and Release JSON records are retained with the recovery evidence. The first 4.19 attempt failed required-task policy; the second attempt is the successful candidate.

Ready for QE installation and testing; installation and compatibility qualification have not been completed here. The operator integration scenario skipped installation. Confirm CatalogSource readiness, the installed CSV `submariner.v0.23.4` reaches Succeeded, and operand pulls use the approved stage mirrors before running QE tests.

The successful Releases also report full internal IIB indexes. Their contents were not independently extracted here; the initial internal-registry probe timed out. The Quay fragments above were independently extracted and verified. No production Release was applied.
