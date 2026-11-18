#!/usr/bin/env bash
# #1797: *.mesh.diegonmarcos.com must resolve through Hickory on wg0.
#
# On gcp-proxy the GCE drop-in sets DNS=169.254.169.254 and resolved used it
# as current server; it answers NXDOMAIN for mesh names. vm-pilot's
# dns-hickory.nix now installs hickory-mesh-dns.service, which gives the wg0
# link DNS=<primary> and the routing domain ~mesh.diegonmarcos.com.
#
# This renders the unit and the activation script from the Nix source
# (python, no nix needed), runs the activation in a scratch root with stubbed
# sudo/systemctl/resolvectl, and checks:
#   U  rendered unit: routing domain, DNS on wg0, BindsTo/After/WantedBy the
#      wg0 device unit, re-run on wg-quick@wg0, oneshot + RemainAfterExit
#   A  resolved active, wg0 present → unit written, enabled, started
#   I  second run → unit byte-equal, no second daemon-reload
#   N  resolved inactive → no unit
#   G  add-only: the activation never touches GCE resolver config
#   E  if nix is on PATH, the evaluated module's unit equals the python render
#
# DNS_HICKORY_NIX points it at a planted copy (mutation runs).
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SRC="${DNS_HICKORY_NIX:-$REPO_ROOT/b_infra/_shared/vm-pilot/src/modules/network/dns-hickory.nix}"
[ -f "$SRC" ] || { echo "::error::source not found: $SRC"; exit 1; }
command -v python3 >/dev/null || { echo "::error::python3 is required"; exit 1; }

PRI=10.0.0.1 DOM=mesh.diegonmarcos.com DEV=sys-subsystem-net-devices-wg0.device
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

python3 -I - "$SRC" "$T" "$PRI" <<'PY'
import re, sys, shlex, textwrap
src, out, pri = sys.argv[1:]
s = open(src).read()
def let(name):
    m = re.search(r"^\s*" + name + r' = "([^"]*)";', s, re.M)
    if m: return m.group(1)
    m = re.search(r"^\s*" + name + r' = [^;]* or "([^"]*)";', s, re.M)
    if m: return m.group(1)
    sys.exit("let binding not found: " + name)
v = {"primaryDns": pri, "meshDomain": let("meshDomain"), "meshIface": let("meshIface"),
     "meshUnitName": let("meshUnitName")}
v["meshDevUnit"] = let("meshDevUnit").replace("${meshIface}", v["meshIface"])
def sub(t):
    for k, x in v.items(): t = t.replace("${" + k + "}", x)
    return t
m = re.search(r"meshUnit = ''\n(.*?)\n  '';", s, re.S)
if not m: sys.exit("meshUnit not found")
unit = sub(textwrap.dedent(m.group(1)))
open(out + "/unit.rendered", "w").write(unit + "\n")
m = re.search(r"entryAfter \[\"configureHickoryDns\"\] ''\n(.*?)\n  '';", s, re.S)
if not m: sys.exit("mesh activation body not found")
b = m.group(1).replace("${lib.escapeShellArg meshUnit}", shlex.quote(unit))
b = sub(b).replace("''$", "$")
b = re.sub(r"(?<![\w/])/(run/current-system/sw/bin|usr/bin)/", "$R/bin/", b)
b = re.sub(r"(?<![\w/])/(usr/local/bin|usr/sbin|sbin|bin|run/wrappers/bin)/", "$R/none/", b)
b = re.sub(r"(?<![\w])/etc/", "$R/etc/", b)
b = re.sub(r"(?<![\w])/sys/", "$R/sys/", b)
open(out + "/activate.sh", "w").write(b + "\n")
PY
[ -s "$T/activate.sh" ] && [ -s "$T/unit.rendered" ] || { echo "::error::could not extract the mesh unit/activation"; exit 1; }
U="$T/unit.rendered"
line() { grep -cxF -- "$1" "$U" | tr -d ' '; }

