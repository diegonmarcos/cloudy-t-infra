#!/usr/bin/env bash
# Test: "Ship → home-manager" plan job — an opt-in VM the run will not deploy
# gets NO matrix job, so it can never report a green it did not earn.
#
# 2026-11-18: run 44348642929's oci-mail job went green while the in-job
# opt-in gate skipped the deploy; it read as "deployed" and was not.
#
# Asserts:
#   1. cloud-ship-hm-matrix.sh (real opt-in helper, real repo tree)
#      - workflow_run / push on a shared-only change: oci-mail excluded, the
#        other three kept, gcp-proxy still last;
#      - push touching b_infra/nixhm-sudo-oci-mail/: oci-mail included;
#      - dispatch vm=oci-mail: exactly ["oci-mail"];
#      - dispatch vm=oci-apps: exactly ["oci-apps"];
#      - dispatch all + include_opt_in_vms=true: all four;
#      - dispatch all, include false: oci-mail excluded;
#      - opt-in helper error for a VM: that VM is kept (gate fails loud);
#      - empty HM_OPT_IN_VMS: all four (old behaviour).
#   2. Workflow wiring (source AND .github copy): deploy needs plan, its
#      matrix is fromJSON(needs.plan.outputs.vms), it is skipped on an empty
#      list, the in-job opt-in + authorization gates are still there, and the
#      plan job keeps the workflow_run-success guard.
#   3. Generated copies = source + banner.
set -eu

ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
M="$ROOT/1_cicd/src/scripts/cloud-ship-hm-matrix.sh"
SRC_WF="$ROOT/1_cicd/src/cicd/ship-home-manager.yml"
GEN_WF="$ROOT/.github/workflows/ship-home-manager.yml"
fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
FLEET="oci-analytics oci-mail oci-apps gcp-proxy"
CONS="1_cloud-configs/dist/_cloud-data-consolidated.json"

run() { # event dispatch_vm include paths...
  local ev="$1" dv="$2" inc="$3"; shift 3
  printf '%s\n' "$@" | HM_FLEET="$FLEET" HM_OPT_IN_VMS="${OPTIN_VMS-oci-mail}" HM_RELEVANCE_ROOT="$ROOT" \
    bash "$M" "$ev" "$dv" "$inc" 2>/dev/null
}
expect() { [ "$3" = "$2" ] && ok "$1 → $3" || bad "$1: want $2, got '$3'"; }

echo "1. cloud-ship-hm-matrix.sh"
THREE='["oci-analytics","oci-apps","gcp-proxy"]'
ALL='["oci-analytics","oci-mail","oci-apps","gcp-proxy"]'
expect "workflow_run, shared-only change" "$THREE" "$(run workflow_run "" "" "$CONS")"
expect "push, b_infra/_shared change"     "$THREE" "$(run push "" "" "b_infra/_shared/vm-pilot/src/modules/protection/resource-bouncer.nix")"
expect "push, oci-mail's own config"      "$ALL"   "$(run push "" "" "b_infra/nixhm-sudo-oci-mail/src/oci-mail.nix")"
expect "dispatch vm=oci-mail"             '["oci-mail"]' "$(run workflow_dispatch oci-mail false "")"
expect "dispatch vm=oci-apps"             '["oci-apps"]' "$(run workflow_dispatch oci-apps false "")"
expect "dispatch all, include_opt_in_vms=true" "$ALL" "$(run workflow_dispatch "" true "")"
expect "dispatch all, include false"      "$THREE" "$(run workflow_dispatch "" false "")"
expect "dispatch of an unknown VM"        '[]' "$(run workflow_dispatch nosuch-vm false "")"
OPTIN_VMS="" expect "empty HM_OPT_IN_VMS = old behaviour" "$ALL" "$(OPTIN_VMS="" run workflow_run "" "" "$CONS")"
# helper error (unknown event) → every VM kept, so the in-job gate fails loud
expect "opt-in helper error keeps the VM" "$ALL" "$(run schedule "" "" "")"
# missing helper → loud failure, never an empty (silently green) matrix
if printf '' | HM_FLEET="$FLEET" HM_OPTIN_SCRIPT=/nonexistent bash "$M" push "" "" >/dev/null 2>&1; then
  bad "missing opt-in helper exited 0"; else ok "missing opt-in helper fails loud"; fi

echo "2. workflow wiring"
for wf in "$SRC_WF" "$GEN_WF"; do
  n="${wf#"$ROOT/"}"
  python3 - "$wf" <<'PY' && ok "$n: plan → deploy wiring" || bad "$n: plan/deploy wiring"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); j = d["jobs"]; p, dep = j["plan"], j["deploy"]
assert dep["needs"] == "plan", "deploy must need plan"
assert dep["strategy"]["matrix"]["vm"] == "${{ fromJSON(needs.plan.outputs.vms) }}"
assert "needs.plan.outputs.vms != '[]'" in dep["if"], "empty list must skip deploy"
assert "workflow_run.conclusion == 'success'" in dep["if"] and "workflow_run.conclusion == 'success'" in p["if"]
assert p["outputs"]["vms"] == "${{ steps.matrix.outputs.vms }}"
assert p["env"]["HM_FLEET"].split() == ["oci-analytics", "oci-mail", "oci-apps", "gcp-proxy"]
assert d["env"]["HM_OPT_IN_VMS"] == "oci-mail"
assert dep["strategy"]["max-parallel"] == 1
run = next(s["run"] for s in p["steps"] if s.get("id") == "matrix")
assert "cloud-ship-hm-matrix.sh" in run and "cloud-ship-hm-supersede-range.sh paths" in run
gate = next(s["run"] for s in dep["steps"] if s.get("id") == "gate")
assert "cloud-ship-hm-vm-optin.sh" in gate and "cloud-ship-b-infra-deploy-authorization.sh" in gate
assert "cloud-ship-hm-path-relevance.sh" in gate and "cloud-ship-hm-supersede-range.sh paths" in gate
PY
done

echo "3. generated copies"
[ "$(tail -n +13 "$GEN_WF")" = "$(cat "$SRC_WF")" ] && ok ".github workflow matches its source" || bad ".github workflow drifted from source"
D="$ROOT/1_cicd/dist/scripts/cloud-ship-hm-matrix.sh"
if [ -x "$D" ] && [ "$(sed '2,14d' "$D")" = "$(cat "$M")" ]; then ok "dist helper matches its source"; else bad "dist cloud-ship-hm-matrix.sh missing, not executable or drifted"; fi
[ -x "$ROOT/.github/workflows/scripts/cloud-ship-hm-matrix.sh" ] && ok ".github scripts copy present" || bad ".github/workflows/scripts/cloud-ship-hm-matrix.sh missing"

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL" >&2; exit 1; }
