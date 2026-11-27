#!/usr/bin/env bash
# Test (#1983, rule 16): every layer of the shell mail full test exists in the Rust engine.
#
# 1_cicd/src/ops/cloud-health-mail-full.sh is the shell mail full test. Its layer 1 IS the Rust engine
# (cloud-mail-health-full, run on oci-apps); layers 2 (cross-store reconciliation against Gmail) and 3 (send/receive
# round-trip) are TypeScript/Python run through `docker exec`, not Rust. Until the Rust engine carries them as checks
# named below, the shell script stays (it is the only thing that runs them) and health_mail_full.yml must keep
# calling it. KNOWN_GAPS lists what is still missing; #1978 owns closing it.
#
# Fails when: a shell layer has no row in LAYERS (new layer, unmapped); a layer outside KNOWN_GAPS has no Rust marker;
# a KNOWN_GAPS layer already has its marker (stale list: delete the entry). `--require-parity` also fails while any
# gap remains: it is the gate before health_mail_full.yml may switch to the Rust engine alone.
# `--selftest` proves the test: each mutation of its inputs must turn it red.
#
# Run: bash 9_others/test/test_mail_full_rust_parity.sh [--require-parity|--selftest]   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
SHELL_SCRIPT="${PARITY_SHELL:-$ROOT/1_cicd/src/ops/cloud-health-mail-full.sh}"
ENGINE_SRC="${PARITY_RUST_SRC:-}"
if [ -z "$ENGINE_SRC" ]; then
  for c in "$ROOT/a_solutions/infra-obs_reports/src/src/cloud-mail-health-full/src" \
           "$ROOT/../cloudy-u-containers/infra-obs_reports/src/src/cloud-mail-health-full/src"; do
    [ -d "$c" ] && ENGINE_SRC="$c" && break
  done
fi

# layer number -> fixed string the Rust engine must contain (the check name the port uses)
declare -A LAYERS=(
  [1]='path_checks'
  [2]='Cross-store reconciliation'
  [3]='Send/receive round-trip'
)
KNOWN_GAPS="${PARITY_GAPS-2 3}"

run() {
  local require="$1" fail=0 n
  [ -f "$SHELL_SCRIPT" ] || { echo "FAIL: missing $SHELL_SCRIPT"; return 1; }
  [ -d "$ENGINE_SRC" ] || { echo "FAIL: Rust engine source not found (set PARITY_RUST_SRC)"; return 1; }
  while read -r n; do
    local m="${LAYERS[$n]:-}"
    if [ -z "$m" ]; then echo "FAIL: shell layer $n has no row in LAYERS (unmapped layer)"; fail=1; continue; fi
    local has=0; grep -rqF -- "$m" "$ENGINE_SRC" && has=1
    local gap=0; case " $KNOWN_GAPS " in *" $n "*) gap=1 ;; esac
    if [ $has = 1 ] && [ $gap = 1 ]; then echo "FAIL: layer $n is in the Rust engine ('$m') but still in KNOWN_GAPS: delete it"; fail=1
    elif [ $has = 0 ] && [ $gap = 0 ]; then echo "FAIL: layer $n has no Rust check named '$m' and is not a known gap"; fail=1
    elif [ $has = 1 ]; then echo "PARITY layer $n: '$m'"
    else echo "GAP    layer $n: '$m' is not in the Rust engine yet (#1978)"; [ "$require" = 1 ] && fail=1
    fi
  done < <(grep -oE '═══ [0-9]+\.' "$SHELL_SCRIPT" | grep -oE '[0-9]+')
  return $fail
}

selftest() {
  local t; t="$(mktemp -d)"; local bad=0
  cp "$SHELL_SCRIPT" "$t/sh.sh"; mkdir "$t/rs"; cp -r "$ENGINE_SRC/." "$t/rs/"
  echo 'echo "═══ 4. A new shell layer ═══"' >> "$t/sh.sh"
  PARITY_SHELL="$t/sh.sh" PARITY_RUST_SRC="$t/rs" bash "${BASH_SOURCE[0]}" >/dev/null && { echo "SURVIVED: an unmapped shell layer passed"; bad=1; }
  cp "$SHELL_SCRIPT" "$t/sh.sh"
  echo '// "Cross-store reconciliation"' >> "$t/rs/main.rs"
  PARITY_SHELL="$t/sh.sh" PARITY_RUST_SRC="$t/rs" bash "${BASH_SOURCE[0]}" >/dev/null && { echo "SURVIVED: a stale KNOWN_GAPS entry passed"; bad=1; }
  PARITY_SHELL="$t/sh.sh" PARITY_RUST_SRC="$ENGINE_SRC" PARITY_GAPS="3" bash "${BASH_SOURCE[0]}" >/dev/null && { echo "SURVIVED: a missing Rust check outside KNOWN_GAPS passed"; bad=1; }
  bash "${BASH_SOURCE[0]}" --require-parity >/dev/null && { echo "SURVIVED: --require-parity passed with gaps"; bad=1; }
  rm -rf "$t"
  [ $bad = 0 ] && echo "selftest: every mutation turned the test red"
  return $bad
}

case "${1:-}" in
  --selftest) selftest ;;
  --require-parity) run 1 ;;
  *) run 0 ;;
esac
