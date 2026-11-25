# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/load-shedder.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# protection/load-shedder.nix — memory-pressure load shedder
#
# Guarantees the VM never freezes and WireGuard never goes dark.
#
# A long-running, OOM-immune daemon (in connectivity.slice with WG/SSH, so it
# is itself never starved) watches kernel PSI (Pressure Stall Information).
# When the box is about to thrash itself to death it SHEDS container load in
# GRADUATED steps, protecting tier-1 apps (maddy/caddy etc.) until last resort:
#
#   PSI ≥ warn:  notify health_resources (no action)
#   PSI ≥ crit × N: stop NON-tier-1 containers + notify health_resources:crit
#   PSI ≥ page × N: stop ALL (systemctl stop docker) + notify page-level
#
# It does NOT reboot (watchdog-petter's reboot-loop bug).
#
# On the RECOVERY edge (pressure demonstrably cleared) it makes ONE attempt to
# start docker.service if a full shed had stopped it, notifies loudly either
# way, and never retries — see the block itself for the authorization and the
# two oci-analytics outages that motivated it. Restoring shed CONTAINERS is
# still `build.sh ship`; this only undoes the shedder's own `systemctl stop`.
# Tier-1 services configured per VM in the consolidated protection block.
#
# P4: thresholds are data-driven from the consolidated cloud-data
# (config.json native.protection defaults + b_infra/nixhm-sudo-<alias>/build.json
# .protection per-VM overrides) — never hardcoded in this file.
{ config, pkgs, lib, ramMB, vmName, ... }:

let
  # Data-driven thresholds from the consolidated cloud-data (P4). Single source
  # of truth: config.json native.protection (defaults) + b_infra/nixhm-sudo-<alias>/
  # build.json .protection (per-VM overrides), emitted by 9_others into
  # native.protection and _home_manager.vms.<vmName>.protection respectively.
  # builtins.fromJSON reads at build time → baked into script; redeploy to change.
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  defaults     = consolidated.native.protection or {};
  vmConf       = (consolidated._home_manager.vms.${vmName} or {}).protection or {};
  # Per-VM override wins over default; safe fallback if both absent.
  cfg          = key: fallback: vmConf.${key} or (defaults.${key} or fallback);

  memPsiWarn   = cfg "mem_psi_warn"  35;    # notify only
  memPsiCrit   = cfg "mem_psi_crit"  50;    # shed non-tier1
  memPsiPage   = cfg "mem_psi_page"  65;    # shed everything
  interval     = cfg "interval_secs" 15;
  backoff      = cfg "backoff_secs"  120;
  needBreaches = cfg "need_breaches" 3;
  # Pause between each `docker start` when un-shedding. Restoring forty
  # containers at once is itself a load spike, and re-entering pressure
  # immediately after recovering from it is the flap this avoids.
  unshedDelaySecs = cfg "unshed_delay_secs" 5;
  # Longest wait, per container, for a just-started shed container to report
  # healthy (or running, if it has no healthcheck) before the next one starts.
  # A dependent started before its dependency is up dies on its own startup
  # check: on 2026-10-01 01:16 umami was started 14s before umami-db, failed
  # "Can't reach database server", and the single shot was spent.
  unshedReadyWaitSecs = cfg "unshed_ready_wait_secs" 120;
  # Seconds after docker.service enters active during which pressure is NOT
  # counted toward a shed, and the longest the recovery start waits for docker
  # to come up. dockerd's own startup (containerd boot + live-restore reattach)
  # peaks near 510M on a 954M box; on 2026-09-30 that alone drove memPSI to 89
  # and the shedder stopped the daemon it had restarted 32 seconds earlier.
  dockerStartGraceSecs = cfg "docker_start_grace_secs" 180;
  # Post-activation arm check (load-shedder-arm-check.sh): how many times to
  # ask systemctl, how long each answer may take, and the pause between. A
  # 1-CPU box under load answers slowly; 10s was too short on 2026-10-01.
  armCheckAttempts    = cfg "arm_check_attempts" 4;
  armCheckTimeoutSecs = cfg "arm_check_timeout_secs" 15;
  armCheckPauseSecs   = cfg "arm_check_pause_secs" 5;

  # Tier-1 services that survive graduated shed (stopped only on page-level).
  tier1Services = cfg "tier1_services" [];
  tier1List     = builtins.concatStringsSep " " tier1Services;

  # ntfy routing (data-driven): base URL + topic. §4A structured event body.
  ntfyBase  = consolidated.native.monitoring.ntfy_base or "https://rss.diegonmarcos.com";
  ntfyTopic = cfg "ntfy_topic" "health_resources";

  # MEMORY PSI IS THE ONLY SHED TRIGGER.
  # INCIDENT 2026-07-02, THREE false sheds proved cpu/io gates unusable on
  # build hosts. cpu/io still LOGGED for observability; never shed.
