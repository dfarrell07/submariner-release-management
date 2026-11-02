#!/usr/bin/env bash
# Refresh digest-pinned registry.redhat.io base images in Konflux Dockerfiles.
#
# Hermetic builds only update what the RPM lockfile lists, so every other package
# stays at the pinned base's versions until the pin moves. Run in the repo root.
# Sourced before the macOS VM re-exec, so it must at least parse under bash 3.2.

PINNED_BASE_ARCHES="amd64 arm64 s390x ppc64le"
# FROM [--flag ...] registry.redhat.io/<repo>@sha256:<digest> [AS name]
# A tag-and-digest pin (<repo>:9.6@sha256:...) deliberately does not match: that pin
# chose a tag, and moving it to :latest would change what it follows.
PINNED_BASE_FROM_RE='^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(--[^[:space:]]+[[:space:]]+)*registry\.redhat\.io/([a-z0-9._/-]+)@sha256:([0-9a-f]{64})([[:space:]]|$)'

# Result of pinned_base_refresh.
PINNED_BASE_CHANGED=()

# pinned_base_resolve REPO: print the digest of registry.redhat.io/REPO:latest.
# Returns 1 if skopeo or jq fails, the digest is malformed or it is not a multi-arch
# index with every architecture we build.
pinned_base_resolve() {
  local image="registry.redhat.io/$1" json digest raw missing
  # The file setup-entitlements logs in to and check_prerequisites verifies. skopeo
  # would otherwise try other auth files first, which may hold stale credentials.
  local -a auth=()
  [ ! -s "$HOME/.docker/config.json" ] || auth=(--authfile "$HOME/.docker/config.json")

  json=$(skopeo inspect --no-tags ${auth[@]+"${auth[@]}"} "docker://$image:latest") || {
    echo "skopeo could not inspect $image:latest" >&2
    return 1
  }
  digest=$(printf '%s' "$json" | jq -r '.Digest // empty') || {
    echo "Could not parse skopeo output for $image:latest" >&2
    return 1
  }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Malformed digest for $image:latest: '$digest'" >&2
    return 1
  }
  # Inspect the digest itself, not the tag, which may have moved since the call above
  raw=$(skopeo inspect --raw ${auth[@]+"${auth[@]}"} "docker://$image@$digest") || {
    echo "skopeo could not inspect $image@$digest" >&2
    return 1
  }
  missing=$(printf '%s' "$raw" | jq -r --arg want "$PINNED_BASE_ARCHES" \
    '($want | split(" ")) - [.manifests[]? | select(.platform.os == "linux") | .platform.architecture] | join(" ")') || {
    echo "$image@$digest is not a readable image index" >&2
    return 1
  }
  [ -z "$missing" ] || {
    echo "$image@$digest is not a multi-arch index for $PINNED_BASE_ARCHES (missing: $missing)" >&2
    return 1
  }
  printf '%s\n' "$digest"
}

# pinned_base_refresh FILTER: point each pin in the in-scope package/Dockerfile*.konflux
# at its repo's current :latest digest. FILTER is a component name for only that
# component's Dockerfile; anything else means all of them. Everything is resolved before
# anything is written, so on failure (return 1) no Dockerfile has changed. On success
# PINNED_BASE_CHANGED lists the rewritten files.
pinned_base_refresh() {
  local filter="$1" file line n pin repo old new
  local -a pins=() resolved=()
  PINNED_BASE_CHANGED=()

  for file in package/Dockerfile*.konflux; do
    [ -f "$file" ] || continue
    case "$filter" in
      gateway|globalnet|route-agent|nettest)
        case "$file" in
          "package/Dockerfile.$filter.konflux"|"package/Dockerfile.submariner-$filter.konflux") ;;
          *) continue ;;
        esac
        ;;
    esac
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      if [[ "$line" =~ $PINNED_BASE_FROM_RE ]]; then
        pins+=("$file $n ${BASH_REMATCH[2]} sha256:${BASH_REMATCH[3]}")
      fi
    done < "$file"
  done
  [ "${#pins[@]}" -gt 0 ] || return 0

  echo "Refreshing pinned base images:"
  for pin in "${pins[@]}"; do
    read -r file n repo old <<< "$pin"
    new=$(pinned_base_resolve "$repo") || {
      echo "❌ Cannot refresh $repo in $file; not keeping the old digest silently" >&2
      return 1
    }
    resolved+=("$file $n $repo $old $new")
  done

  for pin in "${resolved[@]}"; do
    read -r file n repo old new <<< "$pin"
    echo "    $repo in $file"
    if [ "$old" = "$new" ]; then
      echo "      already current: $old"
      continue
    fi
    echo "      old: $old"
    echo "      new: $new"
    if ! sed -i "${n}s/@$old/@$new/" "$file"; then
      echo "❌ Could not rewrite $file" >&2
      git checkout -- "$file" ${PINNED_BASE_CHANGED[@]+"${PINNED_BASE_CHANGED[@]}"} || true
      PINNED_BASE_CHANGED=()
      return 1
    fi
    case " ${PINNED_BASE_CHANGED[*]:-} " in
      *" $file "*) ;;
      *) PINNED_BASE_CHANGED+=("$file") ;;
    esac
  done
}
