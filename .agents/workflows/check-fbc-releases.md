# Check FBC releases

Audit the exact Release attempts recorded for this Submariner version and
identify the intended attempt for each applicable OCP target. Do not select by
a broad OCP prefix, which can return a different Submariner release.

```bash
VERSION=0.24.1
ENV=stage
DASH=${VERSION//./-}
for YAML in releases/fbc/*-*/"$ENV"/submariner-fbc-*-"$DASH"-"$ENV"-*.yaml; do
  [ -f "$YAML" ] || continue
  NAME=$(yq -r '.metadata.name' "$YAML")
  oc get release "$NAME" -n submariner-tenant \
    -o jsonpath='{.metadata.name}{": "}{.status.conditions[?(@.type=="Released")]}{"\n"}'
done
```

Each intended attempt must have `Released=True` and `reason=Succeeded`. A
superseded failed attempt remains in the audit but does not invalidate a verified
successful retry. Investigate missing, pending, or failed intended attempts. Use
`make watch NAME=...` for the exact release. Historical files without a Submariner version need explicit
identification by their component release date; do not mix them into a modern
release merely because their OCP version matches.

Save completed Release JSON alongside the existing release evidence before live
records stop being returned:

```bash
oc get release "$NAME" -n submariner-tenant -o json > "$NAME.completed.json"
```

Retain the exact plan, snapshot, released artifact digests, completion condition
and relevant managed pipeline/policy results. Failed attempts remain failures;
a later retry has its own identity. `NotFound` does not prove failure, successful
publication or a particular deletion cause. Reconcile retained completed evidence
for that exact Release. A local YAML or available snapshot alone is insufficient.
