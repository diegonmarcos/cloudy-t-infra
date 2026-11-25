#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_tier1_watchdog_no_docker_requires.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #1898: tier1-watchdog.service must not hard-depend on docker.service.
# 2026-11-25 (run 45687530592, gcp-proxy): every activation printed "[tier1-watchdog] WARNING: failed to
# start (state: inactive)" with systemd "Dependency failed for tier1-watchdog.service ... result
# 'dependency'" (14:20:55Z and 20:12:01Z). The unit declared Requires=docker.service, so (a) a docker that
# could not start on the thrashing 944 MB hub failed the watchdog's start, and (b) the load-shedder's
# `systemctl stop docker` stopped the watchdog with it. The script itself is built for the docker-down
# window (it skips a cycle while docker.service is inactive), so the unit may only ORDER after docker.
# Mutation: the unit with Requires=docker.service put back must fail the check.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N="$ROOT/b_infra/_shared/vm-pilot/src/modules/protection/tier1-apps.nix"
fail=0; ok(){ echo "  ok   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }
# directive lines of the rendered unit: the .service text block, comments dropped
unit() { awk '/tier1-watchdog.service".text = /{f=1;next} f&&/^  '"''"';/{exit} f' "$1" | sed 's/^ *//' | grep -v '^#'; }
dep_lines() { unit "$1" | grep -E '^(Requires|Wants|BindsTo|PartOf|Requisite)=.*docker'; }
[ -n "$(unit "$N")" ] && ok "unit text extracted" || bad "unit text not found"
if dep_lines "$N" >/dev/null; then bad "tier1-watchdog.service has a hard dependency on docker: $(dep_lines "$N" | tr '\n' ' ')"; else ok "no Requires/Wants/BindsTo/PartOf on docker"; fi
unit "$N" | grep -q '^After=.*docker.service' && ok "ordered After=docker.service" || bad "After=docker.service missing"
grep -q 'systemctl is-active --quiet docker.service' "$N" && ok "script still skips a cycle while docker is down" || bad "script no longer handles docker down"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed 's/^    After=docker.service multi-user.target$/&\n    Requires=docker.service/' "$N" > "$T/mut.nix"
dep_lines "$T/mut.nix" >/dev/null && ok "mutation (Requires=docker.service back) is caught" || bad "mutation NOT caught"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
