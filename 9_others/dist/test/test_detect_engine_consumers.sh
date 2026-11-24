#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_detect_engine_consumers.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: cloud-ship-detect-engine-consumers.sh ships what a _shared/ change
# feeds, and only that.
#
# #451: `_shared/engine.nix` has first segment `_shared`, so the first-segment
# classifier mapped an engine-only commit to ZERO services and the run went
# green having built nothing. The fix derived the fan-out from each service's
# `import ../../_shared/engine.nix`.
#
# #1886: that fan-out then fired for EVERY _shared/ path. 734f4621 changed
# _shared/fleet-addressing.json (read by infra-sec_caddy alone) plus a test,
# Ship 45308011308 selected the whole fleet, and the gcp-proxy deploy took the
# auth plane down for ~40 minutes. Now only engine.nix and what it reads fan
# out; a data file ships the services that declare it; tests/docs ship nothing.
#
# Both directions are asserted on a fleet-shaped fixture, and each mutation of
# the detector that would bring an outage class back must turn the suite red.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-detect-engine-consumers.sh"
[ -f "$DETECT" ] || { echo "::error::$DETECT not found"; exit 1; }

FIXTURE=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$FIXTURE" "$WORK"' EXIT

# ── A fleet-shaped fixture ──────────────────────────────────────────────────
# engine_svc: imports the engine (a plain consumer)
# edge_svc:   imports the engine AND reads _shared/fleet-addressing.json from
#             a long nix file (the caddyfile.nix shape: >64 KiB after the
#             reference, so a `grep -q` pipeline would take SIGPIPE)
# quiet_svc:  never imports the engine; only MENTIONS the data file in a
#             comment and in build.json doc keys (not consumption)
# json_svc:   names _shared/mcp-manifest.json under a real build.json key
build_fixture() {
  rm -rf "$FIXTURE"; mkdir -p "$FIXTURE"
  cd "$FIXTURE"
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p a_solutions/_shared/jev-gate
  cat > a_solutions/_shared/engine.nix <<'NIX'
{ lib }:
let
  # see ./fleet-addressing.json -- a comment, not a read
  defaults = builtins.fromJSON (builtins.readFile ./compose-defaults.json);
  ceiling = import ./memory-ceiling.nix { };
in { engineMarker = "shared"; inherit defaults ceiling; }
NIX
  echo '{ }: { cap = "1G"; }' > a_solutions/_shared/memory-ceiling.nix
  echo '{"defaults":{}}' > a_solutions/_shared/compose-defaults.json
  echo '{"tiers":{}}' > a_solutions/_shared/fleet-addressing.json
  echo '{}' > a_solutions/_shared/mcp-manifest.json
  echo '{}' > a_solutions/_shared/oom-priority.json
  echo 'print(1)' > a_solutions/_shared/jev-gate/gate.py
  for svc in engine_svc edge_svc quiet_svc json_svc; do mkdir -p "a_solutions/$svc/src"; done
  cat > a_solutions/engine_svc/src/flake.nix <<'NIX'
{ engine = import ../../_shared/engine.nix; }
NIX
  cat > a_solutions/edge_svc/src/flake.nix <<'NIX'
{ engine = import ../../_shared/engine.nix; jev = ../../_shared/jev-gate; }
NIX
  {
    echo '{ lib }:'
    echo 'let fa = builtins.fromJSON (builtins.readFile ../../_shared/fleet-addressing.json); in'
    echo '{'
    i=0; while [ $i -lt 4000 ]; do echo "  route$i = \"reverse_proxy 10.0.0.1:$i\";"; i=$((i+1)); done
    echo '}'
  } > a_solutions/edge_svc/src/caddyfile.nix
  cat > a_solutions/quiet_svc/src/flake.nix <<'NIX'
{ lib }:
# routing tiers: see _shared/fleet-addressing.json (documentation only)
{ own = "no shared engine here"; }
NIX
  cat > a_solutions/quiet_svc/build.json <<'JSON'
{
  "_doc": "tiers come from _shared/fleet-addressing.json",
  "routes": [ { "reason": "explicit allowlist (_shared/fleet-addressing.json tiers.pub)" } ],
  "tests": { "fa": { "cmd": "node ../_shared/test-fleet-addressing.mjs" } },
  "guards": { "addressing": "_shared/test-fleet-addressing.mjs" }
}
JSON
  cat > a_solutions/json_svc/build.json <<'JSON'
{ "exposure": { "mcp": "_shared/mcp-manifest.json" } }
JSON
  git add -A >/dev/null; git commit -qm base
  cd - >/dev/null
}

resolve() {  # $1 = detector, $2 = changed path(s), one per line; stdout only
  local r
  r=$(cd "$FIXTURE" && printf '%s\n' "$2" | bash "$1" 2>/dev/null)
  printf '%s' "${r% }"
}

