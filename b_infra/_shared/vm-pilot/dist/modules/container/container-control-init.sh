#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/container/container-control-init.sh
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ╔══════════════════════════════════════════════════════════════════╗
# ║ Container Init — VM-side container lifecycle manager            ║
# ║ Managed by home-manager — DO NOT EDIT on VM                    ║
# ║ Source: cloud/b_infra/_shared/vm-pilot/src/modules/       ║
# ║         container/container-control-init.sh                    ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║ Usage:                                                         ║
# ║   container-init                    Full boot sequence          ║
# ║   container-init dockerd-up         Start Docker daemon         ║
# ║   container-init dockerd-down       Stop Docker daemon          ║
# ║   container-init nixhm-up           Pull + activate HM image    ║
# ║   container-init containers-up      Pull + start all services   ║
# ║   container-init containers-down    Stop all services           ║
# ║   container-init containers-restart Restart all services        ║
# ║   container-init service-up <name>  Start one service           ║
# ║   container-init service-down <name> Stop one service           ║
# ║   container-init health             Health check all            ║
# ║   container-init status             Show running containers     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

# ── Sudo: escalate if not root ──
if [ "$(id -u)" != "0" ]; then exec sudo "$0" "$@"; fi

# ── PATH: ensure nix + docker binaries available ──
for p in /home/*/nix-profile/bin /home/*/.nix-profile/bin /nix/var/nix/profiles/default/bin; do
  [ -d "$p" ] && PATH="$p:$PATH"
done
export PATH

# ── Config ──
CONFIG="/opt/scripts/container-init.json"
[ -f "$CONFIG" ] || { echo "[init] FATAL: $CONFIG not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[init] FATAL: jq not found" >&2; exit 1; }

VM_ALIAS=$(jq -r '.vm_alias' "$CONFIG")
CLOUD_DATA_REPO=$(jq -r '.cloud_data_repo // "https://github.com/diegonmarcos/cloud-data.git"' "$CONFIG")
CLOUD_DATA_DIR=$(jq -r '.cloud_data_dir // "/home/diego/git/cloud-data"' "$CONFIG")
CONTAINERS_DIR=$(jq -r '.containers_dir // "/opt/containers"' "$CONFIG")
NTFY_BASE=$(jq -r '.ntfy_base // "https://rss.diegonmarcos.com"' "$CONFIG")
NTFY_TOPIC=$(jq -r '.ntfy_topic // "container-init"' "$CONFIG")
DOCKER_TIMEOUT=$(jq -r '.docker_timeout // 60' "$CONFIG")
START_DELAY=$(jq -r '.start_delay // 3' "$CONFIG")
GIT_USER=$(jq -r '.git_user // "diego"' "$CONFIG")
HM_DELIVERY=$(jq -r '.hm_delivery // "nix-copy"' "$CONFIG")
HM_IMAGE=$(jq -r '.hm_image // ""' "$CONFIG")
HM_USER=$(jq -r '.hm_user // "diego"' "$CONFIG")
REGISTRY="ghcr.io/diegonmarcos"

HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
BOOT_START=$(date +%s)
BOOT_JSON="/var/log/container-init-boot.json"
LOG_FILE="/var/log/container-init.log"

# ── Helpers ──
log()     { _m="[init] +$(( $(date +%s) - BOOT_START ))s $*"; echo "$_m" >&2; echo "$_m" >> "$LOG_FILE" 2>/dev/null; }
log_err() { _m="[init] ERROR: $*"; echo "$_m" >&2; echo "$_m" >> "$LOG_FILE" 2>/dev/null; }
mem_free(){ free -m 2>/dev/null | awk '/Mem:/{print $4}'; }
ntfy() {
  curl -sf -X POST "${NTFY_BASE}/${NTFY_TOPIC}" \
    -H "Title: [$HOSTNAME] $1" -H "Priority: ${3:-default}" -H "Tags: ${4:-whale}" \
    -d "$2" >/dev/null 2>&1 || true
}

elapsed() { echo $(( $(date +%s) - BOOT_START )); }

# ══════════════════════════════════════════════════════════════
# COMMANDS
# ══════════════════════════════════════════════════════════════

cmd_dockerd_up() {
  log "Starting Docker daemon..."
  if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    log "Docker already running"
    return 0
  fi
  systemctl start docker 2>/dev/null
  _i=0
  while [ "$_i" -lt "$DOCKER_TIMEOUT" ]; do
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && break
    _i=$((_i + 1))
    [ $((_i % 10)) -eq 0 ] && log "  waiting... (${_i}s)"
    sleep 1
  done
  if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    log "Docker ready ($(elapsed)s)"
  else
    log_err "FATAL: Docker failed to start after ${DOCKER_TIMEOUT}s"
    return 1
  fi
}

