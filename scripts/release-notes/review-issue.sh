#!/bin/bash
# Review a single Jira issue for release notes inclusion
# Pre-fetches all evidence, then asks Claude to evaluate it
# Args: ISSUE_KEY VERSION STAGE_YAML
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 ISSUE_KEY VERSION STAGE_YAML" >&2
  exit 1
fi

ISSUE_KEY="$1"
VERSION="$2"
STAGE_YAML="$3"
VERSION_MAJOR_MINOR="${VERSION%.*}"
MINOR_VERSION="${VERSION_MAJOR_MINOR##*.}"
ACM_VERSION="ACM 2.$((MINOR_VERSION - 7)).0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE="$SCRIPT_DIR/review-prompt.md"

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
  echo "❌ ERROR: Prompt template not found: $PROMPT_TEMPLATE" >&2
  exit 1
fi

# ============================================================================
# Pre-fetch all evidence (deterministic, no LLM needed)
# ============================================================================

# Jira details (including comments — often contain PR/commit links)
JIRA_JSON=$(acli jira workitem view "$ISSUE_KEY" \
  --fields "summary,status,resolution,components,labels,fixVersions,issuelinks,description,comment" \
  --json </dev/null 2>/dev/null) || JIRA_JSON="{}"

SUMMARY=$(jq -r '.fields.summary // ""' <<< "$JIRA_JSON")
COMPONENTS=$(jq -r '[.fields.components[]?.name] | join(", ")' <<< "$JIRA_JSON")

