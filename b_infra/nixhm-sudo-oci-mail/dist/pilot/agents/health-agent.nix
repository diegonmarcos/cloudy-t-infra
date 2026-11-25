# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/agents/health-agent.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Health Agent — collect VM state to /opt/health/latest.json
# Runs every 5 min. Served via dashboard-httpd symlink (no standalone httpd).
#
# Split from: system-protection-watchdog-petter-dropbear-health-agent.nix
# Imported by: default.nix
#
{ config, pkgs, lib, vmName, ... }:
let
  # P4: data-driven fd / wg-stale thresholds + ntfy base/topic. Single SoT:
  # config.json native.protection (defaults) + b_infra/nixhm-sudo-<alias>/build.json
  # .protection (per-VM overrides), emitted by 9_others into native.protection +
  # _home_manager.vms.<vmName>.protection.
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  protDefaults = consolidated.native.protection or {};
  protVm       = (consolidated._home_manager.vms.${vmName} or {}).protection or {};
  prot         = key: fallback: protVm.${key} or (protDefaults.${key} or fallback);

  fdWarnPct  = prot "fd_warn_pct"   70;
  fdCritPct  = prot "fd_crit_pct"   90;
  wgStaleSec = prot "wg_stale_secs" 180;
  # P6: logind session-leak self-heal threshold (dead sessions, see script).
  logindLeakRestart = prot "logind_leak_restart" 200;
  ntfyBase   = consolidated.native.monitoring.ntfy_base or "https://rss.diegonmarcos.com";
  ntfyTopic  = prot "ntfy_topic"    "health_resources";