cmd_dockerd_down() {
  log "Stopping Docker daemon..."
  systemctl stop docker 2>/dev/null
  log "Docker stopped"
}

cmd_hm_update() {
  [ "$HM_DELIVERY" = "docker" ] && [ -n "$HM_IMAGE" ] || return 0
  log "HM self-update..."
  _old=$(docker inspect --format '{{.Id}}' "$HM_IMAGE" 2>/dev/null || echo "none")
  if docker pull "$HM_IMAGE" >/dev/null 2>&1; then
    _new=$(docker inspect --format '{{.Id}}' "$HM_IMAGE" 2>/dev/null || echo "none")
    if [ "$_old" != "$_new" ]; then
      log "  HM image updated — activating"
      _hm_home=$(eval echo "~$HM_USER")
      docker run --rm -v /:/host -e HM_HOST_ROOT=/host "$HM_IMAGE" 2>&1 | while IFS= read -r _l; do log "    $_l"; done
      log "  HM activated"
    else
      log "  HM unchanged"
    fi
  else
    log "  HM pull failed — using existing"
  fi
}

cmd_cloud_data_sync() {
  log "Cloud-data sync..."
  mkdir -p "$(dirname "$CLOUD_DATA_DIR")" 2>/dev/null || true
  if [ -d "$CLOUD_DATA_DIR/.git" ]; then
    (cd "$CLOUD_DATA_DIR" && git fetch origin main 2>&1 && git reset --hard origin/main 2>&1) >/dev/null 2>&1 \
      && log "  cloud-data updated" || log "  cloud-data pull failed — using cached"
  else
    git clone --depth 1 "$CLOUD_DATA_REPO" "$CLOUD_DATA_DIR" >/dev/null 2>&1 \
      && log "  cloud-data cloned" || log_err "  cloud-data clone failed"
  fi
}

# Resolve declared services from per-VM manifest.
# Probe order:
#   1. /opt/scripts/build-vm.json — NEW canonical, deployed by home-manager
#      from 1_cloud-configs/dist/build-vm-{vm}.json. cloud-data emits NOTHING; this
#      is the only declarative source going forward.
#   2. $CLOUD_DATA_DIR/cloud-data-containers-${VM_ALIAS}.json — LEGACY fallback
#      for VMs not yet re-shipped under the new pattern. Remove once all VMs
#      have been redeployed and verified.
# Both files have the same `.services[].compose_path` shape (verified against
# 1_cloud-configs/dist/build-vm-oci-mail.json).
_get_services() {
  _json=""
  for _p in "/opt/scripts/build-vm.json" "$CLOUD_DATA_DIR/cloud-data-containers-${VM_ALIAS}.json"; do
    if [ -f "$_p" ] && [ -s "$_p" ] && jq -e '.services | length > 0' "$_p" >/dev/null 2>&1; then
      _json="$_p" && break
    fi
  done
  [ -z "$_json" ] && { log_err "No manifest for vm=$VM_ALIAS (probed /opt/scripts/build-vm.json + $CLOUD_DATA_DIR/cloud-data-containers-${VM_ALIAS}.json)"; return 1; }
  jq -r '.services[].compose_path' "$_json"
}