# Extract keywords from summary + description (remove stopwords and noise)
DESCRIPTION=$(jq -r '[.fields.description | .. | .text? // empty] | join(" ")' <<< "$JIRA_JSON" 2>/dev/null) || DESCRIPTION=""
if [[ ${#DESCRIPTION} -lt 5 ]]; then
  for _retry in 1 2 3; do
    DESCRIPTION=$(acli jira workitem view "$ISSUE_KEY" --fields "description" --json </dev/null 2>/dev/null | \
      jq -r '[.fields.description | .. | .text? // empty] | join(" ")' 2>/dev/null) || DESCRIPTION=""
    [[ ${#DESCRIPTION} -ge 5 ]] && break
    sleep 1
  done
fi

# Strip Jira bug template sections from description before keyword extraction
DESCRIPTION=$(echo "$DESCRIPTION" | sed 's/How reproducible.*//' | sed 's/Steps to [Rr]eproduce.*//' | \
  sed 's/Actual results.*//' | sed 's/Expected results.*//' | sed 's/Additional info.*//')

STOPWORDS='.{0,2}|the|and|for|not|with|from|that|this|are|was|has|have|been|able|after|between|all|old|new|add|update|remove|review|ensure|create|issues|known|support|submariner|version|release|number|selected|component|applicable|problem|description|reproducible|steps|reproduce|actual|expected|additional|info|environment|cluster|clusters|managed|error|failed|following|getting|output|using|should|would|could|does|also'
STOPWORDS+='|pod|pods|node|nodes|service|services'
STOPWORDS+='|nil|string|true|false|func|return|type'
STOPWORDS+='|ocp|rhel|redhat|openshift'
STOPWORDS+='|workaround|restarting|editing|changing'

# Two-tier keyword extraction: summary keywords always included
SUMMARY_KWS=$(echo "$SUMMARY" | tr '[:upper:]' '[:lower:]' | \
  sed 's/[^a-z0-9 ]/ /g' | tr ' ' '\n' | \
  grep -vxE "$STOPWORDS" | \
  grep -vxE '[0-9a-f]{5,}' | \
  grep -vxE '[0-9]+' | \
  sort | uniq -c | sort -rn | awk '{print $2}' | head -5 || true)

DESC_KWS=$(echo "$SUMMARY $DESCRIPTION" | tr '[:upper:]' '[:lower:]' | \
  sed 's/[^a-z0-9 ]/ /g' | tr ' ' '\n' | \
  grep -vxE "$STOPWORDS" | \
  grep -vxE '[0-9a-f]{5,}' | \
  grep -vxE '[0-9]+' | \
  sort | uniq -c | sort -rn | awk '{print $2}' | head -15 || true)

# Merge: summary keywords first, then fill from description (deduplicated)
KEYWORDS="$SUMMARY_KWS"
for KW in $DESC_KWS; do
  echo "$KEYWORDS" | grep -qw "$KW" 2>/dev/null && continue
  KEYWORDS+=" $KW"
done
KEYWORDS=$(echo "$KEYWORDS" | tr ' ' '\n' | head -10 | tr '\n' ' ')

# Extract GitHub/PR links from Jira comments (often the best evidence source)
COMMENT_LINKS=$(jq -r '[.fields.comment.comments[]? | [.body | .. | .text? // empty] | join(" ")] | join(" ")' <<< "$JIRA_JSON" 2>/dev/null | \
  grep -oE "https://github\.com/[^ \"')>]+" | sort -u || echo "")

# GitHub PR search
GH_PRS_SUBMARINER=$(gh search prs "$ISSUE_KEY" --owner submariner-io --json title,url,repository --limit 5 2>/dev/null || echo "[]")
GH_PRS_STOLOSTRON=$(gh search prs "$ISSUE_KEY" --owner stolostron --json title,url,repository --limit 5 2>/dev/null || echo "[]")
GH_PRS_DOCS=$(gh search prs "$ISSUE_KEY" --repo stolostron/rhacm-docs --json title,url --limit 5 2>/dev/null || echo "[]")

# Search git commit messages for the issue key directly
ISSUE_KEY_COMMITS=""
for REPO in submariner submariner-operator lighthouse subctl shipyard cloud-prepare; do
  REPO_DIR="$HOME/go/src/submariner-io/$REPO"
  [[ -d "$REPO_DIR" ]] || continue
  RESULT=$(cd "$REPO_DIR" && git log "origin/release-${VERSION_MAJOR_MINOR}" --oneline -i --grep="$ISSUE_KEY" 2>/dev/null | head -3 || true)
  [[ -n "$RESULT" ]] && ISSUE_KEY_COMMITS+="$REPO: $RESULT
"
done

# DFBUGS link check — search issuelinks, description, and comments
# (developers often paste DFBUGS links in text without creating formal links)
ALL_TEXT=$(jq -r '([.fields.description | .. | .text? // empty] + [.fields.comment.comments[]? | .body | .. | .text? // empty]) | join(" ")' <<< "$JIRA_JSON" 2>/dev/null || echo "")
DFBUGS_KEY=$(jq -r '[.fields.issuelinks[]? | (.outwardIssue.key // .inwardIssue.key // "") | select(startswith("DFBUGS-"))] | first // ""' <<< "$JIRA_JSON")
if [[ -z "$DFBUGS_KEY" ]]; then
  # Check description and comments for DFBUGS references
  DFBUGS_KEY=$(echo "$ALL_TEXT" | grep -oE "DFBUGS-[0-9]+" | head -1 || true)
fi
DFBUGS_STATUS=""
if [[ -n "$DFBUGS_KEY" ]]; then
  DFBUGS_STATUS=$(acli jira workitem view "$DFBUGS_KEY" --fields "status" --json </dev/null 2>/dev/null | jq -r '.fields.status.name // ""' 2>/dev/null || echo "")
fi

# Git log search across repos (use keywords from summary)
GIT_EVIDENCE=""
for REPO in submariner submariner-operator lighthouse subctl shipyard cloud-prepare; do
  REPO_DIR="$HOME/go/src/submariner-io/$REPO"
  [[ -d "$REPO_DIR" ]] || continue

  HITS=""
  SEEN_SHAS=()
  # Skip noisy keywords (>15 hits in this repo); scan the rest for evidence
  NOISY_KWS=()
  for KW in $KEYWORDS; do
    HIT_COUNT=$(cd "$REPO_DIR" && git log "origin/release-${VERSION_MAJOR_MINOR}" --oneline -i --grep="$KW" 2>/dev/null | wc -l || true)
    if [[ "$HIT_COUNT" -gt 15 ]]; then
      NOISY_KWS+=("$KW")
      continue
    fi
    while IFS= read -r SHA; do
      [[ -z "$SHA" ]] && continue
      printf '%s\n' "${SEEN_SHAS[@]}" | grep -qx "$SHA" 2>/dev/null && continue
      SEEN_SHAS+=("$SHA")
      COMMIT_DETAIL=$(cd "$REPO_DIR" && git log -1 --format="%h %s%n%b" "$SHA" 2>/dev/null | head -8)
      # Skip dependency bumps and merge commits (noise)
      echo "$COMMIT_DETAIL" | head -1 | grep -qiE "^[0-9a-f]+ (Bump |Merge pull request)" && continue
      CHANGED_FILES=$(cd "$REPO_DIR" && git diff-tree --no-commit-id --name-only -r "$SHA" 2>/dev/null | head -5)
      HITS+="  keyword '$KW': $COMMIT_DETAIL
    files: $CHANGED_FILES
"
    done < <(cd "$REPO_DIR" && git log "origin/release-${VERSION_MAJOR_MINOR}" --format="%H" -i --grep="$KW" 2>/dev/null | head -3)
  done

  # Try combining noisy keyword pairs (--all-match) to narrow results
  if [[ ${#NOISY_KWS[@]} -ge 2 ]]; then
    KW1="${NOISY_KWS[0]}"
    for ((i=1; i < ${#NOISY_KWS[@]} && i <= 4; i++)); do
      KW2="${NOISY_KWS[$i]}"
      while IFS= read -r SHA; do
        [[ -z "$SHA" ]] && continue
        printf '%s\n' "${SEEN_SHAS[@]}" | grep -qx "$SHA" 2>/dev/null && continue
        SEEN_SHAS+=("$SHA")
        COMMIT_DETAIL=$(cd "$REPO_DIR" && git log -1 --format="%h %s%n%b" "$SHA" 2>/dev/null | head -8)
        echo "$COMMIT_DETAIL" | head -1 | grep -qiE "^[0-9a-f]+ (Bump |Merge pull request)" && continue
        CHANGED_FILES=$(cd "$REPO_DIR" && git diff-tree --no-commit-id --name-only -r "$SHA" 2>/dev/null | head -5)
        HITS+="  combined '$KW1'+'$KW2': $COMMIT_DETAIL
    files: $CHANGED_FILES
"
      done < <(cd "$REPO_DIR" && git log "origin/release-${VERSION_MAJOR_MINOR}" --format="%H" -i --grep="$KW1" --grep="$KW2" --all-match 2>/dev/null | head -3)
    done
  fi

  if [[ -n "$HITS" ]]; then
    GIT_EVIDENCE+="
$REPO (release-${VERSION_MAJOR_MINOR}):
$HITS"
  fi
done

# Cross-squad addon check (if multiple components)
ADDON_PRS="[]"
COMP_COUNT=$(jq '[.fields.components[]?.name] | length' <<< "$JIRA_JSON")
if [[ "$COMP_COUNT" -gt 1 ]]; then
  # Search addon repo by keywords
  for KW in $KEYWORDS; do
    RESULT=$(gh search prs "$KW" --repo stolostron/submariner-addon --json title,url --limit 3 2>/dev/null || echo "[]")
    if jq -e 'length > 0' <<< "$RESULT" >/dev/null 2>&1; then
      ADDON_PRS="$RESULT"
      break
    fi
  done
fi

# ============================================================================
# CVE-specific evidence (only for Security-labeled issues)
# ============================================================================

IS_CVE=$(jq -r '[.fields.labels[]? | select(test("^(Security|SecurityTracking|CVE-)"; "i"))] | length > 0' <<< "$JIRA_JSON" 2>/dev/null)
CVE_EVIDENCE=""

if [[ "$IS_CVE" == "true" ]]; then
  CVE_ID=$(jq -r '[.fields.labels[]? | select(startswith("CVE-"))] | first // ""' <<< "$JIRA_JSON")
  PSCOMPONENT=$(jq -r '[.fields.labels[]? | select(startswith("pscomponent:")) | sub("pscomponent:"; "")] | first // ""' <<< "$JIRA_JSON")

  # Map pscomponent to upstream repo
  TARGET_REPO=""
  case "$PSCOMPONENT" in
    *lighthouse-coredns*) TARGET_REPO="lighthouse" ;;
    *lighthouse-agent*) TARGET_REPO="lighthouse" ;;
    *submariner-rhel9-operator*|*submariner-operator*) TARGET_REPO="submariner-operator" ;;
    *submariner-route-agent*|*submariner-gateway*|*submariner-globalnet*) TARGET_REPO="submariner" ;;
    *subctl*) TARGET_REPO="subctl" ;;
    *nettest*) TARGET_REPO="shipyard" ;;
  esac

  GO_VERSION="" GRPC_VERSION="" COREDNS_VERSION=""
  GO_MOD_COMMITS="" COREDNS_MOD_COMMITS=""
  GHSA_COMMITS="" GHSA_DETAILS=""
  RPM_CHANGES="" BUILDER_IMAGE=""

  if [[ -n "$TARGET_REPO" ]]; then
    REPO_DIR="$HOME/go/src/submariner-io/$TARGET_REPO"
    if [[ -d "$REPO_DIR" ]]; then
      # Collect all go.mod files (main, tools/, coredns/) for dependency version checking
      GO_MOD=$(git -C "$REPO_DIR" show "origin/release-${VERSION_MAJOR_MINOR}:go.mod" 2>/dev/null || echo "")
      TOOLS_GO_MOD=$(git -C "$REPO_DIR" show "origin/release-${VERSION_MAJOR_MINOR}:tools/go.mod" 2>/dev/null || echo "")
      COREDNS_GO_MOD=$(git -C "$REPO_DIR" show "origin/release-${VERSION_MAJOR_MINOR}:coredns/go.mod" 2>/dev/null || echo "")
      ALL_GO_MODS=$(printf '%s\n%s\n%s' "$GO_MOD" "$TOOLS_GO_MOD" "$COREDNS_GO_MOD")

      # `|| true`: GO_MOD may be empty (fetch failed above), so grep finds no
      # "go " line and exits non-zero; under set -e/pipefail that would abort
      # the script. Siblings below already guard the same way.
      GO_VERSION=$(echo "$GO_MOD" | grep "^go " | awk '{print $2}' || true)
      GRPC_VERSION=$(echo "$ALL_GO_MODS" | grep "google.golang.org/grpc " | head -1 | awk '{print $2}' || true)
      COREDNS_VERSION=$(echo "$ALL_GO_MODS" | grep "github.com/coredns/coredns " | head -1 | awk '{print $2}' || true)

      GO_MOD_COMMITS=$(git -C "$REPO_DIR" log "origin/release-${VERSION_MAJOR_MINOR}" --oneline -- go.mod go.sum tools/go.mod tools/go.sum 2>/dev/null | head -5 || true)
      COREDNS_MOD_COMMITS=$(git -C "$REPO_DIR" log "origin/release-${VERSION_MAJOR_MINOR}" --oneline -- coredns/go.mod coredns/go.sum 2>/dev/null | head -5 || true)

      GHSA_COMMITS=$(git -C "$REPO_DIR" log "origin/release-${VERSION_MAJOR_MINOR}" --oneline --grep="GHSA-" 2>/dev/null | head -5 || true)

      # Resolve GHSA identifiers to summaries
      for GHSA in $(echo "$GHSA_COMMITS" | grep -oE "GHSA-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+" 2>/dev/null | sort -u); do
        INFO=$(gh api "/advisories/$GHSA" --jq '"\(.ghsa_id): \(.summary) | identifiers: \([.identifiers[] | .value] | join(", "))"' 2>/dev/null || echo "$GHSA: lookup failed")
        GHSA_DETAILS+="  $INFO
"
      done

      # OSV vulnerability database lookup — definitive "fixed or not" answer
      OSV_RESULT=""
      if [[ -n "$CVE_ID" && -n "$GO_VERSION" ]]; then
        # Check Go stdlib
        STDLIB_HIT=$(curl -sf https://api.osv.dev/v1/query \
          -d "{\"package\":{\"name\":\"stdlib\",\"ecosystem\":\"Go\"},\"version\":\"$GO_VERSION\"}" 2>/dev/null | \
          jq -r "[.vulns[]? | select(.aliases[]? == \"$CVE_ID\")] | length" 2>/dev/null || echo "")
        if [[ "$STDLIB_HIT" == "0" ]]; then
          OSV_RESULT="Go stdlib $GO_VERSION is NOT affected by $CVE_ID (fixed)"
        elif [[ -n "$STDLIB_HIT" ]]; then
          OSV_RESULT="Go stdlib $GO_VERSION is STILL AFFECTED by $CVE_ID"
        fi

        # Check specific Go dependencies if we have versions
        if [[ -z "$OSV_RESULT" || "$OSV_RESULT" == *"STILL AFFECTED"* ]]; then
          for DEP_PAIR in "google.golang.org/grpc:$GRPC_VERSION" "github.com/coredns/coredns:$COREDNS_VERSION"; do
            DEP_NAME="${DEP_PAIR%%:*}"
            DEP_VER="${DEP_PAIR##*:}"
            [[ -z "$DEP_VER" ]] && continue
            DEP_HIT=$(curl -sf https://api.osv.dev/v1/query \
              -d "{\"package\":{\"name\":\"$DEP_NAME\",\"ecosystem\":\"Go\"},\"version\":\"${DEP_VER#v}\"}" 2>/dev/null | \
              jq -r "[.vulns[]? | select(.aliases[]? == \"$CVE_ID\")] | length" 2>/dev/null || echo "")
            if [[ "$DEP_HIT" == "0" ]]; then
              OSV_RESULT="$DEP_NAME ${DEP_VER} is NOT affected by $CVE_ID (fixed)"
              break
            elif [[ -n "$DEP_HIT" ]]; then
              OSV_RESULT="$DEP_NAME ${DEP_VER} is STILL AFFECTED by $CVE_ID"
            fi
          done
        fi
      fi

      RPM_CHANGES=$(git -C "$REPO_DIR" log "origin/release-${VERSION_MAJOR_MINOR}" --oneline -- '.rpm-lockfiles/' 2>/dev/null | head -5 || true)

      BUILDER_IMAGE=""
      for DF in $(git -C "$REPO_DIR" ls-tree -r --name-only "origin/release-${VERSION_MAJOR_MINOR}" 2>/dev/null | grep -E "Dockerfile.*konflux" | head -5); do
        LINE=$(git -C "$REPO_DIR" show "origin/release-${VERSION_MAJOR_MINOR}:$DF" 2>/dev/null | grep -i "^FROM.*builder\|^FROM.*go-toolset\|^FROM.*golang" | head -1 || true)
        [[ -n "$LINE" ]] && BUILDER_IMAGE+="  $DF: $LINE
"
      done
    fi
  fi

  CVE_EVIDENCE="### CVE-Specific Evidence
CVE ID: ${CVE_ID:-not found in labels}
Affected component: ${PSCOMPONENT:-not found in labels}
Target repo: ${TARGET_REPO:-unknown}

Go toolchain version: ${GO_VERSION:-unknown}
$(if [[ -n "$GRPC_VERSION" ]]; then echo "gRPC version: $GRPC_VERSION"; fi)
$(if [[ -n "$COREDNS_VERSION" ]]; then echo "CoreDNS version: $COREDNS_VERSION"; fi)
$(if [[ -n "$OSV_RESULT" ]]; then echo "
OSV vulnerability check: $OSV_RESULT"; fi)

go.mod change history (release-${VERSION_MAJOR_MINOR}):
$(if [[ -n "$GO_MOD_COMMITS" ]]; then echo "$GO_MOD_COMMITS"; else echo "  No go.mod changes found"; fi)
$(if [[ -n "$COREDNS_MOD_COMMITS" ]]; then echo "coredns/go.mod changes:
$COREDNS_MOD_COMMITS"; fi)

GHSA-referenced commits:
$(if [[ -n "$GHSA_COMMITS" ]]; then echo "$GHSA_COMMITS"; else echo "  None found"; fi)
$(if [[ -n "$GHSA_DETAILS" ]]; then echo "GHSA details:
$GHSA_DETAILS"; fi)

RPM lockfile changes:
$(if [[ -n "$RPM_CHANGES" ]]; then echo "$RPM_CHANGES"; else echo "  None found"; fi)

Builder images:
$(if [[ -n "$BUILDER_IMAGE" ]]; then echo "$BUILDER_IMAGE"; else echo "  Not found"; fi)
"
fi

# ============================================================================
# Build prompt with pre-fetched evidence
# ============================================================================

# Export variables for envsubst
export ISSUE_KEY VERSION STAGE_YAML VERSION_MAJOR_MINOR ACM_VERSION

# Build the evidence block
EVIDENCE="## Pre-fetched Evidence for ${ISSUE_KEY}

### Jira Details
\`\`\`json
$(jq '{summary: .fields.summary, status: .fields.status.name, resolution: (.fields.resolution.name // "Unresolved"), components: [.fields.components[]?.name], labels: .fields.labels, fixVersions: [.fields.fixVersions[]?.name], links: [.fields.issuelinks[]? | {type: .type.name, key: (.outwardIssue.key // .inwardIssue.key), summary: (.outwardIssue.fields.summary // .inwardIssue.fields.summary // "")[:70]}], description_excerpt: ([.fields.description | .. | .text? // empty] | join(" ") | .[:500])}' <<< "$JIRA_JSON" 2>/dev/null)
\`\`\`

### DFBUGS Tracker
$(if [[ -n "$DFBUGS_KEY" ]]; then echo "Found: $DFBUGS_KEY — status: $DFBUGS_STATUS"; else echo "None found in issue links."; fi)

### GitHub Links from Jira Comments
$(if [[ -n "$COMMENT_LINKS" ]]; then echo "$COMMENT_LINKS"; else echo "None found."; fi)

### Git Commits (by issue key)
$(if [[ -n "$ISSUE_KEY_COMMITS" ]]; then echo "$ISSUE_KEY_COMMITS"; else echo "None found."; fi)

### GitHub PRs (by issue key)
submariner-io: $(jq -r 'if length == 0 then "none" else [.[] | "\(.repository.name): \(.title)"] | join("; ") end' <<< "$GH_PRS_SUBMARINER")
stolostron: $(jq -r 'if length == 0 then "none" else [.[] | "\(.repository.nameWithOwner // .repository.name): \(.title)"] | join("; ") end' <<< "$GH_PRS_STOLOSTRON")
rhacm-docs: $(jq -r 'if length == 0 then "none" else [.[] | .title] | join("; ") end' <<< "$GH_PRS_DOCS")

### Git History (keyword search on release-${VERSION_MAJOR_MINOR} branch)
$(if [[ -n "$GIT_EVIDENCE" ]]; then echo "$GIT_EVIDENCE"; else echo "No matching commits found for keywords: $KEYWORDS"; fi)

$(if [[ "$COMP_COUNT" -gt 1 ]]; then echo "### Cross-squad Addon Check
Components: $COMPONENTS (multi-component issue)
Addon PRs: $(jq -r 'if length == 0 then "none" else [.[] | .title] | join("; ") end' <<< "$ADDON_PRS")"; fi)

${CVE_EVIDENCE}
"

# Build full prompt
PROMPT_BASE=$(envsubst < "$PROMPT_TEMPLATE")
PROMPT="${PROMPT_BASE}

${EVIDENCE}"

# ============================================================================
# Invoke Claude to evaluate the evidence
# ============================================================================

OUTPUT=$(claude -p "$PROMPT" \
  --print \
  --model sonnet \
  --allowedTools "Bash" \
  --dangerously-skip-permissions \
  2>&1) || true

# The prompt contracts that the verdict is the LAST line beginning with KEEP or REMOVE
# (the reasoning above it may quote either word). Select that final verdict line, then
# branch on it — scanning every line for REMOVE would let a stray "Remove ..." in the
# reasoning trigger a false removal even when the real verdict is KEEP.
# Flexible matching: agent may indent or wrap the verdict in markdown (**REMOVE**).
# `|| true`: OUTPUT (from `claude -p ... || true` above) can be empty or verdict-less;
# grep then exits 1 and, under pipefail + set -e, would abort here — making the
# "output unclear, keeping by default" else branch below dead code.
VERDICT_LINE=$(echo "$OUTPUT" | grep -iE "^\*{0,2}(KEEP|REMOVE)" | tail -1 || true)

if echo "$VERDICT_LINE" | grep -qiE "^\*{0,2}REMOVE"; then
  REASON=$(echo "$VERDICT_LINE" | sed 's/^[*]*REMOVE:*[*]* *//')
  echo "  ✗ REMOVE $ISSUE_KEY - $REASON"

  # Execute removal deterministically (don't rely on agent running bash)
  # Strip markdown formatting from reason for clean commit messages
  CLEAN_REASON=$(echo "$REASON" | sed 's/\*//g' | sed 's/^[[:space:]]*//')
  yq eval -i "del(.spec.data.releaseNotes.issues.fixed[] | select(.id == \"$ISSUE_KEY\"))" "$STAGE_YAML"
  yq eval '.' "$STAGE_YAML" > /dev/null
  git add "$STAGE_YAML"
  git commit -s -m "Remove $ISSUE_KEY from ${VERSION} release notes

${CLEAN_REASON:0:78}" || true

elif echo "$VERDICT_LINE" | grep -qiE "^\*{0,2}KEEP"; then
  REASON=$(echo "$VERDICT_LINE" | sed 's/^[*]*KEEP:*[*]* *//')
  echo "  ✓ KEEP  $ISSUE_KEY - ${REASON:-issue passes review}"
else
  echo "  ? KEEP  $ISSUE_KEY - agent output unclear, keeping by default"
fi
