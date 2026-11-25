#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_lowmem_pkgmgr_quiesced.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #1898: package-manager timers and PackageKit are quiesced (disabled, stopped, masked) on the low-memory
# VM class (ram_gb <= 1: gcp-proxy hub, oci-mail, oci-analytics) and left alone elsewhere.
# 2026-11-25 20:30-20:32Z on the 944 MB hub a dnf5 metadata refresh ran while containers were starting
# and health-agent / data-publisher timed out on start (serial console). Packages come from nix; none of
# these units has a function on a declaratively managed VM.
# Mutation: a default.nix that drops the quiesce wiring, and a list without dnf5-makecache, must be caught.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/b_infra/_shared/vm-pilot/src/modules"
fail=0; ok(){ echo "  ok   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }
chk() { # $1 default.nix
  grep -q 'lowMemVm = (vmData.specs.ram_gb or 99) <= 1;' "$1" || return 1
  grep -q 'systemd-control.nix { quiesce = lib.optionals lowMemVm packageManagerQuiesce; }' "$1" || return 1
  for u in dnf-makecache.timer dnf5-makecache.timer dnf-automatic.timer dnf5-automatic.timer packagekit.service; do
    grep -q "\"$u\"" "$1" || return 1
  done
}
chk "$M/default.nix" && ok "default.nix: low-memory class gets the quiesce list (dnf makecache/automatic, packagekit)" || bad "default.nix wiring/list incomplete"
S="$M/protection/systemd-control.nix"
grep -q 'systemctl mask "\$unit"' "$S" && grep -q 'systemctl stop --no-block "\$unit"' "$S" && grep -q 'systemctl cat "\$unit"' "$S" \
  && ok "systemd-control: stop + mask, only when the unit exists, timeout-capped" || bad "systemd-control quiesce loop missing"
grep -q 'extraBlacklist ? \[\], quiesce ? \[\]' "$S" && ok "default quiesce is empty (other VM classes untouched)" || bad "quiesce default not empty"
python3 -c 'import json,sys
c=json.load(open(sys.argv[1]))["_home_manager"]["vms"]
low=sorted(k for k,v in c.items() if (v.get("specs",{}).get("ram_gb") if v.get("specs",{}).get("ram_gb") is not None else 99)<=1)
print(" ".join(low)); sys.exit(0 if low==["gcp-proxy","oci-analytics","oci-mail"] else 1)' "$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json" >/dev/null \
  && ok "class = gcp-proxy, oci-analytics, oci-mail (oci-apps 24 GB untouched)" || bad "low-memory class changed; re-check the list"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
grep -v 'systemd-control.nix { quiesce' "$M/default.nix" > "$T/a.nix"; chk "$T/a.nix" && bad "mutation (wiring dropped) NOT caught" || ok "mutation: wiring dropped is caught"
sed 's/"dnf5-makecache.timer"//' "$M/default.nix" > "$T/b.nix"; chk "$T/b.nix" && bad "mutation (unit dropped) NOT caught" || ok "mutation: unit dropped is caught"
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
