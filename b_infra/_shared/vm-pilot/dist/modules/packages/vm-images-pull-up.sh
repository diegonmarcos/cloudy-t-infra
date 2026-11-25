#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/packages/vm-images-pull-up.sh
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# VM Images Pull & Up — serial Docker image pull + compose up
# POSIX sh — no bash required
#
# Usage:
#   vm-images-pull-up.sh                           # discover from /opt/containers/
#   vm-images-pull-up.sh --manifest file.json      # read services from JSON manifest
#   vm-images-pull-up.sh --manifest file.json svc  # filter to one service
#
# Phase 1: Serial docker pull for each service (avoids memory spike)
# Phase 2: Serial docker compose up for each service
#
# Managed by home-manager — DO NOT EDIT on VM
# Source: cloud/b_infra/_shared/modules/vm-images-pull-up.sh

set -u
HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")
LOG="/var/log/images-pull-up.log"
CONTAINERS_DIR="/opt/containers"
MANIFEST=""
FILTER=""

# ── Parse args ──────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    *)          FILTER="$1"; shift ;;
  esac
done

log() {
  MSG="$(date -Is) [$HOSTNAME] [images-pull-up] $1"
  printf '%s\n' "$MSG" >> "$LOG" 2>/dev/null && sync "$LOG" 2>/dev/null
  printf '%s\n' "$MSG"
}

die() { log "FATAL: $1"; exit 1; }

# Resolve the SERVICE ROOT of a service directory (empty if it has no compose
# file in either layout).
#
# It must stay at the ROOT and drive compose with
# `-f compose/docker-compose.yml --project-directory .`, never `cd .../compose`:
# cd'ing INTO compose/ makes compose/ the compose project directory, so compose
# resolves `env_file: [".secrets"]` and the ./.secrets.d + ./.secrets.json bind
# mounts against compose/ — while the ship engine scp's all three to the service
# ROOT (cloud-ship-container-step-deploy-rsync.sh) and itself runs compose with
# `--project-directory .` there. So EVERY v2-layout service died with
# "env file /opt/containers/<svc>/compose/.secrets not found"
# (gha-runner on oci-apps, 2026-09-05), making single-service recreation
# unusable. Same bug, same fix as c3-infra-api's composeCd (1a87a55d).
find_service_root() {
  if [ -f "$1/docker-compose.yml" ] || [ -f "$1/compose/docker-compose.yml" ]; then
    printf '%s' "${1%/}"
  fi
}

# Global compose flags for a service ROOT: v2 layout (compose/) needs the -f +
# --project-directory pair, v1 layout needs nothing. `if`/`fi` rather than a
# bare test-and-print so the function exits 0 on BOTH branches — a v1 service
# must not poison the `&&` chains of its callers.
compose_flags() {
  if [ -f "$1/compose/docker-compose.yml" ]; then
    printf '%s' "-f compose/docker-compose.yml --project-directory ."
  fi
}

# ── Pre-flight ──────────────────────────────────────────────────
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  log "Docker not running — starting"
  sudo systemctl start docker 2>/dev/null || true
  sleep 3
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || die "Docker failed to start"
fi

# GHCR login - always refresh when token available; stale stored creds cause "denied" on public images
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-diegonmarcos}" --password-stdin 2>/dev/null
  log "GHCR: logged in"
else
  docker logout ghcr.io >/dev/null 2>&1 || true
  log "GHCR: no token — cleared stale creds, using anonymous pull"
fi

# ── Discover services ───────────────────────────────────────────
# Two modes: manifest JSON or filesystem discovery

