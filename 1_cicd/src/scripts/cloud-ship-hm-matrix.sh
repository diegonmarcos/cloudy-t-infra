#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-hm-matrix.sh — which VMs get a "Ship → home-manager"    ║
# ║ deploy job on this run?                                            ║
# ║                                                                    ║
# ║ Usage: cloud-ship-hm-matrix.sh <event> [dispatch_vm]               ║
# ║                                [dispatch_include] < changed-paths  ║
# ║   HM_FLEET       space-separated VMs, in deploy order (set in the  ║
# ║                  workflow; gcp-proxy last)                         ║
# ║   HM_OPT_IN_VMS  passed through to cloud-ship-hm-vm-optin.sh       ║
# ║   prints a JSON array of VMs (HM_FLEET order kept), e.g.           ║
# ║   ["oci-analytics","oci-apps","gcp-proxy"]; reasons go to stderr.  ║
# ║                                                                    ║
# ║ A VM is left out only when the run was never going to touch it:    ║
# ║   - a dispatch targets another VM (`vm` input), or                 ║
# ║   - cloud-ship-hm-vm-optin.sh says "skip" (opt-in VM not           ║
# ║     requested, or its own config did not change).                  ║
# ║ Every other VM keeps its job, and the in-job gate (authorization,  ║
# ║ path-relevance, the same opt-in check) decides exactly as before.  ║
# ║ If the opt-in helper errors for a VM, that VM is KEPT so the       ║
# ║ in-job gate fails loud on it, as it did before this pre-job.       ║
# ║                                                                    ║
# ║ Why (2026-11-18): the opt-in skip ran INSIDE the oci-mail job, so  ║
# ║ the job went green with no deploy (run 44348642929) and read as    ║
# ║ "deployed". A VM that is filtered out here gets no job at all.     ║
# ║ Test: 9_others/test/test_hm_ship_matrix.sh                         ║
# ╚════════════════════════════════════════════════════════════════════╝
set -Eeuo pipefail

EVENT="${1:?event name required as argument 1}"
DISPATCH_VM="${2:-}"
DISPATCH_INCLUDE="${3:-false}"
FLEET="${HM_FLEET:?HM_FLEET (space-separated VM list) required}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OPTIN="${HM_OPTIN_SCRIPT:-$HERE/cloud-ship-hm-vm-optin.sh}"
[ -f "$OPTIN" ] || { echo "::error::hm-matrix: opt-in helper missing ($OPTIN)" >&2; exit 2; }

PATHS="$(cat)"
out=""
for vm in $FLEET; do
  if [ -n "$DISPATCH_VM" ] && [ "$DISPATCH_VM" != "$vm" ]; then
    echo "::notice::hm-matrix: $vm left out — dispatch targets $DISPATCH_VM" >&2
    continue
  fi
  if dec=$(printf '%s\n' "$PATHS" | bash "$OPTIN" "$vm" "$EVENT" "$DISPATCH_VM" "$DISPATCH_INCLUDE"); then
    if [ "${dec%% *}" = "skip" ]; then
      echo "::notice::hm-matrix: $vm left out — ${dec#skip }" >&2
      continue
    fi
    echo "::notice::hm-matrix: $vm kept — ${dec#deploy }" >&2
  else
    echo "::warning::hm-matrix: opt-in helper failed for $vm — kept so its gate decides (and fails loud)" >&2
  fi
  out="${out:+$out,}\"$vm\""
done
printf '[%s]\n' "$out"