in
{
  home.file.".local/share/system-protection/health-agent.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      VM=$(hostname -s 2>/dev/null || echo "unknown")
      OUT="/opt/health/latest.json"
      mkdir -p /opt/health

      # P4: data-driven thresholds + ntfy routing (baked from consolidated protection block).
      FD_WARN_PCT=${toString fdWarnPct}
      FD_CRIT_PCT=${toString fdCritPct}
      WG_STALE_SECS=${toString wgStaleSec}
      NTFY_TOPIC="${ntfyTopic}"
      # WG-direct ntfy (oci-apps :8090) first, then public edge — same pattern as the other agents.
      NTFY_URLS="http://10.0.0.6:8090/$NTFY_TOPIC ${ntfyBase}/$NTFY_TOPIC"

      # Collect data
      MEM=$(free -m 2>/dev/null | awk '/Mem/{printf "{\"used\":%d,\"total\":%d,\"pct\":%d}", $3, $2, ($2>0 ? $3*100/$2 : 0)}' || echo '{"used":0,"total":0,"pct":0}')
      SWAP=$(free -m 2>/dev/null | awk '/Swap/{printf "{\"used\":%d,\"total\":%d}", $3, $2}' || echo '{"used":0,"total":0}')
      DISK=$(df -h / 2>/dev/null | awk 'NR==2{printf "{\"used\":\"%s\",\"total\":\"%s\",\"pct\":\"%s\"}", $3, $2, $5}' || echo '{"used":"?","total":"?","pct":"?"}')
      LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "0 0 0")
      UPTIME=$(awk '{printf "%dd %dh", $1/86400, ($1%86400)/3600}' /proc/uptime 2>/dev/null || echo "?")
      # P3: WG binary up/down + peer handshake staleness (detects silent tunnel death)
      WG_UP=$(ip link show wg0 >/dev/null 2>&1 && echo "true" || echo "false")
      WG_PEERS_JSON="[]"
      if [ "$WG_UP" = "true" ] && command -v wg >/dev/null 2>&1; then
        WG_PEERS_JSON=$(wg show wg0 dump 2>/dev/null | awk -v stale_secs="$WG_STALE_SECS" '
          BEGIN { printf "[" }
          NR>1 {
            now = systime()
            ts = ($5+0 > 0) ? $5 : 0
            age = (ts > 0) ? (now - ts) : -1
            stale = (age < 0 || age > stale_secs) ? "true" : "false"
            if (NR>2) printf ","
            printf "{\"pub_key\":\"%s\",\"endpoint\":\"%s\",\"handshake_age_secs\":%d,\"stale\":%s}",
              $1, $3, age, stale
          }
          END { printf "]" }
        ' || echo "[]")
      fi

      # Memory PSI (some avg10, int) — the load-shedder's trigger; surfaces
      # thrash BEFORE OOM. And whether protection is actually ARMED: oci-mail
      # ran with load-shedder inactive while thrashing to 85% memPSI (2026-07-03),
      # invisible because the health report never checked either.
      MEM_PSI=$(awk -F'avg10=' '/^some/{split($2,a," ");printf "%d",a[1];exit}' /proc/pressure/memory 2>/dev/null || echo 0)
      SHED=$(systemctl is-active load-shedder.service 2>/dev/null || echo "unknown")
      SHED_FAILED=$([ -f /run/load-shedder.deploy-failed ] && echo "true" || echo "false")

      # P5: If load-shedder deploy-failed, send a one-shot ntfy alert (do it every cycle
      # so the alert fires even if the first delivery failed; ntfy deduplication by title
      # prevents flooding — callers see it once per rate window).
      if [ "$SHED_FAILED" = "true" ]; then
        for _ntfy in $NTFY_URLS; do
          curl -sf --max-time 5 -X POST "$_ntfy" \
            -H "Title: [$VM] LOAD SHEDDER NOT ARMED" \
            -H "Priority: 5" \
            -H "Tags: rotating_light,$VM,shedder" \
            -d "source=health-agent severity=page host=$VM service=load-shedder | VM is UNPROTECTED against memory thrash — load-shedder.service failed to start during last HM activation. Check: journalctl -u load-shedder.service" \
            >/dev/null 2>&1 && break || true
        done
      fi

      # P2: File descriptor exhaustion check — the 2026-06-19 fluent-bit EMFILE incident
      # showed fd exhaustion silently kills WG/SSH accept() BEFORE any OOM signal.
      # Read /proc/sys/fs/file-nr: "open allocated max" (3 fields; we want field1 and field3).
      FD_JSON='{"open":0,"max":0,"pct":0,"status":"ok"}'
      if [ -f /proc/sys/fs/file-nr ]; then
        FD_JSON=$(awk -v warn="$FD_WARN_PCT" -v crit="$FD_CRIT_PCT" '{
          open=$1; max=$3
          pct = (max>0) ? int(open*100/max) : 0
          status = (pct>=crit) ? "critical" : (pct>=warn) ? "warn" : "ok"
          printf "{\"open\":%d,\"max\":%d,\"pct\":%d,\"status\":\"%s\"}", open, max, pct, status
        }' /proc/sys/fs/file-nr 2>/dev/null || echo '{"open":0,"max":0,"pct":0,"status":"ok"}')
        # Alert on fd pressure (thresholds data-driven: FD_WARN_PCT / FD_CRIT_PCT)
        FD_PCT=$(echo "$FD_JSON" | awk -F'"pct":' '{split($2,a,",");print int(a[1])}')
        if [ "''${FD_PCT:-0}" -ge "$FD_CRIT_PCT" ]; then
          for _ntfy in $NTFY_URLS; do
            curl -sf --max-time 5 -X POST "$_ntfy" \
              -H "Title: [$VM] FD EXHAUSTION CRITICAL" -H "Priority: 5" \
              -H "Tags: rotating_light,$VM,fd" \
              -d "source=health-agent severity=page host=$VM service=kernel-fd | File descriptors ''${FD_PCT}%% used (>=''${FD_CRIT_PCT}%%) — WG/SSH will fail accept() when exhausted (2026-06-19 pattern)" \
              >/dev/null 2>&1 && break || true
          done
        elif [ "''${FD_PCT:-0}" -ge "$FD_WARN_PCT" ]; then
          for _ntfy in $NTFY_URLS; do
            curl -sf --max-time 5 -X POST "$_ntfy" \
              -H "Title: [$VM] FD pressure warning" -H "Priority: 3" \
              -H "Tags: warning,$VM,fd" \
              -d "source=health-agent severity=warn host=$VM service=kernel-fd | File descriptors ''${FD_PCT}%% used (>=''${FD_WARN_PCT}%%) — monitor for leaks" \
              >/dev/null 2>&1 && break || true
          done
        fi
      fi

      # P6: logind session leak. oci-mail, 2026-10-01 → 10-13: logind stopped
      # seeing the JobRemoved signal for one session scope (session 42282 sat in
      # "opening" with a SCOPE_JOB that no longer existed), and from then on no
      # closed SSH session was ever garbage-collected. ~70 health/MCP SSH logins
      # an hour filled the 8192-session cap (uptime: "8192 users") in five
      # days; past the cap PAM can no longer register sessions at all, so
      # every SSH command (deploys included) ran inside ssh.service's cgroup.
      # Dead = a session record whose session-N.scope cgroup is gone. A
      # restart makes logind re-read /run/systemd/sessions and GC those; live
      # sessions are kept. Rate-limited to one restart per 6h.
      LOGIND_LEAK_RESTART=${toString logindLeakRestart}
      SESS_TOTAL=0; SESS_DEAD=0; LOGIND_HEALED=false
      if [ -d /run/systemd/sessions ]; then
        SESS_ALL=$(ls /run/systemd/sessions 2>/dev/null | grep -E '^[0-9]+$' | sort || true)
        SESS_LIVE=$(ls -d /sys/fs/cgroup/user.slice/user-*.slice/session-*.scope 2>/dev/null \
                      | sed 's|.*/session-||; s|\.scope$||' | sort || true)
        SESS_TOTAL=$(printf '%s\n' "$SESS_ALL" | grep -c . || true)
        SESS_DEAD=$(comm -23 <(printf '%s\n' "$SESS_ALL") <(printf '%s\n' "$SESS_LIVE") | grep -c . || true)
        STAMP=/run/health-agent.logind-heal
        if [ "$(id -u)" = 0 ] && [ "''${SESS_DEAD:-0}" -ge "$LOGIND_LEAK_RESTART" ] \
           && { [ ! -f "$STAMP" ] || [ -n "$(find "$STAMP" -mmin +360 2>/dev/null)" ]; }; then
          touch "$STAMP" 2>/dev/null || true
          if timeout 20 systemctl restart systemd-logind 2>/dev/null; then
            LOGIND_HEALED=true
          fi
          for _ntfy in $NTFY_URLS; do
            curl -sf --max-time 5 -X POST "$_ntfy" \
              -H "Title: [$VM] logind session leak — restarted systemd-logind" -H "Priority: 4" \
              -H "Tags: warning,$VM,logind" \
              -d "source=health-agent severity=warn host=$VM service=systemd-logind | ''${SESS_DEAD} of ''${SESS_TOTAL} logind sessions had no live scope (threshold ''${LOGIND_LEAK_RESTART}); restart ok=$LOGIND_HEALED. Recurrence means logind is missing PID1 job signals again — check for daemon-reload storms." \
              >/dev/null 2>&1 && break || true
          done
        fi
      fi

      # Docker containers via awk (POSIX, no subshell issues)
      TMPF=$(mktemp)
      docker ps -a --format '{{.Names}}|{{.Status}}' > "$TMPF" 2>/dev/null || true
      CTR_TOTAL=$(wc -l < "$TMPF" 2>/dev/null); CTR_TOTAL=''${CTR_TOTAL:-0}
      CTR_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l); CTR_RUNNING=''${CTR_RUNNING:-0}
      CONTAINERS=$(awk -F'|' '
        BEGIN { printf "[" }
        NR > 1 { printf "," }
        {
          h = "none"
          if ($2 ~ /\(healthy\)/) h = "healthy"
          else if ($2 ~ /\(unhealthy\)/) h = "unhealthy"
          else if ($2 ~ /health: starting/) h = "starting"
          else if ($2 ~ /^Created/) h = "created"
          else if ($2 ~ /^Exited/) h = "exited"
          gsub(/"/, "\\\"", $2)
          printf "{\"name\":\"%s\",\"status\":\"%s\",\"health\":\"%s\"}", $1, $2, h
        }
        END { printf "]" }
      ' "$TMPF" 2>/dev/null || echo "[]")
      rm -f "$TMPF"

      # Write JSON (extended with P2 fd + P3 WG peers)
      cat > "$OUT" <<EOF
      {
        "vm": "$VM",
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "mem": $MEM,
        "swap": $SWAP,
        "disk": $DISK,
        "load": "$LOAD",
        "uptime": "$UPTIME",
        "wg_up": $WG_UP,
        "wg_peers": $WG_PEERS_JSON,
        "mem_psi": $MEM_PSI,
        "fd": $FD_JSON,
        "logind": {"sessions": ''${SESS_TOTAL:-0}, "dead_sessions": ''${SESS_DEAD:-0}, "healed": $LOGIND_HEALED},
        "protection": {"load_shedder": "$SHED", "deploy_failed": $SHED_FAILED},
        "containers_running": $CTR_RUNNING,
        "containers_total": $CTR_TOTAL,
        "containers": $CONTAINERS
      }
      EOF
      echo "[health-agent] Updated $OUT"
    '';
  };

  home.file.".local/share/system-protection/health-agent.service".text = ''
    [Unit]
    Description=Health Agent — collect VM state to /opt/health/latest.json
    After=network.target docker.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/health-agent.sh
    User=root
    TimeoutStartSec=30
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/health-agent.timer".text = ''
    [Unit]
    Description=Health Agent timer (every 5 min)
    [Timer]
    OnBootSec=1min
    OnUnitActiveSec=5min
    RandomizedDelaySec=15s
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installHealthAgent = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[health-agent] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[health-agent] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts /opt/health
    $SUDO cp -f "$SRC/health-agent.sh" /opt/scripts/health-agent.sh
    $SUDO chmod +x /opt/scripts/health-agent.sh
    $SUDO cp -f "$SRC/health-agent.service" /etc/systemd/system/health-agent.service
    $SUDO cp -f "$SRC/health-agent.timer" /etc/systemd/system/health-agent.timer

    # Remove legacy standalone httpd (now served via dashboard-httpd symlinks)
    if $SUDO systemctl is-active health-httpd >/dev/null 2>&1; then
      $SUDO systemctl stop health-httpd 2>/dev/null || true
      $SUDO systemctl disable health-httpd 2>/dev/null || true
    fi
    $SUDO rm -f /etc/systemd/system/health-httpd.service

    # ACTIVATION MUST NEVER BLOCK (2026-07-08 exit-255 deploy hang): every
    # systemctl is timeout-capped, and the oneshot service start uses
    # --no-block — a bare `systemctl start` on Type=oneshot waits for the whole
    # collection script, stalling activation inside the deploy's SSH session.
    echo "[health-agent] step: daemon-reload"
    timeout 15 $SUDO systemctl daemon-reload || true
    echo "[health-agent] step: enable+start timer"
    timeout 10 $SUDO systemctl enable health-agent.timer 2>/dev/null || true
    timeout 10 $SUDO systemctl start health-agent.timer 2>/dev/null || true
    echo "[health-agent] step: kick first collection (no-block)"
    timeout 10 $SUDO systemctl start --no-block health-agent.service 2>/dev/null || true

    echo "[health-agent] deployed: timer=5min (served via dashboard-httpd)"
    ) || echo "[health-agent] FAILED — activation continues"
  '';
}
