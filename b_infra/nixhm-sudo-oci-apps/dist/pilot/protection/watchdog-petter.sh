#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/watchdog-petter.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Watchdog Petter — kernel watchdog + container auto-healer
# Rich telemetry: mem, swap, PSI, top procs, disk, containers every 30s
# POSIX sh — no bash required
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/_shared/modules/watchdog-petter.sh

# Hardware watchdog DISABLED — CPUQuota throttling causes missed pets → VM reset
# TODO: re-enable once we confirm VMs are stable without it
# exec 3>/dev/watchdog 2>/dev/null || echo "[watchdog] WARNING: /dev/watchdog not available"
WD_ENABLED=0
DOCKER_FAIL=0

# Docker CLI is FORBIDDEN in the watchdog — it spawns plugin metadata
# subprocesses that inherit RT priority and can starve the VM.
# Use lightweight alternatives: docker socket API via curl, or /proc.
DOCKER_SOCK="unix:///var/run/docker.sock"
# Query docker API without spawning any docker CLI process
dapi() { curl -sf --max-time 5 --unix-socket /var/run/docker.sock "http://localhost$1" 2>/dev/null; }
# Only for actions (restart/prune) — with timeout (no nice/ionice wrapping; docker-real wrapper retired)
dcli() { timeout 15 docker "$@" 2>/dev/null; }
# P4: thresholds data-driven via env injected by watchdog.nix from the
# consolidated protection block (config.json native.protection + per-VM
# b_infra/nixhm-sudo-<alias>/build.json .protection). Env-with-default keeps
# the script runnable standalone (tester) while the deployed unit sets real values.
DOCKER_FAIL_THRESHOLD=${DOCKER_FAIL_THRESHOLD:-120}
LOW_MEM_PRUNE_MB=${LOW_MEM_PRUNE_MB:-50}
CTR_RESTART_TRACK=""
HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
LOG=/var/log/watchdog-petter.log
# NTFY base + topic data-driven (native.monitoring.ntfy_base + protection.ntfy_topic).
NTFY="${NTFY:-http://10.0.0.1:8090/watchdog-dropbear}"
BOOT_TIME=$(date -Is)
CYCLE=0
TICK=0

