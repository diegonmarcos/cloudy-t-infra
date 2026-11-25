# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/tier1-apps.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# protection/tier1-apps.nix — tier-1 app cgroup reservations + auto-restart
#
# Phase 2 of the "Island + tier-1 apps" bulletproofing plan (2026-07-07).
#
# For each VM's tier1_services list (data-driven from the consolidated JSON):
#   1. Creates tier1.slice — a cgroup sub-slice with MemoryMin (reserved,
#      unreclaimable) + MemoryHigh so containers that opt in (compose
#      `cgroup_parent: tier1.slice`) survive memory pressure alongside the
#      connectivity island.
#   2. Installs a scoped tier1-watchdog.service that checks tier-1 containers
#      every tier1_check_interval_secs and restarts them if stopped — but with a
#      circuit breaker: after tier1_max_restarts consecutive restarts it stops
#      trying and sends a page-level ntfy alert. This is the one deliberate
#      carve-out from the no-auto-restart doctrine, scoped to critical
#      containers only, rate-limited and circuit-broken.
#
# Complementary to load-shedder.nix: when load-shedder sheds non-tier1 first,
# tier-1 containers survive; when docker as a whole is shed (last resort),
# tier1-watchdog brings tier-1 back after docker recovers.
#
# Data source (P4, single SoT): config.json native.protection (defaults) +
# b_infra/nixhm-sudo-<alias>/build.json .protection (per-VM overrides), emitted
# by 9_others into consolidated native.protection + _home_manager.vms.<vmName>.protection.
{ config, pkgs, lib, vmName, ... }:

let
  # Data-driven (P4): SoT = config.json native.protection (defaults) + per-VM
  # b_infra/nixhm-sudo-<alias>/build.json .protection, emitted by 9_others into
  # native.protection and _home_manager.vms.<vmName>.protection.
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  protDefaults = consolidated.native.protection or {};
  protVm       = (consolidated._home_manager.vms.${vmName} or {}).protection or {};
  prot         = key: fallback: protVm.${key} or (protDefaults.${key} or fallback);

  tier1 = prot "tier1_services" [];

  # Per-tier1-service reserved memory (MB). Small but enough to OOM-resist.
  tier1MemMinMB      = prot "tier1_mem_min_mb"          48;
  tier1MaxRestarts   = prot "tier1_max_restarts"        3;
  tier1ResetWindow   = prot "tier1_reset_window_secs"   300;
  tier1CheckInterval = prot "tier1_check_interval_secs" 30;
  ntfyBase           = consolidated.native.monitoring.ntfy_base or "https://rss.diegonmarcos.com";
  ntfyTopic          = prot "ntfy_topic" "health_resources";

  tier1List = builtins.concatStringsSep " " tier1;
  tier1Count = builtins.length tier1;
  hasTier1  = tier1Count > 0;

  # ── tier1.slice — reserved, unreclaimable memory envelope for tier-1 apps ──
  # MemoryMin is kernel-guaranteed (never reclaimed under pressure), so tier-1
  # containers survive memory thrash alongside the connectivity island. Reserve
  # = per-service tier1MemMinMB × count. MemoryHigh (soft cap) = 2× reserve so a
  # brief spike throttles instead of OOM-kills.
  #
  # Containers run in this slice when their compose declares:
  #   cgroup_parent: tier1.slice
  # (single-line opt-in per tier-1 service's docker-compose; the slice itself is
  # created here declaratively regardless). Without the opt-in the slice is an
  # empty reservation — harmless — and the watchdog still guards liveness.
  tier1ReserveMB = tier1MemMinMB * tier1Count;
  tier1Slice = ''
    [Slice]
    MemoryMin=${toString tier1ReserveMB}M
    MemoryLow=${toString tier1ReserveMB}M
    MemoryHigh=${toString (tier1ReserveMB * 2)}M
    CPUWeight=5000
    IOWeight=500
  '';
