# Skills

## /release-management:learn-release

Teaches Submariner release process

```bash
/release-management:learn-release overview
/release-management:learn-release step 5
```

## /release-management:release-ls

Checks release status

```bash
/release-management:release-ls 0.22.0
```

## /release-management:configure-downstream

Configure Konflux for new Submariner version (Y-stream releases)

```bash
/release-management:configure-downstream 0.23
/release-management:configure-downstream 0.23.0  # Extracts major.minor
make configure-downstream VERSION=0.23
```

## /release-management:add-fbc-ocp-version

Add FBC support for new OCP version in Konflux release data

```bash
/release-management:add-fbc-ocp-version 4.22 0.23
make add-fbc-ocp-version OCP_VERSION=4.22 MIN_SUB=0.23
```

**Requirements:** `konflux-release-data` repo at `~/konflux/konflux-release-data`, clean working tree on main

**What it does:**

1. Creates FBC overlay directory (8 YAML files)
2. Enables overlay in tenant config (7 auto-generated files)
3. Adds new application to FBC stage/prod RPAs
4. Prints Phase 2 instructions for submariner-operator-fbc

**After running:** Push branch, create GitLab MR, then handle bot PR per Phase 2 instructions

## /release-management:add-team-member

Add user to Submariner Konflux team RBAC

```bash
/release-management:add-team-member alice maintainer
/release-management:add-team-member bob admin
/release-management:add-team-member charlie  # Defaults to contributor (read-only)
```

## /release-management:konflux-ci-fix

Diagnose and fix Konflux CI Enterprise Contract violations

```bash
# From release-management (use shortcuts):
/release-management:konflux-ci-fix operator              # Short form
/release-management:konflux-ci-fix lighthouse 0.21       # Short form with branch
/release-management:konflux-ci-fix PR-1234 subctl        # Short form with PR

# Or use full paths:
/release-management:konflux-ci-fix ~/go/src/submariner-io/submariner-operator

# From component repo:
/release-management:konflux-ci-fix                       # Current repo, current branch
/release-management:konflux-ci-fix 0.21                  # Current repo, specified branch
/release-management:konflux-ci-fix PR-1234               # Current repo, specific PR
```

**Shortcuts:** operator, submariner, lighthouse, shipyard, subctl

## /release-management:konflux-component-setup

Automate Konflux component setup on new release branches

Configures Tekton pipelines, Dockerfiles, RPM lockfiles, and hermetic builds for Submariner components.
Handles 8 components across 5 repos. Runs 12 automated setup steps and creates per-step commits for easy review.

```bash
# From release-management (use shortcuts):
/release-management:konflux-component-setup operator 0.23
/release-management:konflux-component-setup submariner submariner-gateway 0.23
/release-management:konflux-component-setup lighthouse lighthouse-agent 0.23

# From component repo (auto-detection):
/release-management:konflux-component-setup        # Detect from branch
/release-management:konflux-component-setup 0.23   # Specify version

# Use full paths:
/release-management:konflux-component-setup ~/go/src/submariner-io/subctl subctl 0.23
```

**Shortcuts:** operator, submariner, lighthouse, shipyard, subctl

**Alternative (make target):**

```bash
make konflux-component-setup REPO=operator VERSION=0.23
make konflux-component-setup REPO=submariner COMPONENT=submariner-gateway VERSION=0.23
```

**Supported components:**

- `submariner-operator` (operator repo)
- `submariner-gateway`, `submariner-globalnet`, `submariner-route-agent` (submariner repo)
- `lighthouse-agent`, `lighthouse-coredns` (lighthouse repo)
- `nettest` (shipyard repo)
- `subctl` (subctl repo)

**Requirements:**

- `/release-management:configure-downstream` must be complete (bot PR branches created)
- Previous release branch must exist (e.g., `release-0.22` when setting up 0.23)

**What it does:**

1. Checks out bot's PR branch (e.g., `konflux-submariner-operator-0-23`)
2. Runs 12 setup steps: yamllint, RPM lockfiles, Dockerfiles, hermetic builds, multi-platform, SBOM, task updates, file filters
3. Creates separate commits for each step
4. Validates YAML after each modification

**After running:** Review commits, validate YAML, push to remote, wait for build (~15-30 min)

## /release-management:bundle-image-update

Update bundle component image SHAs from Konflux snapshots

Automates extraction of component SHAs from passing Konflux snapshots, updates bundle config files,
regenerates bundle manifests, and verifies all SHAs match.

```bash
/release-management:bundle-image-update                              # Auto: latest snapshot, SHA-only
/release-management:bundle-image-update 0.21.2                       # Version bump to 0.21.2
/release-management:bundle-image-update --snapshot submariner-0-21-xxxxx  # Specific snapshot
```

**Alternative (make target):**