# ── Rich telemetry ──────────────────────────────────────────────
sysinfo_full() {
  MEM_TOTAL=$(awk '/MemTotal/    {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  MEM_AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
  MEM_PCT=$((MEM_USED * 100 / (MEM_TOTAL + 1)))
  BUFCACHE=$(awk '/Buffers/{b=$2} /^Cached/{c=$2} END{print int((b+c)/1024)}' /proc/meminfo 2>/dev/null)
  SWAP_TOTAL=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  SWAP_USED=$(awk '/SwapFree/  {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  SWAP_USED=$((SWAP_TOTAL - SWAP_USED))
  MEM_PSI="N/A"; CPU_PSI="N/A"; IO_PSI="N/A"
  [ -f /proc/pressure/memory ] && MEM_PSI=$(awk '/some/{print $2}' /proc/pressure/memory 2>/dev/null | head -1)
  [ -f /proc/pressure/cpu ]    && CPU_PSI=$(awk '/some/{print $2}' /proc/pressure/cpu 2>/dev/null | head -1)
  [ -f /proc/pressure/io ]     && IO_PSI=$(awk '/some/{print $2}' /proc/pressure/io 2>/dev/null | head -1)
  LOAD=$(cut -d" " -f1-3 /proc/loadavg 2>/dev/null)
  PROCS=$(cut -d" " -f4 /proc/loadavg 2>/dev/null)
  UPTIME=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dd%dh%dm", d, h, m}' /proc/uptime 2>/dev/null)
  DISK=$(df / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
  CTRS=0; CTRS_HEALTHY=0; CTRS_UNHEALTHY=0; CTRS_RESTARTING=0
  if [ -S /var/run/docker.sock ]; then
    CTRS_JSON=$(dapi "/containers/json?all=true" || echo "[]")
    CTRS=$(printf '%s' "$CTRS_JSON" | grep -c '"Id"' || echo 0)
    CTRS_HEALTHY=$(printf '%s' "$CTRS_JSON" | grep -c '"healthy"' || echo 0)
    CTRS_UNHEALTHY=$(printf '%s' "$CTRS_JSON" | grep -c '"unhealthy"' || echo 0)
    CTRS_RESTARTING=$(printf '%s' "$CTRS_JSON" | grep -c '"restarting"' || echo 0)
  fi
  TOP_PROCS=$(ps aux --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=6{printf "%s(%s%%/%dMB) ", $11, $4, $6/1024}')
  printf "mem=%dM/%dM(%d%%) buf+cache=%dM swap=%dM/%dM | load=%s procs=%s up=%s | psi:mem=%s cpu=%s io=%s | disk=%s | ctrs=%d(ok=%d bad=%d loop=%d) | top: %s" \
    "$MEM_USED" "$MEM_TOTAL" "$MEM_PCT" "$BUFCACHE" "$SWAP_USED" "$SWAP_TOTAL" \
    "$LOAD" "$PROCS" "$UPTIME" "$MEM_PSI" "$CPU_PSI" "$IO_PSI" \
    "$DISK" "$CTRS" "$CTRS_HEALTHY" "$CTRS_UNHEALTHY" "$CTRS_RESTARTING" \
    "$TOP_PROCS"
}

log() {
  INFO=$(sysinfo_full)
  MSG="$(date -Is) [$HOSTNAME] [watchdog] $1 | $INFO"
  # Force sync to disk — must survive kernel freeze
  printf '%s\n' "$MSG" >> "$LOG" 2>/dev/null && sync "$LOG" 2>/dev/null
  printf '%s\n' "$MSG"
}

ntfy() { curl -sf --max-time 3 -X POST "$NTFY" -H "Title: [$HOSTNAME] $2" -H "Priority: $1" -H "Tags: $4" -d "$3 | $(sysinfo_full)" 2>/dev/null || true; }

# ── Pre-action report: full state dump before any destructive action ──
# Flushed to journal + log file so we always know WHY an action was taken
pre_action_report() {
  ACTION="$1"
  REASON="$2"
  TARGET="${3:-}"

  # Full /proc/meminfo snapshot
  MEMINFO=$(cat /proc/meminfo 2>/dev/null | head -20)

  # All running processes by memory
  ALL_PROCS=$(ps aux --sort=-%mem 2>/dev/null | head -20)

  # Docker containers detail (if running)
  DOCKER_DETAIL=""
  if [ -S /var/run/docker.sock ]; then
    DOCKER_DETAIL=$(dapi "/containers/json?all=true" | grep -o '"Names":\["/[^"]*"\]' | head -20 || echo "N/A")
  fi

  # Swap detail
  SWAP_DETAIL=$(swapon --show 2>/dev/null)

  # PSI full (not just avg10)
  PSI_MEM=""; PSI_CPU=""; PSI_IO=""
  [ -f /proc/pressure/memory ] && PSI_MEM=$(cat /proc/pressure/memory 2>/dev/null)
  [ -f /proc/pressure/cpu ]    && PSI_CPU=$(cat /proc/pressure/cpu 2>/dev/null)
  [ -f /proc/pressure/io ]     && PSI_IO=$(cat /proc/pressure/io 2>/dev/null)

  # OOM score of all processes
  OOM_SCORES=$(for p in /proc/[0-9]*/oom_score; do
    PID=$(echo "$p" | cut -d/ -f3)
    SCORE=$(cat "$p" 2>/dev/null || echo 0)
    NAME=$(cat "/proc/$PID/comm" 2>/dev/null || echo "?")
    [ "$SCORE" -gt 100 ] && printf "  %s(pid=%s oom=%s)\n" "$NAME" "$PID" "$SCORE"
  done 2>/dev/null | sort -t= -k3 -rn | head -10)

  REPORT="
================================================================================
PRE-ACTION REPORT — $(date -Is) [$HOSTNAME]
================================================================================
ACTION: $ACTION
REASON: $REASON
TARGET: $TARGET
================================================================================
MEMORY:
$MEMINFO
================================================================================
SWAP:
$SWAP_DETAIL
================================================================================
PSI PRESSURE:
  memory: $PSI_MEM
  cpu:    $PSI_CPU
  io:     $PSI_IO
================================================================================
TOP PROCESSES BY MEMORY:
$ALL_PROCS
================================================================================
HIGH OOM SCORE (>100):
$OOM_SCORES
================================================================================
DOCKER CONTAINERS:
$DOCKER_DETAIL
================================================================================
"

  # Flush to BOTH journal (survives crash) and log file
  printf '%s\n' "$REPORT" >> "$LOG" 2>/dev/null && sync "$LOG" 2>/dev/null
  printf '%s\n' "$REPORT"
  # Wait 5s for journal + filesystem flush before any destructive action
  sync 2>/dev/null
  sleep 5
}

log "BOOT: watchdog-petter started (threshold=$DOCKER_FAIL_THRESHOLD)"

while true; do
  TICK=$((TICK + 1))

  # Kernel liveness
  if ! [ -f /proc/loadavg ]; then
    pre_action_report "EXIT" "/proc unreadable — kernel frozen" "kernel"
    ntfy 5 "KERNEL FROZEN" "/proc unreadable — reset in 15s" "rotating_light,skull"
    exit 1
  fi

  # Periodic telemetry (every 6th cycle = 30s)
  if [ $((TICK % 6)) -eq 0 ]; then
    log "tick=$TICK"
  fi

  # Docker liveness
  if ! dapi "/_ping" >/dev/null 2>&1; then
    DOCKER_FAIL=$((DOCKER_FAIL + 1))
    # Log every 12th failure (60s) to avoid spam
    if [ $((DOCKER_FAIL % 12)) -eq 1 ]; then
      log "Docker not responding (fail $DOCKER_FAIL/$DOCKER_FAIL_THRESHOLD)"
    fi
    if [ "$DOCKER_FAIL" -ge "$DOCKER_FAIL_THRESHOLD" ]; then
      pre_action_report "DOCKER_RESTART" "Docker hung ($DOCKER_FAIL consecutive failures over $((DOCKER_FAIL * 5))s)" "docker.service"
      ntfy 4 "Docker restart" "Docker hung ($DOCKER_FAIL failures) — restarting" "warning,whale"
      systemctl restart docker 2>/dev/null || true
      DOCKER_FAIL=0
    fi
    [ "$WD_ENABLED" = "1" ] && echo V >&3 2>/dev/null
    sleep 5
    continue
  fi
  [ "$DOCKER_FAIL" -gt 0 ] && log "Docker recovered after $DOCKER_FAIL failures"
  DOCKER_FAIL=0

  # Restart crash-looping containers
  for ctr in $(dapi "/containers/json?all=true&filters=%7B%22status%22%3A%5B%22restarting%22%5D%7D" | grep -o '"Names":\["/[^"]*' | cut -d/ -f2); do
    PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true)
    if [ "$PREV" -lt 2 ]; then
      pre_action_report "CONTAINER_RESTART" "Container $ctr is crash-looping (status=restarting)" "$ctr"
      ntfy 3 "Container restart" "$ctr crash-looping" "warning,package"
      curl -sf --max-time 15 --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/$ctr/restart?t=10" >/dev/null 2>&1 || true
      CTR_RESTART_TRACK="$CTR_RESTART_TRACK
$ctr"
    fi
  done

  # Restart unhealthy containers
  for ctr in $(dapi "/containers/json?filters=%7B%22health%22%3A%5B%22unhealthy%22%5D%7D" | grep -o '"Names":\["/[^"]*' | cut -d/ -f2); do
    PREV=$(echo "$CTR_RESTART_TRACK" | grep -c "^$ctr$" || true)
    if [ "$PREV" -lt 1 ]; then
      pre_action_report "CONTAINER_RESTART" "Container $ctr is unhealthy (health=unhealthy)" "$ctr"
      ntfy 3 "Container unhealthy" "$ctr unhealthy" "warning,heartpulse"
      curl -sf --max-time 15 --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/$ctr/restart?t=10" >/dev/null 2>&1 || true
      CTR_RESTART_TRACK="$CTR_RESTART_TRACK
$ctr"
    fi
  done

  # Low memory prune (threshold data-driven: LOW_MEM_PRUNE_MB)
  MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 9999)
  if [ "$MEM_AVAIL" -lt "$LOW_MEM_PRUNE_MB" ]; then
    pre_action_report "DOCKER_PRUNE" "Low memory: ${MEM_AVAIL}MB available (<${LOW_MEM_PRUNE_MB}MB threshold)" "scoped container+dangling-image prune"
    ntfy 4 "Low memory" "${MEM_AVAIL}MB available" "warning,brain"
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/prune?filters=%7B%22label%21%22%3A%7B%22com.docker.compose.project%22%3Atrue%7D%7D" >/dev/null 2>&1 || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/images/prune" >/dev/null 2>&1 || true
  fi

  # ── Disk pressure: tiered response (data-driven via DISK_WARN/HIGH/EMERG env) ──
  # The HM image (~2.6GB compressed → ~6GB unpacked) needs ~6GB free for
  # docker pull to succeed. Without this block, oci-mail filled to 89% and
  # HM ship failed with "no space left on device" (incident 2026-04-30).
  # Tiers:
  #   WARN  (≥80%): prune containers + dangling images
  #   HIGH  (≥85%): + images + buildkit cache
  #   EMERG (≥90%): + release ballast + journal vacuum
  # Every /containers/prune carries label!=com.docker.compose.project and there
  # is NO /volumes/prune: the same rule as disk-watchdog (watchdog.nix) and
  # infra/prune-maintenance.nix. #353 measured this script's unfiltered prune as
  # the September umami/matomo killer on oci-analytics — load-shedder stops the
  # non-tier1 containers, then an unscoped prune deletes them. The unit is
  # currently disabled by watchdog.nix's activation, but the script still ships
  # to /opt/scripts, so re-enabling it must not resurrect the hole.
  # Also truncate any container json log >50MB to keep them bounded even
  # before the daemon-config max-size=10m takes effect (containers started
  # before that policy keep their old log file).
  DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $5 }')
  : "${DISK_PCT:=0}"
  DISK_WARN=${DISK_WARN:-80}
  DISK_HIGH=${DISK_HIGH:-85}
  DISK_EMERG=${DISK_EMERG:-90}
  if [ "$DISK_PCT" -ge "$DISK_WARN" ]; then
    # Always truncate runaway container logs at any disk-pressure tier.
    find /var/lib/docker/containers -name "*-json.log" -size +50M \
      -exec truncate -s 0 {} + 2>/dev/null || true
  fi
  if [ "$DISK_PCT" -ge "$DISK_EMERG" ]; then
    pre_action_report "DISK_EMERG" "Disk usage ${DISK_PCT}% (≥${DISK_EMERG}%)" "ballast+prune-aggressive"
    ntfy 5 "DISK EMERG" "${DISK_PCT}% used — releasing ballast + aggressive prune" "rotating_light,floppy_disk"
    rm -f /var/disk-reserve/ballast.bin 2>/dev/null || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/prune?filters=%7B%22label%21%22%3A%7B%22com.docker.compose.project%22%3Atrue%7D%7D" >/dev/null 2>&1 || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/images/prune?filters=%7B%22dangling%22%3A%7B%22true%22%3Atrue%7D%7D" >/dev/null 2>&1 || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/build/prune?all=true" >/dev/null 2>&1 || true
    # #413: never below the declared retention floor (JOURNAL_FLOOR_DAYS, set
    # by watchdog.nix from native.protection.journal_retention_floor_days). No
    # default: unset means undeclared, and an undeclared floor must not vacuum.
    [ -n "${JOURNAL_FLOOR_DAYS:-}" ] && journalctl --vacuum-time="${JOURNAL_FLOOR_DAYS}d" >/dev/null 2>&1 || true
  elif [ "$DISK_PCT" -ge "$DISK_HIGH" ]; then
    pre_action_report "DISK_HIGH" "Disk usage ${DISK_PCT}% (≥${DISK_HIGH}%)" "prune+buildcache"
    ntfy 4 "Disk high" "${DISK_PCT}% used — pruning images+buildcache" "warning,floppy_disk"
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/prune?filters=%7B%22label%21%22%3A%7B%22com.docker.compose.project%22%3Atrue%7D%7D" >/dev/null 2>&1 || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/images/prune" >/dev/null 2>&1 || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/build/prune?all=true" >/dev/null 2>&1 || true
  elif [ "$DISK_PCT" -ge "$DISK_WARN" ]; then
    pre_action_report "DISK_WARN" "Disk usage ${DISK_PCT}% (≥${DISK_WARN}%)" "prune-containers+dangling"
    ntfy 3 "Disk warn" "${DISK_PCT}% used — pruning containers+dangling images" "warning,floppy_disk"
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/containers/prune?filters=%7B%22label%21%22%3A%7B%22com.docker.compose.project%22%3Atrue%7D%7D" >/dev/null 2>&1 || true
    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST "http://localhost/images/prune?filters=%7B%22dangling%22%3A%7B%22true%22%3Atrue%7D%7D" >/dev/null 2>&1 || true
  fi

  CYCLE=$((CYCLE + 1))
  if [ "$CYCLE" -ge 10 ]; then
    CTR_RESTART_TRACK=""
    CYCLE=0
  fi

  [ "$WD_ENABLED" = "1" ] && echo V >&3 2>/dev/null
  sleep 5
done
