#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_tier1_names_are_containers.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: every tier-1 service name declared for a VM is a real container name.
#
# The tier-1 watchdog and the load-shedder match these names against
# `docker ps` names. The #1450 API rebrand renamed two containers
# (git-proxy-api -> cloudy-drive-git-proxy-api, c3-infra-api ->
# cloudy-c3-api), but the per-VM tier1_services lists kept the old names.
# The effect (2026-11-18, oci-analytics):
#   - the watchdog reported "git-proxy-api not running ... CIRCUIT OPEN;
#     paging" for a service that was up and healthy under its new name;
#   - the real container was no longer tier-1, so the load-shedder could
#     stop it. Its compose sets restart: "no", so after a shed it stays down
#     (the 2026-09-29 80-minute 502 that made it tier-1 in the first place).
#
# Source of the names: tier1_services in b_infra/nixhm-sudo-*/build.json (the
# file a human edits). Source of the containers: every container_name in the
# consolidated fleet data (1_cloud-configs/dist/_cloud-data-consolidated.json).
#
# Run: bash 9_others/test/test_tier1_names_are_containers.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
CONS="$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json"
fail=0

[ -f "$CONS" ] || { echo "FAIL: consolidated data not found: $CONS"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

containers="$(jq -r '[paths(objects) as $p | getpath($p)
  | select(type == "object" and (.container_name | type) == "string")
  | .container_name] | unique | .[]' "$CONS")"
n_cont=$(printf '%s\n' "$containers" | grep -c .)
if [ "$n_cont" -lt 20 ]; then
  echo "FAIL: only $n_cont container names found in $CONS (the query is broken)"
  exit 1
fi

checked=0
for f in "$ROOT"/b_infra/nixhm-sudo-*/build.json; do
  vm=$(jq -r '.vm.alias // empty' "$f")
  names=$(jq -r '(.protection.tier1_services // [])[]' "$f")
  [ -n "$names" ] || continue
  while IFS= read -r name; do
    checked=$((checked + 1))
    if printf '%s\n' "$containers" | grep -qxF -- "$name"; then
      echo "ok:   $vm tier-1 '$name' is a declared container"
    else
      echo "FAIL: $vm tier-1 '$name' is not any declared container_name ($f)"
      fail=1
    fi
  done <<< "$names"
done

if [ "$checked" -eq 0 ]; then
  echo "FAIL: no tier1_services found in any b_infra/nixhm-sudo-*/build.json"
  exit 1
fi

# The two #1450 renames, checked by name so a revert is caught even if the
# old name were ever re-declared somewhere as a container.
ana="$ROOT/b_infra/nixhm-sudo-oci-analytics/build.json"
apps="$ROOT/b_infra/nixhm-sudo-oci-apps/build.json"
jq -e '.protection.tier1_services | index("cloudy-drive-git-proxy-api")' "$ana" >/dev/null \
  && echo "ok:   oci-analytics keeps the git proxy (cloudy-drive-git-proxy-api) in tier-1" \
  || { echo "FAIL: oci-analytics tier-1 lacks cloudy-drive-git-proxy-api"; fail=1; }
jq -e '.protection.tier1_services | index("cloudy-c3-api")' "$apps" >/dev/null \
  && echo "ok:   oci-apps keeps the C3 API (cloudy-c3-api) in tier-1" \
  || { echo "FAIL: oci-apps tier-1 lacks cloudy-c3-api"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS ($checked tier-1 names)" || echo "FAILED"
exit "$fail"
