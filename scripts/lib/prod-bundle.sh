#!/bin/bash
# Confirm whether a full Submariner version (X.Y.Z) shipped to the prod
# operator-bundle registry, robust to the post-0.22 tag scheme.
#
# Tag scheme (verified 2026-08 against
# registry.redhat.io/rhacm2/submariner-operator-bundle):
#   - Patch releases (X.Y.Z, Z>=1):  exact tag vX.Y.Z exists.        e.g. v0.24.1
#   - Old-scheme initial (<=0.22):   exact tag vX.Y.0 exists.        e.g. v0.22.0
#   - New-scheme initial (>=0.23):   NO vX.Y.0 tag — only a floating vX.Y that
#                                    tracks the LATEST patch (v0.24 -> v0.24.1).
# So a naive `skopeo inspect :vX.Y.Z` reports EVERY new-scheme .0 release as
# absent, because vX.Y.0 was never tagged. This lib checks the exact tag first
# and falls back to the floating vX.Y tag, confirming shipped only when a tag's
# .Labels.version EXACTLY equals the requested version.
#
# Known limitation (safe direction): a new-scheme .0 release can no longer be
# tag-confirmed once its first patch ships, because vX.Y then floats to X.Y.1 —
# the verdict becomes "not-shipped" (a false negative that only SUPPRESSES a
# claim, never fabricates one). For exact/historical confirmation, and for the
# more meaningful "did the FBC prod releases actually land it in the operator
# indexes" signal, use prod_index_has_bundle (below), which reads the operator
# index's bundle entry (bundle-vX.Y.Z.{json,yaml}) — keyed on the EXACT version
# and scheme-independent.
#
# Probe-failure != absence (see feedback-probe-failure-not-absence): a
# non-matching answer counts only when the registry was actually reachable; if no
# probe resolved we return "unreachable" so callers suppress rather than
# fabricate. Registry-only (auth from ~/.docker/config.json), no cluster login.
#
# Sourced by release-status.sh and get-fbc-urls.sh (prod_bundle_shipped), by
# autorelease.sh (prod_index_has_bundle, for auto-close), and by
# test-prod-bundle.sh (which unit-tests the pure bundle_shipped_verdict and
# index_lists_bundle).

# Guard against double-sourcing.
[ -n "${_PROD_BUNDLE_SOURCED:-}" ] && return 0
_PROD_BUNDLE_SOURCED=1

: "${PROD_BUNDLE_REGISTRY:=registry.redhat.io/rhacm2/submariner-operator-bundle}"

# Pure verdict (no I/O, unit-tested offline).
# Args:
#   $1 want     full version, no leading 'v' (e.g. 0.24.0)
#   $2 reachable "true"|"false" — did ANY registry probe resolve a manifest?
#   $3 exact    .Labels.version read from :v$want   (empty if absent/unresolved)
#   $4 floating .Labels.version read from :vX.Y     (empty if absent/unresolved)
# Echoes: shipped | not-shipped | unreachable
# Never false-positives: "shipped" requires an EXACT label match to v$want, so a
# floating tag that has moved on to a later patch yields "not-shipped".
bundle_shipped_verdict() {
  local want="v$1" reachable="$2" exact="$3" floating="$4"
  if [ "$exact" = "$want" ] || [ "$floating" = "$want" ]; then
    echo shipped
  elif [ "$reachable" = "true" ]; then
    echo not-shipped
  else
    echo unreachable
  fi
}

