#!/usr/bin/env bash
# #1797: the hub's own client resolver is set by vm-pilot's dns-hickory.nix.
#
# On a systemd-resolved host `resolvconf` is resolvectl's shim, and its `-a`
# needs a real interface: `resolvconf -a hickory` / `-a hickory-fallback`
# failed with "Failed to resolve interface ... No such device" and left
# /etc/resolv.conf unchanged (gcp-proxy home-manager Ship, run 44259524045).
#
# This extracts the SHIPPED activation script from the Nix source, points its
# absolute paths at a scratch root, stubs sudo/systemctl/resolvconf/chattr,
# and runs every branch:
#   A  resolved active (resolvconf = resolvectl shim) → drop-in with
#      DNS=<primary> / FallbackDNS=<fallback>, resolved restarted, resolvconf
#      never called
#   I  same host again → idempotent: drop-in unchanged, no second restart
#   B  no resolved, real resolvconf → `-a hickory` + `-a hickory-fallback`,
#      stale drop-in removed
#   C  no resolved, no resolvconf → direct write of resolv.conf (3 servers)
#   S  no resolved, only the resolvectl shim → direct write, shim never called
#
# DNS_HICKORY_NIX points it at a planted copy (mutation runs).
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SRC="${DNS_HICKORY_NIX:-$REPO_ROOT/b_infra/_shared/vm-pilot/src/modules/network/dns-hickory.nix}"
[ -f "$SRC" ] || { echo "::error::source not found: $SRC"; exit 1; }
command -v python3 >/dev/null || { echo "::error::python3 is required"; exit 1; }

PRI=10.0.0.1 FB=1.1.1.1
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# The activation body: text between the first `''` and the closing `'';`,
# Nix interpolations substituted, absolute paths moved under $R.
python3 -I - "$SRC" "$T/activate.sh" "$PRI" "$FB" <<'PY'
import re, sys
src, out, pri, fb = sys.argv[1:]
s = open(src).read()
m = re.search(r"entryAfter \[\"linkGeneration\"\] ''\n(.*?)\n  '';", s, re.S)
if not m: sys.exit("activation body not found")
b = m.group(1).replace("${primaryDns}", pri).replace("${fallbackDns}", fb)
b = b.replace("''$", "$")
# candidate binaries: the NixOS + /usr/bin paths → $R/bin (stubs), the rest → $R/none
b = re.sub(r"(?<![\w/])/(run/current-system/sw/bin|usr/bin)/", "$R/bin/", b)
b = re.sub(r"(?<![\w/])/(usr/local/bin|usr/sbin|sbin|bin|run/wrappers/bin)/", "$R/none/", b)
b = re.sub(r"(?<![\w])/etc/", "$R/etc/", b)
b = re.sub(r"(?<![\w])/run/systemd/", "$R/run/systemd/", b)
open(out, "w").write(b + "\n")
PY
[ -s "$T/activate.sh" ] || { echo "::error::could not extract the activation script"; exit 1; }

# mk <resolved:0|1> <resolvconf: none|real|shim>
mk() {
    R="$T/root-$1-$2"; rm -rf "$R"; mkdir -p "$R/bin" "$R/none" "$R/etc/systemd" "$R/run/systemd/resolve"
    CALLS="$R/calls"; : > "$CALLS"
    printf '#!/bin/sh\nexec "$@"\n' > "$R/bin/sudo"
    printf '#!/bin/sh\necho "systemctl $*" >> "%s"\ncase "$1" in is-active) [ "%s" = 1 ];; *) exit 0;; esac\n' "$CALLS" "$1" > "$R/bin/systemctl"
    printf '#!/bin/sh\necho "chattr $*" >> "%s"\n' "$CALLS" > "$R/bin/chattr"
    case "$2" in
      real) printf '#!/bin/sh\necho "resolvconf $* <$(cat)>" >> "%s"\n' "$CALLS" > "$R/bin/resolvconf" ;;
      shim) printf '#!/bin/sh\necho "resolvconf $*" >> "%s"\necho "Failed to resolve interface \\"$2\\": No such device" >&2; exit 1\n' "$CALLS" > "$R/bin/resolvectl"
            chmod +x "$R/bin/resolvectl"; ln -s resolvectl "$R/bin/resolvconf" ;;
    esac
    chmod +x "$R/bin/"*
    ln -s ../run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
    printf 'nameserver 127.0.0.53\n' > "$R/run/systemd/resolve/stub-resolv.conf"
}
act() { OUT="$(R="$R" PATH="$R/bin:$PATH" bash "$T/activate.sh" 2>&1)"; }
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null | tr -d ' ' || true; }
has() { case "$OUT" in *"$1"*) echo yes ;; *) echo no ;; esac; }
DROP() { echo "$R/etc/systemd/resolved.conf.d/hickory.conf"; }

