# Skip Already-Completed Steps

**When:** Re-releases, retargets (e.g. 0.23.2 → 0.23.4), retrying a failed stage or prod release, or resuming a release after the
upstream tag already exists. Applies to Y-stream and Z-stream.

Do not redo upstream work that is already done. These rules are maintainer decisions (see "Settled Decisions" in `CLAUDE.md`).

## The rules

| Step | Skip when | Why |
| ---- | --------- | --- |
| 6. Upstream release | `v$VERSION` exists on all 5 component repos | The tag is permanent. Never re-cut or move it. |
| 5. CVE fixes | The CVE pass was done before the upstream tag was cut | CVE fixes land before the tag; later changes cannot affect it. |
| 4. Tekton tasks | Snapshot and managed release-policy requirements met | Repair actual policy/trust failures only. |
| 5b. Version labels | Component image and compiled Go versions match `$VERSION` (release-ls verifies both) | Nothing to change. |

Consequences:

- Reuse verified completed upstream CVE work for an immutable tag. A new version needs its own source review before tagging.
  Rebuilt downstream images still need scan/policy evidence tied to their exact source and image digests.
- **Do not proactively bump Tekton tasks** or merge Konflux bot task-update PRs "to be safe". Fix EC only when EC fails.
- Require finished aggregate integration and completed policy results for the intended snapshot. `BuildPLRInProgress` alone
  is not proof of success; retained markers require completion evidence. Check the actual signed build and release-required tasks.
  A passing integration scenario can still be followed by a managed release-policy rejection.
- RPM lockfile updates are separate from these rules and unchanged.

## How to tell `/autorelease` and `release-ls`

The conductor still walks every step. Mark the ones you are skipping so it advances:

```bash
/autorelease 0.X.Y --dry-run                    # see what it thinks is next
/autorelease 0.X.Y --complete cveFixes          # CVE fixes were done before the tag
/autorelease 0.X.Y --complete tektonTasks       # Exact candidate meets snapshot/release task requirements
```

How the conductor decides each step is done:

- `upstreamRelease` verifies the tags itself and completes when `v$VERSION` exists on all 5 repos. It runs only after its
  dependencies (`cveFixes`, `ecFixes`, `rpmLockfiles`, `tektonTasks`, `versionLabels`) are complete, so mark skipped ones first.
- `ecFixes` verifies EC on the latest snapshot and completes when it passes.
- `cveFixes` waits for matching open fix PRs on the release branch. After they merge, the script rescans all seven repositories;
  only a clean scan completes the step. Historical merged PRs do not prove the current sources are clean.
- `tektonTasks` waits for open fix PRs (`fix-tekton-tasks-X.Y.Z`), including partial repairs where other repos need no PR.
  When some repos have no repair PR, it checks fresh source branches after pending reviews finish. It repairs only denied
  catalog moves, preserving unrelated pins; all merged repair PRs can complete the source step directly.
  Other violations need diagnosis from the actual EC report; neither task helper completion nor merged PRs prove that the
  rebuilt images meet managed release policy. The exact snapshot still needs verification at the EC and release gates.
  When completed source work is deliberately reused, verify the evidence above and use `--complete` for these steps.

Do not refresh completed upstream source work solely because of age. Repair build tasks when the actual candidate fails
policy or a trust expiry applies, even when its source tag already exists.

### Expected noise

- `release-ls` suppresses the advisory age warning for completed `cveFixes` only after verifying `v$VERSION` on all five component
  repositories. Missing, unreachable or timed-out tag evidence keeps source completion unverified; do not skip work on that basis.
- `release-ls` Step 5 separates completed upstream work from scan evidence for the current downstream snapshot.
- After a retarget, old STEP_DATA from the previous version may still read `complete`. Check the tag, EC, image labels and
  compiled versions directly (`release-ls` does) rather than trusting old tracker entries.

## Checklist before skipping

Verify, do not assume:

```bash
# Upstream tag exists on all 5 component repos
for repo in submariner-operator submariner lighthouse shipyard subctl; do
  git ls-remote --tags https://github.com/submariner-io/$repo refs/tags/v0.X.Y | grep -q refs/tags && echo "$repo ok" || echo "$repo MISSING"
done

# Inspect completed policy evidence for the exact intended snapshot; verify identity independently
scripts/release-status.sh 0.X.Y | sed -n '/Step 4/,/Step 5\]/p'
```

If a tag is missing on any repo, this page does not apply: finish the upstream release first (`cut-upstream-release.md`).

## Example: retarget 0.23.2 → 0.23.4 (2026-09)

0.23.2 failed QE and was never shipped to prod. Upstream v0.23.4 was already tagged on all repos, CVE fixes had been done before
tagging, and EC was passing. Completed upstream work was reused; the release continued from the bundle SHAs step. The
later stage recovery required a
fresh FBC build with a missing policy-required task, proving why actual build and release evidence remain separate gates.
