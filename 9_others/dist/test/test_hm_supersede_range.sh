#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_hm_supersede_range.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_hm_supersede_range.sh — a newer "Ship → home-manager" run may supersede
# (cancel) an older QUEUED one only because its gate covers every change since
# the last run that covered the fleet.
#
# Incident 2026-10-14: 13 home-manager runs queued in ship-wg-runner (FIFO,
# workflow level) ahead of the Matomo/Dagu/wireguard/Caddy deploys. The newest
# queued run's own commit (a gen-configs refresh) touched nothing any VM's
# build reads, so under the HEAD^..HEAD gate it would have deployed NOTHING —
# "keep only the newest" would have dropped the older runs' deliveries.
#
# Under test:
#   1. cloud-ship-hm-supersede-range.sh `base`: which older run covered the
#      fleet (in flight or success; never cancelled/failed/skipped/dispatch).
#   2. `paths`: base..HEAD, every non-b_infra path, b_infra paths ONLY from
#      [deploy-fleet] commits (#414 consent is per commit), exit 3 when unknown.
#   3. End-to-end with the real path-relevance helper on a fixture repo: the
#      incident shape deploys with the range, skips without it.
#   4. Workflow wiring (source AND generated .github copy) + generated copies
#      equal source + banner.
#   5. Mutation: a base filter that counts cancelled runs as covering, or that
#      lets b_infra through without the marker, is caught.
set -uo pipefail
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SRC="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-hm-supersede-range.sh"
DIST="$REPO_ROOT/1_cicd/dist/scripts/cloud-ship-hm-supersede-range.sh"
REL="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-hm-path-relevance.sh"
WF_SRC="$REPO_ROOT/1_cicd/src/cicd/ship-home-manager.yml"
WF_GEN="$REPO_ROOT/.github/workflows/ship-home-manager.yml"
command -v jq >/dev/null || { echo "::error::needs jq"; exit 1; }
FAIL=0; PASS=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "── home-manager supersede range ──"

