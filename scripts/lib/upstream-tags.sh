#!/usr/bin/env bash
# Upstream release tag checks, shared by the conductor's upstreamRelease verifier
# (autorelease.sh) and the scripts that must not run before that step when invoked
# directly (bundle-image-update.sh, create-component-release.sh).

# Thin wrapper around `git ls-remote` with a hard 30-second timeout to prevent
# firewall-silent TCP drops from stalling the conductor indefinitely.  Tests
# override this function to inject mock output without touching the PATH.
_git_ls_remote() { timeout 30 git ls-remote "$@"; }

# Exit codes: 0 all tagged (evidence JSON on stdout), 1 tag missing, 2 check failed.
verify_upstreamRelease() {
  local version="$1"
  # Check only the 5 repos that receive v$VERSION tags per cut-upstream-release.md:
  # submariner-operator (checked separately in step 3 of the workflow), plus the 4
  # repos verified in step 4 of the workflow.  Excludes admiral and cloud-prepare
  # (library repos present in SUBMARINER_UPSTREAM_REPOS that do not produce
  # deliverable images) and submariner-charts (an installer/charts repo).
  local component_repos="submariner-operator submariner lighthouse shipyard subctl"
  local operator_sha=""
  for repo in $component_repos; do
    local ls_out sha ls_rc=0
    ls_out=$(_git_ls_remote --tags "https://github.com/submariner-io/$repo" "refs/tags/v$version" 2>/dev/null) || ls_rc=$?
    if [ "$ls_rc" -ne 0 ]; then
      echo "  ls-remote failed (exit $ls_rc) — network, rate-limit, or timeout issue for submariner-io/$repo" >&2
      return 2
    fi
    # Exact ref only: v0.25.0-rc1 or v0.25.0-m0 must not count as v0.25.0.
    sha=$(printf '%s\n' "$ls_out" | awk -v ref="refs/tags/v$version" '$2 == ref { print $1; exit }')
    if [ -z "$sha" ]; then
      echo "  v$version tag not found on submariner-io/$repo" >&2
      return 1
    fi
    [ "$repo" = "submariner-operator" ] && operator_sha="$sha"
  done
  jq -cn --arg tag "v$version" --arg sha "$operator_sha" '{tag:$tag,operatorSha:$sha}'
}

# Stop a step that needs v$VERSION unless the tag exists on all five repos, or the
# operator chose a pre-tag candidate with ALLOW_PRE_TAG_CANDIDATE=true. A failed
# check always stops, override or not: it proves nothing about the tag.
# Args: $1=version $2=step_key
# Returns: 0 to continue, 1 to stop. Never 2: the conductor reads a script's exit 2
# as "nothing to update".
require_upstream_tag() {
  local version="$1" step="$2" rc=0
  verify_upstreamRelease "$version" >/dev/null || rc=$?
  case "$rc" in
    0)
      echo "✓ v$version is on all five component repos"
      return 0
      ;;
    1) ;;
    *)
      echo "❌ ERROR: could not check for v$version on the component repos (see above)." >&2
      echo "   The step did not run. Check network and GitHub access, then re-run to retry." >&2
      return 1
      ;;
  esac

  if [ "${ALLOW_PRE_TAG_CANDIDATE:-}" != "true" ]; then
    echo "❌ ERROR: v$version is not on all five component repos (see above)." >&2
    echo "   Cut the upstream release first: .agents/workflows/cut-upstream-release.md" >&2
    echo "   For a deliberate pre-tag candidate, re-run with ALLOW_PRE_TAG_CANDIDATE=true." >&2
    return 1
  fi

  echo "⚠️  WARNING: continuing without v$version because ALLOW_PRE_TAG_CANDIDATE=true." >&2
  echo "   $step will use a pre-tag candidate. Do not ship it as the $version release." >&2
}

