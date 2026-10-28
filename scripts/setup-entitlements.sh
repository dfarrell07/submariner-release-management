#!/usr/bin/env bash
# Set up the Red Hat entitlements and registry login rpm-lockfile-update needs.
#
# Usage: setup-entitlements.sh [--check] [--force]
#
#   (no flag)  Set up whatever is missing; skip what already works
#   --check    Report status only; exit 1 if anything is missing
#   --force    Register again even if entitlements exist (e.g. new key)
#
# The team's shared credentials come from secrets/entitlements.asc, sealed
# with one team password (see `make seal-entitlements`). You enter that
# password once and can have it remembered on this machine. Without a bundle
# the script prompts for the org ID and activation key instead.
#
# Non-interactive: ENTITLEMENT_PASSWORD (opens the bundle), or RH_ORG and
# RH_ACTIVATION_KEY, and RH_REGISTRY_USER / RH_REGISTRY_PASSWORD.
#
# It also verifies the registration actually grants access to RHEL content, since
# a valid certificate from an activation key with no repos looks fine until
# the lockfile build fails with a dnf metadata error.
#
# Test hooks: ENTITLEMENT_DIR and CONSUMER_DIR override /etc/pki/entitlement
# and /etc/pki/consumer; PROBE_URLS overrides the repository metadata URLs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/entitlement-bundle.sh
source "$SCRIPT_DIR/lib/entitlement-bundle.sh"

readonly ENTITLEMENT_DIR="${ENTITLEMENT_DIR:-/etc/pki/entitlement}"
readonly CONSUMER_DIR="${CONSUMER_DIR:-/etc/pki/consumer}"
FORCE=false
readonly REGISTRY="registry.redhat.io"
readonly AUTHFILE="${HOME}/.docker/config.json" # the file rpm-lockfile-update checks
readonly KEYS_URL="https://console.redhat.com/insights/connector/activation-keys/"
readonly DOCS_URL="https://github.com/submariner-io/shipyard/blob/devel/.rpm-lockfiles/README.md"

# One RHEL 9 and one RHEL 10 repo: release branches use either.
readonly PROBE_URLS="${PROBE_URLS:-https://cdn.redhat.com/content/dist/rhel9/9/x86_64/baseos/os/repodata/repomd.xml https://cdn.redhat.com/content/dist/rhel10/10/x86_64/baseos/os/repodata/repomd.xml}"
readonly UEP_CA="/etc/rhsm/ca/redhat-uep.pem"

die() {
  echo "❌ $1" >&2
  [ -n "${2:-}" ] && echo "$2" >&2
  exit 1
}