echo "── #1797: hickory client resolver on resolved and non-resolved hosts ──"

mk 1 shim; act
ck "A: drop-in written" "$([ -f "$(DROP)" ] && echo yes || echo no)" "yes"
ck "A: DNS=<primary>" "$(grep -c "^DNS=$PRI\$" "$(DROP)" 2>/dev/null)" "1"
ck "A: FallbackDNS starts with <fallback>" "$(grep -c "^FallbackDNS=$FB\( \|\$\)" "$(DROP)" 2>/dev/null)" "1"
ck "A: [Resolve] section" "$(grep -c '^\[Resolve\]$' "$(DROP)" 2>/dev/null)" "1"
ck "A: resolved restarted once" "$(cnt 'systemctl restart systemd-resolved')" "1"
ck "A: resolvconf shim never called" "$(cnt '^resolvconf')" "0"
ck "A: no 'No such device'" "$(has 'No such device')" "no"
ck "A: no FAILED" "$(has 'FAILED')" "no"
ck "A: stub resolv.conf left as a symlink" "$([ -L "$R/etc/resolv.conf" ] && echo yes || echo no)" "yes"
first="$(cat "$(DROP)")"

act
ck "I: second run keeps the drop-in byte-equal" "$([ "$(cat "$(DROP)")" = "$first" ] && echo yes || echo no)" "yes"
ck "I: second run does not restart resolved again" "$(cnt 'systemctl restart systemd-resolved')" "1"
ck "I: second run says already current" "$(has 'already current')" "yes"

mk 0 real; mkdir -p "$R/etc/systemd/resolved.conf.d"; echo stale > "$(DROP)"; act
ck "B: resolvconf -a hickory <primary>" "$(cnt "resolvconf -a hickory <nameserver $PRI>")" "1"
ck "B: resolvconf -a hickory-fallback <fallback>" "$(cnt "resolvconf -a hickory-fallback <nameserver $FB>")" "1"
ck "B: resolved not restarted" "$(cnt 'systemctl restart')" "0"
ck "B: stale drop-in removed" "$([ -e "$(DROP)" ] && echo present || echo gone)" "gone"

mk 0 none; act
ck "C: resolv.conf is a regular file" "$([ -f "$R/etc/resolv.conf" ] && [ ! -L "$R/etc/resolv.conf" ] && echo yes || echo no)" "yes"
ck "C: resolv.conf servers in order" "$(grep '^nameserver' "$R/etc/resolv.conf" | awk '{print $2}' | paste -sd, -)" "$PRI,$FB,8.8.8.8"
ck "C: made immutable" "$(cnt 'chattr +i')" "1"
ck "C: no drop-in" "$([ -e "$(DROP)" ] && echo present || echo gone)" "gone"

mk 0 shim; act
ck "S: shim without resolved is not called" "$(cnt '^resolvconf')" "0"
ck "S: falls back to direct write" "$(grep -c "^nameserver $PRI\$" "$R/etc/resolv.conf" 2>/dev/null)" "1"
ck "S: no 'No such device'" "$(has 'No such device')" "no"

echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
