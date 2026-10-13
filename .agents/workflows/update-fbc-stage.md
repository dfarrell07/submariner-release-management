# Update FBC catalog with stage bundle

**When:** After the exact component-stage release completes (Step 10).

The conductor handles this step during an authorized release run. For manual
operation or debugging, follow the FBC repository's
`.agents/workflows/update-catalog.md` with the approved component-stage snapshot.
Retain its bundle/operand digests; do not implicitly select a newer snapshot.

## Done when

For each applicable active OCP target, record the exact FBC source commit,
build, snapshot and image digest. Verify completed aggregate/scenario results
and the catalog's approved bundle/component pins using
[stage preparation](create-fbc-stage-release.md). A newest-name lookup or a
`BuildPLRInProgress` marker is insufficient. Generated catalogs for retired
versions do not extend the active release scope.

## Retry the operation that failed

Distinguish a build failure from a snapshot integration failure and a managed
release-policy failure. Diagnose the task logs before retrying.

After fixing integration credentials or configuration, rerun the exact snapshot
scenario rather than rebuilding unchanged catalog content. Initial tests must
have completed, with no rerun already pending:

```bash
oc label snapshot "$SNAPSHOT" -n submariner-tenant \
  test.appstudio.openshift.io/run="submariner-fbc-operator-$OCP_ID"
```

Set `SNAPSHOT` and `OCP_ID` from the recorded candidate, then verify the new run's
snapshot/scenario labels and completed result. See the
[Konflux rerun procedure](https://konflux-ci.dev/docs/testing/integration/rerunning/).
A build retrigger creates a new image/snapshot and needs fresh verification;
a missing policy-required task needs the fresh-build repair described in stage
preparation. Do not retry a release of the same rejected image.