# Start a single service by directory path
_service_up() {
  _dir="$1"
  _svc=$(basename "$_dir")
  _start=$(date +%s)
  log "  [$_svc] mem=$(mem_free)MB"

  # Pull configs image if available
  _cfg="${REGISTRY}/${_svc}-configs:latest"
  _old_id=$(docker inspect --format '{{.Id}}' "$_cfg" 2>/dev/null || echo "none")
  if docker pull "$_cfg" >/dev/null 2>&1; then
    _new_id=$(docker inspect --format '{{.Id}}' "$_cfg" 2>/dev/null || echo "none")
    if [ "$_old_id" != "$_new_id" ]; then
      log "  [$_svc] configs updated — extracting"
      mkdir -p "$_dir" 2>/dev/null || true
      docker run --rm -v "$_dir:/out" "$_cfg" 2>/dev/null
    fi
  fi

  # Pull + run (no build — images are pre-built on GHCR)
  # Configs images extract compose under compose/ (2026-07-03 layout) —
  # support both the legacy top-level and the compose/ subdir location.
  #
  # ALWAYS run from $_dir with `--project-directory .` — never `cd compose/`.
  # Compose resolves BOTH the project name and every `env_file:` against the
  # project directory, so cd-ing into compose/ broke two things at once:
  #   1. env_file: [".secrets"] resolved to compose/.secrets and the service
  #      aborted with "env file ... not found". 41 of the 67 compose/-layout
  #      services on oci-apps keep .secrets at the service root — the majority.
  #   2. the project name became the literal string "compose" for EVERY
  #      service, so named volumes were created as compose_<vol> instead of
  #      <service>_<vol> — i.e. the service came up on a fresh empty volume
  #      while its real data sat in the project-named one. oci-apps still
  #      carries 10 orphaned compose_* volumes from this.
  # This is the same invocation the ship engine uses, which is why ship-
  # deployed services land on the right volumes and container-init's did not
  # (1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh).
  _crel="docker-compose.yml"
  [ ! -f "$_dir/$_crel" ] && [ -f "$_dir/compose/docker-compose.yml" ] && _crel="compose/docker-compose.yml"
  if [ -f "$_dir/$_crel" ]; then
    _cf="-f $_crel --project-directory ."
    _env=""
    [ -f "$_dir/.secrets" ] && _env="--env-file .secrets"
    # Pre-hook (e.g. init.sh for secret substitution)
    [ -f "$_dir/init.sh" ] && (cd "$_dir" && sh init.sh) 2>&1 | while read -r _l; do log "  [$_svc] $_l"; done
    if (cd "$_dir" && docker compose $_cf $_env pull --quiet 2>/dev/null; docker compose $_cf $_env up -d --no-build --force-recreate) >/dev/null 2>&1; then
      _s=$(( $(date +%s) - _start ))
      log "  [$_svc] ok (${_s}s)"
      return 0
    else
      _s=$(( $(date +%s) - _start ))
      log_err "  [$_svc] FAILED (${_s}s)"
      return 1
    fi
  else
    log "  [$_svc] no docker-compose.yml — skipping"
    return 0
  fi
}

# Stop a single service by directory path
_service_down() {
  _dir="$1"
  _svc=$(basename "$_dir")
  # Same project-directory rule as _service_up — a `down` run from compose/
  # targets project "compose" and so leaves the real containers running.
  _crel="docker-compose.yml"
  [ ! -f "$_dir/$_crel" ] && [ -f "$_dir/compose/docker-compose.yml" ] && _crel="compose/docker-compose.yml"
  if [ -f "$_dir/$_crel" ]; then
    _cf="-f $_crel --project-directory ."
    _env=""
    [ -f "$_dir/.secrets" ] && _env="--env-file .secrets"
    (cd "$_dir" && docker compose $_cf $_env down) 2>&1 | while read -r _l; do log "  [$_svc] $_l"; done
    log "  [$_svc] stopped"
  fi
}

cmd_containers_up() {
  log "═══ Pull + Start all services ═══"
  _started=0; _failed=0; _results=""
  _services=$(_get_services) || return 1
  _count=$(echo "$_services" | wc -w)
  log "Declared: $_count services"

  for _dir in $_services; do
    _svc=$(basename "$_dir")
    _t=$(date +%s)
    if _service_up "$_dir"; then
      _s=$(( $(date +%s) - _t ))
      _started=$((_started + 1))
      _results="${_results}{\"name\":\"$_svc\",\"s\":$_s,\"ok\":true},"
    else
      _s=$(( $(date +%s) - _t ))
      _failed=$((_failed + 1))
      _results="${_results}{\"name\":\"$_svc\",\"s\":$_s,\"ok\":false},"
    fi
    sleep "$START_DELAY"
  done

  log "Result: $_started ok, $_failed failed ($(elapsed)s)"
  # Export for boot report
  STARTED=$_started; FAILED=$_failed; BOOT_RESULTS=$_results; PROJECT_COUNT=$_count
}

cmd_containers_down() {
  log "═══ Stopping all services ═══"
  _services=$(_get_services) || return 1
  for _dir in $_services; do
    _service_down "$_dir"
  done
  log "All services stopped"
}

cmd_containers_restart() {
  cmd_containers_down
  sleep 2
  cmd_containers_up
}

cmd_service_up() {
  _name="${1:?Usage: container-init service-up <name>}"
  _dir="${CONTAINERS_DIR}/${_name}"
  [ -d "$_dir" ] || { log_err "Service dir not found: $_dir"; return 1; }
  _service_up "$_dir"
}

cmd_service_down() {
  _name="${1:?Usage: container-init service-down <name>}"
  _dir="${CONTAINERS_DIR}/${_name}"
  [ -d "$_dir" ] || { log_err "Service dir not found: $_dir"; return 1; }
  _service_down "$_dir"
}

