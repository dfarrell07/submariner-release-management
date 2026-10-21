#!/bin/bash
# Keep component image metadata and compiled Go versions on the same release.
# Bundle versions belong to bundle-image-update.sh, alongside CSV generation.
[ -z "${_DOCKERFILE_VERSION_SOURCED:-}" ] || return 0
_DOCKERFILE_VERSION_SOURCED=1

# shellcheck disable=SC2034  # Component metadata is consumed by the callers.
declare -A COMPONENT_DOCKERFILES=(
  [submariner-operator]="package/Dockerfile.submariner-operator.konflux"
  [submariner]="package/Dockerfile.submariner-gateway.konflux package/Dockerfile.submariner-globalnet.konflux package/Dockerfile.submariner-route-agent.konflux"
  [lighthouse]="package/Dockerfile.lighthouse-agent.konflux package/Dockerfile.lighthouse-coredns.konflux"
  [shipyard]="package/Dockerfile.nettest.konflux"
  [subctl]="package/Dockerfile.subctl.konflux"
)
# shellcheck disable=SC2034
COMPONENT_VERSION_REPOS="submariner-operator submariner lighthouse shipyard subctl"
_COMPONENT_VERSION_ASSIGNMENT='-X[ =](main\.[vV]ersion|github\.com/submariner-io/[^[:space:]=]*[vV]ersion)='

# Args: Dockerfile contents, numeric version, whether it builds Go binaries.
component_version_matches() {
  local content="$1" version="$2" has_binary="$3" flags flag
  local assignment="$_COMPONENT_VERSION_ASSIGNMENT"
  grep -Eq "(^|[[:space:]])version=\"v${version//./\\.}\"" <<< "$content" || return 1
  if [ "$has_binary" = true ]; then
    flags=$(grep -Eo -- "${assignment}[^[:space:]\"\\\\]+" <<< "$content") || return 1
    while IFS= read -r flag; do
      [ "${flag##*=}" = "v$version" ] || return 1
    done <<< "$flags"
  fi
}

# Args: Dockerfile, numeric X.Y.Z version, whether the component builds Go binaries.
set_component_version() {
  local file="$1" version="$2" has_binary="$3"
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
  component_version_matches "$(cat "$file")" "$version" "$has_binary"
}
