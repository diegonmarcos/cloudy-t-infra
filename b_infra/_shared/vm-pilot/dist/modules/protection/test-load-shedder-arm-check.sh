#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/protection/test-load-shedder-arm-check.sh
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Drives load-shedder-arm-check.sh against a scripted `systemctl` and `pgrep`.
#
# WHY: on 2026-10-01 oci-analytics wrote /run/load-shedder.deploy-failed while
# load-shedder.service was active — a `timeout 10 systemctl is-active` killed
# by load was read as "inactive". Both directions are pinned here:
#   slow-but-active must ARM, and a really inactive/failed unit must NOT.
#
# Each scenario lists one systemctl answer per `show` call: a state word, or
# SLOW (the stub sleeps past the timeout, so `timeout` kills it).
# Run:  sh test-load-shedder-arm-check.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/load-shedder-arm-check.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
case "$1" in
  show)
    n=$(( $(cat "$SCEN/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SCEN/n"
    a=$(echo "$ANSWERS" | awk -v n="$n" '{ print (n <= NF) ? $n : $NF }')
    [ "$a" = SLOW ] && exec sleep 5
    echo "$a" ;;
  restart) echo restart >> "$SCEN/restarts" ;;
esac
STUB
cat > "$TMP/bin/pgrep" <<'STUB'
#!/bin/sh
[ "${PROC_RUNNING:-0}" = 1 ]
STUB
chmod +x "$TMP/bin/systemctl" "$TMP/bin/pgrep"

# run NAME "ANSWERS" PROC_RUNNING → exit code of the check
run() {
  SCEN="$TMP/$1"; mkdir -p "$SCEN"
  SCEN="$SCEN" ANSWERS="$2" PROC_RUNNING="$3" PATH="$TMP/bin:$PATH" \
    sh "$CHECK" 4 1 0 >"$SCEN/out" 2>&1
}
restarts() { [ -f "$TMP/$1/restarts" ] && wc -l < "$TMP/$1/restarts" | tr -d ' ' || echo 0; }

run A "active" 0 && ok "A: active on first ask → armed" || bad "A: active unit not armed: $(cat "$TMP/A/out")"
run B "SLOW SLOW active" 0 && ok "B: systemctl slow twice, then active → armed (the 2026-10-01 false marker)" || bad "B: slow systemctl produced a false failure: $(cat "$TMP/B/out")"
run C "activating activating active" 0 && ok "C: activating → active → armed" || bad "C: $(cat "$TMP/C/out")"
run D "SLOW" 1 && ok "D: systemctl never answers, shedder process running → armed" || bad "D: $(cat "$TMP/D/out")"

run E "failed" 1 && bad "E: failed unit reported armed (real failure masked)" || ok "E: failed unit → NOT armed, even with a stray process"
[ "$(restarts E)" = 1 ] && ok "E: restarted exactly once" || bad "E: restarts=$(restarts E), want 1"
run F "inactive inactive active" 0 && ok "F: inactive → restart → active → armed" || bad "F: $(cat "$TMP/F/out")"
run G "SLOW" 0 && bad "G: no answer and no process reported armed" || ok "G: no answer and no process → NOT armed"
run H "failed SLOW SLOW SLOW" 1 && bad "H: a definitive 'failed' was overridden by later timeouts" || ok "H: definitive failed then timeouts → NOT armed"
run I "activating" 1 && bad "I: stuck activating reported armed" || ok "I: stuck activating → NOT armed"
grep -q 'NOT ARMED: load-shedder.service last state: activating' "$TMP/I/out" && ok "I: failure names the last state" || bad "I: unnamed failure: $(cat "$TMP/I/out")"

# The verdict above only matters if the activation uses it: the marker must be
# written on THIS script's failure, not on a bare systemctl call of its own.
NIX="$HERE/load-shedder.nix"
grep -q 'source = ./load-shedder-arm-check.sh;' "$NIX" && ok "nix: arm check is installed" || bad "nix: load-shedder-arm-check.sh is not installed by load-shedder.nix"
grep -q 'if $SUDO sh "$SRC/load-shedder-arm-check.sh"' "$NIX" && ok "nix: activation's ARMED/FAILED branch is the arm check's verdict" || bad "nix: activation does not branch on the arm check"
[ -z "$(grep -n 'is-active.*load-shedder' "$NIX")" ] && ok "nix: no bare is-active load-shedder check survives" || bad "nix: a bare systemctl is-active on load-shedder is still in the activation"

echo "--- load-shedder-arm-check: $([ $fail = 0 ] && echo GREEN || echo RED)"
exit $fail
