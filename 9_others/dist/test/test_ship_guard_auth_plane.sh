#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_guard_auth_plane.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: cloud-ship-guard-auth-plane.sh keeps the auth plane out of every
# fan-out Ship (#1886).
#
# 2026-11-24: two fleet-wide Ships recreated authelia + authelia-redis and the
# gated edge was down twice (00:30-00:39Z and ~02:30-03:10Z). The auth plane
# (1_cicd/src/ship-auth-plane.json) must ship only when an operator names it,
# or when its own directory changed in a small push. Asserted against the real
# policy file, then against mutations of the guard that would reopen the hole.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-guard-auth-plane.sh"
POLICY="$REPO_ROOT/1_cicd/src/ship-auth-plane.json"
[ -f "$GUARD" ] && [ -f "$POLICY" ] || { echo "::error::guard or policy missing"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# The policy must name every auth-plane dir the incident took down.
for d in infra-sec_authelia infra-sec_introspect-proxy infra-sec_mcp-oauth infra-sec_caddy; do
  jq -e --arg d "$d" '.services | index($d)' "$POLICY" >/dev/null \
    || { echo "::error::$POLICY does not list $d"; exit 1; }
done
MAX=$(jq -r '.fanout_max' "$POLICY")
[ "$MAX" -ge 1 ] && [ "$MAX" -le 5 ] || { echo "::error::fanout_max=$MAX is not a small number"; exit 1; }

FLEET="infra-ai_cloudy-ai-api infra-api_cloud-infra-mcp infra-db_postlite infra-net_hickory-dns infra-sec_authelia infra-sec_caddy infra-sec_introspect-proxy infra-sec_introspect-proxy-go infra-sec_mcp-oauth user-comm_tools-stalwart"

run() {  # $1 guard, $2 mode, $3 candidates, $4 direct -> kept list
  (cd "$REPO_ROOT" && SHIP_CANDIDATES="$3" SHIP_DIRECT="$4" SHIP_HELD_OUT="$WORK/held" bash "$1" "$2" 2>/dev/null)
}
FAILED=0
check() {
  if [ "$3" = "$2" ]; then [ -n "${QUIET:-}" ] || echo "  ok   $1 → '$3'"
  else [ -n "${QUIET:-}" ] || echo "::error::$1 — expected '$2', got '${3:-<empty>}'"; FAILED=1; fi
}
run_suite() {
  local G="$1"; FAILED=0
  # The 45308011308 shape: a _shared/ change selected the whole fleet.
  check "fan-out from _shared/ holds every auth-plane dir" \
    "infra-ai_cloudy-ai-api infra-api_cloud-infra-mcp infra-db_postlite infra-net_hickory-dns user-comm_tools-stalwart" \
    "$(run "$G" auto "$FLEET" "")"
  check "held list names what was held" \
    "infra-sec_authelia infra-sec_caddy infra-sec_introspect-proxy infra-sec_introspect-proxy-go infra-sec_mcp-oauth" \
    "$(cat "$WORK/held")"
  # The fixed 734f4621: hickory's own build.json + caddy as a data reader.
  check "data-file reader caddy held, hickory (own change) ships" \
    "infra-net_hickory-dns" "$(run "$G" auto "infra-net_hickory-dns infra-sec_caddy" "infra-net_hickory-dns")"
  check "own directory changed in a small push ships" \
    "infra-sec_authelia" "$(run "$G" auto "infra-sec_authelia" "infra-sec_authelia")"
  check "own directory changed but inside a big fan-out is held" \
    "infra-ai_cloudy-ai-api infra-api_cloud-infra-mcp infra-db_postlite infra-net_hickory-dns user-comm_tools-stalwart" \
    "$(run "$G" auto "$FLEET" "infra-sec_authelia")"
  check "named explicitly (workflow_dispatch services=) ships" \
    "infra-sec_authelia infra-sec_caddy" "$(run "$G" explicit "infra-sec_authelia infra-sec_caddy" "")"
  check "non-auth services are never touched" \
    "infra-db_postlite user-comm_tools-stalwart" "$(run "$G" auto "infra-db_postlite user-comm_tools-stalwart" "")"
  check "only auth plane selected by fan-out -> empty (verdict=held upstream)" \
    "" "$(run "$G" auto "infra-sec_caddy infra-sec_caddy" "")"
  check "empty in, empty out" "" "$(run "$G" auto "" "")"
  [ "$FAILED" -eq 0 ]
}

echo "== guard as committed"
run_suite "$GUARD" || { echo "FAIL: auth-plane guard"; exit 1; }

# The guard must be wired into ship.yml on both the push path and services=all.
SHIP="$REPO_ROOT/1_cicd/src/cicd/ship.yml"
[ "$(grep -c 'cloud-ship-guard-auth-plane.sh auto' "$SHIP")" -ge 2 ] \
  || { echo "::error::ship.yml does not run the auth-plane guard on the push path AND services=all"; exit 1; }
grep -q 'verdict=held' "$SHIP" || { echo "::error::ship.yml lost verdict=held"; exit 1; }
echo "  ok   ship.yml runs the guard (push path + services=all) and emits verdict=held"

mutate() {
  local m="$WORK/$1.sh"
  sed -E "$2" "$GUARD" > "$m"
  cmp -s "$m" "$GUARD" && { echo "::error::mutation $1 did not change the guard (stale sed)"; exit 1; }
  if QUIET=1 run_suite "$m"; then echo "::error::mutation $1 survived"; exit 1; fi
  echo "  ok   mutation $1 caught"
}
echo "== mutations"
mutate fanout-keeps-auth   's/HELD="\$HELD \$d"; echo "auth-plane: \$d HELD \(selected by fan-out/KEPT="$KEPT $d"; echo "x (/'
mutate no-size-limit       's/if \[ "\$N" -le "\$MAX" \]; then/if true; then/'
mutate explicit-holds      's/if \[ "\$MODE" = explicit \]; then/if false; then/'
mutate empty-policy        's/^AUTH=.*$/AUTH=" "/'

echo "PASS: the auth plane ships only when named or when its own directory changed in a small push"