# I/O wrapper: probe the prod registry and publish the result via GLOBALS (never
# via stdout/command-substitution — the results include several fields and a
# subshell would drop them). Sets:
#   PROD_BUNDLE_VERDICT  shipped | not-shipped | unreachable
#   PROD_BUNDLE_TAG      tag that carried the version (shipped only, else empty)
#   PROD_BUNDLE_DIGEST   .Digest of that tag        (shipped only, else empty)
#   PROD_BUNDLE_CREATED  build date YYYY-MM-DD       (shipped only, else empty)
# Call it directly (`prod_bundle_shipped X.Y.Z`) then read the globals — do NOT
# wrap it in $(...). Requires: skopeo, jq. Arg $1 = full version X.Y.Z.
prod_bundle_shipped() {
  local version="$1" mm="${1%.*}"
  local exact_json floating_json exact_rc floating_rc reachable=false
  local exact_lbl="" floating_lbl=""

  exact_json=$(timeout 30 skopeo inspect "docker://${PROD_BUNDLE_REGISTRY}:v${version}" 2>/dev/null) && exact_rc=0 || exact_rc=$?
  floating_json=$(timeout 30 skopeo inspect "docker://${PROD_BUNDLE_REGISTRY}:v${mm}" 2>/dev/null) && floating_rc=0 || floating_rc=$?

  if [ "$exact_rc" -eq 0 ]; then
    reachable=true
    exact_lbl=$(printf '%s' "$exact_json" | jq -r '.Labels.version // empty' 2>/dev/null || true)
  fi
  if [ "$floating_rc" -eq 0 ]; then
    reachable=true
    floating_lbl=$(printf '%s' "$floating_json" | jq -r '.Labels.version // empty' 2>/dev/null || true)
  fi

  # PROD_BUNDLE_* are consumed by callers (release-status.sh, get-fbc-urls.sh).
  # shellcheck disable=SC2034
  PROD_BUNDLE_VERDICT=$(bundle_shipped_verdict "$version" "$reachable" "$exact_lbl" "$floating_lbl")

  PROD_BUNDLE_TAG="" PROD_BUNDLE_DIGEST="" PROD_BUNDLE_CREATED=""
  if [ "$PROD_BUNDLE_VERDICT" = "shipped" ]; then
    local src_json src_tag
    if [ "$exact_lbl" = "v$version" ]; then
      src_json="$exact_json" src_tag="v$version"
    else
      src_json="$floating_json" src_tag="v$mm"
    fi
    # shellcheck disable=SC2034
    PROD_BUNDLE_TAG="$src_tag"
    # shellcheck disable=SC2034
    PROD_BUNDLE_DIGEST=$(printf '%s' "$src_json" | jq -r '.Digest // empty' 2>/dev/null || true)
    # shellcheck disable=SC2034
    PROD_BUNDLE_CREATED=$(printf '%s' "$src_json" | jq -r '.Created // empty' 2>/dev/null | cut -dT -f1 || true)
  fi
  return 0
}

# ── Operator-index content check (scheme-independent, exact-version) ─────────
# The prod operator index for an OCP version lists an installable release as
# /configs/submariner/bundles/bundle-vX.Y.Z.{json,yaml}. Unlike the floating
# bundle tag, this is keyed on the EXACT version and survives later patches, so
# it both confirms historical .0 releases AND is the meaningful "the FBC prod
# release actually landed in the index" (OperatorHub-installable) signal.
: "${PROD_INDEX_REGISTRY:=registry.redhat.io/redhat/redhat-operator-index}"

# Pure verdict (no I/O, unit-tested offline): does an already-extracted bundles
# directory contain the exact version's entry?
# Args: $1 dir (holds bundle-*.{json,yaml}), $2 full version X.Y.Z
# Echoes: yes | no
index_lists_bundle() {
  local dir="$1" version="$2"
  if [ -f "$dir/bundle-v${version}.json" ] || [ -f "$dir/bundle-v${version}.yaml" ]; then
    echo yes
  else
    echo no
  fi
}

# I/O wrapper: does the prod operator index for ONE OCP version list the bundle?
# Registry-only (oc image extract; auth from ~/.docker/config.json, no cluster
# login). Echoes: present | absent | unreachable. Probe-failure != absence: an
# extract failure (network/auth/missing tag) yields "unreachable" so callers
# suppress rather than fabricate a shipped claim. Requires: oc.
# Args: $1 OCP minor (e.g. 20 for 4.20), $2 full version X.Y.Z.
prod_index_has_bundle() {
  local ocp="$1" version="$2"
  local image="${PROD_INDEX_REGISTRY}:v4.${ocp}"
  local dir verdict
  dir=$(mktemp -d) || { echo unreachable; return 0; }
  if timeout 120 oc image extract "$image" --path "/configs/submariner/bundles/:$dir/" --confirm >/dev/null 2>&1; then
    [ "$(index_lists_bundle "$dir" "$version")" = yes ] && verdict=present || verdict=absent
  else
    verdict=unreachable
  fi
  rm -rf "$dir"
  echo "$verdict"
}
