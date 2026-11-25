# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/packages/health-post-logs.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# health-post-logs.nix — Systemd timer: collect VM health → push to cloud-data git
#
# Every 5 min:
# 1. Runs health-agent.sh → generates JSON with docker ps, mem, disk, load, ports
# 2. Saves to ~/.cloud-data/{vm}/{vm}-{timestamp}.json
# 3. Copies to ~/git/cloud-data/cloud-health-stack/{vm}/
# 4. git pull --rebase (theirs wins) + git add + commit + push
#
# Deployed via home-manager shared modules (all VMs)
{ config, lib, pkgs, ... }:

let
  homeDir = config.home.homeDirectory;
  # VM identity — derived from SSH alias in cloud-data JSON at activation time
  # Script reads hostname at runtime
  repoDir = "${homeDir}/git/cloud-data";

  healthAgent = pkgs.writeShellScript "health-agent" ''
    set -euo pipefail
    # Derive VM alias from hostname (set by cloud-init/HM)
    VM=$(hostname -s 2>/dev/null || echo "unknown")
    TS=$(date -u +%Y%m%d%H%M)
    HOME_DIR="${homeDir}"
    LOCAL_DIR="$HOME_DIR/.cloud-data/$VM"
    REPO_DIR="${repoDir}"
    TARGET_DIR="$REPO_DIR/cloud-health-stack/$VM"
    FILE="''${VM}-''${TS}.json"

    mkdir -p "$LOCAL_DIR" "$TARGET_DIR"

    # ── Collect data ──────────────────────────────────
    MEM=$(free -m 2>/dev/null | awk '/Mem/{printf "{\"used\":%d,\"total\":%d,\"pct\":%d}", $3, $2, $3*100/$2}')
    SWAP=$(free -m 2>/dev/null | awk '/Swap/{printf "{\"used\":%d,\"total\":%d}", $3, $2}')
    DISK=$(df -h / 2>/dev/null | awk 'NR==2{printf "{\"used\":\"%s\",\"total\":\"%s\",\"pct\":\"%s\"}", $3, $2, $5}')
    LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    UPTIME=$(awk '{printf "%dd %dh", $1/86400, ($1%86400)/3600}' /proc/uptime 2>/dev/null)

    # Docker containers as JSON array
    CTR_TOTAL=0
    CTR_RUNNING=0
    TMPCTRS=$(mktemp)
    docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null > "$TMPCTRS" || true
    CTR_TOTAL=$(wc -l < "$TMPCTRS")
    CTR_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l || echo 0)
    # Build JSON with awk (avoids subshell pipe issue)
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
    ' "$TMPCTRS")
    rm -f "$TMPCTRS"

    # WG interface check
    WG_UP="false"
    ip link show wg0 >/dev/null 2>&1 && WG_UP="true"

    # Local port checks — probe per-VM manifest.
    # Probe order (cloud-data emits NOTHING; new canonical lives in 1_cicd/dist):
    #   1. /opt/scripts/build-vm.json  ← NEW (home-manager-deployed from 1_cloud-configs/dist/build-vm-{vm}.json)
    #   2. $REPO_DIR/cloud-data-containers-$VM.json  ← LEGACY fallback (cloud-data clone)
    MANIFEST=""
    for _p in "/opt/scripts/build-vm.json" "$REPO_DIR/cloud-data-containers-$VM.json"; do
      [ -f "$_p" ] && [ -s "$_p" ] && MANIFEST="$_p" && break
    done
    if [ -n "$MANIFEST" ]; then
      PORT_LIST=$(python3 -c "import json; d=json.load(open('$MANIFEST')); print(' '.join(str(c.get('port','')) for c in d.get('containers',[]) if c.get('port')))" 2>/dev/null || echo "22 80 443 2200")
    else
      PORT_LIST="22 80 443 2200 8080 8443 9091"
    fi
    PORTS_OPEN="["
    PFIRST=true
    for port in $PORT_LIST; do
      nc -zw1 localhost "$port" 2>/dev/null && {
        $PFIRST || PORTS_OPEN="$PORTS_OPEN,"
        PFIRST=false
        PORTS_OPEN="$PORTS_OPEN$port"
      }
    done
    PORTS_OPEN="$PORTS_OPEN]"

    # ── Write JSON ────────────────────────────────────
    cat > "$LOCAL_DIR/$FILE" <<JSONEOF
{
  "vm": "$VM",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mem": $MEM,
  "swap": $SWAP,
  "disk": $DISK,
  "load": "$LOAD",
  "uptime": "$UPTIME",
  "containers_running": $CTR_RUNNING,
  "containers_total": $CTR_TOTAL,
  "containers": $CONTAINERS,
  "wg_up": $WG_UP,
  "ports_open": $PORTS_OPEN
}
JSONEOF

    echo "[health-agent] Generated $FILE"

    # ── Push to git ───────────────────────────────────
    if [ -d "$REPO_DIR/.git" ]; then
      cp "$LOCAL_DIR/$FILE" "$TARGET_DIR/$FILE"

      # Keep only last 12 files (1 hour of 5-min snapshots)
      ls -1t "$TARGET_DIR"/"$VM"-*.json 2>/dev/null | tail -n +13 | xargs -r rm -f
      ls -1t "$LOCAL_DIR"/"$VM"-*.json 2>/dev/null | tail -n +13 | xargs -r rm -f

      cd "$REPO_DIR"
      git pull --rebase --strategy-option=theirs origin main 2>/dev/null || git pull --rebase origin main 2>/dev/null || true
      git add "cloud-health-stack/$VM/" 2>/dev/null || true
      git diff --cached --quiet 2>/dev/null || {
        git commit -m "auto: health $VM $TS [skip ci]" 2>/dev/null || true
        git push origin main 2>/dev/null || echo "[health-agent] push failed (will retry next cycle)"
      }
      echo "[health-agent] Pushed $FILE to cloud-data"
    else
      echo "[health-agent] WARN: $REPO_DIR not found — local only"
    fi
  '';
in {
  # ── Systemd timer: every 5 minutes ─────────────────
  systemd.user.timers.health-post-logs = {
    Unit.Description = "Health data collection + push to cloud-data";
    Timer = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.health-post-logs = {
    Unit = {
      Description = "Collect VM health data and push to cloud-data git";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${healthAgent}";
      TimeoutStartSec = "120";
      Environment = [
        "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.netcat-openbsd pkgs.git pkgs.openssh pkgs.docker-client pkgs.procps pkgs.iproute2 pkgs.util-linux ]}"
        "HOME=${homeDir}"
        "GIT_AUTHOR_NAME=health-agent"
        "GIT_AUTHOR_EMAIL=health@vm"
        "GIT_COMMITTER_NAME=health-agent"
        "GIT_COMMITTER_EMAIL=health@vm"
      ];
    };
  };
}