in {
  home.file.".local/share/system-protection/load-shedder.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Load shedder — graduated memory-pressure protection.
      # MEMORY-PSI-ONLY trigger (cpu/io logged, never shed — three false sheds 2026-07-02).
      # P1: notifies ntfy on every action (shed/warn/recovery).
      # Phase 2: graduated response — warn → shed non-tier1 → shed all.
      # Tier-1 services (from consolidated protection block) survive until last resort.
      MEM_PSI_WARN=${toString memPsiWarn}
      MEM_PSI_CRIT=${toString memPsiCrit}
      MEM_PSI_PAGE=${toString memPsiPage}
      INTERVAL=${toString interval}
      BACKOFF=${toString backoff}
      NEED=${toString needBreaches}
      DOCKER_START_GRACE=${toString dockerStartGraceSecs}
      UNSHED_READY_WAIT=${toString unshedReadyWaitSecs}
      TIER1_SERVICES="${tier1List}"    # space-separated container names to protect
      NTFY_TOPIC="${ntfyTopic}"        # data-driven topic (default health_resources)
      NTFY_BASE="${ntfyBase}"          # public-edge fallback base
      VM=$(hostname -s 2>/dev/null || echo unknown)

      # $1 = cpu|memory|io, $2 = some|full — integer part of avg10, 0 if unavailable
      psi_avg10() {
        awk -F'avg10=' -v kind="$2" '$1 ~ "^"kind { split($2, a, " "); print a[1]; exit }' \
          "/proc/pressure/$1" 2>/dev/null || echo 0
      }

      # Seconds since docker.service last entered active; huge if it never did.
      docker_age() {
        _enter=$(systemctl show -p ActiveEnterTimestampMonotonic --value docker.service 2>/dev/null)
        [ "''${_enter:-0}" -gt 0 ] 2>/dev/null || { echo 999999; return; }
        awk -v e="$_enter" '{ printf "%d\n", $1 - e / 1000000 }' /proc/uptime
      }

      # Order shed containers so each starts after the in-list containers it
      # depends_on. `docker start` knows nothing of compose's depends_on, so the
      # order has to come from compose's own labels (service names, scoped to
      # the project). Names docker cannot inspect go last, still in the list,
      # so they keep their start attempt and their FAILED verdict.
      unshed_order() {
        _known=$(docker inspect --format '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.depends_on"}}' "$@" 2>/dev/null \
          | awk -F'|' '
              { sub(/^\//, "", $1); n[NR] = $1; p[NR] = $2; d[NR] = $4; if ($3 != "") svc[$2 "/" $3] = $1 }
              END {
                for (i = 1; i <= NR; i++) {
                  m = split(d[i], dl, ",")
                  for (j = 1; j <= m; j++) {
                    split(dl[j], f, ":"); k = p[i] "/" f[1]
                    if ((k in svc) && svc[k] != n[i]) need[i] = need[i] " " svc[k]
                  }
                }
                left = NR
                while (left > 0) {
                  prog = 0
                  for (i = 1; i <= NR; i++) {
                    if (i in done) continue
                    ok = 1; m = split(need[i], r, " ")
                    for (j = 1; j <= m; j++) if (!(r[j] in up)) ok = 0
                    if (ok) { print n[i]; up[n[i]] = 1; done[i] = 1; left--; prog = 1 }
                  }
                  # A dependency cycle cannot be ordered; start the rest as listed.
                  if (!prog) for (i = 1; i <= NR; i++) if (!(i in done)) { print n[i]; up[n[i]] = 1; done[i] = 1; left-- }
                }
              }')
        for _c in $_known; do printf '%s ' "$_c"; done
        for _c in "$@"; do
          printf '%s\n' $_known | grep -qxF -e "$_c" || printf '%s ' "$_c"
        done
      }

      # 0 once a just-started container is healthy (or running, if it has no
      # healthcheck); 1 if it exits, turns unhealthy, or the wait runs out.
      wait_ready() {
        _w=0
        while :; do
          case "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null)" in
            healthy|running) return 0 ;;
            starting|created|restarting) ;;
            *) return 1 ;;
          esac
          [ "$_w" -ge "$UNSHED_READY_WAIT" ] && return 1
          sleep 5; _w=$((_w + 5))
        done
      }

      # P1/§4A: notify ntfy — try WG-direct first (10.0.0.6=oci-apps:8090), then
      # public edge. Topic + base are data-driven ($NTFY_TOPIC/$NTFY_BASE). Body is
      # a structured event (source/severity/host/service) so the future §4A broker
      # can route it; today it lands on the configured topic.
      # $1=priority(1-5) $2=severity(info|warn|crit|page) $3=title $4=body
      ntfy_send() {
        _prio="$1"; _sev="$2"; _title="$3"; _body="$4"
        _event="source=load-shedder severity=$_sev host=$VM service=docker | $_body"
        _sent=false
        for _url in "http://10.0.0.6:8090/$NTFY_TOPIC" "$NTFY_BASE/$NTFY_TOPIC"; do
          if curl -sf --max-time 5 -X POST "$_url" \
               -H "Title: [$VM] $_title" \
               -H "Priority: $_prio" \
               -H "Tags: shedder,$VM" \
               -d "$_event" >/dev/null 2>&1; then
            _sent=true; break
          fi
        done
        # If ntfy is unreachable (e.g. we just shed docker on oci-apps), log it — not fatal.
        "$_sent" || logger -p daemon.warn -t load-shedder "ntfy notify failed (non-fatal): [$_title] $_body"
      }

      # Graduated shed step 1: stop non-tier1 containers only.
      shed_non_tier1() {
        if [ -z "$TIER1_SERVICES" ]; then
          # No tier1 services configured — fall through to full shed
          return 1
        fi
        # §3C: shed NON-tier1 biggest-memory-first. Ordering is best-effort via a
        # timeout-guarded `docker stats` (heavy under thrash, so hard-capped at 5s);
        # on any failure we fall back to plain `docker ps` order. Either way ALL
        # non-tier1 are stopped in one `docker stop`, so ordering only affects which
        # frees first if the stop itself is slow — never correctness.
        _running=$(timeout 5 docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' 2>/dev/null \
                   | sort -k2 -h -r | awk '$1 != "--" {print $1}')
        # `docker stats` prints "--" as the NAME of any container whose stats
        # it cannot collect — which under thrash is all of them. On 2026-09-30
        # 06:20 seven "--" rows were shed instead of real containers, landed in
        # the shed-list, and the UNSHED that followed reported "--" as still
        # down and spent its single shot on containers that never existed.
        [ -z "$_running" ] && _running=$(docker ps --format '{{.Names}}' 2>/dev/null || echo "")
        _to_stop=""
        for _c in $_running; do
          _is_t1=false
          for _t in $TIER1_SERVICES; do
            [ "$_c" = "$_t" ] && _is_t1=true && break
          done
          "$_is_t1" || _to_stop="$_to_stop $_c"
        done
        if [ -n "$_to_stop" ]; then
          logger -t load-shedder "SHED-CRIT: stopping non-tier1 (biggest-first):$_to_stop (keeping: $TIER1_SERVICES)"
          # Persist WHAT was shed. Without this the list dies with the
          # function and the crit-level shed has no inverse: on 2026-09-09
          # about forty containers were stopped at 02:37 and the box then sat
          # at load 0.04 with 16GB free until a human noticed, because the
          # pressure-cleared branch could only ever restart docker itself.
          # Appended, not overwritten — a second shed before recovery must
          # not orphan the first one's containers.
          # shellcheck disable=SC2086
          printf '%s\n' $_to_stop >> /run/load-shedder.shed-list 2>/dev/null || true
          # shellcheck disable=SC2086
          docker stop $_to_stop 2>/dev/null || true
          return 0
        fi
        # All running containers are tier-1 — escalate to full shed
        return 1
      }

      logger -t load-shedder "armed: warn>=${toString memPsiWarn}%% crit>=${toString memPsiCrit}%% page>=${toString memPsiPage}%% tier1=[${tier1List}]"

      breaches_crit=0
      breaches_page=0
      shed_level=0   # 0=normal 1=non-tier1-shed 2=full-shed

      while :; do
        CPU=$(psi_avg10 cpu some);    CPU_I=''${CPU%%.*}; CPU_I=''${CPU_I:-0}
        MEM=$(psi_avg10 memory some); MEM_I=''${MEM%%.*}; MEM_I=''${MEM_I:-0}
        IO=$(psi_avg10 io full);      IO_I=''${IO%%.*};  IO_I=''${IO_I:-0}

        # The single-shot latches are per EPISODE, not per process lifetime.
        # recovery_failed exists so a docker that cannot start is not retried
        # in a loop; once docker is observed active again (systemd's own
        # Restart=always, or a ship) that condition is gone, and keeping the
        # latch only guarantees the next full shed is permanent — which is how
        # oci-analytics stayed dark after 2026-09-30 08:14.
        if [ "''${recovery_failed:-0}" -ne 0 ] && systemctl is-active --quiet docker.service; then
          recovery_failed=0
          logger -t load-shedder "RE-ARMED: docker.service is active again — recovery latch cleared"
        fi

        # ── Warn level (no action, just notify) ───────────────────────────
        if [ "$MEM_I" -ge "$MEM_PSI_WARN" ] && [ "$MEM_I" -lt "$MEM_PSI_CRIT" ] && [ "$shed_level" -eq 0 ]; then
          logger -t load-shedder "WARN: memPSI=''${MEM} (threshold=$MEM_PSI_WARN)"
          # Notify on the TRANSITION into warn only. Without this latch a box
          # that sits in the warn band re-notifies every loop tick: gcp-proxy
          # at 42% memPSI for a day produced 2699 ntfy->email messages in
          # Cloud-Infra/Health/Checks/health_resources (2026-09-02), which
          # then made the phone mail client crawl. Re-arms on recovery below.
          if [ "''${warned:-0}" -eq 0 ]; then
            warned=1
            ntfy_send 3 "warn" "Memory pressure WARN" "memPSI=''${MEM}%% cpuPSI=''${CPU}%% ioPSI=''${IO}%%"
          fi
        fi

        # ── Crit level: track breaches ────────────────────────────────────
        # Pressure inside the docker start grace window is docker starting,
        # not demand: counting it makes the shedder undo its own recovery.
        if [ "$MEM_I" -ge "$MEM_PSI_CRIT" ] && [ "$(docker_age)" -lt "$DOCKER_START_GRACE" ]; then
          breaches_crit=0; breaches_page=0
          logger -t load-shedder "GRACE: memPSI=''${MEM} not counted — docker.service started <''${DOCKER_START_GRACE}s ago"
        elif [ "$MEM_I" -ge "$MEM_PSI_CRIT" ] && [ "$MEM_I" -lt "$MEM_PSI_PAGE" ]; then
          breaches_crit=$((breaches_crit + 1))
          breaches_page=0
          logger -t load-shedder "CRIT breach ''${breaches_crit}/$NEED: memPSI=''${MEM} cpuPSI=''${CPU}"
        elif [ "$MEM_I" -ge "$MEM_PSI_PAGE" ]; then
          breaches_page=$((breaches_page + 1))
          breaches_crit=0
          logger -t load-shedder "PAGE breach ''${breaches_page}/$NEED: memPSI=''${MEM} (CRITICAL level)"
        else
          # Pressure subsided — reset + notify recovery if we had shed
          if [ "$shed_level" -gt 0 ]; then
            logger -t load-shedder "RECOVERY: memPSI=''${MEM} — pressure resolved (shed_level was $shed_level)"
            # ── Recovery-after-clear: SINGLE-SHOT docker restart ──────────
            # AUTHORIZED DEVIATION from the fleet no-autorestart doctrine.
            # This is not a restart policy and not a supervisor: it is this
            # state machine COMPLETING its own transition. A full shed stops
            # docker; without this the box stays amputated until a human runs
            # one command. oci-analytics (the only public edge) died twice in
            # 24h that way: 2026-09-05 stop 19:50 → ~70min down, and
            # 2026-09-06 stop 05:34 after a FOUR-MINUTE pressure event that
            # had cleared by 05:36 (memPSI=0.02) → SEVEN HOURS down. Both
            # recoveries were literally `systemctl start docker.service`.
            # Rules that keep this honest:
            #   • fires ONLY here, on the demonstrated pressure-cleared edge
            #   • ONE attempt per episode — `recovery_failed` latches it off
            #     until docker is seen active again (see RE-ARMED), so a
            #     broken docker escalates to PAGE instead of flapping. We
            #     latch rather than exit because the unit is Restart=always;
            #     exiting would recreate the very retry loop this forbids.
            #   • LOUD either way — started or failed, ntfy hears about it
            if systemctl is-active --quiet docker.service; then
              # shed_level=1 (non-tier1 only) — docker never stopped, so the
              # thing to undo is the container shed, not the daemon. This
              # branch used to only send a notification saying a ship was
              # needed, which is how forty containers stayed down on an idle
              # box for hours. Same single-shot doctrine as the docker
              # recovery below: one attempt, latched off on failure, loud
              # either way.
              #
              # `docker start`, deliberately not container-init containers-up:
              # the containers still exist, so this needs no image pull and no
              # --force-recreate, and re-running a full bring-up is exactly
              # the load that caused the shed. The cost is that a shed
              # spanning a deploy leaves stale containers until the next ship.
              _shed_list=/run/load-shedder.shed-list
              if [ ! -s "$_shed_list" ]; then
                ntfy_send 4 "warn" "Memory pressure RESOLVED" "memPSI now ''${MEM}%% (was shed_level=$shed_level). docker up; nothing recorded as shed."
              elif [ "''${unshed_failed:-0}" -ne 0 ]; then
                logger -p daemon.err -t load-shedder "UNSHED: already attempted and failed — not retrying (manual action required)"
              else
                # "--" filtered here too: a list written by the pre-fix
                # shedder (see shed_non_tier1) lives until reboot, and one
                # "--" makes every later un-shed report FAILED.
                # shellcheck disable=SC2046
                _want=$(unshed_order $(grep -vxF -e '--' "$_shed_list" | sort -u))
                logger -t load-shedder "UNSHED: single-shot start of shed containers: $_want"
                # Each start waits for the container to be ready before the
                # next: the verdict is what the container did, not whether
                # `docker ps` happened to list it the instant after its start.
                _still=""
                for _c in $_want; do
                  { docker start "$_c" >/dev/null 2>&1 && wait_ready "$_c"; } || _still="$_still $_c"
                  sleep ${toString unshedDelaySecs}
                done
                if [ -z "$_still" ]; then
                  rm -f "$_shed_list" /run/load-shedder.fired 2>/dev/null || true
                  logger -t load-shedder "UNSHED: all shed containers restarted"
                  ntfy_send 4 "warn" "RECOVERY — shed containers restarted" "memPSI cleared to ''${MEM}%% (was shed_level=$shed_level). Single-shot restart of the shed list SUCCEEDED."
                else
                  unshed_failed=1
                  logger -p daemon.err -t load-shedder "UNSHED FAILED: still down:$_still — NOT retrying"
                  ntfy_send 5 "page" "UNSHED FAILED — containers still down" "memPSI cleared to ''${MEM}%% but these did not restart:$_still. NOT retrying. Ship the VM or start them by hand."
                fi
              fi
            elif [ "''${recovery_failed:-0}" -ne 0 ]; then
              logger -p daemon.err -t load-shedder "RECOVERY: docker still down but restart already attempted and failed — not retrying (manual action required)"
            else
              logger -t load-shedder "RECOVERY: single-shot start of docker.service"
              timeout 120 systemctl start docker.service 2>/dev/null || true
              # Wait, don't sample once: docker.service is Restart=always, so a
              # first start that exits 1 is retried by systemd 5s later. On
              # 2026-09-30 a one-shot check 5s after the start read that retry
              # as failure and latched, while docker came up 15s later.
              _waited=0
              until systemctl is-active --quiet docker.service || [ "$_waited" -ge "$DOCKER_START_GRACE" ]; do
                sleep 5; _waited=$((_waited + 5))
              done
              if systemctl is-active --quiet docker.service; then
                rm -f /run/load-shedder.fired 2>/dev/null || true
                logger -t load-shedder "RECOVERY: docker.service started (live-restore reattaches containers)"
                ntfy_send 4 "warn" "RECOVERY — docker restarted" "memPSI cleared to ''${MEM}%% (was shed_level=$shed_level). Single-shot auto-start of docker.service SUCCEEDED. Verify containers, then ship if any are missing."
              else
                recovery_failed=1
                logger -p daemon.err -t load-shedder "RECOVERY FAILED: docker.service did not start — NOT retrying; manual intervention required"
                ntfy_send 5 "page" "RECOVERY FAILED — docker did NOT start" "memPSI cleared to ''${MEM}%% but the single-shot start of docker.service FAILED. NOT retrying. VM IS DOWN — manual action required: systemctl status docker.service."
              fi
            fi
            shed_level=0
          fi
          breaches_crit=0; breaches_page=0; warned=0
        fi

        # ── Page-level shed: stop everything ─────────────────────────────
        if [ "$breaches_page" -ge "$NEED" ] && [ "$shed_level" -lt 2 ]; then
          logger -t load-shedder "SHED-PAGE: memPSI=''${MEM} — stopping ALL docker (last resort)"
          ntfy_send 5 "page" "LOAD SHED — ALL DOCKER STOPPED" "LAST RESORT: memPSI=''${MEM}%% ≥ $MEM_PSI_PAGE%% × $NEED checks. ALL containers stopped. docker auto-starts once pressure clears (single-shot); if that fails you get a PAGE."
          : > /run/load-shedder.fired 2>/dev/null || true
          systemctl stop docker.socket 2>/dev/null || true
          systemctl stop docker.service 2>/dev/null || true
          shed_level=2
          breaches_page=0; sleep "$BACKOFF"

        # ── Crit-level shed: stop non-tier1 only ─────────────────────────
        elif [ "$breaches_crit" -ge "$NEED" ] && [ "$shed_level" -lt 1 ]; then
          logger -t load-shedder "SHED-CRIT: memPSI=''${MEM} — shedding non-tier1 containers"
          # New episode, new single shot: a failed UNSHED from an earlier
          # episode must not leave this one's containers down for good.
          unshed_failed=0
          if shed_non_tier1; then
            ntfy_send 4 "crit" "LOAD SHED — non-tier1 stopped" "memPSI=''${MEM}%% ≥ $MEM_PSI_CRIT%% × $NEED. Stopped non-tier1. Tier1 [${tier1List}] still running. Recover: build.sh ship."
            : > /run/load-shedder.fired 2>/dev/null || true
            shed_level=1
          else
            # No non-tier1 to stop — escalate immediately to full shed
            logger -t load-shedder "SHED-PAGE (escalated): no non-tier1 containers to shed"
            ntfy_send 5 "page" "LOAD SHED — ALL DOCKER (escalated)" "No sheddable containers (tier1 list is [${tier1List}]); stopping everything. memPSI=''${MEM}%%. An EMPTY tier1 list here means this VM has no graduated shed — populate .protection.tier1_services in b_infra/nixhm-sudo-<alias>/build.json."
            : > /run/load-shedder.fired 2>/dev/null || true
            systemctl stop docker.socket 2>/dev/null || true
            systemctl stop docker.service 2>/dev/null || true
            shed_level=2
          fi
          breaches_crit=0; sleep "$BACKOFF"
        fi

        sleep "$INTERVAL"
      done
    '';
  };

  home.file.".local/share/system-protection/load-shedder-arm-check.sh" = {
    executable = true;
    source = ./load-shedder-arm-check.sh;
  };

  home.file.".local/share/system-protection/load-shedder.service".text = ''
    [Unit]
    Description=Load shedder — stop docker on memory pressure to keep WireGuard/SSH alive
    After=multi-user.target
    [Service]
    Type=simple
    ExecStart=/opt/scripts/load-shedder.sh
    # Protected like WG/SSH: never starved, OOM-immune, top CPU priority — so it
    # can always run + act precisely when the box is under pressure.
    Slice=connectivity.slice
    OOMScoreAdjust=-999
    MemoryMin=12M
    MemoryMax=32M
    CPUWeight=10000
    Nice=-20
    Restart=always
    RestartSec=3
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installLoadShedder = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[load-shedder] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[load-shedder] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/load-shedder.sh" /opt/scripts/load-shedder.sh
    $SUDO chmod +x /opt/scripts/load-shedder.sh
    $SUDO cp -f "$SRC/load-shedder.service" /etc/systemd/system/load-shedder.service
    # ACTIVATION MUST NEVER BLOCK (2026-07-08 exit-255 deploy hang): every
    # systemctl timeout-capped + step markers; restart uses --no-block (the
    # is-active verify below still proves it armed).
    echo "[load-shedder] step: daemon-reload"
    timeout 15 $SUDO systemctl daemon-reload || true
    echo "[load-shedder] step: enable+restart (no-block)"
    timeout 10 $SUDO systemctl enable load-shedder.service 2>/dev/null || true
    timeout 10 $SUDO systemctl restart --no-block load-shedder.service 2>/dev/null || true
    sleep 2

    # VERIFY it actually armed. A silently-unguarded VM is exactly how oci-mail
    # thrashed to 85%% memPSI with the shedder never firing (2026-07-03): the
    # old activation swallowed install/start failures into a bare echo nobody
    # sees, and never confirmed the service came up. The arm check retries a
    # slow systemctl instead of reading a timed-out query as "inactive" (the
    # 2026-10-01 false marker on oci-analytics), restarts once on a real
    # inactive/failed, then FAIL LOUD + drop a persistent marker the health
    # report surfaces.
    $SUDO rm -f /run/load-shedder.deploy-failed 2>/dev/null || true
    if $SUDO sh "$SRC/load-shedder-arm-check.sh" ${toString armCheckAttempts} ${toString armCheckTimeoutSecs} ${toString armCheckPauseSecs}; then
      echo "[load-shedder] ARMED ✓ (MEMORY-PSI-ONLY: mem>=${toString memPsiCrit}%% sustained → stop docker)"
    else
      echo "[load-shedder] ✗✗✗ FAILED TO ARM — VM UNPROTECTED against memory thrash ✗✗✗" >&2
      $SUDO sh -c 'echo "load-shedder inactive after HM activation $(date -u +%%FT%%TZ)" > /run/load-shedder.deploy-failed' 2>/dev/null || true
      logger -p daemon.err -t load-shedder "DEPLOY FAILED — service inactive after activation; VM UNPROTECTED against memory thrash" 2>/dev/null || true
    fi
    ) || echo "[load-shedder] activation error (see above) — check 'systemctl status load-shedder'"
  '';
}