```bash
make bundle-image-update                                # Auto-detect from branch
make bundle-image-update VERSION=0.21.2                 # Version bump
make bundle-image-update VERSION=0.21.2 SNAPSHOT=submariner-0-21-xxxxx
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

## /release-management:add-release-notes

Add release notes from Jira to stage YAML

Queries Jira, filters, auto-applies, commits.

```bash
make add-release-notes VERSION=0.22.1              # Auto-find latest stage YAML
make add-release-notes VERSION=0.22.1 STAGE_YAML=path/to/file.yaml
```

**Requirements:**

- acli authenticated: `acli jira auth login --token` (create token at <https://id.atlassian.com/manage-profile/security/api-tokens>)
- Step 8 complete (stage YAML exists)

**What it does:**

1. Queries Jira, scans prod for existing
2. Filters (excludes published, invalid resolutions; keeps Unresolved)
3. Z-stream: also filters by date
4. Auto-applies, validates, commits

**After running:** Review (`git show`), amend, push

## /release-management:rpm-lockfile-update

Regenerates RPM lockfiles in submariner and shipyard repositories by creating fix branches, running hermetic builds,
and committing updated lockfiles.

```bash
/release-management:rpm-lockfile-update                             # Auto-detect branch, all repos
/release-management:rpm-lockfile-update 0.21                        # Explicit branch, all repos
/release-management:rpm-lockfile-update gateway                     # Auto-detect branch, gateway only
/release-management:rpm-lockfile-update 0.21 submariner             # Explicit branch, repo filter
make rpm-lockfile-update                         # Auto-detect branch
make rpm-lockfile-update COMPONENT=gateway       # Auto-detect, component filter
make rpm-lockfile-update BRANCH=0.21 COMPONENT=gateway  # Explicit branch
```

**Filter options:** all, submariner, shipyard, gateway, globalnet, route-agent, nettest

**Requirements:** Red Hat entitlements, `podman login registry.redhat.io`, `gh auth login`, Bash 4.0+

**After running:** Review commits, push to remote, create PRs per repo

## /release-management:konflux-bundle-setup

Automate Konflux bundle setup on new release branches

Configures Tekton pipelines for bundle builds including infrastructure, OLM annotations, hermetic builds, and multi-platform support.
Runs 14 automated setup steps and creates 6-9 commits for easy review.

```bash
# Can run from anywhere (auto-navigates to submariner-operator):
/release-management:konflux-bundle-setup              # Auto-detect version from branch
/release-management:konflux-bundle-setup 0.23         # Specify version explicitly
```

**Alternative (make target):**

```bash
make konflux-bundle-setup VERSION=0.23
```

**Requirements:**

- `~/go/src/submariner-io/submariner-operator` repository must exist (auto-navigates if needed)
- `/release-management:configure-downstream` must be complete (bot PR branch created)
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

## /release-management:get-fbc-urls

Get FBC catalog URLs for QE sharing (Release CRs, snapshots, or prod index)

```bash
/release-management:get-fbc-urls 0.24.0                    # All OCP versions
/release-management:get-fbc-urls 0.24.0 --ocp 4.21         # Single OCP version
/release-management:get-fbc-urls 0.24.0 --raw-url          # URLs only (for automation)
/release-management:get-fbc-urls 0.24.0 --prod-index       # Prod operator index URLs
make get-fbc-urls VERSION=0.24.0        # Via make target
make get-fbc-urls VERSION=0.24.0 PROD_INDEX=true
```

## /release-management:create-fbc-release

Create FBC releases for all OCP versions (stage or prod) with comprehensive verification

Automates Step 12 (FBC stage releases) and Step 17 (FBC prod releases) of the Submariner release workflow.

```bash
/release-management:create-fbc-release 0.22.1 stage  # Create stage releases
/release-management:create-fbc-release 0.22.1 prod   # Create prod releases
/release-management:create-fbc-release 0.22 stage    # Expands to 0.22.0
/release-management:create-fbc-release 0.22          # Defaults to stage
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

## /release-management:create-component-release

Create component release (stage or prod) with comprehensive verification

Automates Step 8 (stage) and Step 15 (prod) of the Submariner release workflow.

```bash
/release-management:create-component-release 0.22.1          # Stage (default)
/release-management:create-component-release 0.22.1 stage    # Stage (explicit)
/release-management:create-component-release 0.22.1 prod     # Prod (copies stage)
/release-management:create-component-release 0.22            # Auto-expands to 0.22.0
```

**Alternative (make target):**

```bash
make create-component-release VERSION=0.22.1              # Stage (default)
make create-component-release VERSION=0.22.1 TYPE=prod    # Production
```

**Prerequisites:**

- oc login (required for snapshot queries)
- **For stage:** Step 7 complete (bundle SHAs updated)
- **For prod:** Stage YAML exists with release notes (Steps 8-9 complete)

**What it does:**

1. Verifies latest component snapshot (push event, tests passed, 9 components)
2. Generates Release YAML (stage or prod mode)
3. Validates with make test-remote
4. Commits automatically

**After running:**

- **Stage:** Fill notes placeholder via Step 9 workflow, then apply
- **Prod:** Apply immediately (notes copied from stage)

1. Review commit: `git show`
2. Push: `git push origin $(git rev-parse --abbrev-ref HEAD)`
3. Apply: `make apply FILE=<yaml>`
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
