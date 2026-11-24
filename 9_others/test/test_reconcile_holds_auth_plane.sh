#!/usr/bin/env bash
# #1886: a reconcile re-ship names services explicitly, so the Ship guard would
# take it as an operator ask. cloud-ship-reconcile-reship.sh must itself drop
# every auth-plane dir (1_cicd/src/ship-auth-plane.json), report it, and still
# re-ship the rest; a missing or empty policy must stop the re-ship.
# Mutations: the filter removed, and an empty policy, must both be caught.
set -euo pipefail
ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
S="$ROOT/1_cicd/src/scripts/cloud-ship-reconcile-reship.sh"
POL="$ROOT/1_cicd/src/ship-auth-plane.json"
CLS="$(jq -r '.reship_classes[0]' "$ROOT/9_others/ship-reconcile.json")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
printf 'gcp-proxy\tinfra-sec_authelia\t%s\tx\noci-apps\tuser-comm_ntfy\t%s\tx\ngcp-proxy\tinfra-sec_caddy-public\t%s\tx\n' "$CLS" "$CLS" "$CLS" > "$TMP/f.tsv"
run() { CLOUD_ROOT="$ROOT" SHIP_AUTH_PLANE_POLICY="$2" bash "$1" < "$TMP/f.tsv" 2>"$TMP/err"; }
check() { # $1 script  $2 policy  -> 0 when the hold holds
  out="$(run "$1" "$2")"
  [ "$out" = "user-comm_ntfy" ] || return 1
  grep -q "held out of the reconcile" "$TMP/err" || return 1
}
check "$S" "$POL" || { echo "RED: auth plane not held (got '$(run "$S" "$POL")')"; fail=1; }
jq -e '.services|index("infra-sec_caddy-public")' "$POL" >/dev/null || { echo "RED: infra-sec_caddy-public missing from the auth-plane hold"; fail=1; }
echo '{"services":[]}' > "$TMP/empty.json"
[ -z "$(run "$S" "$TMP/empty.json")" ] || { echo "RED: empty policy still re-shipped"; fail=1; }
sed '/^AUTH_HELD=/,/^fi$/d' "$S" > "$TMP/mut.sh"
if check "$TMP/mut.sh" "$POL"; then echo "RED mutation: filter removed but check green"; fail=1; fi
[ "$fail" = 0 ] && echo "OK reconcile holds the auth plane (caddy-public included); mutations caught"
exit "$fail"
