#!/usr/bin/env bash
# Read, change and check the on-cel-expression annotation of a .tekton pipeline.
# Expressions are always read by parsing the YAML, because bot pipelines and some
# release branches wrap them over several lines.
[ -n "${_CEL_FILTER_SOURCED:-}" ] && return 0
_CEL_FILTER_SOURCED=1

readonly CEL_ANNOTATION="pipelinesascode.tekton.dev/on-cel-expression"

# bundle/ and config/ must stay out of the operator filter: SHA updates change
# them, so including them would rebuild the operator and split the snapshot digests.
readonly OPERATOR_FORBIDDEN_PATHS='^(bundle|config)([/.]|$)'

# Prints the expression on one line, or nothing if the annotation is absent.
# Args: $1=YAML file, or - for stdin
cel_read() {
  local raw
  raw=$(yq eval ".metadata.annotations[\"$CEL_ANNOTATION\"] // \"\"" "$1") || return 1
  printf '%s' "$raw" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# Prints each pathChanged() path in an expression, one per line.
cel_paths() {
  { grep -oE '"[^"]+"\.pathChanged\(\)' <<< "$1" || true; } | sed -E 's/^"(.*)"\.pathChanged\(\)$/\1/'
}

# Checks the whole expression has the shape
#   event == "E" && target_branch == "B" && ("p".pathChanged() || ...)
# and the required paths, so a filter that doesn't actually restrict the build
# (a top-level ||, the wrong branch) is rejected rather than just containing
# "pathChanged".
# Args: $1=expression $2=event $3=branch $4=forbidden path regex (may be empty)
#       $5...=required paths
cel_check() {
  local expr="$1" event="$2" branch="$3" forbidden="$4"
  shift 4
  local path_call='"[^"]+"\.pathChanged\(\)' rc=0 paths path
  local shape="^event == \"${event}\" && target_branch == \"${branch//./\\.}\" && \\(${path_call}( \\|\\| ${path_call})*\\)\$"

  if [[ ! "$expr" =~ $shape ]]; then
    echo "  not a path-filtered expression for event '$event', branch '$branch': ${expr:-<none>}" >&2
    rc=1
  fi
  paths=$(cel_paths "$expr")
  for path in "$@"; do
    if ! grep -qxF -- "$path" <<< "$paths"; then
      echo "  missing required path: $path" >&2
      rc=1
    fi
  done
  if [ -n "$forbidden" ]; then
    while IFS= read -r path; do
      if [[ "$path" =~ $forbidden ]]; then
        echo "  path must not be in this filter: $path" >&2
        rc=1
      fi
    done <<< "$paths"
  fi
  return "$rc"
}

# The operator build inputs, as on release-0.25 (submariner-operator#4325).
# Args: $1=expression $2=event $3=branch $4=component-with-version (submariner-operator-0-25)
cel_check_operator() {
  cel_check "$1" "$2" "$3" "$OPERATOR_FORBIDDEN_PATHS" \
    ".tekton/$4-pull-request.yaml" ".tekton/$4-push.yaml" go.mod go.sum .tekton/konflux.args \
    "cmd/***" "deploy/crds/***" tools/go.mod tools/go.sum "api/***" "package/***" "internal/***" "pkg/***"
}

# Args: $1=expression $2=event $3=branch $4=component-with-version (submariner-bundle-0-25)
cel_check_bundle() {
  cel_check "$1" "$2" "$3" "" \
    ".tekton/$4-pull-request.yaml" ".tekton/$4-push.yaml" \
    bundle.Dockerfile.konflux "bundle/***" "config/bundle/***"
}

# Replaces the annotation, however many lines it spans, with a one-line form, or
# adds it after max-keep-runs. The file only changes if the result parses back to
# the same expression, which also fails when there was nowhere to put it.
# Args: $1=file $2=expression
cel_write() {
  local file="$1" expr="$2" tmp="$1.cel-tmp" present=0
  grep -q "^[[:space:]]*${CEL_ANNOTATION}:" "$file" && present=1
  CEL_LINE="${CEL_ANNOTATION}: ${expr}" awk -v present="$present" '
    function indent(text) { match(text, /^ */); return RLENGTH }
    # Continuation lines are blank or indented deeper than the key.
    skipping {
      if ($0 ~ /^[[:space:]]*$/ || indent($0) > key_indent) next
      skipping = 0
    }
    /^[[:space:]]*pipelinesascode\.tekton\.dev\/on-cel-expression:/ {
      key_indent = indent($0)
      printf "%*s%s\n", key_indent, "", ENVIRON["CEL_LINE"]
      skipping = 1
      next
    }
    { print }
    !present && /^[[:space:]]*pipelinesascode\.tekton\.dev\/max-keep-runs:/ {
      printf "%*s%s\n", indent($0), "", ENVIRON["CEL_LINE"]
    }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

  if [ "$(cel_read "$tmp" 2>/dev/null)" != "$expr" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}
