# CLAUDE.md

## Creating Releases

Files: `releases/0.20/{stage|prod}/submariner-0-20-{patch}-{stage|prod}-YYYYMMDD-NN.yaml`

Example: `releases/0.20/stage/submariner-0-20-2-stage-20250930-01.yaml`

1. Copy existing YAML from same environment (stage→stage, prod→prod)
2. Update `metadata.name`, `spec.snapshot`, `spec.data.releaseNotes` (type/cves/issues)
3. `make test-remote` then `make apply FILE=...`
4. `make watch NAME=...`

## Finding Snapshots

```bash
oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp
oc get snapshot <name> -n submariner-tenant \
  -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' \
  | jq
```

Look for snapshots where all tests show `"status": "TestPassed"`.

## Requirements

- Advisory types: RHSA (security, must have ≥1 CVE), RHBA (bug fix), RHEA (enhancement)
- Component names must have version suffix: `lighthouse-coredns-0-20`
- Issue IDs:
  - Jira: `PROJECT-12345` (source: `issues.redhat.com`)
  - Bugzilla: `1234567` (source: `bugzilla.redhat.com`)

## Validation

Releases: `make test` | `make test-remote` (requires cluster)

Markdown: `npx markdownlint-cli2 "**/*.md"`