if [ -n "$MANIFEST" ]; then
  # ── Manifest mode: read from JSON ──
  [ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"
  command -v jq >/dev/null 2>&1 || die "jq required for manifest mode"

  TOTAL=$(jq '.services | length' "$MANIFEST")
  log "START: manifest=$MANIFEST ($TOTAL services, filter=${FILTER:-all})"

  # ── Phase 1: Serial pull ──────────────────────────────────────
  log "═══ PHASE 1: Pulling images ═══"
  PULL_OK=0; PULL_FAIL=0; IDX=0

  for i in $(seq 0 $((TOTAL - 1))); do
    NAME=$(jq -r ".services[$i].name" "$MANIFEST")
    COMPOSE_PATH=$(jq -r ".services[$i].compose_path" "$MANIFEST")
    HAS_BUILD=$(jq -r ".services[$i].has_docker_build" "$MANIFEST")
    IMAGES=$(jq -r ".services[$i].images[]" "$MANIFEST" 2>/dev/null)

    [ -n "$FILTER" ] && [ "$NAME" != "$FILTER" ] && continue
    IDX=$((IDX + 1))

    # Pull explicit images (skip build-only services)
    if [ -n "$IMAGES" ] && [ "$HAS_BUILD" != "true" ]; then
      for img in $IMAGES; do
        log "[$IDX] PULL: $img ($NAME)"
        if docker pull "$img" 2>&1; then
          PULL_OK=$((PULL_OK + 1))
        else
          log "[$IDX] PULL FAIL: $img"
          PULL_FAIL=$((PULL_FAIL + 1))
        fi
      done
    elif [ -d "$COMPOSE_PATH" ] && [ -n "$(find_service_root "$COMPOSE_PATH")" ]; then
      # Fallback: extract images from compose and pull individually
      # (docker compose pull spawns heavy Go binary — kills E2 micros)
      EFF_ROOT=$(find_service_root "$COMPOSE_PATH")
      C_FLAGS=$(compose_flags "$EFF_ROOT")
      ENV_FLAG=""
      [ -f "$EFF_ROOT/.secrets" ] && ENV_FLAG="--env-file $EFF_ROOT/.secrets"
      log "[$IDX] PULL IMAGES: $NAME"
      if (cd "$EFF_ROOT" && docker compose $C_FLAGS $ENV_FLAG config --images 2>/dev/null | sort -u | while read img; do docker pull "$img" 2>/dev/null || true; done); then
        PULL_OK=$((PULL_OK + 1))
      else
        PULL_FAIL=$((PULL_FAIL + 1))
      fi
    fi

    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    log "[$IDX] mem_free=${MEM_AVAIL}MB after $NAME"
  done

  log "PHASE 1 DONE: $PULL_OK pulled, $PULL_FAIL failed"

  # ── Phase 2: Serial compose up ────────────────────────────────
  log "═══ PHASE 2: Starting containers ═══"
  UP_OK=0; UP_FAIL=0; IDX=0

  for i in $(seq 0 $((TOTAL - 1))); do
    NAME=$(jq -r ".services[$i].name" "$MANIFEST")
    COMPOSE_PATH=$(jq -r ".services[$i].compose_path" "$MANIFEST")
    HAS_BUILD=$(jq -r ".services[$i].has_docker_build" "$MANIFEST")

    [ -n "$FILTER" ] && [ "$NAME" != "$FILTER" ] && continue
    [ -d "$COMPOSE_PATH" ] || { log "SKIP: $NAME ($COMPOSE_PATH not found)"; continue; }
    EFF_ROOT=$(find_service_root "$COMPOSE_PATH")
    [ -n "$EFF_ROOT" ] || { log "SKIP: $NAME (no docker-compose.yml)"; continue; }
    C_FLAGS=$(compose_flags "$EFF_ROOT")
    IDX=$((IDX + 1))

    ENV_FLAG=""
    [ -f "$EFF_ROOT/.secrets" ] && ENV_FLAG="--env-file $EFF_ROOT/.secrets"

    log "[$IDX] UP: $NAME"
    if (cd "$EFF_ROOT" && docker compose $C_FLAGS $ENV_FLAG pull --quiet 2>/dev/null; docker compose $C_FLAGS $ENV_FLAG up -d --no-build --force-recreate 2>&1); then
      log "[$IDX] UP OK: $NAME"
      UP_OK=$((UP_OK + 1))
    else
      log "[$IDX] UP FAIL: $NAME (exit $?)"
      UP_FAIL=$((UP_FAIL + 1))
    fi

    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    CTRS=$(docker ps -q 2>/dev/null | wc -l)
    log "[$IDX] mem_free=${MEM_AVAIL}MB containers=$CTRS after $NAME"
  done

else
  # ── Filesystem discovery mode (backward compatible) ──
  [ -d "$CONTAINERS_DIR" ] || die "$CONTAINERS_DIR not found"

  SERVICES=""
  TOTAL=0
  for dir in "$CONTAINERS_DIR"/*/; do
    [ -d "$dir" ] || continue
    [ -n "$(find_service_root "$dir")" ] || continue
    # A retired service keeps its directory (it holds the volume backup written
    # by `build.sh retire`), so presence on disk is not a declaration. Without
    # this the dir is re-discovered every run and the service resurrects long
    # after it was archived in the repo — how bc-obs_fluent-bit stayed deployed
    # on oci-analytics with no reference left in cloud-fleet-declared.json.
    if [ -f "$dir/.retired" ]; then
      log "SKIP: $(basename "$dir") — retired $(cat "$dir/.retired" 2>/dev/null)"
      continue
    fi
    name=$(basename "$dir")
    [ -n "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
    SERVICES="$SERVICES $name"
    TOTAL=$((TOTAL + 1))
  done

  [ "$TOTAL" -eq 0 ] && { log "No services found"; exit 0; }
  log "START: filesystem discovery ($TOTAL services, filter=${FILTER:-all})"

  # Phase 1: Serial pull
  log "═══ PHASE 1: Pulling images ═══"
  PULL_OK=0; PULL_FAIL=0; IDX=0
  for name in $SERVICES; do
    IDX=$((IDX + 1))
    dir="$CONTAINERS_DIR/$name"
    eff_root=$(find_service_root "$dir")
    c_flags=$(compose_flags "$eff_root")
    ENV_FLAG=""
    [ -f "$eff_root/.secrets" ] && ENV_FLAG="--env-file $eff_root/.secrets"
    log "[$IDX/$TOTAL] PULL: $name"
    if (cd "$eff_root" && docker compose $c_flags $ENV_FLAG config --images 2>/dev/null | sort -u | while read img; do docker pull "$img" 2>/dev/null || true; done); then
      PULL_OK=$((PULL_OK + 1))
    else
      PULL_FAIL=$((PULL_FAIL + 1))
    fi
    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    log "[$IDX/$TOTAL] mem_free=${MEM_AVAIL}MB after $name"
  done
  log "PHASE 1 DONE: $PULL_OK pulled, $PULL_FAIL failed"

  # Phase 2: Serial compose up
  log "═══ PHASE 2: Starting containers ═══"
  UP_OK=0; UP_FAIL=0; IDX=0
  for name in $SERVICES; do
    IDX=$((IDX + 1))
    dir="$CONTAINERS_DIR/$name"
    eff_root=$(find_service_root "$dir")
    c_flags=$(compose_flags "$eff_root")
    ENV_FLAG=""
    [ -f "$eff_root/.secrets" ] && ENV_FLAG="--env-file $eff_root/.secrets"
    log "[$IDX/$TOTAL] UP: $name"
    if (cd "$eff_root" && docker compose $c_flags $ENV_FLAG pull --quiet 2>/dev/null; docker compose $c_flags $ENV_FLAG up -d --no-build --force-recreate 2>&1); then
      UP_OK=$((UP_OK + 1))
    else
      UP_FAIL=$((UP_FAIL + 1))
    fi
    MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")
    CTRS=$(docker ps -q 2>/dev/null | wc -l)
    log "[$IDX/$TOTAL] mem_free=${MEM_AVAIL}MB containers=$CTRS after $name"
  done
fi

# ── Summary ─────────────────────────────────────────────────────
TOTAL_CTRS=$(docker ps -q 2>/dev/null | wc -l)
HEALTHY=$(docker ps --filter health=healthy -q 2>/dev/null | wc -l)
MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "?")

log "═══ DONE ═══"
log "Pull: ${PULL_OK:-0} ok, ${PULL_FAIL:-0} fail | Up: ${UP_OK:-0} ok, ${UP_FAIL:-0} fail"
log "Containers: $TOTAL_CTRS running ($HEALTHY healthy) | mem_free=${MEM_AVAIL}MB"

[ "${PULL_FAIL:-0}" -gt 0 ] || [ "${UP_FAIL:-0}" -gt 0 ] && exit 1
exit 0