FAILED=0
check() {  # $1 = label   $2 = expected   $3 = actual
  if [ "$3" = "$2" ]; then
    [ -n "${QUIET:-}" ] || echo "  ok   $1 → '$3'"
  else
    [ -n "${QUIET:-}" ] || echo "::error::$1 — expected '$2', got '${3:-<empty>}'"
    FAILED=1
  fi
}

run_suite() {  # $1 = detector under test; returns non-zero when any check fails
  local D="$1"
  FAILED=0
  check "engine change ships every engine consumer, not the non-consumers" \
    "edge_svc engine_svc" "$(resolve "$D" $'_shared/engine.nix\n')"
  check "a file engine.nix READS is an engine file (compose-defaults.json)" \
    "edge_svc engine_svc" "$(resolve "$D" $'_shared/compose-defaults.json\n')"
  check "a file the engine imports transitively is an engine file (memory-ceiling.nix)" \
    "edge_svc engine_svc" "$(resolve "$D" $'_shared/memory-ceiling.nix\n')"
  # The #1886 commit, replayed: data file + its test + one service's build.json
  check "data file ships only its declared reader (734f4621 shape)" \
    "edge_svc" "$(resolve "$D" $'_shared/fleet-addressing.json\n_shared/test-fleet-addressing.mjs\n')"
  check "a value under a real build.json key is consumption" \
    "json_svc" "$(resolve "$D" $'_shared/mcp-manifest.json\n')"
  check "a file inside a directory a service imports ships that service" \
    "edge_svc" "$(resolve "$D" $'_shared/jev-gate/gate.py\n')"
  check "a data file nobody reads ships nothing (oom-priority.json)" \
    "" "$(resolve "$D" $'_shared/oom-priority.json\n')"
  check "_shared test/doc-only change ships nothing" \
    "" "$(resolve "$D" $'_shared/test-fleet-addressing.mjs\n_shared/test/no-sops-in-public.sh\n_shared/README.md\n')"
  check "non-_shared change ships nothing from this script" \
    "" "$(resolve "$D" $'quiet_svc/src/flake.nix\nengine_svc/build.json\n')"
  check "empty change set ships nothing" "" "$(resolve "$D" '')"
  [ "$FAILED" -eq 0 ]
}

build_fixture
echo "== detector as committed"
run_suite "$DETECT" || { echo "FAIL: engine-consumer detection"; exit 1; }

# The historical defect stays locked in: the old first-segment classifier
# resolves `_shared/engine.nix` to nothing, which is why this script exists.
OLD=$(printf '%s\n' '_shared/engine.nix' | grep -E '^[^/]+/(src/|build\.json$)' | awk -F/ '{print $1}' || true)
[ -z "$OLD" ] || { echo "::error::old regex unexpectedly resolves _shared/engine.nix"; exit 1; }

# stdout is the caller's contract: exactly the services, no reasoning text.
OUT=$(cd "$FIXTURE" && printf '_shared/fleet-addressing.json\n' | bash "$DETECT" 2>/dev/null)
[ "$OUT" = "edge_svc " ] || [ "$OUT" = "edge_svc" ] || { echo "::error::stdout contract broken: '$OUT'"; exit 1; }
echo "  ok   stdout carries only the ship list"

# ── Mutations: each must turn the suite red ─────────────────────────────────
mutate() {  # $1 = name, $2 = sed expression
  local m="$WORK/$1.sh"
  sed -E "$2" "$DETECT" > "$m"
  cmp -s "$m" "$DETECT" && { echo "::error::mutation $1 did not change the detector (stale sed)"; exit 1; }
  if QUIET=1 run_suite "$m"; then echo "::error::mutation $1 survived"; exit 1; fi
  echo "  ok   mutation $1 caught"
}
echo "== mutations"
# M1: every _shared/ path is an engine file again (the #1886 fan-out)
mutate every-shared-path-fans-out 's/if _in_engine "\$p"; then/if true; then/'
# M2: comments count as consumption (a "see _shared/x" note ships a service)
mutate comments-count-as-reads 's/sed -e .s\/\^\[\[:space:\]\]\*#\.\*\$\/\/. -e .s\/\[\[:space:\]\]#\.\*\$\/\/. "\$f"/cat "$f"/'
# M3: grep -q in the declaration pipeline (SIGPIPE turns a long file into a miss)
mutate grep-q-sigpipe 's/\| grep -E "\$pat" >\/dev\/null \\$/| grep -qE "$pat" \\/'
# M4: build.json doc keys count as consumption
mutate doc-keys-count 's/grep -vE .\"\(reason\|description\|note\|comment\|cmd\)\"\[\[:space:\]\]\*:./cat/'
# M5: test files are not CI-only any more (quiet_svc names one as a guard)
mutate tests-ship 's/_shared\/test-\*\|//'
# M6: the engine closure stops following engine.nix's reads
mutate no-engine-closure 's/^_queue="engine.nix"$/_queue=""/'

echo "PASS: _shared/ changes ship their real consumers, the engine fans out, tests/docs ship nothing"
