#!/usr/bin/env bash
# Test: VMs fetch the watchdog from the release CI still publishes.
#
# cloudy-u-linux renamed my-watchdog to c3-watchdog. Its CI
# (.github/workflows/ship-c3-watchdog.yml) publishes the rolling release
# c3-watchdog-latest with assets c3-watchdog-x86_64 / c3-watchdog-aarch64.
# my-stack.nix kept fetching my-watchdog-latest, a release that froze on
# 2026-09-03, so every VM stayed on an old sampler: on oci-mail it ran
# `docker stats` every 30 s on a CPU-starved micro VM (2026-11-19).
#
# Checks on b_infra/_shared/vm-pilot/src/modules/agents/my-stack.nix:
#   1. the watchdog `get` line fetches c3-watchdog-latest;
#   2. its asset pattern is c3-watchdog-$suffix, and suffix covers both
#      arches CI builds (x86_64, aarch64);
#   3. it still installs as my-watchdog (the unit's ExecStart path);
#   4. no code line fetches the frozen my-watchdog-latest release.
#
# Run: bash 9_others/test/test_my_stack_watchdog_release.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
F="$ROOT/b_infra/_shared/vm-pilot/src/modules/agents/my-stack.nix"
[ -f "$F" ] || { echo "FAIL: missing $F"; exit 1; }
fail=0
code="$(grep -vE '^[[:space:]]*#' "$F")"

line="$(printf '%s\n' "$code" | grep -E '^[[:space:]]*get [^ ]+ +"[^"]*watchdog[^"]*" +[^ ]+' | head -n 1)"
if [ -z "$line" ]; then
  echo "FAIL: no watchdog get line in my-stack.nix"; exit 1
fi
read -r _ tag asset dest <<< "$line"
asset="${asset//\"/}"

[ "$tag" = "c3-watchdog-latest" ] && echo "ok:   fetches release c3-watchdog-latest" \
  || { echo "FAIL: fetches release '$tag', CI publishes c3-watchdog-latest"; fail=1; }
[ "$asset" = 'c3-watchdog-$suffix' ] && echo "ok:   asset pattern c3-watchdog-\$suffix" \
  || { echo "FAIL: asset pattern '$asset', CI publishes c3-watchdog-<arch>"; fail=1; }
[ "$dest" = "my-watchdog" ] && echo "ok:   installs as my-watchdog (unit ExecStart)" \
  || { echo "FAIL: installs as '$dest', the unit runs ~/.local/bin/my-watchdog"; fail=1; }
for arch in x86_64 aarch64; do
  printf '%s\n' "$code" | grep -qE "suffix=$arch" && echo "ok:   suffix maps to $arch" \
    || { echo "FAIL: no suffix=$arch (CI builds c3-watchdog-$arch)"; fail=1; }
done
printf '%s\n' "$code" | grep -q 'my-watchdog-latest' \
  && { echo "FAIL: a code line still fetches the frozen my-watchdog-latest"; fail=1; } \
  || echo "ok:   nothing fetches the frozen my-watchdog-latest"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
