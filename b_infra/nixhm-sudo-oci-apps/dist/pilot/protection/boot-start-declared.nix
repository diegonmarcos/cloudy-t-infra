# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/boot-start-declared.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# protection/boot-start-declared.nix — bring the VM's declared containers back after a reboot
#
# Why (#1886 follow-up, 2026-11-24): the fleet ships every container with
# restart "no" (doctrine, cloudy-u-containers _shared/engine.nix), so after the
# 08:30Z reset of oci-analytics only the tier1_services came back (via
# tier1-watchdog). cloud-me-api and alerts-api are declared on that VM but are
# deliberately NOT tier-1 (they are the sheddable demand load-shedder needs, an
# empty shed set escalates to a full docker stop) and stayed Exited(255).
#
# What: a systemd one-shot, once per boot, After docker.service and Before
# tier1-watchdog/load-shedder, that starts every container the deploy declared
# for this VM, tier-1 first, then the rest, one at a time. Same restart form
# as tier1-watchdog (compose labels the deploy stamps):
#   docker compose -p <project> --project-directory <wd> -f <files> --env-file <secrets>
#       up -d --no-recreate --no-build --pull never <service>
# Never pull, recreate, build, down or rm. A container whose service dir is
# gone, or that does not exist, is skipped (it is never created here).
#
# What it must NOT do: run again on a shed. The unit has no Requires/BindsTo/
# PartOf on docker (a later `systemctl stop docker` by load-shedder does not
# touch it, and a docker start does not re-run it), it is WantedBy
# multi-user.target only, the activation never starts it, and the script
# leaves a stamp under /run (tmpfs, one per boot) so a manual re-start is a
# no-op. Names in /run/load-shedder.shed-list are skipped too.
#
# Data (single SoT, same as tier1-apps.nix): _home_manager.vms.<vm>.containers
# (declared containers) and protection.tier1_services (started first).
# Guard: 9_others/test/test_boot_start_declared.sh.
{ config, pkgs, lib, vmName, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  vmData       = (consolidated._home_manager.vms or {}).${vmName} or {};
  protDefaults = consolidated.native.protection or {};
  protVm       = vmData.protection or {};
  prot         = key: fallback: protVm.${key} or (protDefaults.${key} or fallback);

  tier1    = prot "tier1_services" [];
  declared = vmData.containers or [];
  rest     = builtins.filter (c: !(builtins.elem c tier1)) declared;
  ordered  = tier1 ++ rest;

  # Bounds: a 1 GB VM must not be overwhelmed by a thundering herd.
  perContainerSecs = prot "boot_start_per_container_secs" 90;
  totalSecs        = prot "boot_start_total_secs" 330;
  pauseSecs        = prot "boot_start_pause_secs" 5;
  minFreeMB        = prot "boot_start_min_free_mb" 64;

  tier1List = builtins.concatStringsSep " " tier1;
  restList  = builtins.concatStringsSep " " rest;
  hasAny    = ordered != [];
in
lib.mkIf hasAny {

  home.file.".local/share/system-protection/boot-start-declared.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Boot start of the declared containers (see boot-start-declared.nix).
      TIER1="${tier1List}"
      REST="${restList}"
      PER_CONTAINER=${toString perContainerSecs}   # seconds one compose up may take
      TOTAL=${toString totalSecs}                  # seconds for the whole run
      PAUSE=${toString pauseSecs}                  # seconds between two starts
      MIN_FREE_MB=''${BOOT_START_MIN_FREE_MB:-${toString minFreeMB}}  # MemAvailable needed to start a non-tier-1 container
      STAMP="''${BOOT_START_STAMP:-/run/boot-start-declared.done}"
      TAG=boot-start-declared

      # Once per boot: /run is tmpfs, so the stamp is gone after a reboot only.
      if [ -e "$STAMP" ]; then
        logger -t "$TAG" "already ran this boot; nothing to do (shed stops stay)"
        exit 0
      fi
      : > "$STAMP"
      START=$(date +%s)

      free_mb() { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0; }

      start_one() {
        _c="$1"; _tier="$2"
        if [ -r /run/load-shedder.shed-list ] && grep -qxF "$_c" /run/load-shedder.shed-list 2>/dev/null; then
          logger -t "$TAG" "[$_c] on the shed list; left stopped"; return 0
        fi
        if ! docker inspect "$_c" >/dev/null 2>&1; then
          logger -t "$TAG" "[$_c] no such container; skipped (never created here)"; return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$_c" 2>/dev/null)" = true ]; then
          logger -t "$TAG" "[$_c] already running"; return 0
        fi
        _lbl() { docker inspect -f "{{index .Config.Labels \"$1\"}}" "$_c" 2>/dev/null; }
        _proj=$(_lbl com.docker.compose.project); _wd=$(_lbl com.docker.compose.project.working_dir)
        _cfg=$(_lbl com.docker.compose.project.config_files); _svc=$(_lbl com.docker.compose.service)
        if [ -z "$_proj" ] || [ -z "$_svc" ] || [ -z "$_cfg" ]; then
          logger -t "$TAG" "[$_c] no compose labels; skipped"; return 0
        fi
        if [ ! -d "$_wd" ]; then
          logger -t "$TAG" "[$_c] service dir $_wd is gone; skipped"; return 0
        fi
        # Memory gate for the sheddable rest; tier-1 always goes ahead.
        if [ "$_tier" != 1 ]; then
          _w=0
          while [ "$(free_mb)" -lt "$MIN_FREE_MB" ] && [ "$_w" -lt 30 ]; do sleep 5; _w=$((_w + 5)); done
          if [ "$(free_mb)" -lt "$MIN_FREE_MB" ]; then
            logger -t "$TAG" "[$_c] only $(free_mb) MB available (< $MIN_FREE_MB); skipped, not started"; return 0
          fi
        fi
        _args=(-p "$_proj" --project-directory "$_wd")
        IFS=, read -r -a _files <<< "$_cfg"
        for _f in "''${_files[@]}"; do _args+=(-f "$_f"); done
        for _e in "$_wd/compose/.secrets" "$_wd/.secrets"; do
          [ -f "$_e" ] && { _args+=(--env-file "$_e"); break; }
        done
        if (cd "$_wd" && timeout "$PER_CONTAINER" docker compose "''${_args[@]}" up -d --no-recreate --no-build --pull never "$_svc") >/dev/null 2>&1; then
          logger -t "$TAG" "[$_c] started via compose (project $_proj, service $_svc)"
        else
          logger -t "$TAG" "[$_c] compose up failed or timed out after ''${PER_CONTAINER}s; left as is"
        fi
        sleep "$PAUSE"
      }

      logger -t "$TAG" "begin: tier-1 [$TIER1] then [$REST]"
      for _c in $TIER1; do
        [ $(( $(date +%s) - START )) -ge "$TOTAL" ] && { logger -t "$TAG" "total budget ''${TOTAL}s used; stopping before $_c"; break; }
        start_one "$_c" 1
      done
      for _c in $REST; do
        [ $(( $(date +%s) - START )) -ge "$TOTAL" ] && { logger -t "$TAG" "total budget ''${TOTAL}s used; stopping before $_c"; break; }
        start_one "$_c" 0
      done
      logger -t "$TAG" "done in $(( $(date +%s) - START ))s"
      exit 0
    '';
  };

  # Ordering: after docker, before the two units that act on containers. No
  # Requires/BindsTo/PartOf on docker (a shed stop of docker must not touch it
  # and a later docker start must not re-run it); WantedBy the boot target only.
  home.file.".local/share/system-protection/boot-start-declared.service".text = ''
    [Unit]
    Description=Boot start of the declared containers (once per boot, never on a shed)
    After=docker.service network-online.target
    Wants=docker.service
    Before=tier1-watchdog.service load-shedder.service
    ConditionPathExists=!/run/boot-start-declared.done
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/boot-start-declared.sh
    # Bounded: the watchdog and the shedder start after this unit finishes.
    TimeoutStartSec=420
    Slice=connectivity.slice
    OOMScoreAdjust=-800
    MemoryMin=8M
    # 128M like tier1-watchdog: the compose CLI alone is ~40 MB resident.
    MemoryMax=128M
    CPUWeight=1000
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  # Activation installs and enables the unit. It never starts it: the unit
  # runs at boot only, so a ship cannot touch a running container.
  home.activation.installBootStartDeclared = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[boot-start-declared] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[boot-start-declared] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/boot-start-declared.sh" /opt/scripts/boot-start-declared.sh
    $SUDO chmod +x /opt/scripts/boot-start-declared.sh
    $SUDO cp -f "$SRC/boot-start-declared.service" /etc/systemd/system/boot-start-declared.service
    echo "[boot-start-declared] step: daemon-reload"
    timeout 15 $SUDO systemctl daemon-reload || true
    echo "[boot-start-declared] step: enable (no start: boot only)"
    timeout 10 $SUDO systemctl enable boot-start-declared.service 2>/dev/null || true
    # Mark this boot as already done so nothing can re-run it now.
    $SUDO touch /run/boot-start-declared.done 2>/dev/null || true
    if [ "$(timeout 10 $SUDO systemctl is-enabled boot-start-declared.service 2>/dev/null)" = enabled ]; then
      echo "[boot-start-declared] ARMED ✓ (tier1 first: ${tier1List} | then: ${restList})"
    else
      echo "[boot-start-declared] WARNING: unit not enabled — declared containers will not come back after a reboot" >&2
    fi
    ) || echo "[boot-start-declared] activation error — check above"
  '';
}