echo "── #1797: wg0 routing domain for ~$DOM → Hickory ──"
ck "U: ExecStart sets the routing domain on wg0" "$(line "ExecStart=__RESOLVECTL__ domain wg0 ~$DOM")" "1"
ck "U: ExecStart sets DNS $PRI on wg0" "$(line "ExecStart=__RESOLVECTL__ dns wg0 $PRI")" "1"
ck "U: BindsTo the wg0 device" "$(line "BindsTo=$DEV")" "1"
ck "U: After the wg0 device + wg-quick@wg0" "$(grep -c "^After=.*$DEV.*wg-quick@wg0.service" "$U" | tr -d ' ')" "1"
ck "U: WantedBy wg0 device (re-applied when wg0 comes up)" "$(grep -c "^WantedBy=$DEV wg-quick@wg0.service\$" "$U" | tr -d ' ')" "1"
ck "U: oneshot" "$(line 'Type=oneshot')" "1"
ck "U: RemainAfterExit" "$(line 'RemainAfterExit=yes')" "1"
ck "U: no global DNS= override" "$(grep -c '^DNS=' "$U" | tr -d ' ')" "0"
ck "G: activation never names GCE config" "$(grep -c 'gce' "$T/activate.sh" | tr -d ' ')" "0"
ck "G: activation never deletes files" "$(grep -c 'rm ' "$T/activate.sh" | tr -d ' ')" "0"

mk() {  # mk <resolved 0|1> <wg0 0|1>
    R="$T/root-$1-$2"; rm -rf "$R"; mkdir -p "$R/bin" "$R/none" "$R/etc/systemd/system" "$R/sys/class/net"
    [ "$2" = 1 ] && mkdir -p "$R/sys/class/net/wg0"
    CALLS="$R/calls"; : > "$CALLS"
    printf '#!/bin/sh\nexec "$@"\n' > "$R/bin/sudo"
    printf '#!/bin/sh\necho "systemctl $*" >> "%s"\ncase "$1" in is-active) [ "%s" = 1 ];; *) exit 0;; esac\n' "$CALLS" "$1" > "$R/bin/systemctl"
    printf '#!/bin/sh\necho "resolvectl $*" >> "%s"\n' "$CALLS" > "$R/bin/resolvectl"
    chmod +x "$R/bin/"*
}
act() { OUT="$(R="$R" PATH="$R/bin:$PATH" bash "$T/activate.sh" 2>&1)"; }
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null | tr -d ' ' || true; }
UF() { echo "$R/etc/systemd/system/hickory-mesh-dns.service"; }

mk 1 1; act
ck "A: unit written" "$([ -f "$(UF)" ] && echo yes || echo no)" "yes"
ck "A: resolvectl path substituted" "$(grep -c "^ExecStart=$R/bin/resolvectl domain wg0 ~$DOM\$" "$(UF)" 2>/dev/null | tr -d ' ')" "1"
ck "A: no placeholder left" "$(grep -c '__RESOLVECTL__' "$(UF)" 2>/dev/null | tr -d ' ')" "0"
ck "A: daemon-reload once" "$(cnt 'systemctl daemon-reload')" "1"
ck "A: enabled" "$(cnt 'systemctl enable hickory-mesh-dns.service')" "1"
ck "A: started now (wg0 present)" "$(cnt 'systemctl restart hickory-mesh-dns.service')" "1"
ck "A: no FAILED" "$(case "$OUT" in *FAILED*) echo yes;; *) echo no;; esac)" "no"
first="$(cat "$(UF)")"
act
ck "I: unit byte-equal on second run" "$([ "$(cat "$(UF)")" = "$first" ] && echo yes || echo no)" "yes"
ck "I: no second daemon-reload" "$(cnt 'systemctl daemon-reload')" "1"

mk 1 0; act
ck "A0: unit written without wg0" "$([ -f "$(UF)" ] && echo yes || echo no)" "yes"
ck "A0: not started without wg0" "$(cnt 'systemctl restart')" "0"

mk 0 1; act
ck "N: resolved inactive → no unit" "$([ -e "$(UF)" ] && echo present || echo gone)" "gone"

if command -v nix-instantiate >/dev/null 2>&1; then
    EV="$(nix-instantiate --eval --strict --json -E "
      let lib = { hm.dag.entryAfter = _: x: x; escapeShellArg = x: x; };
          m = import $SRC { config = {}; inherit lib; pkgs = {}; };
      in m.home.activation.configureHickoryMeshDomain" 2>/dev/null \
      | python3 -I -c 'import json,sys,re; b=json.load(sys.stdin); m=re.search(r"TEMPLATE=(.*?)\n\s*WANT=", b, re.S); print(m.group(1) if m else "")')"
    ck "E: nix-evaluated unit equals python render" "$([ "$EV" = "$(cat "$U")" ] && echo yes || echo no)" "yes"
else
    echo "  skip E (nix-instantiate not on PATH)"
fi

echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
