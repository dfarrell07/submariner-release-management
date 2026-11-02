#!/usr/bin/env bash
# Keep component image metadata and compiled Go versions on the same release.
# Bundle versions belong to bundle-image-update.sh, alongside CSV generation.
[ -z "${_DOCKERFILE_VERSION_SOURCED:-}" ] || return 0
_DOCKERFILE_VERSION_SOURCED=1

# shellcheck disable=SC2034  # Component metadata is consumed by the callers.
declare -gA COMPONENT_DOCKERFILES=(
  [submariner-operator]="package/Dockerfile.submariner-operator.konflux"
  [submariner]="package/Dockerfile.submariner-gateway.konflux package/Dockerfile.submariner-globalnet.konflux package/Dockerfile.submariner-route-agent.konflux"
  [lighthouse]="package/Dockerfile.lighthouse-agent.konflux package/Dockerfile.lighthouse-coredns.konflux"
  [shipyard]="package/Dockerfile.nettest.konflux"
  [subctl]="package/Dockerfile.subctl.konflux"
)
# shellcheck disable=SC2034
COMPONENT_VERSION_REPOS="submariner-operator submariner lighthouse shipyard subctl"
_COMPONENT_VERSION_ASSIGNMENT='-X[ =](main\.[vV]ersion|github\.com/submariner-io/[^[:space:]=]*[vV]ersion)='

# Only nettest (shipyard) builds no Go binary. Args: Dockerfile path.
_component_has_binary() { [[ "${1##*/}" != Dockerfile.nettest* ]]; }

# Print each compiled version; fails when there are none. Args: Dockerfile contents.
_component_compiled_versions() {
  grep -Eo -- "${_COMPONENT_VERSION_ASSIGNMENT}[^[:space:]\"\\\\]+" <<< "$1" | sed 's/.*=//' | grep .
}

# Args: Dockerfile contents, numeric version.
component_label_matches() {
  grep -Eq "(^|[[:space:]])version=\"v${2//./\\.}\"" <<< "$1"
}

# True when a compiled version is a literal other than this release. Older branches
# use ${BASE_BRANCH} until their next version update, which isn't stale.
# Args: Dockerfile contents, numeric version.
component_compiled_version_stale() {
  local values
  # shellcheck disable=SC2016  # the literal Dockerfile variable reference
  values=$(_component_compiled_versions "$1") && grep -qvxF -e "v$2" -e '${BASE_BRANCH}' <<< "$values"
}

# Strict: the label and every compiled version must be this release.
# Args: Dockerfile, numeric version.
component_version_matches() {
  local content values
  content=$(cat "$1") && component_label_matches "$content" "$2" || return 1
  _component_has_binary "$1" || return 0
  values=$(_component_compiled_versions "$content") && ! grep -qvxF "v$2" <<< "$values"
}

# Args: Dockerfile, numeric X.Y.Z version.
set_component_version() {
  local file="$1" version="$2" has_binary=false
  _component_has_binary "$file" && has_binary=true
  local label='(^|[[:space:]])version="(v[0-9]+(\.[0-9]+){2}|\$\{BASE_BRANCH\})"'
  local assignment="$_COMPONENT_VERSION_ASSIGNMENT"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  grep -Eq "$label" "$file" || {
    echo "Missing component version label in $file" >&2
    return 1
  }
  if [ "$has_binary" = true ] && ! grep -Eq -- "$assignment" "$file"; then
    echo "Missing Go version linker assignments in $file" >&2
    return 1
  fi

  sed -E -i "s#$label#\1version=\"v$version\"#g" "$file" || return 1
  if [ "$has_binary" = true ]; then
    # Literal versions cannot be overridden by a pipeline's BASE_BRANCH argument.
    sed -E -i "s#($assignment)[^[:space:]\"\\\\]+#\1v$version#g" "$file" || return 1
  fi
  component_version_matches "$file" "$version"
}

# Args: repo, Dockerfile path, git ref, numeric version.
# Returns 0 on a match, 1 on a mismatch, 2 if unreadable.
_component_version_at_ref() {
  local repo="$1" file="$2" ref="$3" version="$4" content
  content=$(gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/submariner-io/$repo/contents/$file?ref=$ref") || return 2
  # Older branches compile ${BASE_BRANCH} until their next version update; only a
  # wrong label or a stale literal (as release-0.25 inherited) is a mismatch.
  if ! component_label_matches "$content" "$version" || \
     { _component_has_binary "$file" && component_compiled_version_stale "$content" "$version"; }; then
    echo "  Image/compiled version mismatch: $repo/$file at $ref" >&2
    return 1
  fi
}

# List the repos whose release branch Dockerfiles don't match, one per line.
# Args: numeric X.Y.Z version. Returns 2 if a Dockerfile is unreadable.
stale_release_component_repos() {
  local version="$1" repo file rc
  for repo in $COMPONENT_VERSION_REPOS; do
    for file in ${COMPONENT_DOCKERFILES[$repo]}; do
      rc=0
      _component_version_at_ref "$repo" "$file" "release-${version%.*}" "$version" || rc=$?
      [ "$rc" -ne 2 ] || return 2
      [ "$rc" -eq 0 ] || { echo "$repo"; break; }
    done
  done
}

# Check the Dockerfiles each snapshot component was actually built from. A matching
# branch head proves nothing about an image built before the fix merged.
# Args: numeric X.Y.Z version, Snapshot JSON. Same return codes as above.
verify_snapshot_component_versions() {
  local version="$1" snapshot_json="$2" stream repo file component revision
  stream="${version%.*}"
  for repo in $COMPONENT_VERSION_REPOS; do
    for file in ${COMPONENT_DOCKERFILES[$repo]}; do
      component="${file##*Dockerfile.}"
      component="${component%.konflux}-${stream//./-}"
      revision=$(jq -r --arg name "$component" \
        '.spec.components[]? | select(.name == $name) | .source.git.revision // empty' \
        <<< "$snapshot_json") || return 2
      if [ -z "$revision" ]; then
        echo "  No source revision for $component in snapshot" >&2
        return 2
      fi
      _component_version_at_ref "$repo" "$file" "$revision" "$version" || return $?
    done
  done
}