cmd_health() {
  log "═══ Health check ═══"
  _healthy=0; _total=0; _unhealthy=""

  for _cid in $(docker ps -q 2>/dev/null); do
    _total=$((_total + 1))
    _name=$(docker inspect --format='{{.Name}}' "$_cid" 2>/dev/null | sed 's/^\///')
    _has_hc=$(docker inspect --format='{{if .Config.Healthcheck}}yes{{else}}no{{end}}' "$_cid" 2>/dev/null || echo "no")

    if [ "$_has_hc" = "yes" ]; then
      _h="starting"; _w=0
      while [ "$_h" = "starting" ] && [ "$_w" -lt 120 ]; do
        _h=$(docker inspect --format='{{.State.Health.Status}}' "$_cid" 2>/dev/null || echo "unknown")
        [ "$_h" = "starting" ] && sleep 5 && _w=$((_w + 5))
      done
      if [ "$_h" = "healthy" ]; then
        _healthy=$((_healthy + 1))
      else
        log_err "  $_name: UNHEALTHY ($_h)"
        docker restart "$_cid" >/dev/null 2>&1
        _unhealthy="$_unhealthy $_name"
      fi
    else
      _st=$(docker inspect --format='{{.State.Status}}' "$_cid" 2>/dev/null || echo "unknown")
      if [ "$_st" = "running" ]; then
        _healthy=$((_healthy + 1))
      else
        _unhealthy="$_unhealthy $_name"
      fi
    fi
  done

  log "Health: $_healthy/$_total healthy ($(elapsed)s)"
  # Export for boot report
  HEALTHY=$_healthy; TOTAL=$_total; UNHEALTHY=$_unhealthy
}

cmd_status() {
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo "Docker not running"
}

cmd_boot_report() {
  TOTAL_S=$(elapsed)
  cat > "$BOOT_JSON" 2>/dev/null <<REPORT || true
{"boot":"$(date -Iseconds)","vm":"$VM_ALIAS","hostname":"$HOSTNAME","projects":${PROJECT_COUNT:-0},"started":${STARTED:-0},"failed":${FAILED:-0},"containers":${TOTAL:-0},"healthy":${HEALTHY:-0},"total_s":$TOTAL_S,"detail":[${BOOT_RESULTS%,}]}
REPORT

  if [ -n "${UNHEALTHY:-}" ]; then
    ntfy "UNHEALTHY:$UNHEALTHY" "${STARTED:-0}/${PROJECT_COUNT:-0} | ${HEALTHY:-0}/${TOTAL:-0} healthy | ${TOTAL_S}s" "high" "warning"
  elif [ "${FAILED:-0}" -gt 0 ]; then
    ntfy "$FAILED failed" "${STARTED:-0}/${PROJECT_COUNT:-0} | ${HEALTHY:-0}/${TOTAL:-0} healthy | ${TOTAL_S}s" "high" "warning"
  else
    ntfy "OK: ${PROJECT_COUNT:-0} svcs" "${HEALTHY:-0}/${TOTAL:-0} healthy | ${TOTAL_S}s" "default" "white_check_mark"
  fi
}

# ══════════════════════════════════════════════════════════════
# FULL BOOT SEQUENCE (default — no args)
# ══════════════════════════════════════════════════════════════
cmd_boot() {
  log "═══ BOOT: $VM_ALIAS ($HOSTNAME) mem=$(mem_free)MB ═══"
  cmd_dockerd_up || exit 1
  cmd_hm_update
  cmd_cloud_data_sync
  cmd_containers_up
  sleep 10
  cmd_health
  cmd_boot_report
  log "═══ COMPLETE ($(elapsed)s) ═══"
}

# ══════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════
case "${1:-boot}" in
  boot)               cmd_boot ;;
  dockerd-up)         cmd_dockerd_up ;;
  dockerd-down)       cmd_dockerd_down ;;
  nixhm-up)           cmd_dockerd_up && cmd_hm_update ;;
  containers-up)      cmd_containers_up ;;
  containers-down)    cmd_containers_down ;;
  containers-restart) cmd_containers_restart ;;
  service-up)         cmd_service_up "${2:-}" ;;
  service-down)       cmd_service_down "${2:-}" ;;
  health)             cmd_health ;;
  status)             cmd_status ;;
  *)                  echo "Usage: $0 {boot|dockerd-up|dockerd-down|nixhm-up|containers-up|containers-down|containers-restart|service-up <name>|service-down <name>|health|status}" >&2; exit 1 ;;
esac
