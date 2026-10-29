#!/usr/bin/env bash
# Tests for setup-entitlements.sh (stubbed sudo/subscription-manager/podman)
# Run: ./scripts/lib/test-setup-entitlements.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../setup-entitlements.sh"
SEAL="$SCRIPT_DIR/../seal-entitlements.sh"
LOCKFILE="$SCRIPT_DIR/../rpm-lockfile-update.sh"

PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1"; echo "    got:  '$2'"; echo "    want: '$3'"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if ! printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}

# Fresh sandbox: fake HOME, entitlement dir, and stub binaries. Call logs
# record one argument per line so quoting bugs are visible.
new_sandbox() {
  SB="$TMP/sb$((++N))"
  mkdir -p "$SB/bin" "$SB/home" "$SB/ent"
  export HOME="$SB/home" ENTITLEMENT_DIR="$SB/ent" PATH="$SB/bin:$ORIG_PATH"
  export CONSUMER_DIR="$SB/consumer" TMPDIR="$SB/tmp"; mkdir -p "$CONSUMER_DIR" "$SB/tmp"
  export SM_LOG="$SB/sm.log" PODMAN_LOG="$SB/podman.log" CURL_LOG="$SB/curl.log"
  export PROBE_URLS="https://probe.invalid/a https://probe.invalid/b"
  export ENTITLEMENT_BUNDLE="$SB/bundle.asc"
  unset XDG_CONFIG_HOME ENTITLEMENT_PASSWORD CURL_CODE SM_FAIL_UNREGISTER
  unset RH_ORG RH_ACTIVATION_KEY RH_REGISTRY_USER RH_REGISTRY_PASSWORD SM_FAIL SM_NO_CERTS
  cat > "$SB/bin/uname" <<'STUB'
#!/bin/bash
if [ "${1:-}" = -s ]; then echo Linux; else exec /usr/bin/uname "$@"; fi
STUB
  cat > "$SB/bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
  cat > "$SB/bin/subscription-manager" <<'STUB'
#!/bin/bash
printf 'CALL\n' >> "$SM_LOG"; printf '%s\n' "$@" >> "$SM_LOG"
[ "$1" = unregister ] && [ -n "${SM_FAIL_UNREGISTER:-}" ] && { echo "Remote server error" >&2; exit 1; }
[ "$1" = register ] && [ -n "${SM_FAIL:-}" ] && { echo "invalid key" >&2; exit 1; }
[ "$1" = clean ] && rm -f "$ENTITLEMENT_DIR"/* "$CONSUMER_DIR"/*
[ "$1" = register ] || exit 0
[ -n "${SM_NO_CERTS:-}" ] || touch "$ENTITLEMENT_DIR/1.pem" "$ENTITLEMENT_DIR/1-key.pem"
STUB
  cat > "$SB/bin/podman" <<'STUB'
#!/bin/bash
printf 'CALL\n' >> "$PODMAN_LOG"; printf '%s\n' "$@" >> "$PODMAN_LOG"
authfile=""; get=false
for ((i = 1; i <= $#; i++)); do
  [ "${!i}" = "--authfile" ] && { j=$((i + 1)); authfile="${!j}"; }
  [ "${!i}" = "--get-login" ] && get=true
done
if $get; then [ -s "$authfile" ] && echo user; exit; fi
cat > /dev/null 2>&1 < /dev/stdin || true
echo '{"auths":{"registry.redhat.io":{}}}' > "$authfile"
STUB
  printf '#!/bin/bash\nexit 0\n' > "$SB/bin/gh"
  cat > "$SB/bin/curl" <<'STUB'
#!/bin/bash
printf 'CALL\n' >> "$CURL_LOG"; printf '%s\n' "$@" >> "$CURL_LOG"
printf '%s' "${CURL_CODE:-200}"
STUB
  chmod +x "$SB/bin/"*
  : > "$SM_LOG"; : > "$PODMAN_LOG"; : > "$CURL_LOG"
}

run() { OUT=$("$SETUP" "$@" </dev/null 2>&1) && RC=0 || RC=$?; }
run_seal() { OUT=$("$SEAL" "$@" </dev/null 2>&1) && RC=0 || RC=$?; }
# Team password printed by the seal script (64 base64 chars on an indented line)
printed_password() { printf '%s\n' "$OUT" | grep -E '^    [A-Za-z0-9+/=]{64}$' | tr -d ' '; }

ORIG_PATH="$PATH"; N=0

echo "1: --check on a bare machine reports both missing and exits 1"
new_sandbox
run --check
assert_eq "exit 1" "$RC" "1"
assert_contains "entitlements marked missing" "$OUT" "✗ Red Hat entitlements"
assert_contains "registry marked missing" "$OUT" "✗ registry.redhat.io login"
assert_contains "hints the fix" "$OUT" "make setup-entitlements"
assert_eq "no registration attempted" "$(cat "$SM_LOG")" ""

echo "2: full setup from env vars registers, logs in, then --check passes"
new_sandbox
export RH_ORG=12345 RH_ACTIVATION_KEY=my-key RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=s3cret
run
assert_eq "exit 0" "$RC" "0"
assert_contains "registers" "$(cat "$SM_LOG")" "register"
assert_not_contains "no register --force (it aborts on a stale consumer)" "$(cat "$SM_LOG")" "--force"
assert_contains "org passed" "$(cat "$SM_LOG")" "--org=12345"
assert_contains "key passed" "$(cat "$SM_LOG")" "--activationkey=my-key"
assert_contains "login writes the file rpm-lockfile-update checks" "$(cat "$PODMAN_LOG")" "$HOME/.docker/config.json"
assert_contains "password via stdin" "$(cat "$PODMAN_LOG")" "--password-stdin"
assert_not_contains "password not on the command line" "$(cat "$PODMAN_LOG")" "s3cret"
assert_not_contains "key not echoed" "$OUT" "my-key"
assert_not_contains "password not echoed" "$OUT" "s3cret"
assert_contains "points at the next step" "$OUT" "make rpm-lockfile-update"
run --check
assert_eq "--check now passes" "$RC" "0"

echo "3: rerun skips everything that already works"
: > "$SM_LOG"; : > "$PODMAN_LOG"
run
assert_eq "exit 0" "$RC" "0"
assert_eq "no re-registration" "$(cat "$SM_LOG")" ""
assert_not_contains "no second login" "$(cat "$PODMAN_LOG")" "--password-stdin"
assert_contains "says entitlements present" "$OUT" "already present"

echo "4: --force registers again"
run --force
assert_contains "re-registered" "$(cat "$SM_LOG")" "--org=12345"
assert_contains "unregisters first" "$(cat "$SM_LOG")" "unregister"
assert_contains "then cleans local state" "$(cat "$SM_LOG")" "clean"

echo "5: values with quotes and spaces stay single arguments"
new_sandbox
export RH_ORG="o r'g" RH_ACTIVATION_KEY="k\"e y" RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p
run
assert_contains "org intact" "$(cat "$SM_LOG")" "--org=o r'g"
assert_contains "key intact" "$(cat "$SM_LOG")" "--activationkey=k\"e y"

echo "6: no terminal and no env vars fails clearly without registering"
new_sandbox
run
assert_eq "exit 1" "$RC" "1"
assert_contains "names the env vars" "$OUT" "RH_ORG"
assert_eq "no registration attempted" "$(cat "$SM_LOG")" ""

echo "7: registration failure is reported and stops"
new_sandbox
export RH_ORG=1 RH_ACTIVATION_KEY=bad SM_FAIL=1
run
assert_eq "exit 1" "$RC" "1"
assert_contains "says registration failed" "$OUT" "Registration failed"
assert_not_contains "key not echoed" "$OUT" "bad"
assert_eq "no registry login after failed registration" "$(cat "$PODMAN_LOG")" ""

echo "8: registration with no certificates is an error"
new_sandbox
export RH_ORG=1 RH_ACTIVATION_KEY=k SM_NO_CERTS=1
run
assert_eq "exit 1" "$RC" "1"
assert_contains "explains missing certs" "$OUT" "no entitlement certificates"

echo "9: entitlements present, only the registry login is missing"
new_sandbox
touch "$ENTITLEMENT_DIR/9.pem"
export RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p
run
assert_eq "exit 0" "$RC" "0"
assert_eq "no registration" "$(cat "$SM_LOG")" ""
assert_contains "logged in" "$OUT" "Logged in to registry.redhat.io"

echo "10: a lone key file does not count as an entitlement"
new_sandbox
touch "$ENTITLEMENT_DIR/1-key.pem"
run --check
assert_contains "still missing" "$OUT" "✗ Red Hat entitlements"

echo "11: unknown flag exits 2"
new_sandbox
run --bogus
assert_eq "exit 2" "$RC" "2"

echo "12: repo-access probe: entitled, denied, and unverifiable"
new_sandbox
touch "$ENTITLEMENT_DIR/1.pem" "$ENTITLEMENT_DIR/1-key.pem"; mkdir -p "$HOME/.docker"; echo '{"auths":{"x":{}}}' > "$HOME/.docker/config.json"
run --check
assert_eq "entitled: exit 0" "$RC" "0"
assert_contains "entitled: ✓ line" "$OUT" "✓ Entitlement grants access"
assert_contains "probe presents the entitlement cert" "$(cat "$CURL_LOG")" "$ENTITLEMENT_DIR/1.pem"
CURL_CODE=403 run --check
assert_eq "denied: exit 1" "$RC" "1"
assert_contains "denied: ✗ line" "$OUT" "grants no RHEL repository access"
assert_contains "denied: suggests re-registering first" "$OUT" "probably stale"
assert_contains "denied: reassures the old registration is kept on failure" "$OUT" "restored on failure"
assert_contains "denied: then another network" "$OUT" "try another network"
assert_contains "denied: then the key repos" "$OUT" "add RHEL BaseOS/AppStream"
assert_contains "denied: points at FORCE=1" "$OUT" "make setup-entitlements FORCE=1"
assert_not_contains "denied: no misleading plain re-run hint" "$OUT" "Fix with: make setup-entitlements"
CURL_CODE=000 run --check
assert_eq "unreachable: still exit 0" "$RC" "0"
assert_contains "unreachable: ? line" "$OUT" "Could not verify"

echo "13: --force survives a stale registration (Red Hat no longer knows the machine)"
new_sandbox
touch "$CONSUMER_DIR/cert.pem" "$ENTITLEMENT_DIR/old.pem"
export RH_ORG=5 RH_ACTIVATION_KEY=k RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p SM_FAIL_UNREGISTER=1
run --force
assert_eq "exit 0 despite unregister failing" "$RC" "0"
LOG=$(tr '\n' ' ' < "$SM_LOG")
assert_contains "order: unregister, clean, register" "$LOG" "CALL unregister CALL clean CALL register"
assert_contains "registered with the key" "$LOG" "--org=5"

echo "14: a leftover consumer certificate triggers cleanup even without --force"
new_sandbox
touch "$CONSUMER_DIR/cert.pem"
export RH_ORG=6 RH_ACTIVATION_KEY=k RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p
run
assert_contains "cleans first" "$(tr '\n' ' ' < "$SM_LOG")" "CALL unregister CALL clean CALL register"

echo "15: a fresh machine only registers, and failure gives network and log hints"
new_sandbox
export RH_ORG=7 RH_ACTIVATION_KEY=k SM_FAIL=1
run
assert_eq "exit 1" "$RC" "1"
assert_not_contains "no unregister/clean on a fresh machine" "$(cat "$SM_LOG")" "unregister"
assert_contains "mentions network" "$OUT" "network"
assert_contains "gives a redacting log command" "$OUT" "<redacted>"
assert_not_contains "never suggests VPN is required" "$OUT" "may be needed"

echo "16: a failed re-registration restores the previous working registration"
new_sandbox
printf 'old-cert' > "$ENTITLEMENT_DIR/old.pem"; printf 'old-key' > "$ENTITLEMENT_DIR/old-key.pem"; printf 'consumer' > "$CONSUMER_DIR/cert.pem"
export RH_ORG=9 RH_ACTIVATION_KEY=k SM_FAIL=1
run --force
assert_eq "exit 1" "$RC" "1"
assert_contains "says it restored" "$OUT" "Restored your previous registration"
assert_eq "old entitlement cert is back" "$(cat "$ENTITLEMENT_DIR/old.pem" 2>/dev/null)" "old-cert"
assert_eq "old consumer cert is back" "$(cat "$CONSUMER_DIR/cert.pem" 2>/dev/null)" "consumer"
assert_eq "backup directory cleaned up" "$(ls "$SB/tmp" | wc -l | tr -d ' ')" "0"

echo "17: a successful re-registration replaces the old certs and cleans the backup"
new_sandbox
printf 'old-cert' > "$ENTITLEMENT_DIR/old.pem"; printf 'consumer' > "$CONSUMER_DIR/cert.pem"
export RH_ORG=9 RH_ACTIVATION_KEY=k RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p
run --force
assert_eq "exit 0" "$RC" "0"
assert_eq "old cert gone" "$([ -e "$ENTITLEMENT_DIR/old.pem" ] && echo present || echo gone)" "gone"
assert_eq "new cert present" "$([ -e "$ENTITLEMENT_DIR/1.pem" ] && echo present || echo missing)" "present"
assert_eq "backup directory cleaned up" "$(ls "$SB/tmp" | wc -l | tr -d ' ')" "0"

echo "18: setup fails loudly when registration grants no repos"
new_sandbox
export RH_ORG=1 RH_ACTIVATION_KEY=k RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p CURL_CODE=403
run
assert_eq "exit 1" "$RC" "1"
assert_contains "explains" "$OUT" "grants no RHEL repository access"
assert_contains "registration was still done" "$(cat "$SM_LOG")" "--org=1"
assert_not_contains "does not claim ready" "$OUT" "Ready:"
CURL_CODE=200 run
assert_contains "healthy run says ready" "$OUT" "Ready: make rpm-lockfile-update"

echo "19: rpm-lockfile-update uses the same prerequisite check and fails fast"
new_sandbox
run_lockfile() { OUT=$("$LOCKFILE" 0.24 nettest </dev/null 2>&1) && RC=0 || RC=$?; }
run_lockfile
assert_eq "no entitlements: exit 1" "$RC" "1"
assert_contains "no entitlements: shows the ✗ report" "$OUT" "✗ Red Hat entitlements"
assert_contains "no entitlements: points at setup" "$OUT" "make setup-entitlements"
assert_not_contains "no entitlements: did not start work" "$OUT" "Updating"
touch "$ENTITLEMENT_DIR/1.pem" "$ENTITLEMENT_DIR/1-key.pem"; mkdir -p "$HOME/.docker"; echo '{"auths":{"x":{}}}' > "$HOME/.docker/config.json"
CURL_CODE=403 run_lockfile
assert_eq "no repo access: exit 1" "$RC" "1"
assert_contains "no repo access: says why" "$OUT" "grants no RHEL repository access"
assert_not_contains "no repo access: did not start work" "$OUT" "Updating"
run_lockfile
assert_contains "healthy: prerequisites verified" "$OUT" "✓ Prerequisites verified"
CURL_CODE=000 run_lockfile
assert_contains "unverifiable repo access does not block" "$OUT" "✓ Prerequisites verified"

echo "20: --check works without subscription-manager installed"
new_sandbox
rm -f "$SB/bin/subscription-manager"
run --check
assert_contains "reports normally" "$OUT" "Red Hat entitlements"
assert_not_contains "no install nag" "$OUT" "subscription-manager not found"

if command -v gpg >/dev/null 2>&1; then
echo "21: seal creates an encrypted bundle, prints a strong password once, saves it"
new_sandbox
export RH_ORG=777 RH_ACTIVATION_KEY="shared key" RH_REGISTRY_USER=svc RH_REGISTRY_PASSWORD=svcpw
run_seal
assert_eq "exit 0" "$RC" "0"
PW1=$(printed_password)
assert_eq "64-char password shown" "${#PW1}" "64"
assert_contains "armored PGP message" "$(cat "$ENTITLEMENT_BUNDLE")" "BEGIN PGP MESSAGE"
assert_not_contains "org not in the file" "$(cat "$ENTITLEMENT_BUNDLE")" "777"
assert_not_contains "key not in the file" "$(cat "$ENTITLEMENT_BUNDLE")" "shared key"
assert_eq "password saved 0600" "$(stat -c %a "$HOME/.config/submariner-release-management/entitlement-password" 2>/dev/null || stat -f %Lp "$HOME/.config/submariner-release-management/entitlement-password")" "600"
assert_not_contains "registry password not in output" "$OUT" "svcpw"

echo "22: setup opens the bundle with ENTITLEMENT_PASSWORD and uses the shared values"
unset RH_ORG RH_ACTIVATION_KEY RH_REGISTRY_USER RH_REGISTRY_PASSWORD
ENTITLEMENT_PASSWORD="$PW1" run
assert_eq "exit 0" "$RC" "0"
assert_contains "shared org" "$(cat "$SM_LOG")" "--org=777"
assert_contains "shared key with a space" "$(cat "$SM_LOG")" "--activationkey=shared key"
assert_contains "shared registry user" "$(cat "$PODMAN_LOG")" "svc"
assert_not_contains "password not echoed" "$OUT" "$PW1"

echo "23: the remembered password is used with no prompt"
rm -f "$ENTITLEMENT_DIR"/*.pem "$HOME/.docker/config.json"; : > "$SM_LOG"
run
assert_eq "exit 0" "$RC" "0"
assert_contains "registered from the bundle" "$(cat "$SM_LOG")" "--org=777"

echo "24: wrong ENTITLEMENT_PASSWORD fails clearly and registers nothing"
rm -f "$ENTITLEMENT_DIR"/*.pem; : > "$SM_LOG"
ENTITLEMENT_PASSWORD="not-the-password" run
assert_eq "exit 1" "$RC" "1"
assert_contains "explains" "$OUT" "does not open"
assert_eq "nothing registered" "$(cat "$SM_LOG")" ""

echo "25: a stale remembered password without a terminal says what to do"
printf 'stale-password' > "$HOME/.config/submariner-release-management/entitlement-password"
run
assert_eq "exit 1" "$RC" "1"
assert_contains "asks for a terminal or env var" "$OUT" "ENTITLEMENT_PASSWORD"
assert_eq "nothing registered" "$(cat "$SM_LOG")" ""
printf '%s' "$PW1" > "$HOME/.config/submariner-release-management/entitlement-password"

echo "26: rotating the key reuses the password, so teammates need nothing new"
RH_ORG=888 RH_ACTIVATION_KEY=rotated run_seal
assert_eq "exit 0" "$RC" "0"
assert_contains "says password reused" "$OUT" "Reused the existing team password"
assert_eq "no new password printed" "$(printed_password)" ""
rm -f "$ENTITLEMENT_DIR"/*.pem; : > "$SM_LOG"
ENTITLEMENT_PASSWORD="$PW1" run
assert_contains "new org used" "$(cat "$SM_LOG")" "--org=888"
assert_contains "new key used" "$(cat "$SM_LOG")" "--activationkey=rotated"

echo "27: --new-password issues a fresh password and the old one stops working"
RH_ORG=888 RH_ACTIVATION_KEY=rotated run_seal --new-password
PW2=$(printed_password)
assert_eq "new 64-char password" "${#PW2}" "64"
assert_eq "different from the old one" "$([ "$PW2" != "$PW1" ] && echo yes)" "yes"
rm -f "$ENTITLEMENT_DIR"/*.pem; : > "$SM_LOG"
ENTITLEMENT_PASSWORD="$PW1" run
assert_eq "old password rejected" "$RC" "1"
ENTITLEMENT_PASSWORD="$PW2" run
assert_eq "new password accepted" "$RC" "0"

echo "28: seal refuses weak passwords and multi-line values"
RH_ORG=1 RH_ACTIVATION_KEY=k ENTITLEMENT_PASSWORD=short run_seal
assert_eq "short password rejected" "$RC" "1"
assert_contains "explains" "$OUT" "too short"
RH_ORG=1 RH_ACTIVATION_KEY=$'a\nRH_ORG=evil' run_seal
assert_eq "newline in value rejected" "$RC" "1"

echo "29: a tampered bundle is rejected"
# Flip one ciphertext character to a different one. A bare s/./A/ is a no-op when
# the character already is "A" (about 1 run in 64, since every seal is salted).
cp "$ENTITLEMENT_BUNDLE" "$ENTITLEMENT_BUNDLE.orig"
first=$(sed -n '5s/^\(.\).*/\1/p' "$ENTITLEMENT_BUNDLE")
flipped=A; [ "$first" != A ] || flipped=B
sed -i "5s/./$flipped/" "$ENTITLEMENT_BUNDLE"
assert_eq "tamper changed the bundle" "$(cmp -s "$ENTITLEMENT_BUNDLE" "$ENTITLEMENT_BUNDLE.orig" && echo same || echo changed)" "changed"
rm -f "$ENTITLEMENT_DIR"/*.pem; : > "$SM_LOG"
ENTITLEMENT_PASSWORD="$PW2" run
assert_eq "exit 1" "$RC" "1"
assert_eq "nothing registered" "$(cat "$SM_LOG")" ""

echo "30: explicit env vars take priority over the bundle"
new_sandbox
RH_ORG=1 RH_ACTIVATION_KEY=k run_seal
export RH_ORG=override RH_ACTIVATION_KEY=overridekey RH_REGISTRY_USER=me RH_REGISTRY_PASSWORD=p
run
assert_contains "env org used" "$(cat "$SM_LOG")" "--org=override"

echo "31: a bundle without registry creds falls back to the interactive login"
new_sandbox
RH_ORG=1 RH_ACTIVATION_KEY=k run_seal
unset RH_ORG RH_ACTIVATION_KEY
ENTITLEMENT_PASSWORD="$(cat "$HOME/.config/submariner-release-management/entitlement-password")" run
assert_eq "exit 1 without a terminal" "$RC" "1"
assert_eq "failed login left no ~/.docker behind" "$([ -e "$HOME/.docker" ] && echo exists || echo none)" "none"
assert_contains "asks for registry env vars" "$OUT" "RH_REGISTRY_USER"
assert_contains "registration still happened" "$(cat "$SM_LOG")" "--org=1"
else
  echo "SKIP: gpg not installed, bundle tests not run"
fi

echo ""
echo "════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then echo "All $PASS tests passed"; else echo "$FAIL FAILED, $PASS passed"; exit 1; fi