has_entitlements() {
  local f
  for f in "$ENTITLEMENT_DIR"/*.pem; do
    [ -e "$f" ] && [[ "$f" != *-key.pem ]] && return 0
  done
  return 1
}

has_registry_auth() {
  [ -s "$AUTHFILE" ] && podman login --get-login "$REGISTRY" --authfile "$AUTHFILE" &>/dev/null
}

# repo_access: prints "ok" if the entitlement certificate can fetch RHEL repo
# metadata, "denied" if Red Hat answers but refuses it, else "unknown" (offline,
# VPN, or curl missing).
repo_access() {
  local cert key url code seen_denied=false
  for cert in "$ENTITLEMENT_DIR"/*.pem; do
    [ -e "$cert" ] && [[ "$cert" != *-key.pem ]] && break
  done
  key="${cert%.pem}-key.pem"
  [ -e "$cert" ] && [ -e "$key" ] && command -v curl &>/dev/null || { echo unknown; return; }
  local -a ca=()
  [ -r "$UEP_CA" ] && ca=(--cacert "$UEP_CA")
  for url in $PROBE_URLS; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${ca[@]}" --cert "$cert" --key "$key" "$url" 2>/dev/null) || code=000
    case "$code" in
      200) echo ok; return ;;
      401 | 403) seen_denied=true ;;
    esac
  done
  if $seen_denied; then echo denied; else echo unknown; fi
}

denied_hint() { # indent
  printf '%sRed Hat accepts the certificate but refuses to serve RHEL repos.\n' "$1"
  printf '%s1. The registration is probably stale (revoked or removed on Red Hat'"'"'s side).\n' "$1"
  printf '%s   Re-register; your current one is backed up and restored on failure:\n' "$1"
  printf '%s     make setup-entitlements FORCE=1\n' "$1"
  printf '%s2. If that fails or is still denied, try another network (e.g. a hotspot).\n' "$1"
  printf '%s3. If still denied, add RHEL BaseOS/AppStream to the activation key:\n' "$1"
  printf '%s   %s\n' "$1" "$KEYS_URL"
}

report() { # label, status-command
  if "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; return 1; fi
}

# Keep a copy of the current registration so a failed re-registration (bad
# network, wrong key) cannot leave the machine with none.
backup_registration() {
  local b
  b=$(sudo mktemp -d "${TMPDIR:-/var/tmp}/rhsm-backup.XXXXXX") || return 1
  if [ -d "$ENTITLEMENT_DIR" ]; then sudo cp -a "$ENTITLEMENT_DIR" "$b/entitlement" || return 1; fi
  if [ -d "$CONSUMER_DIR" ]; then sudo cp -a "$CONSUMER_DIR" "$b/consumer" || return 1; fi
  echo "$b"
}

restore_registration() { # backup-dir
  if [ -d "$1/entitlement" ]; then sudo cp -a "$1/entitlement/." "$ENTITLEMENT_DIR/"; fi
  if [ -d "$1/consumer" ]; then sudo cp -a "$1/consumer/." "$CONSUMER_DIR/"; fi
  sudo rm -rf "$1"
}

BUNDLE_LOADED=false
# Decrypt the team bundle once and export BUNDLE_<KEY> variables. Tries
# ENTITLEMENT_PASSWORD, then the password remembered on this machine, then
# prompts (which also handles a rotated password).
open_bundle() {
  $BUNDLE_LOADED && return 0
  local plain pw rejected=false n
  try_password() { plain=$(bundle_decrypt "$1" "$BUNDLE_FILE") && [ -n "$plain" ]; }

  pw="${ENTITLEMENT_PASSWORD:-}"
  if [ -n "$pw" ]; then
    try_password "$pw" || die "ENTITLEMENT_PASSWORD does not open $BUNDLE_FILE"
  else
    pw=$(cached_password)
    if [ -n "$pw" ] && try_password "$pw"; then
      :
    else
      [ -z "$pw" ] || rejected=true
      [ -t 0 ] || die "Cannot open the team bundle without a terminal" \
        "Set ENTITLEMENT_PASSWORD, or run this from a terminal."
      $rejected && echo "The password saved on this machine no longer opens the bundle (rotated?)."
      echo "Team credentials are in $BUNDLE_FILE. Ask a teammate for the team password."
      for n in 1 2 3; do
        read -r -s -p "Team password: " pw
        echo
        try_password "$pw" && break
        echo "  Wrong password ($n/3)"
        pw=""
      done
      [ -n "$pw" ] || die "Could not open the team bundle"
      read -r -p "Remember it on this machine ($PASSWORD_FILE)? [Y/n] " n
      case "$n" in [nN]*) ;; *) save_password "$pw" ;; esac
    fi
  fi
  parse_bundle <<<"$plain"
  BUNDLE_LOADED=true
}

register() {
  local org="${RH_ORG:-}" key="${RH_ACTIVATION_KEY:-}"
  if [ -z "$org" ] || [ -z "$key" ]; then
    if [ -f "$BUNDLE_FILE" ]; then
      open_bundle
      org="${BUNDLE_RH_ORG:-}"
      key="${BUNDLE_RH_ACTIVATION_KEY:-}"
    else
      [ -t 0 ] || die "No team bundle at $BUNDLE_FILE and no terminal to prompt on" \
        "Set RH_ORG and RH_ACTIVATION_KEY, or run this from a terminal."
      cat <<INFO

No team bundle found at $BUNDLE_FILE.
(Whoever holds the shared key can create it with: make seal-entitlements)
Enter the credentials directly instead:
  activation keys: $KEYS_URL
  guide: $DOCS_URL

INFO
      read -r -p "Org ID: " org
      read -r -s -p "Activation key name (input hidden): " key
      echo
    fi
  fi
  [ -n "$org" ] && [ -n "$key" ] || die "Org ID and activation key are both required"

  echo "Registering (sudo will ask for your password)..."
  # Drop any earlier registration first, the sequence upstream documents.
  # `unregister` may fail if Red Hat no longer knows this machine (a stale
  # registration), so its failure is ignored; `clean` only removes local state.
  # `register --force` would do the unregister itself and then abort on that error.
  local backup=""
  if $FORCE || [ -e "$CONSUMER_DIR/cert.pem" ]; then
    backup=$(backup_registration) || die "Could not back up the current registration; not changing it"
    sudo subscription-manager unregister &>/dev/null || true
    sudo subscription-manager clean &>/dev/null || true
  fi
  # The key is visible in `ps` while this runs; subscription-manager has no
  # stdin option.
  if ! sudo subscription-manager register \
    "--org=$org" "--activationkey=$key" >/dev/null; then
    if [ -n "$backup" ]; then
      restore_registration "$backup"
      echo "Restored your previous registration." >&2
    fi
    die "Registration failed" \
      "Check the org ID, key name and network (try another network or without a VPN).
Details (activation key redacted): sudo tail -40 /var/log/rhsm/rhsm.log | sed -E 's/(activation_?keys?=)[^& \"]+/\\1<redacted>/g'"
  fi
  if [ -n "$backup" ]; then sudo rm -rf "$backup"; fi
  has_entitlements || die "Registered, but no entitlement certificates appeared in $ENTITLEMENT_DIR" \
    "Add repos (RHEL BaseOS/AppStream) to the activation key, then re-run with --force."
}

registry_login() {
  local user="${RH_REGISTRY_USER:-}" pass="${RH_REGISTRY_PASSWORD:-}"
  if [ -z "$user" ] && [ -z "$pass" ] && [ -f "$BUNDLE_FILE" ]; then
    open_bundle
    user="${BUNDLE_RH_REGISTRY_USER:-}"
    pass="${BUNDLE_RH_REGISTRY_PASSWORD:-}"
  fi
  if [ -n "$user" ] && [ -n "$pass" ]; then
    mkdir -p "$(dirname "$AUTHFILE")"
    printf '%s' "$pass" |
      podman login "$REGISTRY" --authfile "$AUTHFILE" \
        --username "$user" --password-stdin >/dev/null
  else
    [ -t 0 ] || die "No terminal to prompt on" \
      "Set RH_REGISTRY_USER and RH_REGISTRY_PASSWORD, or run this from a terminal."
    echo
    echo "Logging in to $REGISTRY with your own Red Hat account."
    mkdir -p "$(dirname "$AUTHFILE")"
    podman login "$REGISTRY" --authfile "$AUTHFILE"
  fi
}

main() {
  local check=false force=false arg
  for arg in "$@"; do
    case "$arg" in
      --check) check=true ;;
      --force) force=true; FORCE=true ;;
      -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done

  [ "$(uname -s)" = "Linux" ] || die "Linux only" "See: $DOCS_URL"
  command -v podman &>/dev/null || die "podman not found"

  if $check; then
    echo "RPM lockfile prerequisites:"
    local rc=0 denied=false
    report "Red Hat entitlements in $ENTITLEMENT_DIR" has_entitlements || rc=1
    report "$REGISTRY login in $AUTHFILE" has_registry_auth || rc=1
    if has_entitlements; then
      case "$(repo_access)" in
        ok) echo "  ✓ Entitlement grants access to RHEL repositories" ;;
        denied) echo "  ✗ Entitlement grants no RHEL repository access"; denied_hint "    "; rc=1; denied=true ;;
        *) echo "  ? Could not verify RHEL repository access (cdn.redhat.com unreachable: network or VPN?)" ;;
      esac
    fi
    if [ "$rc" -ne 0 ] && ! $denied; then echo "Fix with: make setup-entitlements"; fi
    exit "$rc"
  fi

  if ! $force && has_entitlements; then
    echo "✓ Entitlements already present (use --force to re-register)"
  else
    command -v subscription-manager &>/dev/null || die "subscription-manager not found" \
      "Install it (Fedora/RHEL: sudo dnf install subscription-manager)"
    register
    echo "✓ Registered"
  fi

  if has_registry_auth; then
    echo "✓ Already logged in to $REGISTRY"
  else
    registry_login
    has_registry_auth || die "Registry login did not take effect"
    echo "✓ Logged in to $REGISTRY"
  fi

  case "$(repo_access)" in
    ok) echo "✓ Entitlement grants access to RHEL repositories" ;;
    denied) die "The entitlement grants no RHEL repository access" "$(denied_hint "")" ;;
    *) echo "? Could not verify RHEL repository access (network or VPN?); continuing" ;;
  esac

  echo "Ready: make rpm-lockfile-update"
}

main "$@"
