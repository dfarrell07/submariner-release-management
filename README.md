# Submariner Release Management

Submariner release orchestration via Konflux.

## Usage

```bash
# Login to cluster
oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/

# Show available commands
make

# Create FBC releases (requires cluster login)
make create-fbc-releases VERSION=0.22.1              # Stage (default)
make create-fbc-releases VERSION=0.22.1 TYPE=prod    # Production

# Validate locally (no cluster access needed)
make test

# Validate with cluster checks (requires cluster login)
make test-remote

# Apply release (requires cluster login)
make apply FILE=releases/0.20/stage/submariner-0-20-2-stage-20250930-01.yaml

# Watch release (requires cluster login)
make watch NAME=submariner-0-20-2-stage-20250930-01
```

## Claude Skills

```bash
/plugin marketplace add submariner-release https://github.com/stolostron/submariner-release-management
/plugin install release-management@submariner-release
```

| Command                    | Purpose                                        |
|----------------------------|------------------------------------------------|
| `/learn-release`           | Learn 20-step release workflow                 |
| `/release-ls`              | Check release status                           |
| `/configure-downstream`    | Create Konflux app for new version             |
| `/add-team-member`         | Add user to Submariner Konflux RBAC            |
| `/konflux-ci-fix`          | Fix Konflux CI Enterprise Contract issues      |
| `/konflux-component-setup` | Automate Konflux component setup on new branch |
| `/bundle-image-update`     | Update bundle image SHAs from snapshots        |
| `/konflux-bundle-setup`    | Automate Konflux bundle setup on new branch    |
| `/create-fbc-release`      | Create FBC releases for all OCP versions       |

See [.claude/SKILLS.md](.claude/SKILLS.md).
