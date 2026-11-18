#!/usr/bin/env bash
# hm-zram-low-ram.test.sh — vm-pilot resource-bouncer.nix zram sizing.
#
# 2026-11-18 oci-mail (1 GB): 512 MB zram at 2.6:1, IO-PSI some ~61% from
# file refaults. VMs with a declared ram_gb <= 1 now get zram at 75% of RAM;
# bigger and unknown-size VMs keep 50%. Swappiness and disk-swap priority
# are unchanged.
#
# Checks:
#   1. rendered zram size: 1 GB → 768 MB, 24 GB → 12288 MB, unknown → 512 MB
#   2. swappiness is still 60 on 1 GB and 100 on 24 GB; zram prio 100, zstd
#   3. rendered script in a stub sysfs: fresh box → zram0 at full size;
#      live 512 MB zram0 → hot-adds one 256 MB device, no swapoff;
#      already at size → no change
#   4. activation restarts zram-setup.service only when the script changed
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
MOD="$REPO_ROOT/b_infra/_shared/vm-pilot/src/modules/protection/resource-bouncer.nix"
[ -f "$MOD" ] || { echo "::error::$MOD not found"; exit 1; }

FAIL=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hm-zram-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if ! command -v nix-instantiate >/dev/null 2>&1 \
   || ! nix-instantiate --eval -E '(import <nixpkgs> {}).lib.version' >/dev/null 2>&1; then
    # Static fallback when nix is unavailable on the runner
    grep -q 'lowRam = ramMB > 0 && ramMB <= 1024;' "$MOD" \
        && grep -q 'if lowRam then safeRamMB \* 3 / 4 else safeRamMB / 2' "$MOD" \
        && ok "static: 75% zram gated on declared ram_gb <= 1" || bad "static: zram gate missing"
    [ "$FAIL" -eq 0 ] && echo "PASS: hm zram low-ram (static)" || echo "FAIL: hm zram low-ram"
    exit "$FAIL"
fi

render() { # $1 = ramMB, $2 = home.file key (or "activation")
    local sel
    if [ "$2" = activation ]; then sel='m.home.activation.installResourceBouncer'
    else sel="m.home.file.\".local/share/system-protection/$2\".text"; fi
    nix-instantiate --eval --strict --json -E "
      let lib = (import <nixpkgs> {}).lib // { hm.dag.entryAfter = _: x: x; };
          m = import $MOD { config = {}; pkgs = { e2fsprogs = null; }; inherit lib; ramMB = $1; };
      in $sel" 2>&1 | python3 -c 'import json,sys; print(json.load(sys.stdin), end="")'
}

# 1. sizes
for case in "1024 768" "24576 12288" "0 512"; do
    set -- $case
    unit=$(render "$1" zram-setup.service)
    printf '%s' "$unit" | grep -q "Setup zram compressed swap ($2MB)" \
        && ok "ramMB=$1 → zram $2 MB" || bad "ramMB=$1: expected $2 MB" "$unit"
done
s1=$(render 1024 zram-setup.sh)
printf '%s' "$s1" | grep -q "WANT=$((768 * 1024 * 1024))$" && ok "1 GB script targets 768 MB" || bad "1 GB script WANT" "$s1"
printf '%s' "$(render 24576 zram-setup.sh)" | grep -q "WANT=$((12288 * 1024 * 1024))$" \
    && ok "24 GB script targets 12288 MB (50%, unchanged)" || bad "24 GB script WANT"

# 2. unchanged tiers
printf '%s' "$(render 1024 sysctl.conf)" | grep -q '^vm.swappiness = 60$' && ok "1 GB swappiness still 60" || bad "1 GB swappiness changed"
printf '%s' "$(render 24576 sysctl.conf)" | grep -q '^vm.swappiness = 100$' && ok "24 GB swappiness still 100" || bad "24 GB swappiness changed"
printf '%s' "$s1" | grep -q 'swapon -p 100 /dev/zram0' && printf '%s' "$s1" | grep -q 'swapon -p 100 /dev/zram\$ID' \
    && ok "zram devices at prio 100 (disk swapfile stays 10)" || bad "zram priority"
