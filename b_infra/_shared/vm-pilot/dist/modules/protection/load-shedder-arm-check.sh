#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/protection/load-shedder-arm-check.sh
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# load-shedder-arm-check.sh — did load-shedder.service actually arm?
#
# Run by load-shedder.nix's activation (as root) right after the no-block
# restart. Exit 0 = armed, 1 = NOT armed (the caller writes
# /run/load-shedder.deploy-failed and pages).
#
# WHY a script of its own: on 2026-10-01 oci-analytics (1 CPU, 954M) logged
# "FAILED TO ARM" and wrote the failure marker while the unit was active. The
# old check was `timeout 10 systemctl is-active` twice: under load systemctl
# took longer than 10s to answer, `timeout` killed it, and a killed query was
# read as "inactive". A query that did not answer is UNKNOWN, not inactive.
#
# Verdict rules (a real failure is never masked):
#   active                       → armed
#   activating / reloading       → still coming up, ask again
#   no answer within TIMEOUT     → unknown, ask again (box is slow, not broken)
#   inactive / failed / other    → restart once, ask again; if that is still
#                                  the answer at the end → NOT armed
#   never a single answer across all ATTEMPTS → fall back to the process
#     itself: the shedder loop running IS the protection. No process → NOT armed.
#
# Usage: load-shedder-arm-check.sh ATTEMPTS TIMEOUT_SECS PAUSE_SECS
# Worst-case wall time ≈ ATTEMPTS × (TIMEOUT + PAUSE); activation must never block.
attempts="${1:?attempts}"; to="${2:?timeout}"; pause="${3:?pause}"
UNIT=load-shedder.service
SCRIPT=/opt/scripts/load-shedder.sh

restarted=0; answered=0; last="no answer"
i=1
while [ "$i" -le "$attempts" ]; do
  state="$(timeout "$to" systemctl show -p ActiveState --value "$UNIT" 2>/dev/null)" || state=""
  case "$state" in
    active)
      echo "armed: $UNIT active (check $i/$attempts)"; exit 0 ;;
    "")
      last="no answer from systemctl within ${to}s" ;;
    activating|reloading)
      answered=1; last="$state" ;;
    *)
      answered=1; last="$state"
      if [ "$restarted" = 0 ]; then
        restarted=1
        timeout "$to" systemctl restart --no-block "$UNIT" 2>/dev/null || true
      fi ;;
  esac
  i=$((i + 1))
  [ "$i" -le "$attempts" ] && sleep "$pause"
done

if [ "$answered" = 0 ] && pgrep -f "$SCRIPT" >/dev/null 2>&1; then
  echo "armed: systemctl never answered in $attempts checks, but $SCRIPT is running"
  exit 0
fi
echo "NOT ARMED: $UNIT last state: $last (after $attempts checks)" >&2
exit 1
