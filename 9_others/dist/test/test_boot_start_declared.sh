#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_boot_start_declared.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: every container the deploy declares for a VM comes back after a reboot,
# and the unit that does it runs once per boot, never on a shed (#1886).
#
# 2026-11-24 08:30Z, oci-analytics reset: fleet containers ship with restart
# "no", only tier1_services come back (tier1-watchdog). cloud-me-api and
# alerts-api are declared on the VM, are deliberately not tier-1 (they are the
# sheddable demand), and stayed Exited(255) until started by hand.
#
# Checks
#   1. Coverage: for every b_infra/nixhm-sudo-*/build.json VM, each declared
#      container (_home_manager.vms.<alias>.containers) is in tier1_services or
#      is covered by boot-start-declared.nix (imported by system-protection.nix
#      and built from that same declared list).
#   2. Unit: After=docker.service, Before the watchdog and the shedder, no
#      Requires/BindsTo/PartOf (a shed stop must not touch it, a docker start
#      must not re-run it), WantedBy the boot target only, activation never
#      starts it, memory limits, logger tag.
#   3. Script (rendered, driven with a stub docker): tier-1 first then the rest,
#      the compose `up -d --no-recreate --no-build --pull never` form, a gone
#      service dir is skipped, a missing container is not created, a second run
#      in the same boot is a no-op, never pull/rm/down/recreate.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
while [ ! -e "$ROOT/.git" ] && [ "$ROOT" != / ]; do ROOT=$(dirname "$ROOT"); done
MOD="$ROOT/b_infra/_shared/vm-pilot/src/modules/protection"
NIX="$MOD/boot-start-declared.nix"
CONS="$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
[ -f "$CONS" ] || { echo "FAIL: consolidated data not found: $CONS"; exit 1; }

echo "-- 1. coverage"
if [ -f "$NIX" ]; then
  grep -q 'boot-start-declared.nix' "$MOD/system-protection.nix" && ok "system-protection.nix imports boot-start-declared.nix" || bad "boot-start-declared.nix is not imported by system-protection.nix"
  grep -q 'vmData.containers or \[\]' "$NIX" && ok "module is built from the declared container list" || bad "module does not read _home_manager.vms.<vm>.containers"
  covered=1
else
  bad "boot-start-declared.nix does not exist"; covered=0
fi
checked=0
for f in "$ROOT"/b_infra/nixhm-sudo-*/build.json; do
  alias=$(jq -r '.vm.alias // empty' "$f"); [ -n "$alias" ] || continue
  for c in $(jq -r --arg a "$alias" '(._home_manager.vms[$a].containers // [])[]' "$CONS"); do
    checked=$((checked+1))
    if jq -e --arg c "$c" '(.protection.tier1_services // []) | index($c)' "$f" >/dev/null 2>&1; then :
    elif [ "$covered" = 1 ]; then :
    else bad "$alias declares '$c': neither tier-1 nor covered by a boot start"; fi
  done
done
[ "$checked" -ge 5 ] && ok "$checked declared containers checked across the fleet" || bad "only $checked declared containers found (query broken)"

echo "-- 2. unit"
if [ -f "$NIX" ]; then
  unit=$(awk '/boot-start-declared.service".text = /{f=1;next} f&&/^  '"''"';/{exit} f' "$NIX")
  [ -n "$unit" ] || bad "unit text not found"
  echo "$unit" | grep -qE '^ *After=.*docker\.service' && ok "ordered After=docker.service" || bad "not ordered After=docker.service"
  echo "$unit" | grep -qE '^ *Before=.*tier1-watchdog\.service' && echo "$unit" | grep -qE '^ *Before=.*load-shedder\.service' && ok "Before tier1-watchdog and load-shedder" || bad "not ordered Before tier1-watchdog/load-shedder"
  echo "$unit" | grep -qE '^ *(Requires|BindsTo|PartOf|Upholds|Requisite)=' && bad "unit has Requires/BindsTo/PartOf (a shed stop or docker start would re-trigger it)" || ok "no Requires/BindsTo/PartOf"
  [ "$(echo "$unit" | grep -cE '^ *WantedBy=')" = 1 ] && echo "$unit" | grep -qE '^ *WantedBy=multi-user\.target *$' && ok "WantedBy=multi-user.target only" || bad "WantedBy is not exactly multi-user.target"
  echo "$unit" | grep -qE '^ *Type=oneshot' && ok "Type=oneshot" || bad "not a one-shot"
  echo "$unit" | grep -qE '^ *TimeoutStartSec=' && echo "$unit" | grep -qE '^ *MemoryMax=' && ok "timeout and MemoryMax set" || bad "no TimeoutStartSec/MemoryMax"
  act=$(awk '/installBootStartDeclared/{f=1} f' "$NIX")
  echo "$act" | grep -E 'systemctl[^|]* (start|restart)' | grep -vq '^ *#' && bad "activation starts/restarts the unit (it must run at boot only)" || ok "activation never starts the unit"
  echo "$act" | grep -q 'systemctl enable boot-start-declared' && ok "activation enables the unit" || bad "activation does not enable the unit"