printf '%s' "$s1" | grep -q 'echo zstd > /sys/block/zram0/comp_algorithm' && ok "zstd" || bad "zstd missing"
printf '%s' "$s1" | grep -v '^ *#' | grep -q 'swapoff' && bad "script swaps off a live device" || ok "script never swaps off"

# 3. run the rendered script against a stub sysfs
mkdir -p "$WORK/bin"
for t in modprobe mkswap; do printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$t" > "$WORK/bin/$t"; done
cat > "$WORK/bin/swapon" <<'FAKE'
#!/bin/sh
case "$1" in
  --show*) cat "$ROOT/swaps" 2>/dev/null ;;
  -p) echo "$3" >> "$ROOT/swaps"; echo "swapon $*" >> "$LOG" ;;
esac
FAKE
chmod +x "$WORK/bin/"*
run_script() { # $1 = initial zram0 disksize (0 = none)
    ROOT="$WORK/root"; rm -rf "$ROOT"; mkdir -p "$ROOT/sys/block/zram0" "$ROOT/sys/class/zram-control"
    : > "$ROOT/swaps"; LOG="$WORK/log"; : > "$LOG"
    if [ "$1" -gt 0 ]; then echo "$1" > "$ROOT/sys/block/zram0/disksize"; echo /dev/zram0 > "$ROOT/swaps"; fi
    # hot_add hands out zram1 and creates its sysfs dir (a read in the kernel)
    mkdir -p "$ROOT/sys/block/zram1"; echo 1 > "$ROOT/sys/class/zram-control/hot_add"
    printf '%s' "$s1" | sed -e '/^export PATH=/d' -e "s|/sys/|$ROOT/sys/|g" > "$WORK/zram.sh"
    OUT=$(PATH="$WORK/bin:$PATH" ROOT="$ROOT" LOG="$LOG" bash "$WORK/zram.sh" 2>&1); RC=$?
}
MB=$((1024 * 1024))
run_script 0
[ "$RC" -eq 0 ] && [ "$(cat "$WORK/root/sys/block/zram0/disksize")" = "$((768 * MB))" ] \
   && grep -q 'swapon -p 100 /dev/zram0' "$WORK/log" \
    && ok "fresh box: zram0 = 768 MB at prio 100" || bad "fresh box: rc=$RC" "$OUT"
run_script $((512 * MB))
[ "$RC" -eq 0 ] && [ "$(cat "$WORK/root/sys/block/zram1/disksize" 2>/dev/null)" = "$((256 * MB))" ] \
   && grep -q 'swapon -p 100 /dev/zram1' "$WORK/log" && ! grep -q 'zram0' "$WORK/log" \
   && printf '%s' "$OUT" | grep -q 'Grew 512MB → 768MB (added zram1)' \
    && ok "live 512 MB zram0: hot-adds zram1 256 MB, zram0 untouched" || bad "live grow: rc=$RC" "$OUT"
run_script $((768 * MB))
[ "$RC" -eq 0 ] && ! grep -q 'swapon' "$WORK/log" && printf '%s' "$OUT" | grep -q 'Already active (768MB)' \
    && ok "already at size: no change" || bad "at size: rc=$RC" "$OUT"

# 4. activation re-runs the oneshot only on change
act=$(render 1024 activation)
printf '%s' "$act" | grep -q 'cmp -s "$SRC/zram-setup.sh" /opt/scripts/zram-setup.sh' \
   && printf '%s' "$act" | grep -q 'systemctl restart zram-setup.service' \
    && ok "activation restarts zram-setup.service when the script changed" || bad "activation restart-on-change missing"

[ "$FAIL" -eq 0 ] && echo "PASS: hm zram low-ram" || echo "FAIL: hm zram low-ram"
exit "$FAIL"
