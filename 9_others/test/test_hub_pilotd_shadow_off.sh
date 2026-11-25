#!/bin/sh
# #1898: the vm-pilotd shadow is switched off on the 944 MB gcp-proxy hub only (vm_pilotd_shadow=false in its
# protection block); every other VM keeps the shadow (default true). The activation stops it when disabled.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N="$ROOT/b_infra/_shared/vm-pilot/src/modules/agents/vm-pilotd.nix"
B="$ROOT/b_infra/nixhm-sudo-gcp-proxy/build.json"
fail=0; ok(){ echo "  ok   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }
grep -q 'cfg "vm_pilotd_shadow" true' "$N" && ok "default stays enabled" || bad "default not true"
grep -q 'systemctl disable --now vm-pilotd.service' "$N" && ok "disabled path stops the unit" || bad "no stop on disable"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["protection"]; sys.exit(0 if p.get("vm_pilotd_shadow") is False else 1)' "$B" \
  && ok "hub sets vm_pilotd_shadow=false" || bad "hub does not disable the shadow"
for v in oci-mail oci-analytics oci-apps; do
  f="$ROOT/b_infra/nixhm-sudo-$v/build.json"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])).get("protection",{}); sys.exit(1 if p.get("vm_pilotd_shadow") is False else 0)' "$f" && ok "$v keeps the shadow" || bad "$v shadow disabled"
done
[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