fi

echo "-- 3. script"
if [ -f "$NIX" ]; then
  awk '/boot-start-declared.sh" = \{/{f=1} f&&/text = '"''"'/{g=1;next} g&&/^    '"''"';/{exit} g' "$NIX" \
    | sed "s/''\\\${/\${/g; s/\\\${tier1List}/t1a t1b/; s/\\\${restList}/r1 gone r3 absent/; s/\\\${toString perContainerSecs}/90/; s/\\\${toString totalSecs}/330/; s/\\\${toString pauseSecs}/0/; s/\\\${toString minFreeMB}/0/" > "$WORK/bs.sh"
  bash -n "$WORK/bs.sh" 2>"$WORK/err" || { bad "rendered script does not parse: $(head -1 "$WORK/err")"; }
  grep -qE 'docker (pull|rm|rmi|down|stop|kill)|--force-recreate' "$WORK/bs.sh" && bad "script pulls/removes/stops/recreates" || ok "script never pulls, removes, stops or recreates"
  grep -q 'logger -t "\$TAG"' "$WORK/bs.sh" && grep -q 'TAG=boot-start-declared' "$WORK/bs.sh" && ok "logs via logger -t boot-start-declared" || bad "no logger -t boot-start-declared"
  mkdir -p "$WORK/bin" "$WORK/opt"
  for n in t1a t1b r1 r3; do mkdir -p "$WORK/opt/$n/compose"; : > "$WORK/opt/$n/compose/.secrets"; done
  cat > "$WORK/bin/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$WORK/calls"
case "\$1" in
  inspect)
    if [ "\$2" = "-f" ]; then c="\$4"; q="\$3"; else c="\$2"; q=""; fi
    [ "\$c" = absent ] && exit 1
    case "\$q" in
      *State.Running*) echo false ;;
      *'"com.docker.compose.project"'*) echo "p-\$c" ;;
      *'"com.docker.compose.project.working_dir"'*) echo "$WORK/opt/\$c" ;;
      *'"com.docker.compose.project.config_files"'*) echo "$WORK/opt/\$c/compose/docker-compose.yml" ;;
      *'"com.docker.compose.service"'*) echo "s-\$c" ;;
    esac ;;
  compose) exit 0 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/docker"
  printf '#!/bin/sh\nshift; exec "$@"\n' > "$WORK/bin/timeout"; chmod +x "$WORK/bin/timeout"
  printf '#!/bin/sh\necho "$*" >> %s/log\n' "$WORK" > "$WORK/bin/logger"; chmod +x "$WORK/bin/logger"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sleep"; chmod +x "$WORK/bin/sleep"
  : > "$WORK/calls"; : > "$WORK/log"
  export BOOT_START_STAMP="$WORK/stamp" BOOT_START_MIN_FREE_MB=0
  PATH="$WORK/bin:$PATH" bash "$WORK/bs.sh"; rc=$?
  check "script exits 0" "$rc" 0
  ups=$(grep '^docker compose' "$WORK/calls" | sed -E 's/.* up -d (.*)$/\1/' | tr '\n' ';')
  check "tier-1 first, then the rest; missing container and gone dir skipped" "$ups" "--no-recreate --no-build --pull never s-t1a;--no-recreate --no-build --pull never s-t1b;--no-recreate --no-build --pull never s-r1;--no-recreate --no-build --pull never s-r3;"
  grep '^docker compose' "$WORK/calls" | head -1 | grep -q -- "-p p-t1a --project-directory $WORK/opt/t1a -f $WORK/opt/t1a/compose/docker-compose.yml --env-file $WORK/opt/t1a/compose/.secrets up -d --no-recreate --no-build --pull never s-t1a" && ok "exact compose form from the labels" || bad "compose form differs from the watchdog's"
  # service dir gone -> skipped (r1 dir removed)
  rm -rf "$WORK/stamp" "$WORK/opt/r1"; : > "$WORK/calls"; : > "$WORK/log"
  PATH="$WORK/bin:$PATH" bash "$WORK/bs.sh"
  grep -q 'p-r1' "$WORK/calls" && grep -q '^docker compose.* s-r1$' "$WORK/calls" && bad "container with a gone service dir was started" || ok "gone service dir skipped"
  grep -q 'r1.*gone; skipped' "$WORK/log" && ok "skip is logged" || bad "skip not logged"
  # second run in the same boot is a no-op
  : > "$WORK/calls"
  PATH="$WORK/bin:$PATH" bash "$WORK/bs.sh"
  check "second run in the same boot starts nothing" "$(grep -c '^docker compose' "$WORK/calls")" 0
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
