# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/infra/idle-shutdown.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, vmName, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
  };
  vmData = cloudData.vms.${vmName};
  idleCfg = vmData.idle_shutdown;
  idleTimeoutHours = if idleCfg != null then idleCfg.timeout_hours else 4;
  idleTimeoutSeconds = idleTimeoutHours * 3600;
  cpuThreshold = if idleCfg != null then idleCfg.cpu_threshold else 60;
  dockerCpuThreshold = if idleCfg != null then idleCfg.docker_cpu_threshold else 30;
  networkThreshold = if idleCfg != null then idleCfg.network_threshold else 51200;
  minUptimeSeconds = if idleCfg != null then idleCfg.min_uptime_seconds else 600;

  idleShutdownScript = pkgs.writeShellScriptBin "idle-shutdown.sh" ''
    #!/bin/bash
    # idle-shutdown.sh - Auto-shutdown VM after ${toString idleTimeoutHours} hours of inactivity
    # Managed by Home Manager — thresholds from _cloud-data-consolidated.json (._home_manager.vms.<vm>.idle_shutdown)

    set -euo pipefail

    # === Configuration (from cloud-data) ===
    IDLE_TIMEOUT_SECONDS=${toString idleTimeoutSeconds}
    STATE_FILE="/var/run/idle-shutdown-state"
    LOG_FILE="/var/log/idle-shutdown.log"
    CPU_THRESHOLD=${toString cpuThreshold}
    DOCKER_CPU_THRESHOLD=${toString dockerCpuThreshold}
    NETWORK_THRESHOLD=${toString networkThreshold}
    MIN_UPTIME_SECONDS=${toString minUptimeSeconds}

    # === Logging ===
    log() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE"
    }

    # === Activity Checks ===
    check_ssh_sessions() {
        local ssh_count
        ssh_count=$(who 2>/dev/null | grep -c pts || true)
        ssh_count=''${ssh_count:-0}

        if [[ "$ssh_count" -gt 0 ]]; then
            log "ACTIVE: $ssh_count SSH session(s) detected"
            return 1
        fi
        return 0
    }

    check_cpu_usage() {
        local cpu_usage
        cpu_usage=$(awk '{printf "%.0f", $1 * 100 / '"$(nproc)"'}' /proc/loadavg)

        if [[ "$cpu_usage" -ge "$CPU_THRESHOLD" ]]; then
            log "ACTIVE: CPU usage at ''${cpu_usage}% (threshold: ''${CPU_THRESHOLD}%)"
            return 1
        fi
        return 0
    }

    check_docker_activity() {
        local active_containers active_names
        active_names=$(docker stats --no-stream --format "{{.Name}}:{{.CPUPerc}}" 2>/dev/null | \
            awk -F: '{gsub(/%/,"",$2); if($2 > '"$DOCKER_CPU_THRESHOLD"') print $1}') || active_names=""

        active_containers=$(echo "$active_names" | grep -c . || true)
        active_containers=''${active_containers:-0}

        if [[ "$active_containers" -gt 0 ]]; then
            log "ACTIVE: $active_containers container(s) using >''${DOCKER_CPU_THRESHOLD}% CPU: $active_names"
            return 1
        fi
        return 0
    }

    check_network_activity() {
        local iface
        iface=$(ip route | grep default | awk '{print $5}' | head -1)

        if [[ -z "$iface" ]]; then
            return 0
        fi

        local rx1 tx1 rx2 tx2
        rx1=$(cat "/sys/class/net/''${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx1=$(cat "/sys/class/net/''${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)

        sleep 2

        rx2=$(cat "/sys/class/net/''${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx2=$(cat "/sys/class/net/''${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)

        local rx_rate tx_rate
        rx_rate=$(( (rx2 - rx1) / 2 ))
        tx_rate=$(( (tx2 - tx1) / 2 ))

        if [[ "$rx_rate" -gt "$NETWORK_THRESHOLD" ]] || [[ "$tx_rate" -gt "$NETWORK_THRESHOLD" ]]; then
            log "ACTIVE: Network activity RX:''${rx_rate}B/s TX:''${tx_rate}B/s"
            return 1
        fi
        return 0
    }

    is_system_idle() {
        check_ssh_sessions || return 1
        check_cpu_usage || return 1
        check_docker_activity || return 1
        check_network_activity || return 1
        return 0
    }

    check_uptime() {
        local uptime_seconds
        uptime_seconds=$(awk '{print int($1)}' /proc/uptime)

        if [[ "$uptime_seconds" -lt "$MIN_UPTIME_SECONDS" ]]; then
            log "System just booted (''${uptime_seconds}s ago), skipping shutdown check"
            return 1
        fi
        return 0
    }

    perform_shutdown() {
        log "=== INITIATING SHUTDOWN ==="
        log "System has been idle for $IDLE_TIMEOUT_SECONDS seconds"
        docker stop $(docker ps -q) 2>/dev/null || true
        sync
        sudo shutdown -h now "Idle timeout reached (''${IDLE_TIMEOUT_SECONDS}s)"
    }

    main() {
        log "=== Idle shutdown check started ==="

        check_uptime || exit 0

        if is_system_idle; then
            log "System is IDLE"

            local idle_start
            idle_start=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)

            if [[ "$idle_start" == "0" ]]; then
                echo "$now" | sudo tee "$STATE_FILE" > /dev/null
                log "Started idle timer at $now"
            else
                local idle_duration
                idle_duration=$((now - idle_start))
                log "Idle for ''${idle_duration}s (timeout: ''${IDLE_TIMEOUT_SECONDS}s)"

                if [[ "$idle_duration" -ge "$IDLE_TIMEOUT_SECONDS" ]]; then
                    perform_shutdown
                fi
            fi
        else
            local current_idle
            current_idle=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
            if [[ "$current_idle" != "0" ]]; then
                echo "0" | sudo tee "$STATE_FILE" > /dev/null
                log "Idle timer reset - activity detected"
            fi
        fi

        log "=== Check complete ==="
    }

    main "$@"
  '';

in {
  home.file.".local/share/idle-shutdown/idle-shutdown.sh" = {
    source = "${idleShutdownScript}/bin/idle-shutdown.sh";
    executable = true;
  };

  home.file.".local/share/idle-shutdown/idle-shutdown.service".text = ''
    [Unit]
    Description=Idle shutdown check
    Wants=idle-shutdown.timer

    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/idle-shutdown.sh
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/idle-shutdown/idle-shutdown.timer".text = ''
    [Unit]
    Description=Run idle shutdown check every 5 minutes

    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=5min
    AccuracySec=1min

    [Install]
    WantedBy=timers.target
  '';

  home.file.".local/share/idle-shutdown/daily-shutdown.sh".text = ''
    #!/bin/bash
    # Daily forced shutdown at 1:00 AM Berlin time
    sudo shutdown -h now "Daily scheduled shutdown"
  '';

  home.file.".local/share/idle-shutdown/daily-shutdown.service".text = ''
    [Unit]
    Description=Daily forced shutdown

    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/daily-shutdown.sh

    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/idle-shutdown/daily-shutdown.timer".text = ''
    [Unit]
    Description=Daily forced shutdown at 1:00 AM Berlin time

    [Timer]
    OnCalendar=*-*-* 01:00:00 Europe/Berlin
    Persistent=false

    [Install]
    WantedBy=timers.target
  '';

  home.activation.installIdleScripts = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[idle-shutdown] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    # Find sudo (not in PATH during home-manager activation)
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[idle-shutdown] WARNING: sudo not found — skipping idle-shutdown installation"
      exit 0
    fi

    $DRY_RUN_CMD $SUDO mkdir -p /opt/scripts
    $DRY_RUN_CMD $SUDO mkdir -p /var/log
    $DRY_RUN_CMD $SUDO cp -f $HOME/.local/share/idle-shutdown/*.sh /opt/scripts/
    $DRY_RUN_CMD $SUDO chmod +x /opt/scripts/*.sh
    $DRY_RUN_CMD $SUDO cp -f $HOME/.local/share/idle-shutdown/*.service $HOME/.local/share/idle-shutdown/*.timer /etc/systemd/system/
    $DRY_RUN_CMD $SUDO systemctl daemon-reload
    $DRY_RUN_CMD $SUDO systemctl enable idle-shutdown.timer daily-shutdown.timer
    $DRY_RUN_CMD $SUDO systemctl restart idle-shutdown.timer daily-shutdown.timer
    $VERBOSE_ECHO "Idle shutdown scripts installed for ${vmName} (${toString idleTimeoutHours}h timeout)"
    ) || echo "[idle-shutdown] FAILED — see errors above, activation continues"
  '';
}
