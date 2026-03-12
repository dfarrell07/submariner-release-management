# Skills

## /learn-release

Teaches Submariner release process

```bash
/learn-release overview
/learn-release step 5
```

## /release-ls

Checks release status

```bash
/release-ls 0.22.0
```

## /configure-downstream

Configure Konflux for new Submariner version (Y-stream releases)

```bash
/configure-downstream 0.23
/configure-downstream 0.23.0  # Extracts major.minor
```

## /add-team-member

Add user to Submariner Konflux team RBAC

```bash
/add-team-member alice maintainer
/add-team-member bob admin
/add-team-member charlie  # Defaults to contributor (read-only)
```

## /konflux-ci-fix

Diagnose and fix Konflux CI Enterprise Contract violations

```bash
# From release-management (use shortcuts):
/konflux-ci-fix operator              # Short form
/konflux-ci-fix lighthouse 0.21       # Short form with branch
/konflux-ci-fix PR-1234 subctl        # Short form with PR

# Or use full paths:
/konflux-ci-fix ~/go/src/submariner-io/submariner-operator

# From component repo:
/konflux-ci-fix                       # Current repo, current branch
/konflux-ci-fix 0.21                  # Current repo, specified branch
/konflux-ci-fix PR-1234               # Current repo, specific PR
```

**Shortcuts:** operator, submariner, lighthouse, shipyard, subctl

## /konflux-component-setup

Automate Konflux component setup on new release branches

Configures Tekton pipelines, Dockerfiles, RPM lockfiles, and hermetic builds for Submariner components.
Handles 8 components across 5 repos. Runs 12 automated setup steps and creates per-step commits for easy review.

```bash
# From release-management (use shortcuts):
/konflux-component-setup operator 0.23              # Setup operator
/konflux-component-setup submariner submariner-gateway 0.23  # Multi-component repo
/konflux-component-setup lighthouse lighthouse-agent 0.23    # Specify component

# From component repo (auto-detection):
/konflux-component-setup                            # Detect from branch
/konflux-component-setup 0.23                       # Specify version

# Use full paths:
/konflux-component-setup ~/go/src/submariner-io/subctl subctl 0.23
```

**Shortcuts:** operator, submariner, lighthouse, shipyard, subctl

**Supported components:**

- `submariner-operator` (operator repo)
- `submariner-gateway`, `submariner-globalnet`, `submariner-route-agent` (submariner repo)
- `lighthouse-agent`, `lighthouse-coredns` (lighthouse repo)
- `nettest` (shipyard repo)
- `subctl` (subctl repo)

**Requirements:**

- `/configure-downstream` must be complete (bot PR branches created)
- Previous release branch must exist (e.g., `release-0.22` when setting up 0.23)

**What it does:**

1. Checks out bot's PR branch (e.g., `konflux-submariner-operator-0-23`)
2. Runs 12 setup steps: yamllint, RPM lockfiles, Dockerfiles, hermetic builds, multi-platform, SBOM, task updates, file filters
3. Creates separate commits for each step
4. Validates YAML after each modification

**After running:** Review commits, validate YAML, push to remote, wait for build (~15-30 min)

## /bundle-image-update

Update bundle component image SHAs from Konflux snapshots

Automates extraction of component SHAs from passing Konflux snapshots, updates bundle config files,
regenerates bundle manifests, and verifies all SHAs match.

```bash
/bundle-image-update                              # Auto: latest snapshot, SHA-only
/bundle-image-update 0.21.2                       # Version bump to 0.21.2
/bundle-image-update --snapshot submariner-0-21-xxxxx  # Specific snapshot
```

**Requirements:**

- Must be in `submariner-operator` repository on release branch
- Must be logged into Konflux cluster
- Bash 4.0+ (for associative arrays)

**What it does:**

