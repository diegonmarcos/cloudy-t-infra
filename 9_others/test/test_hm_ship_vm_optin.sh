#!/usr/bin/env bash
# Test: "Ship → home-manager" leaves OPT-IN VMs (oci-mail) alone unless asked,
# and every other VM behaves exactly as before.
#
# 2026-10-13: oci-mail (1 OCPU / 954MiB E2.1.Micro, the mail stack) took 6 HM
# runs in 3h. None of the triggering commits touched oci-mail's own config —
# every one was a gen-configs refresh of the SHARED consolidated artifact,
# which path-relevance (correctly, #662) treats as an input of every VM. Each
# run pulled the ~2GB nixhm-sudo-oci-mail image and activated for 36-64 min,
# on top of load 6-10 and io PSI ~78%.
#
# Asserts:
#   1. cloud-ship-hm-vm-optin.sh
#      - a non-opt-in VM always gets "deploy" (behaviour unchanged), whatever
#        the event and paths;
#      - oci-mail SKIPS a consolidated-only / shared-input / other-VM change;
#      - oci-mail DEPLOYS when b_infra/nixhm-sudo-oci-mail/ or its own
#        build-vm-oci-mail.json changes;
#      - dispatch: oci-mail only when vm=oci-mail or include_opt_in_vms=true;
#      - an unknown event fails loud.
#   2. Workflow wiring (source AND generated .github copy): HM_OPT_IN_VMS is
#      exactly "oci-mail", the declared fleet (plan.env.HM_FLEET) still lists
#      all four VMs in the same order (gcp-proxy last), the input defaults to false, and the opt-in
#      block runs BEFORE the authorization gate.
#   3. Generated copies are the source plus the banner, nothing else.
set -eu

ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
H="$ROOT/1_cicd/src/scripts/cloud-ship-hm-vm-optin.sh"
SRC_WF="$ROOT/1_cicd/src/cicd/ship-home-manager.yml"
GEN_WF="$ROOT/.github/workflows/ship-home-manager.yml"
CONS="1_cloud-configs/dist/_cloud-data-consolidated.json"
fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1" >&2; fail=1; }

# run <vm> <event> <dispatch_vm> <include> <paths...>
run() {
  local vm="$1" ev="$2" dv="$3" inc="$4"; shift 4
  printf '%s\n' "$@" | HM_OPT_IN_VMS="oci-mail" HM_RELEVANCE_ROOT="$ROOT" bash "$H" "$vm" "$ev" "$dv" "$inc" 2>&1
}
expect() { # <label> <want-prefix> <got>
  case "$3" in "$2"*) ok "$1";; *) bad "$1 (got '$3')";; esac
}

echo "1. opt-in helper"
for vm in oci-analytics oci-apps gcp-proxy; do
  for ev in push workflow_run; do
    expect "$vm $ev consolidated-only still deploys (unchanged)" "deploy not-opt-in" "$(run "$vm" "$ev" "" "" "$CONS")"
  done
  expect "$vm dispatch-all still deploys (unchanged)" "deploy not-opt-in" "$(run "$vm" workflow_dispatch "" false "")"
done
expect "oci-mail skips a consolidated-only refresh (the storm)" "skip" "$(run oci-mail workflow_run "" "" "$CONS")"
expect "oci-mail skips shared hm-config.json" "skip" "$(run oci-mail workflow_run "" "" "b_infra/_shared/modules/hm-config.json" "1_cloud-configs/src/inputs/hm-config.json")"
expect "oci-mail skips another VM's config" "skip" "$(run oci-mail push "" "" "b_infra/nixhm-sudo-oci-apps/src/oci-apps.nix" "1_cloud-configs/dist/build-vm-oci-apps.json")"
expect "oci-mail skips an empty change set" "skip" "$(run oci-mail push "" "" "")"
expect "oci-mail deploys on its own b_infra dir" "deploy own-config" "$(run oci-mail push "" "" "$CONS" "b_infra/nixhm-sudo-oci-mail/src/oci-mail.nix")"
if [ -e "$ROOT/1_cloud-configs/dist/build-vm-oci-mail.json" ]; then
  expect "oci-mail deploys on its own build-vm json" "deploy own-input" "$(run oci-mail workflow_run "" "" "1_cloud-configs/dist/build-vm-oci-mail.json")"
