#!/bin/sh
# #1898: vm.swappiness is 10 on the gcp-proxy hub only (944 MB, edge routing); other VMs keep their tier.
# resource-bouncer.nix takes vmName from system-protection.nix; evaluated with nix when available.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D="$ROOT/b_infra/_shared/vm-pilot/src/modules/protection"
fail=0; ok(){ echo "  ok   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }
grep -q 'swappiness = if vmName == "gcp-proxy" then 10' "$D/resource-bouncer.nix" && ok "hub gets 10" || bad "hub swappiness 10 missing"
grep -q 'else if safeRamMB <= 2048 then 60 else 100' "$D/resource-bouncer.nix" && ok "other tiers keep 60/100" || bad "other tiers changed"
grep -q 'resource-bouncer.nix { inherit config pkgs lib ramMB vmName; }' "$D/system-protection.nix" && ok "vmName passed through" || bad "vmName not passed to resource-bouncer"
if command -v nix-instantiate >/dev/null 2>&1 && nix-instantiate --eval -E '(import <nixpkgs> {}).lib.version' >/dev/null 2>&1; then
  r() { nix-instantiate --eval --strict --json -E "
    let lib = (import <nixpkgs> {}).lib // { hm.dag.entryAfter = _: x: x; };
        m = import $D/resource-bouncer.nix { config = {}; pkgs = { e2fsprogs = null; }; inherit lib; ramMB = 1024; vmName = \"$1\"; };
    in m.home.file.\".local/share/system-protection/sysctl.conf\".text" | python3 -c 'import json,sys; print(json.load(sys.stdin))'; }
  r gcp-proxy | grep -q '^vm.swappiness = 10$' && ok "eval: gcp-proxy 10" || bad "eval: gcp-proxy not 10"
  r oci-mail | grep -q '^vm.swappiness = 60$' && ok "eval: oci-mail 60" || bad "eval: oci-mail changed"
fi
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
