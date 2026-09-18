---
name: get-fbc-urls
description: Get FBC catalog URLs for QE sharing (Release CRs, snapshots, or prod index)
version: 2.0.0
argument-hint: "<version> [--ocp 4.XX] [--raw-url] [--prod-index]"
user-invocable: true
allowed-tools: Bash
---

# Get FBC URLs

Gets FBC catalog URLs for sharing with QE. Default mode extracts quay.io catalog URLs from Release CRs
on the cluster, falling back to snapshot lookup from local YAML files if Release CRs are garbage-collected.
Prod-index mode checks the Red Hat operator index at registry.redhat.io.

```text
Claude: /release-management:get-fbc-urls 0.24.0
Codex:  $release-management:get-fbc-urls 0.24.0
```

Additional argument forms:

```text
0.24.0 --ocp 4.21                   # Single OCP version
0.24.0 --raw-url                    # URLs only
0.24.0 --prod-index                 # Check prod operator index
0.24.0 --prod-index --raw-url       # Prod index URLs only
make get-fbc-urls VERSION=0.24.0        # Via make target
make get-fbc-urls VERSION=0.24.0 PROD_INDEX=true
```

**Requirements:** `oc login` (default mode), `skopeo` (prod-index mode)

## Inputs and execution

The version is required. Optional arguments are `--ocp <version>`, `--raw-url`,
and `--prod-index`. Preserve the user's argument order and do not infer a
release or OCP version.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/get-fbc-urls.sh`. Verify the script exists and is executable.

Run `scripts/get-fbc-urls.sh`, passing each supplied value as a separate
argument. Do not combine arguments into a shell string or use `eval`.