else
  bad "1_cloud-configs/dist/build-vm-oci-mail.json missing — cannot prove own-input detection"
fi
expect "oci-mail dispatch-all without include skips" "skip" "$(run oci-mail workflow_dispatch "" false "")"
expect "oci-mail dispatch vm=oci-mail deploys" "deploy dispatch-targeted" "$(run oci-mail workflow_dispatch oci-mail false "")"
expect "oci-mail dispatch include_opt_in_vms=true deploys" "deploy dispatch-include" "$(run oci-mail workflow_dispatch "" true "")"
if out=$(run oci-mail schedule "" "" ""); then bad "unknown event exited 0 ($out)"; else ok "unknown event fails loud"; fi
out=$(printf '%s\n' "$CONS" | HM_OPT_IN_VMS="" HM_RELEVANCE_ROOT="$ROOT" bash "$H" oci-mail workflow_run "" "" 2>&1)
expect "empty HM_OPT_IN_VMS = old behaviour for oci-mail too" "deploy not-opt-in" "$out"

echo "2. workflow wiring"
for wf in "$SRC_WF" "$GEN_WF"; do
  n="${wf#"$ROOT/"}"
  # HM_OPT_IN_VMS is workflow-level env since the plan job (2026-11-18), so the
  # matrix filter and the in-job gate read one value.
  grep -qE '^  HM_OPT_IN_VMS: "oci-mail"$' "$wf" && ok "$n: HM_OPT_IN_VMS is exactly oci-mail" || bad "$n: HM_OPT_IN_VMS not exactly \"oci-mail\""
  # The declared fleet moved to plan.env.HM_FLEET; the matrix reads plan's filtered list.
  grep -qF 'HM_FLEET: "oci-analytics oci-mail oci-apps gcp-proxy"' "$wf" && grep -qF 'vm: ${{ fromJSON(needs.plan.outputs.vms) }}' "$wf" \
    && ok "$n: fleet unchanged (all four, gcp-proxy last), matrix from plan" || bad "$n: fleet list or matrix wiring changed"
  grep -A4 -E '^      include_opt_in_vms:' "$wf" | grep -qE 'default: false' && ok "$n: include_opt_in_vms defaults to false" || bad "$n: include_opt_in_vms missing or not default false"
  l_opt=$(grep -n 'cloud-ship-hm-vm-optin.sh' "$wf" | head -1 | cut -d: -f1)
  l_auth=$(grep -n 'AUTH=".github/workflows/scripts/cloud-ship-b-infra-deploy-authorization.sh"' "$wf" | head -1 | cut -d: -f1)
  if [ -n "$l_opt" ] && [ -n "$l_auth" ] && [ "$l_opt" -lt "$l_auth" ]; then ok "$n: opt-in decided before authorization"; else bad "$n: opt-in block missing or after the auth gate ($l_opt vs $l_auth)"; fi
  grep -qF 'cloud-ship-hm-path-relevance.sh "$VM"' "$wf" && ok "$n: path-relevance still wired" || bad "$n: path-relevance call lost"
done

echo "3. generated copies = source + banner"
if [ "$(tail -n +13 "$GEN_WF")" = "$(cat "$SRC_WF")" ]; then ok ".github workflow matches its source"; else bad ".github/workflows/ship-home-manager.yml drifted from 1_cicd/src/cicd/ship-home-manager.yml"; fi
D="$ROOT/1_cicd/dist/scripts/cloud-ship-hm-vm-optin.sh"
if [ -x "$D" ] && [ "$(sed '2,14d' "$D")" = "$(cat "$H")" ]; then ok "dist helper matches its source"; else bad "1_cicd/dist/scripts/cloud-ship-hm-vm-optin.sh missing, not executable or drifted"; fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL" >&2; exit 1; }