in
lib.mkIf hasTier1 {

  # tier1.slice unit (declarative reserved-memory envelope; see comment above)
  home.file.".local/share/system-protection/tier1.slice".text = tier1Slice;

  # ── Tier-1 watchdog script ────────────────────────────────────────────────
  home.file.".local/share/system-protection/tier1-watchdog.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Tier-1 app watchdog — restart critical containers if stopped.
      # bash (NOT sh): uses `declare -A` associative arrays for per-service restart
      # counters — dash (Debian /bin/sh) has no associative arrays, so a #!/bin/sh
      # shebang would crash the watchdog on start.
      # Circuit breaker: stop after MAX_RESTARTS to avoid restart loops.
      # Phase 2 carve-out from no-auto-restart doctrine — scoped + rate-limited.
      TIER1="${tier1List}"
      MAX_RESTARTS=${toString tier1MaxRestarts}     # consecutive restarts before circuit-breaking
      CHECK_INTERVAL=${toString tier1CheckInterval} # seconds between health checks
      RESET_WINDOW=${toString tier1ResetWindow}     # seconds of clean health before reset restart counter
      NTFY_TOPIC="${ntfyTopic}"
      VM=$(hostname -s 2>/dev/null || echo unknown)

      # Same helper pattern as watchdog-petter.sh / load-shedder.sh: WG-direct
      # ntfy first (fast, survives edge outage), then public edge fallback.
      # Emits a structured event body (source/severity/host/service) so the
      # future §4A broker can route it; today it lands on the configured topic.
      ntfy() {
        _prio="$1"; _title="$2"; _body="$3"; _svc="$4"
        _sev=info
        [ "$_prio" -ge 5 ] && _sev=page || { [ "$_prio" -ge 4 ] && _sev=crit || { [ "$_prio" -ge 3 ] && _sev=warn; }; }
        _event="source=tier1-watchdog severity=$_sev host=$VM service=$_svc | $_body"
        for _url in "http://10.0.0.6:8090/$NTFY_TOPIC" "${ntfyBase}/$NTFY_TOPIC"; do
          curl -sf --max-time 5 -X POST "$_url" \
            -H "Title: [$VM] $_title" -H "Priority: $_prio" \
            -H "Tags: tier1,$VM,$_svc" -d "$_event" >/dev/null 2>&1 && break || true
        done
        # #1886: an owner path that does not ride the gated edge. ntfy is read
        # through the edge, so during an edge outage nobody sees the page above.
        # crit/page also go straight to the Telegram Bot API from this host.
        # Dormant until /etc/c3/owner-alert.env (root 0600: TELEGRAM_BOT_TOKEN,
        # TELEGRAM_CHAT_ID) is provisioned; the token reaches curl on stdin
        # (-K -), never on argv.
        if [ "$_prio" -ge 4 ] && [ -r /etc/c3/owner-alert.env ]; then
          ( . /etc/c3/owner-alert.env
            [ -n "''${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "''${TELEGRAM_CHAT_ID:-}" ] || exit 0
            printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
              | curl -sf --max-time 8 -K - --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
                  --data-urlencode "text=[$VM] $_title: $_body" >/dev/null 2>&1 ) || true
        fi
      }

      # Restart one tier-1 container WITH its compose dependencies (#1886).
      # The old path looked for /opt/containers/<container>/docker-compose.yml,
      # which the v2 layout never has (compose lives in compose/, the deploy
      # deletes a root copy), so it always fell back to a bare `docker start`.
      # That cannot bring back a dependency: on 2026-11-24 authelia-redis was
      # stopped (exit 143), every `docker start authelia` re-died on "redis
      # connection error", the circuit opened after 3 tries, and the edge stayed
      # down ~40 min. The deploy stamps each container with its compose
      # project, working dir, files and service, so `up` of that one service
      # (which starts its depends_on and waits for their healthchecks) is
      # rebuilt from the container itself. --no-recreate/--no-build/--pull never:
      # start what is deployed, never change it. Without labels, or if compose
      # fails, start the labelled dependencies by hand, then the container.
      restart_tier1() {
        _c="$1"
        _lbl() { docker inspect -f "{{index .Config.Labels \"$1\"}}" "$_c" 2>/dev/null; }
        _proj=$(_lbl com.docker.compose.project); _wd=$(_lbl com.docker.compose.project.working_dir)
        _cfg=$(_lbl com.docker.compose.project.config_files); _svc=$(_lbl com.docker.compose.service)
        if [ -n "$_proj" ] && [ -n "$_svc" ] && [ -n "$_cfg" ] && [ -d "$_wd" ]; then
          _args=(-p "$_proj" --project-directory "$_wd")
          IFS=, read -r -a _files <<< "$_cfg"
          for _f in "''${_files[@]}"; do _args+=(-f "$_f"); done
          for _e in "$_wd/compose/.secrets" "$_wd/.secrets"; do
            [ -f "$_e" ] && { _args+=(--env-file "$_e"); break; }
          done
          if (cd "$_wd" && timeout 120 docker compose "''${_args[@]}" up -d --no-recreate --no-build --pull never "$_svc") >/dev/null 2>&1; then
            logger -t tier1-watchdog "[$_c] started via compose (project $_proj, service $_svc, with depends_on)"
            return 0
          fi
          logger -t tier1-watchdog "[$_c] compose up failed; starting dependencies by hand"
        fi
        _deps=$(_lbl com.docker.compose.depends_on)
        IFS=, read -r -a _dl <<< "$_deps"
        for _d in "''${_dl[@]}"; do
          _d=''${_d%%:*}; [ -n "$_d" ] && [ -n "$_proj" ] || continue
          for _id in $(docker ps -aq --filter "label=com.docker.compose.project=$_proj" --filter "label=com.docker.compose.service=$_d"); do
            docker start "$_id" >/dev/null 2>&1 || true
          done
        done
        docker start "$_c" >/dev/null 2>&1 || true
      }

      declare -A restarts last_fail
      for svc in $TIER1; do restarts[$svc]=0; last_fail[$svc]=0; done

      while :; do
        for svc in $TIER1; do
          # Circuit breaker: stop trying if too many restarts
          if [ "''${restarts[$svc]:-0}" -ge "$MAX_RESTARTS" ]; then
            # Check if circuit has been open long enough to reset
            now=$(date +%s)
            gap=$((now - ''${last_fail[$svc]:-0}))
            if [ "$gap" -ge "$RESET_WINDOW" ]; then
              restarts[$svc]=0
              logger -t tier1-watchdog "[$svc] circuit reset after ''${RESET_WINDOW}s clean window"
            else
              continue  # circuit open — skip until reset window
            fi
          fi

          # Check if container is running
          if ! docker inspect --format '{{.State.Running}}' "$svc" 2>/dev/null | grep -q "^true$"; then
            # Container not running — is docker itself up?
            if ! systemctl is-active --quiet docker.service 2>/dev/null; then
              # Docker is down (shed) — don't try to restart, docker isn't there
              continue
            fi
            restarts[$svc]=$((''${restarts[$svc]:-0} + 1))
            last_fail[$svc]=$(date +%s)
            logger -t tier1-watchdog "[$svc] not running — restart attempt ''${restarts[$svc]}/$MAX_RESTARTS"

            if [ "''${restarts[$svc]}" -le "$MAX_RESTARTS" ]; then
              restart_tier1 "$svc"
              ntfy 4 "Tier-1 restart: $svc" "Attempt ''${restarts[$svc]}/$MAX_RESTARTS — $svc was not running." "$svc"
            fi

            if [ "''${restarts[$svc]:-0}" -ge "$MAX_RESTARTS" ]; then
              logger -t tier1-watchdog "[$svc] CIRCUIT OPEN — $MAX_RESTARTS restarts exhausted; paging"
              ntfy 5 "Tier-1 CIRCUIT OPEN: $svc" "$svc failed to stay up after $MAX_RESTARTS restart attempts. MANUAL INTERVENTION REQUIRED. Check: docker logs $svc" "$svc"
            fi
          else
            # Container healthy — reset restart counter on clean check
            restarts[$svc]=0
          fi
        done
        sleep "$CHECK_INTERVAL"
      done
    '';
  };

  home.file.".local/share/system-protection/tier1-watchdog.service".text = ''
    [Unit]
    Description=Tier-1 app watchdog — restart critical containers with circuit breaker
    # Ordering only, NO Requires=/Wants=/BindsTo= on docker.service (#1898). The watchdog's
    # whole job includes the window where docker is down: the script skips a cycle while
    # docker.service is inactive and restarts tier-1 once docker is back. With Requires=,
    # (a) the load-shedder's `systemctl stop docker` stopped the watchdog with it, and
    # (b) any start of the watchdog while docker could not start (a thrashing 944 MB hub)
    # failed with "Dependency failed ... result 'dependency'" (2026-11-25 14:20:55Z and
    # 20:12:01Z, run 45687530592), leaving tier-1 with no auto-recovery. Wants= would pull
    # docker back up against a deliberate shed, so it is not used either.
    After=docker.service multi-user.target
    [Service]
    Type=simple
    ExecStart=/opt/scripts/tier1-watchdog.sh
    # In connectivity.slice so the watchdog itself survives shed pressure
    Slice=connectivity.slice
    OOMScoreAdjust=-800
    MemoryMin=8M
    # 128M, not 32M (#1886): the restart path now runs `docker compose`, whose
    # CLI alone is ~40 MB resident; 32M would OOM-kill the restart it exists for.
    MemoryMax=128M
    CPUWeight=1000
    Restart=always
    RestartSec=10
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installTier1Watchdog = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[tier1-watchdog] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[tier1-watchdog] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/tier1-watchdog.sh" /opt/scripts/tier1-watchdog.sh
    $SUDO chmod +x /opt/scripts/tier1-watchdog.sh
    $SUDO cp -f "$SRC/tier1-watchdog.service" /etc/systemd/system/tier1-watchdog.service
    # tier1.slice — reserved-memory envelope (MemoryMin) for tier-1 containers.
    # Deployed regardless of whether any compose opts in via cgroup_parent, so the
    # reservation exists the moment a service adopts it.
    $SUDO cp -f "$SRC/tier1.slice" /etc/systemd/system/tier1.slice
    # ACTIVATION MUST NEVER BLOCK (2026-07-08 exit-255 deploy hang): every
    # systemctl timeout-capped + step markers so any stall is visible in the
    # ship log instead of dying silently with the deploy's SSH session.
    echo "[tier1-watchdog] step: daemon-reload"
    timeout 15 $SUDO systemctl daemon-reload || true
    echo "[tier1-watchdog] step: start tier1.slice"
    timeout 10 $SUDO systemctl start tier1.slice 2>/dev/null || true
    echo "[tier1-watchdog] step: enable+restart watchdog (no-block)"
    timeout 10 $SUDO systemctl enable tier1-watchdog.service 2>/dev/null || true
    timeout 10 $SUDO systemctl restart --no-block tier1-watchdog.service 2>/dev/null || true

    # --no-block returns before the unit is up. One check 2 s later raced it:
    # on a 1 GB VM the unit went active ~5 s after the restart and every
    # activation logged a false "failed to start" (2026-11-18, oci-analytics
    # run 44419144605: unit active since 23:41:02, 0 restarts). Poll the
    # state for up to ~30 s; "failed" ends the wait at once, and a real
    # failure now prints the unit state and its last journal lines.
    T1_STATE=unknown
    for _i in $(seq 1 15); do
      T1_STATE=$(timeout 10 $SUDO systemctl show -p ActiveState --value tier1-watchdog.service 2>/dev/null || echo unknown)
      case "$T1_STATE" in active|failed) break ;; esac
      sleep 2
    done
    if [ "$T1_STATE" = active ]; then
      echo "[tier1-watchdog] ARMED ✓ (tier1: ${tier1List}) | tier1.slice reserve=${toString tier1ReserveMB}M"
    else
      echo "[tier1-watchdog] WARNING: failed to start (state: $T1_STATE) — tier1 apps will not auto-recover" >&2
      timeout 10 $SUDO journalctl -u tier1-watchdog.service -n 5 --no-pager 2>&1 | sed 's/^/[tier1-watchdog]   /' >&2 || true
    fi
    ) || echo "[tier1-watchdog] activation error — check above"
  '';
}