1. Queries Konflux for latest passing snapshot (or uses --snapshot arg)
2. Extracts 7 component SHAs (8 total with metrics-proxy duplicate)
3. Updates `config/manager/patches/related-images.deployment.config.yaml`
4. Runs `make bundle` to regenerate manifests
5. Updates Dockerfile labels (version bumps only)
6. Verifies all SHAs match snapshot
7. Creates single commit with all changes

**After running:** Review commit, push to remote, wait for bundle rebuild (~15-30 min)

## /konflux-bundle-setup

Automate Konflux bundle setup on new release branches

Configures Tekton pipelines for bundle builds including infrastructure, OLM annotations, hermetic builds, and multi-platform support.
Runs 14 automated setup steps and creates 6-9 commits for easy review.

```bash
# Can run from anywhere (auto-navigates to submariner-operator):
/konflux-bundle-setup              # Auto-detect version from branch
/konflux-bundle-setup 0.23         # Specify version explicitly
```

**Requirements:**

- `~/go/src/submariner-io/submariner-operator` repository must exist (auto-navigates if needed)
- `/configure-downstream` must be complete (bot PR branch created)
- Previous release branch must exist (e.g., `release-0.20`)

**What it does:**

1. Validates prerequisites (tools, repository state)
2. Detects version and checks out appropriate branch (bot PR or release)
3. Copies bundle infrastructure from previous release
4. Verifies infrastructure was copied correctly
5. Adds OLM annotations (7 feature annotations + subscription annotation)
6. Configures Tekton build parameters (hermetic, multi-platform, SBOM)
7. Updates file change filters (CEL expressions)
8. Updates task references to latest versions (affects all .tekton files)
9. Creates 6-9 commits with clear messages

**Note:** Bundle image SHAs are copied from previous release. Update them with bundle-sha-update workflow after component builds complete.

**After running:** Review commits, validate YAML (`make yamllint`), push to remote, wait for build (~15-30 min)

## /create-fbc-release

Create FBC releases for all OCP versions (stage or prod) with comprehensive verification

Automates Step 12 (FBC stage releases) and Step 17 (FBC prod releases) of the Submariner release workflow.

```bash
/create-fbc-release 0.22.1 --stage   # Create stage releases
/create-fbc-release 0.22.1 --prod    # Create prod releases
/create-fbc-release 0.22 --stage     # Auto-detects latest patch
/create-fbc-release 0.22             # Defaults to stage
```

**Alternative (make target):**

```bash
make create-fbc-releases VERSION=0.22.1              # Stage (default)
make create-fbc-releases VERSION=0.22.1 TYPE=prod    # Production
```

**Prerequisites:**

- `oc login` (required for snapshot queries)
- Step 10 complete (component stage release)
- Step 11 complete (FBC catalog updated)
- FBC snapshots rebuilt (~15-30 min after Step 11)

**What it does:**

1. Verifies GitHub catalog consistency (all 6 OCP versions have same bundle SHA)
2. Verifies FBC snapshots (push events, tests passed, bundle SHAs match)
3. Verifies component SHAs across 10 sources (operator repo → registry → FBC GitHub → 6 snapshots)
4. Generates 6 Release YAMLs (one per OCP version: 4-16 through 4-21)
5. Validates YAMLs with `make test-remote`
6. Automatically commits with descriptive message

**After running:**

1. Review commit: `git show`
2. Push: `git push origin $(git rev-parse --abbrev-ref HEAD)`
3. Apply releases: `make apply FILE=<yaml>` for each version
4. Monitor: `make watch NAME=<release-name>`

**To undo:** `git reset HEAD~1`

## Installation

### .claude/settings.json

```json
{
  "extraKnownMarketplaces": {
    "submariner-release": {
      "source": {
        "source": "github",
        "repo": "stolostron/submariner-release-management",
        "ref": "main"
      }
    }
  },
  "enabledPlugins": {
    "release-management@submariner-release": true
  }
}
```

### CLI

```bash
/plugin marketplace add submariner-release https://github.com/stolostron/submariner-release-management
/plugin install release-management@submariner-release
```
