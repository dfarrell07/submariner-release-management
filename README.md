# Submariner Release Management

Submariner release orchestration via Konflux.

## Usage

```bash
# Login to cluster
oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/

# Show available commands
make

# Configure downstream for new Y-stream version
make configure-downstream VERSION=0.24

# Create component release (requires cluster login)
make create-component-release VERSION=0.22.1              # Stage (default)
make create-component-release VERSION=0.22.1 TYPE=prod    # Production

# Create FBC releases (requires cluster login)
make create-fbc-releases VERSION=0.22.1              # Stage (default)
make create-fbc-releases VERSION=0.22.1 TYPE=prod    # Production

# Setup Konflux CI/CD for component on new release branch
make konflux-component-setup REPO=operator VERSION=0.24
make konflux-component-setup REPO=submariner COMPONENT=submariner-gateway VERSION=0.24

# Setup Konflux CI/CD for bundle on new release branch
make konflux-bundle-setup VERSION=0.24

# Update bundle component image SHAs from Konflux snapshots
make bundle-image-update                              # Auto-detect from branch
make bundle-image-update VERSION=0.21.2               # Version bump
make bundle-image-update VERSION=0.21.2 SNAPSHOT=submariner-0-21-xxxxx

# Update RPM lockfiles (requires entitlements, registry auth)
make rpm-lockfile-update                         # Auto-detect branch
make rpm-lockfile-update BRANCH=0.21             # Specify branch
make rpm-lockfile-update COMPONENT=gateway       # Filter by component

# Validate locally (no cluster access needed)
make test

# Validate with cluster checks and CVE verification (requires cluster login)
make test-remote FILE=releases/0.22/stage/submariner-0-22-1-stage-20260319-01.yaml

# Apply release (requires cluster login)
make apply FILE=releases/0.20/stage/submariner-0-20-2-stage-20250930-01.yaml

# Watch release (requires cluster login)
make watch NAME=submariner-0-20-2-stage-20250930-01

# Add release notes to stage release (requires acli authentication)
make add-release-notes VERSION=0.22.1                          # Auto-find latest stage YAML
make add-release-notes VERSION=0.22.1 STAGE_YAML=...           # Use specific YAML
make review-release-notes VERSION=0.22.1                       # Per-issue agent review

# Get FBC catalog URLs for QE sharing (requires cluster login or skopeo)
make get-fbc-urls VERSION=0.24.0                          # All OCP versions
make get-fbc-urls VERSION=0.24.0 OCP=4.21                 # Single OCP version
make get-fbc-urls VERSION=0.24.0 OCP=4.21 RAW_URL=true    # quay URL only
make get-fbc-urls VERSION=0.24.0 PROD_INDEX=true           # Prod operator index URLs

# Verify CVE fixes via Clair reports (requires oc login, auto-runs in add-release-notes)
make verify-cve-fixes STAGE_YAML=releases/0.22/stage/submariner-0-22-1-stage-20260319-01.yaml

# Setup acli (one-time)
# Create API token at: https://id.atlassian.com/manage-profile/security/api-tokens
acli jira auth login --token
acli jira auth status
```

## Claude Skills

```bash
/plugin marketplace add submariner-release https://github.com/stolostron/submariner-release-management
/plugin install release-management@submariner-release
```

| Command                     | Purpose                                        |
|-----------------------------|------------------------------------------------|
| `/learn-release`            | Learn 20-step release workflow                 |
| `/release-ls`               | Check release status                           |
| `/configure-downstream`     | Create Konflux app for new version             |
| `/add-fbc-ocp-version`      | Add FBC support for new OCP version            |
| `/add-team-member`          | Add user to Submariner Konflux RBAC            |
| `/konflux-ci-fix`           | Fix Konflux CI Enterprise Contract issues      |
| `/konflux-component-setup`  | Automate Konflux component setup on new branch |
| `/bundle-image-update`      | Update bundle image SHAs from snapshots        |
| `/add-release-notes`        | Add release notes from Jira, per-issue review  |
| `/rpm-lockfile-update`      | Update RPM lockfiles across repos              |
| `/konflux-bundle-setup`     | Automate Konflux bundle setup on new branch    |
| `/create-component-release` | Create component release (stage or prod)       |
| `/create-fbc-release`       | Create FBC releases for all OCP versions       |
| `/get-fbc-urls`             | Get FBC catalog URLs for QE sharing            |

See [.claude/SKILLS.md](.claude/SKILLS.md).

## Codex Skills

Codex discovers repository skills through the relative `.agents/skills` symlink
to `skills/`; no separate installation or skill copy is needed. Type `$` to select
a skill, for example `$release-management:autorelease 0.25.1` or
`$release-management:release-ls 0.25.1`. Use the displayed name if your client omits
the plugin prefix. The skill files and release scripts are shared with Claude.

Start Codex at this checkout (or open a new session after updating it).
Follow [AGENTS.md](AGENTS.md) for explicit argument binding in legacy examples.
The link enables discovery; it does not change release-script behavior.
In particular, normal `autorelease` execution writes to Jira and can push branches,
create PRs, and enable PR auto-merge. It requires explicit authorization for those
actions. Use `--dry-run` to preview.
