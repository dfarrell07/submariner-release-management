# Add Release Notes

**When:** After creating stage release (Step 8)

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

## Process

Automated workflow: query Jira, filter, auto-apply, verify CVEs,
then per-issue agent review.

**Submariner ↔ ACM:** 0.X → 2.(X-7) (e.g., 0.20 → 2.13, 0.21 → 2.14)

### Prerequisites

```bash
# One-time setup
# Create API token at: https://id.atlassian.com/manage-profile/security/api-tokens
acli jira auth login --token
acli jira auth status  # Verify authenticated
```

### Run

```bash
# Option A: Two separate steps
make add-release-notes VERSION=0.22.1         # Phases 1-4
make review-release-notes VERSION=0.22.1      # Phase 5

# Option B: Skill runs both
/add-release-notes 0.22.1
```

### How it works

**Phase 1 - Collect** (`scripts/release-notes/collect.sh`):

- Queries Jira with both ACM and Submariner version formats
- Scans `releases/0.X/prod/*.yaml` for existing issues
- Z-stream: gets last publish date from registry.redhat.io
- Filters deterministically: component (Multicluster Networking/Documentation only),
  addon labels, process tasks (Branch Cut, Support Matrices, Doc audit),
  untouched issues (New/Backlog + unresolved + no links/PRs)
- Outputs `/tmp/release-notes-data.json`

**Phase 2 - Filter** (`scripts/release-notes/prepare.sh`):

- Excludes published, invalid resolutions; keeps Unresolved
- Z-stream: excludes issues resolved before last publish date
- Groups CVEs, recommends release type (RHSA if CVEs, else RHBA)
- Outputs `/tmp/release-notes-topics.json`

**Phase 3 - Auto-apply** (`scripts/release-notes/auto-apply.sh`):

- Applies ALL filtered issues to stage YAML
- Validates, commits

**Phase 4 - Verify CVEs** (`scripts/release-notes/verify-cve-fixes.sh`):

- Only runs if CVEs present
- Verifies CVEs absent in snapshot Clair reports

**Phase 5 - Per-issue review** (`scripts/release-notes/review.sh`):

- Pre-fetches evidence per issue: Jira details + comments, DFBUGS
  status, GitHub PRs, git log keyword search across repos
- Spawns one Claude agent per non-CVE issue to evaluate evidence
- Default is KEEP; only removes for cross-squad addon-only fixes
  or issues clearly not about Submariner
- Each removal is a separate commit, revertable with `git revert`

### After running

```bash
git log --oneline           # Review all commits
git revert <hash>           # Revert any incorrect removal
git push
```

### Component mapping

CVE `pscomponent:` labels → Konflux component names:

- `rhacm2/lighthouse-coredns-rhel9` → `lighthouse-coredns-0-X`
- `rhacm2/submariner-gateway-rhel9` → `submariner-gateway-0-X`
- `rhacm2/submariner-addon-rhel9` → **EXCLUDED** (built separately in ACM/MCE)

See `map_component_name()` in `scripts/lib/release-notes-common.sh` for full mapping.

## Done When

Stage YAML committed with release notes, per-issue review complete.

```bash
git log --oneline -1 | grep "release notes"
```
