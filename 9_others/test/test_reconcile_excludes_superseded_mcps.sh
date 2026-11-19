#!/usr/bin/env bash
# Tester: the reconcile's absent/stopped redeploy never starts a superseded #1450 MCP.
#
# THE DEFECT (2026-11-19 08:10): infra-api_cloud-mail-mcp and its replacement
# infra-api_cloudy-apps-communication-mcp both declare port 3103 on oci-apps (host
# network). The old one was started again, bound 3103 first, and the merged MCP died
# with EADDRINUSE; restart is "no" fleet-wide, so every mail tool stayed down until a
# manual start. The old container is `stopped` after each eviction, and `stopped` is
# exactly what cloud-ship-reconcile-absent-redeploy.sh restarts, so it must be excluded.
# Ship is held separately by build.ship_hold in cloudy-u-containers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CFG="$ROOT/9_others/ship-reconcile.json"
SCRIPT="$ROOT/1_cicd/src/scripts/cloud-ship-reconcile-absent-redeploy.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }

for d in infra-api_cloud-mail-mcp infra-api_cloud-drive-mcp; do
  r="$(jq -r --arg d "$d" '.absent_redeploy.exclude[$d] // empty' "$CFG")"
  if [ -n "$r" ]; then ok "$d is excluded from the absent/stopped redeploy"; else bad "$d missing from absent_redeploy.exclude"; fi
  case "$r" in *"#1450"*) ok "$d exclusion names #1450" ;; *) bad "$d exclusion does not name #1450" ;; esac
done

# The exclusion is keyed by the service DIRECTORY and the script looks it up that way.
if grep -q '.absent_redeploy.exclude\[\$d\]' "$SCRIPT"; then ok "redeploy script reads exclude by service dir"; else bad "redeploy script no longer reads exclude[\$d]"; fi
# ...and it applies to `stopped` as well as `absent` findings.
if grep -q '\$3=="absent" || \$3=="stopped"' "$SCRIPT"; then ok "stopped findings go through the same exclusion"; else bad "stopped findings no longer share the absent path"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
