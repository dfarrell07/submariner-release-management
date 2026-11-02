---
name: rpm-lockfile-update
description: Update RPM lockfiles across Submariner repositories
version: 2.0.0
argument-hint: "[branch] [repo|component]"
user-invocable: true
allowed-tools: Bash
---

# RPM Lockfile Update

Regenerates RPM lockfiles in submariner and shipyard repositories by creating fix branches, running hermetic builds,
and committing updated lockfiles. Also refreshes digest-pinned base images, committed with the lockfiles.

## Invocation

```text
Claude: /release-management:rpm-lockfile-update 0.21 submariner
Codex:  $release-management:rpm-lockfile-update 0.21 submariner
```

Additional argument forms:

```text
(none)                                      # Auto-detect branch, all repos
0.21                                        # Explicit branch, all repos
gateway                                     # Auto-detect branch, gateway only
make rpm-lockfile-update                         # Auto-detect branch
make rpm-lockfile-update COMPONENT=gateway       # Auto-detect, component filter
make rpm-lockfile-update BRANCH=0.21 COMPONENT=gateway  # Explicit branch
```

**Filter options:** all, submariner, shipyard, gateway, globalnet, route-agent, nettest

**Requirements:** Red Hat entitlements and `registry.redhat.io` login (one-time: `make setup-entitlements`), `gh auth login`,
`skopeo`, `jq`, Bash 4.0+

On macOS, run `make linux-vm-setup` once first; the script then re-runs itself in that VM.

## Pinned base images

Hermetic builds keep every package not in `rpms.in.yaml` at the base image's versions, so an old pin keeps its fixable
CVEs however fresh the lockfile is. After creating the fix branch and before generating lockfiles, the script handles
each in-scope `package/Dockerfile*.konflux` (all in the repo, or only the filtered component's):

- `FROM` lines with `registry.redhat.io/<repo>@sha256:<digest>` move to the current digest of `<repo>:latest`, printing
  the old and new digests. `--platform` and the rest of the line are kept.
- `:latest`, tag-and-digest and other registries' references are left alone.
- The new digest must be well formed and a multi-arch index with amd64, arm64, s390x and ppc64le.
- Rewritten Dockerfiles are committed with the lockfiles, so a digest bump commits even if no lockfile changed.

If a digest cannot be resolved or validated, that repo is reported failed (`base-refresh-failed`, details on stderr) with
its Dockerfiles untouched and the original branch restored. It never keeps the old digest silently. Check the registry
login and retry.

## Inputs and execution

The branch and repository/component filter are optional. Preserve exactly the
values and order supplied by the user; otherwise let the script perform its
documented branch and repository detection.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/rpm-lockfile-update.sh`. Verify the script exists and is executable.

Run `scripts/rpm-lockfile-update.sh`, passing each supplied value as a separate
argument, or no arguments for full auto-detection. Do not combine arguments into
a shell string or use `eval`.
