# Plan: Integrate submariner-addon Tekton Setup into Release Process

## Problem

submariner-addon lives in a different Konflux tenant (`crt-redhat-acm-tenant` on
`stone-prd-rh01`) than the 9 Submariner components (`submariner-tenant` on
`kflux-prd-rh02`). When a new ACM release branch is cut (e.g., `release-2.17`),
the ACM team's fast-forwarding mechanism creates `.tekton/` files that inherit
`target_branch == "main"` from the source branch. Nobody updates these to
`target_branch == "release-2.17"`, so:

- Pushes to `main` build images for the release component (wrong source code)
- Pushes to the release branch trigger nothing (CEL never matches)

This caused the ACM 2.17 CrashLoopBackOff incident (2026-08-13): the 2.17
submariner-addon image contained unreleased `main` code.

The existing `konflux-component-setup.sh` handles this fixup for the 9
`submariner-io/` components but explicitly excludes submariner-addon.

## Approach: New `tektonAddon` Step in the Release Graph

Add a first-class step to `jira-tracker.sh` with a simple backing script. This
is the cleanest integration because:

1. The addon setup is much simpler than `konflux-component-setup.sh` (no
   Dockerfile copy, no RPM lockfiles, no CPE labels, no build-args, no inline
   pipelineSpec task refs to patch). It's just: copy `.tekton/` from previous
   release, sed version strings, remove stale files.
2. Adding it to the dependency graph means `upstreamRelease` cannot proceed
   until the addon is set up — the release literally cannot forget this step.
3. The autorelease conductor can run it automatically (`AUTOMATION_LEVEL=auto`).
4. `/release-ls` shows it. A verifier catches misconfiguration.

### What NOT to do

- Do NOT extend `konflux-component-setup.sh`. That script is 1100 lines of
  `submariner-io`-specific logic (org paths, `package/Dockerfile.*.konflux`
  convention, inline pipelineSpec, CPE labels, RPM lockfiles). Forcing the addon
  in would require `if [ "$COMPONENT" = "submariner-addon" ]` branches
  everywhere.
- Do NOT just update the workflow doc in `submariner-addon`. Without a tracked
  step in the release graph, it will be forgotten again.

## Scope

The `tektonAddon` step only applies when the Submariner release cycle creates a
new Y-stream that maps to an ACM 2.x release. It does NOT apply to:

- ACM 5.x branches (`release-5.0`, `release-5.1`) — these are fast-forwarded
  from `main` by the ACM team and are not part of our release cycle
- Z-stream releases — the `.tekton/` files are already correct on the release
  branch

### Version Mapping

The existing formula in `configure-downstream.sh` applies:
`ACM version = 2.(Submariner_minor - 7)` (e.g., Submariner 0.24 → ACM 2.17).
The script derives the ACM version from the Submariner version argument.

## Changes

### 1. `scripts/lib/jira-tracker.sh` — Step Graph (6 additions)

Add `tektonAddon` to the step definition arrays:

```bash
# STEP_TITLES — add:
["tektonAddon"]="Tekton addon setup"

# STEP_ORDER — insert after "tektonBundle":
"createBranches" "configureDownstream" "tektonComponents" "tektonBundle" "tektonAddon" ...

# YSTREAM_STEPS — add:
readonly YSTREAM_STEPS=("createBranches" "configureDownstream" "tektonComponents" "tektonBundle" "tektonAddon")

# STEP_DEPENDENCIES — add:
["tektonAddon"]="configureDownstream"

# AUTOMATION_LEVEL — add:
["tektonAddon"]="auto"

# STEP_SCRIPT — add:
["tektonAddon"]="scripts/addon-tekton-setup.sh"

# STEP_PHASE — add:
["tektonAddon"]="Branch Setup"

# STEP_DEPENDENCIES for upstreamRelease — append tektonAddon:
["upstreamRelease"]="cveFixes,ecFixes,rpmLockfiles,tektonTasks,versionLabels,tektonComponents,tektonBundle,tektonAddon"
```

### 2. `scripts/addon-tekton-setup.sh` — New Script (~100 lines)

Core logic:

```bash
#!/bin/bash
set -euo pipefail

# Args: VERSION (e.g., 0.24 or 0.24.0)
# Derives: ACM_VERSION=2.17, PREV_ACM=2.16, component numbers 217/216

ADDON_REPO="$HOME/go/src/stolostron/submariner-addon"

# 1. Derive versions
MAJOR_MINOR=$(echo "$1" | grep -oE '^[0-9]+\.[0-9]+')
NEW_MINOR=$(echo "$MAJOR_MINOR" | cut -d. -f2)
PREV_MINOR=$((NEW_MINOR - 1))
NEW_ACM="2.$((NEW_MINOR - 7))"
PREV_ACM="2.$((PREV_MINOR - 7))"
NEW_COMPONENT="${NEW_ACM//./}"      # "217"
PREV_COMPONENT="${PREV_ACM//./}"    # "216"

# 2. Validate
cd "$ADDON_REPO"
git fetch origin
# Verify release branches exist
git rev-parse --verify "origin/release-$NEW_ACM" >/dev/null
git rev-parse --verify "origin/release-$PREV_ACM" >/dev/null

# 3. Create working branch
BRANCH="addon-tekton-setup-${NEW_ACM}"
git checkout -b "$BRANCH" "origin/release-$NEW_ACM"

# 4. Copy .tekton/ from previous release
git checkout "origin/release-$PREV_ACM" -- .tekton/

# 5. Rename files
for f in .tekton/*; do
  new_name="${f/acm-$PREV_COMPONENT/acm-$NEW_COMPONENT}"
  [ "$f" != "$new_name" ] && mv "$f" "$new_name"
done

# 6. Update version references in all tekton files
sed -i \
  -e "s/release-$PREV_ACM/release-$NEW_ACM/g" \
  -e "s/acm-$PREV_COMPONENT/acm-$NEW_COMPONENT/g" \
  -e "s/release-acm-$PREV_COMPONENT/release-acm-$NEW_COMPONENT/g" \
  .tekton/*.yaml

# 7. Remove stale tekton files (only keep files for this version)
for f in .tekton/submariner-addon-acm-*; do
  case "$f" in
    *.tekton/submariner-addon-acm-${NEW_COMPONENT}-*) ;;  # keep
    *) rm -f "$f" ;;                                       # remove stale
  esac
done

# 8. Validate
for f in .tekton/submariner-addon-acm-${NEW_COMPONENT}-*.yaml; do
  grep -q "target_branch.*release-$NEW_ACM" "$f" || { echo "ERROR: $f missing target_branch"; exit 1; }
  grep -q "acm-$NEW_COMPONENT" "$f" || { echo "ERROR: $f missing component ref"; exit 1; }
done

# 9. Commit
git add .tekton/
git commit -s -m "Configure Tekton for release-$NEW_ACM

Copy working pipeline configs from release-$PREV_ACM and update for $NEW_ACM.
Remove stale tekton files from other versions."

# 10. Push and create PR
git push origin "$BRANCH"
gh pr create \
  --repo stolostron/submariner-addon \
  --base "release-$NEW_ACM" \
  --title "Configure Tekton for release-$NEW_ACM" \
  --body "$(cat <<EOF
## Summary
- Copy .tekton/ configs from release-$PREV_ACM
- Update version references ($PREV_ACM → $NEW_ACM)
- Remove stale tekton files from other versions

Ensures builds trigger from the release-$NEW_ACM branch (not main).
EOF
)"

# 11. Mark step complete (if tracker integration available)
```

### 3. `scripts/autorelease.sh` — Verifier Function

```bash
verify_tektonAddon() {
  local version="$1"
  local minor="${version%.*}"
  minor="${minor#*.}"
  local acm_version="2.$((minor - 7))"
  local component="${acm_version//./}"

  # Check release branch has tekton files with correct target_branch
  local push_content
  push_content=$(gh api \
    "repos/stolostron/submariner-addon/contents/.tekton/submariner-addon-acm-${component}-push.yaml?ref=release-${acm_version}" \
    --jq '.content' 2>/dev/null | base64 -d) || return 1
  echo "$push_content" | grep -q "target_branch.*\"release-${acm_version}\"" || return 1

  # Check no stale files for other versions
  local file_count
  file_count=$(gh api \
    "repos/stolostron/submariner-addon/contents/.tekton?ref=release-${acm_version}" \
    --jq 'length' 2>/dev/null) || return 1
  [ "$file_count" -eq 2 ]  # Should be exactly 2: push + pull-request
}
```

Add to the `STEP_VERIFIERS` map:

```bash
["tektonAddon"]="verify_tektonAddon"
```

### 4. `scripts/lib/jira-tracker.sh` — Tracker Subtask

Add to the Jira release tracker template so `/create-release-tracker` creates a
subtask for this step (same pattern as existing steps).

### 5. `.agents/workflows/fix-tekton-prs.md` — Documentation Update

Add a note that submariner-addon is now handled by the `tektonAddon` step:

```markdown
**Note:** submariner-addon (in `stolostron/`) is handled separately by Step 3c
(Tekton addon setup) via `scripts/addon-tekton-setup.sh`. It is NOT included in
the repos above.
```

### 6. `CLAUDE.md` — Add Step 3c

Insert after Step 3b:

```markdown
## 3c. Fix Tekton Config - Addon (Y-stream only)

Handled automatically by autorelease. Manual alternative:

**Alternative:** `make addon-tekton-setup VERSION=<version>`
```

### 7. `Makefile` — Add Target

```makefile
addon-tekton-setup:
  ./scripts/addon-tekton-setup.sh $(VERSION)
```

### 8. `submariner-addon` Repo — Clean Up Main Branch `.tekton/`

Separately from the release process changes, fix the current state:

**On `main`:** Remove `submariner-addon-acm-217-{push,pull-request}.yaml` (main
should not build 2.17 images). Keep only the in-development version files
(`acm-50`, `acm-51`, or whatever ACM manages via fast-forwarding).

**On `release-2.17`:** Remove stale `acm-50-*` and `acm-51-*` files. Update
`acm-217-*` files to use `target_branch == "release-2.17"`.

## Testing

1. Verify `tektonAddon` appears in `/release-ls` output for Y-stream releases
2. Verify `tektonAddon` is skipped for Z-stream releases
3. Verify the autorelease conductor runs the script after `configureDownstream`
4. Verify the verifier correctly detects:
   - Missing tekton files → fail
   - Wrong `target_branch` → fail
   - Stale files present → fail
   - Correct state → pass
5. Dry-run the script against a test version to confirm sed replacements

## Risks

- **Version formula breaks for ACM 5.x:** The `2.(minor-7)` formula only works
  for ACM 2.x. ACM 5.x branches are fast-forwarded from main and are managed by
  the ACM team, not our release cycle. The script should validate the derived ACM
  version is in the 2.x range and skip/error otherwise.
- **ACM team changes their process:** If the ACM team stops using
  fast-forwarding or changes how PaC provisions `.tekton/` files, the script may
  need adjustment. The verifier would catch this.
- **Repo access:** The script needs push access to `stolostron/submariner-addon`
  and `gh` CLI authentication. Same as existing scripts that push to
  `submariner-io/` repos.
