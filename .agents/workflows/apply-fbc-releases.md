# Apply FBC releases

**Used by:** Step 13 (stage), Step 18 (prod).

Apply only the reviewed YAMLs for the requested Submariner version, environment
and applicable active OCP scope. Use explicit filenames, including the full
Submariner version and attempt sequence; do not apply every historical YAML or
assume a fixed catalog count.

```bash
FILE=releases/fbc/4-19/stage/submariner-fbc-4-19-0-23-4-stage-YYYYMMDD-02.yaml
make test-remote FILE="$FILE"
make apply FILE="$FILE"
NAME=$(yq -r '.metadata.name' "$FILE")
make watch NAME="$NAME"
```

Replace the example with the exact reviewed file. Confirm its snapshot is the
verified candidate and its ReleasePlan/admission matches the requested environment.
Apply requires explicit authorization; stage authorization does not authorize
production. For production, use the exact QE-approved stage snapshot and follow
[production preparation](create-fbc-prod-release.md).

## Done when

Each intended Release reports `Released=True/Succeeded`, its artifact matches
the verified snapshot, and the published digest is accessible. Follow
[exact Release checks](check-fbc-releases.md) and [QE handoff](share-with-qe.md).
A running Release or a passing build is not completed publication. Investigate
failures before creating a distinct retry; retain each attempt's evidence.
