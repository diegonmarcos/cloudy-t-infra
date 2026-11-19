#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_mail_health_exec_targets.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: the mail health report execs only into containers that exist.
#
# 1_cicd/src/ops/cloud-health-mail-full.sh runs its Gmail count, its maddy/
# Stalwart count and its send/receive round trip with `docker exec` / `docker
# cp` into named containers on oci-apps, and copies each script from an
# a_solutions/<dir>/ path. The #1450 rebrand merged cloud-mail-mcp into
# cloudy-apps-communication-mcp. The report kept the old name, so from then
# on every round trip ended "did not run — delivery unverified
# [docker-container-absent]" (2026-11-19, run 44444402900): mail delivery
# was never actually measured.
#
# Checks:
#   1. every container named after `docker exec [-i]` or before `:/` in
#      `docker cp` is a container_name in the consolidated fleet data;
#   2. no a_solutions/<dir> it reads is an archived/retired service dir:
#      each must be a service in the consolidated data.
#
# Run: bash 9_others/test/test_mail_health_exec_targets.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
CONS="$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json"
SCRIPT="$ROOT/1_cicd/src/ops/cloud-health-mail-full.sh"
fail=0

for f in "$CONS" "$SCRIPT"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

containers="$(jq -r '[paths(objects) as $p | getpath($p)
  | select(type == "object" and (.container_name | type) == "string")
  | .container_name] | unique | .[]' "$CONS")"
[ "$(printf '%s\n' "$containers" | grep -c .)" -ge 20 ] \
  || { echo "FAIL: container list from $CONS looks empty"; exit 1; }

# Code lines only (comments explain history and may name old containers).
code="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"

targets="$( {
  printf '%s\n' "$code" | grep -oE 'docker exec( -i)? [A-Za-z0-9_.-]+' | awk '{print $NF}'
  printf '%s\n' "$code" | grep -oE '[A-Za-z0-9_.-]+:/(app|tmp)/' | sed 's#:/.*##'
} | sort -u)"

[ -n "$targets" ] || { echo "FAIL: no docker exec/cp targets found in $SCRIPT"; exit 1; }
while IFS= read -r t; do
  if printf '%s\n' "$containers" | grep -qxF -- "$t"; then
    echo "ok:   exec/cp target '$t' is a declared container"
  else
    echo "FAIL: exec/cp target '$t' is not any declared container_name"
    fail=1
  fi
done <<< "$targets"

dirs="$(printf '%s\n' "$code" | grep -oE 'a_solutions/[A-Za-z0-9_.-]+/' | sed 's#a_solutions/##; s#/$##' | sort -u)"
services="$(jq -r '[paths(objects) as $p | getpath($p)
  | select(type == "object" and (.name | type) == "string") | .name] | unique | .[]' "$CONS")"
while IFS= read -r d; do
  [ -n "$d" ] || continue
  svc="${d#*_}"   # infra-api_cloudy-apps-communication-mcp -> cloudy-apps-communication-mcp
  if printf '%s\n' "$services" "$containers" | grep -qxF -- "$svc"; then
    echo "ok:   source dir '$d' is a live service"
  else
    echo "FAIL: source dir '$d' ($svc) is not a live service or container"
    fail=1
  fi
done <<< "$dirs"

printf '%s\n' "$code" | grep -q 'cloud-mail-mcp' \
  && { echo "FAIL: retired container cloud-mail-mcp is still referenced in code"; fail=1; } \
  || echo "ok:   no code line references the retired cloud-mail-mcp"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