suite() {  # $1 = script under test; prints nothing, sets counters via ck
  S="$1"
  # ── 1. base selection ──
  RUNS='{"workflow_runs":[
    {"id":50,"event":"workflow_run","status":"completed","conclusion":"success","head_sha":"s50"},
    {"id":60,"event":"workflow_run","status":"completed","conclusion":"failure","head_sha":"s60"},
    {"id":70,"event":"workflow_dispatch","status":"completed","conclusion":"success","head_sha":"s70"},
    {"id":80,"event":"workflow_run","status":"completed","conclusion":"cancelled","head_sha":"s80"},
    {"id":85,"event":"workflow_run","status":"completed","conclusion":"skipped","head_sha":"s85"},
    {"id":90,"event":"push","status":"completed","conclusion":"cancelled","head_sha":"s90"},
    {"id":100,"event":"workflow_run","status":"queued","conclusion":null,"head_sha":"s100"},
    {"id":110,"event":"workflow_run","status":"completed","conclusion":"success","head_sha":"s110"}]}'
  ck "base skips cancelled/failed/skipped/dispatch runs" "$(printf '%s' "$RUNS" | bash "$S" base 95)" "s50"
  ck "an older run still in flight covers its commit" "$(printf '%s' "$RUNS" | bash "$S" base 105)" "s100"
  ck "newer runs never count" "$(printf '%s' "$RUNS" | bash "$S" base 55)" "s50"
  ck "no covering run -> empty" "$(printf '%s' "$RUNS" | bash "$S" base 50)" ""

  # ── 2/3. fixture repo ──
  R="$TMP/repo-$RANDOM"; mkdir -p "$R" && cd "$R" || return
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p 1_cloud-configs/dist b_infra/nixhm-sudo-oci-apps/dist b_infra/_shared
  echo '{}' > 1_cloud-configs/dist/_cloud-data-consolidated.json
  ln -s ../../../1_cloud-configs/dist/_cloud-data-consolidated.json b_infra/nixhm-sudo-oci-apps/dist/_cloud-data-consolidated.json
  echo a > b_infra/nixhm-sudo-oci-apps/a.nix; echo x > README
  git add -A && git commit -qm "c1 deployed"; C1=$(git rev-parse HEAD)
  echo '{"v":2}' > 1_cloud-configs/dist/_cloud-data-consolidated.json; git commit -qam "c2 gen-configs refresh"
  echo b > b_infra/nixhm-sudo-oci-apps/unmarked.nix; git add -A; git commit -qm "c3 b_infra no marker"
  echo c > b_infra/nixhm-sudo-oci-apps/marked.nix; git add -A; git commit -qm "c4 b_infra [deploy-fleet]"
  echo y >> README; git commit -qam "c5 newest: touches nothing a VM reads"
  printf '{"workflow_runs":[{"id":1,"event":"workflow_run","status":"completed","conclusion":"success","head_sha":"%s"},{"id":2,"event":"workflow_run","status":"completed","conclusion":"cancelled","head_sha":"x"}]}' "$C1" > runs.json
  OUT=$(HM_RANGE_RUNS_JSON=runs.json B_INFRA_DEPLOY_MARKER='[deploy-fleet]' bash "$S" paths 9 2>/dev/null); RC=$?
  ck "paths: exit 0 with a base" "$RC" "0"
  ck "paths: includes the superseded input change" "$(printf '%s\n' "$OUT" | grep -cx '1_cloud-configs/dist/_cloud-data-consolidated.json')" "1"
  ck "paths: includes b_infra of a [deploy-fleet] commit" "$(printf '%s\n' "$OUT" | grep -cx 'b_infra/nixhm-sudo-oci-apps/marked.nix')" "1"
  ck "paths: excludes b_infra of an unmarked commit (#414)" "$(printf '%s\n' "$OUT" | grep -cx 'b_infra/nixhm-sudo-oci-apps/unmarked.nix')" "0"
  echo '{"workflow_runs":[]}' > none.json
  HM_RANGE_RUNS_JSON=none.json B_INFRA_DEPLOY_MARKER='[deploy-fleet]' bash "$S" paths 9 >/dev/null 2>&1; ck "paths: unknown base -> exit 3 (caller keeps single-commit gate)" "$?" "3"
  # End to end with the real relevance helper (incident shape).
  ONE=$(git diff --name-only HEAD^ HEAD | HM_RELEVANCE_ROOT="$R" bash "$REL" oci-apps 2>/dev/null)
  ck "incident: newest commit alone -> VM skipped (the old gate)" "$ONE" ""
  WIDE=$(printf '%s\n' "$OUT" | HM_RELEVANCE_ROOT="$R" bash "$REL" oci-apps 2>/dev/null)
  ck "incident: with the range -> VM deploys" "${WIDE:+deploy}" "deploy"
  cd "$REPO_ROOT" || return
}

suite "$SRC"

# ── 4. wiring ──
for wf in "$WF_SRC" "$WF_GEN"; do
  n=$(basename "$(dirname "$wf")")/$(basename "$wf")
  # 2: the deploy gate AND the plan job (matrix opt-in filter, 2026-11-18)
  ck "$n: gate + plan call the range helper" "$(grep -c 'cloud-ship-hm-supersede-range.sh paths "${{ github.run_id }}"' "$wf")" "2"
  ck "$n: range hits skip the per-commit marker check only via KIND=range" "$(grep -c '"${KIND:-}" != "range"' "$wf")" "1"
  ck "$n: deploy + plan may list runs (actions: read)" "$(grep -c '^      actions: read' "$wf")" "2"
done
ck "generated workflow == banner + source" "$(tail -n +13 "$WF_GEN" | cmp -s - "$WF_SRC" && echo same)" "same"
ck "dist script == banner + source" "$(tail -n +15 "$DIST" | cmp -s - <(tail -n +2 "$SRC") && echo same)" "same"

# ── 5. mutation ──
M1="$TMP/m1.sh"; sed 's/select(.status != "completed" or .conclusion == "success")/select(true)/' "$SRC" > "$M1"
M2="$TMP/m2.sh"; sed 's/grep -qF -- "\$MARKER"/true/' "$SRC" > "$M2"
for m in "$M1" "$M2"; do
  f0=$FAIL; p0=$PASS; suite "$m" >/dev/null; f1=$FAIL; FAIL=$f0; PASS=$p0
  if [ "$f1" -gt "$f0" ]; then PASS=$((PASS+1)); echo "  ok   mutant $(basename "$m") killed"
  else FAIL=$((FAIL+1)); echo "  FAIL mutant $(basename "$m") SURVIVED"; fi
done

echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] && echo PASS || { echo FAILED; exit 1; }
