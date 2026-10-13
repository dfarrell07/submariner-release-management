# Update Tekton Tasks and Resolve EC Violations

**When:** Y-stream (0.20 → 0.21) and Z-stream (0.20.1 → 0.20.2). Components mostly handled in Step 3 for Y-stream, FBC needs checking for both.

> **Reuse completed task work** when the exact candidate meets snapshot and managed release-policy requirements.
> Repair actual policy/trust failures; do not bump unrelated tasks proactively. See `skip-completed-steps.md`.

## Process

Ensure all Konflux builds pass Enterprise Contract validation before cutting releases.

**Component repos** (all in <https://github.com/submariner-io>):

- `submariner-operator` (2): submariner-operator, submariner-bundle
- `submariner` (3): submariner-gateway, submariner-globalnet, submariner-route-agent
- `lighthouse` (2): lighthouse-agent, lighthouse-coredns
- `shipyard` (1): nettest
- `subctl` (1): subctl

**Local:** `~/go/src/submariner-io/`

**FBC repo:** <https://github.com/stolostron/submariner-operator-fbc>
**Local:** `~/konflux/submariner-operator-fbc`

**Workflow:** `~/go/src/submariner-io/submariner-operator/.agents/workflows/konflux-ci-fix.md` (on `kf_claud` branch) for components

**TODO:** Add similar workflows to other component repos.

**TODO:** Add FBC EC violation fixing workflow.

## Done When

Check the exact intended component snapshot and applicable FBC snapshots, not a
newest-name lookup. Require finished aggregate integration, successful aggregate
tests and completion timestamps/results for the configured policy scenarios.
A retained `BuildPLRInProgress` marker alone is not a passing verdict. Preserve
completed warning results when their aggregate verdict is successful.

```bash
SNAPSHOT='<exact intended snapshot>'
oc get snapshot "$SNAPSHOT" -n submariner-tenant -o json | jq '{
  source: .spec.components, conditions: .status.conditions,
  tests: (.metadata.annotations["test.appstudio.openshift.io/status"] | fromjson)
}'
```

Verify source/image identities and signed build tasks separately. A passing
integration scenario does not prove the later managed release policy accepts
the image. For FBC, follow [stage preparation](create-fbc-stage-release.md).
Repair the actual violation; do not update unrelated task pins merely to latest.

### Retrigger Failed Push Builds

If a push build fails due to an infra flake, retrigger with a `/retest` comment on the HEAD commit:

```bash
# Component repos
gh api repos/submariner-io/<repo>/commits/release-0.X --jq '.sha' | \
  xargs -I{} gh api repos/submariner-io/<repo>/commits/{}/comments -f body="/retest"

# FBC repo
gh api repos/stolostron/submariner-operator-fbc/commits/main --jq '.sha' | \
  xargs -I{} gh api repos/stolostron/submariner-operator-fbc/commits/{}/comments -f body="/retest"
```
