#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════╗
# ║ Universal Home Manager build engine                           ║
# ║ Symlinked as build.sh in each VM directory                    ║
# ║ All behavior driven by build.json — zero hardcoded VM names   ║
# ║                                                               ║
# ║ Steps are sourced from cloud-ship-nix-homemanager-step-*.sh   ║
# ╚════════════════════════════════════════════════════════════════╝
# -E (errtrace): inherit ERR trap into command substitutions, subshells
# and PIPELINES. Without it, `set -e + pipefail` exits silently on a
# pipeline failure (e.g. `echo $T | docker login`) and the ERR trap below
# never fires — leading to "FAIL <vm> (exit 1)" with no FATAL log line.
set -Eeuo pipefail

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR")"
# Repo root: SERVICE_DIR is b_infra/nixhm-sudo-<vm>, so ../.. is the cloud repo.
# Steps use this to locate shared flakes. It was never set, so step-build-docker's
# `${CLOUD_ROOT:?}` killed every deploy under `set -u` before any nix build ran
# (2026-08-11: 4/4 VMs failed this way). Honour a caller-provided value if any.
CLOUD_ROOT="${CLOUD_ROOT:-$(cd "$SERVICE_DIR/../.." && pwd)}"
export CLOUD_ROOT
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"
BUILD_LOG_FILE="$SERVICE_DIR/build.log"
CURRENT_STEP=""

# ── Config reader ───────────────────────────────────────────────
get_config() {
    [ ! -f "$CONFIG" ] && return 0
    node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(v===false?'false':v===true?'true':String(v!=null?v:''))"
}

# ── Load config ───────────────────────────────────────────────────────
if [ -f "$CONFIG" ]; then
    DEPLOY_HOST="$(get_config deploy.host)"
    DEPLOY_PATH="$(get_config deploy.remote_path)"
    HM_CONFIG="$(get_config hm.config)"
    REMOTE_BUILD="$(get_config hm.remote_build)"
    HM_DELIVERY="$(get_config hm.delivery)"
    HM_IMAGE="$(get_config hm.image)"
    HM_PLATFORM="$(get_config hm.platform)"
    HM_REMOTE_BUILDER="$(get_config hm.remote_builder)"
    HM_USER="$(get_config hm.user)"
else
    echo "FATAL: $CONFIG not found"
    exit 1
fi

# Required field
if [ -z "$HM_USER" ]; then
    echo "FATAL: hm.user not set in build.json"
    exit 1
fi

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# ── Error trap ──────────────────────────────────────────────────────
_on_error() {
    local rc=$?
    if [ -n "$CURRENT_STEP" ]; then
        log "FATAL: step '$CURRENT_STEP' failed (exit $rc)"
    fi
    exit "$rc"
}
trap _on_error ERR

# ── Logging: console + persistent build.log ───────────────────────────
: > "$BUILD_LOG_FILE"

log() {
    _msg="[$(date '+%H:%M:%S')] $1"
    printf '%s\n' "$_msg"
    printf '%s\n' "$_msg" >> "$BUILD_LOG_FILE"
}

# Log a command's stdout+stderr to both console and build.log
# Usage: run_logged <description> <command> [args...]
run_logged() {
    _desc="$1"; shift
    log "RUN: $_desc"
    log "CMD: $*"
    # `trap - ERR` IS REQUIRED HERE — `set +e` ALONE DOES NOT DISARM AN ERR TRAP.
    # This file runs under `set -Eeuo pipefail` with `trap _on_error ERR`, and
    # _on_error calls `exit`. In bash, `set +e` only clears errexit; the ERR trap
    # still fires on any failing simple command. So without this the failing
    # command below killed the whole engine BEFORE `_exit` was assigned, and the
    # `log "FAILED (exit ...)"` line was unreachable dead code.
    # Verified in bash 5.2.37 (2026-08-12): with the trap armed, `set +e; false;
    # RC=$?` exits immediately and RC is never assigned.
    set +e; trap - ERR
    "$@" 2>&1 | tee -a "$BUILD_LOG_FILE"
    _exit=${PIPESTATUS[0]}
    trap _on_error ERR; set -e
    if [ "$_exit" -ne 0 ]; then
        log "FAILED (exit $_exit): $_desc"
        return "$_exit"
    fi
    log "OK: $_desc"
    return 0
}

# run_with_retry: wrap a command with timeout + retry loop + optional recovery hook.
# Defeats two failure modes:
#   1. Stalled command (no progress, no exit) — `timeout` enforces a wall-clock deadline.
#   2. Stale state across retries (e.g. buildkit cached digest from a previous killed push
#      that the registry never received) — RETRY_RECOVERY_CMD runs between failed attempts
#      to reset state.
#
# Knobs (read from build.json, with safe defaults):
#   build.retry.attempts       — total attempts (default 3)
#   build.retry.timeout_secs   — per-attempt deadline (default 1200 = 20 min)
#   build.retry.backoff_secs   — sleep between attempts (default 30)
#
# Recovery hook (env var, NOT in build.json — set by the caller per-step):
#   RETRY_RECOVERY_CMD         — shell command run between failed attempts
#                                (e.g. `docker restart buildx_buildkit_multiarch0` for
#                                 docker buildx --push to clear stale push tracker state)
#
# Usage: run_with_retry <description> <command> [args...]
run_with_retry() {
    _desc="$1"; shift
    _attempts="$(get_config build.retry.attempts)"; [ -z "$_attempts" ] && _attempts=3
    _timeout="$(get_config build.retry.timeout_secs)"; [ -z "$_timeout" ] && _timeout=1200
    _backoff="$(get_config build.retry.backoff_secs)"; [ -z "$_backoff" ] && _backoff=30

    _try=0
    while [ "$_try" -lt "$_attempts" ]; do
        _try=$(( _try + 1 ))
        log "RUN: $_desc (attempt $_try/$_attempts, timeout ${_timeout}s)"
        log "CMD: $*"
        # trap - ERR: see run_logged. Without it the ERR trap exits the engine on
        # the FIRST failing attempt, so retries 2..N never run and no
        # "FAILED (exit N) ... (attempt 1/3)" line is ever logged. Observed in
        # b_infra/nixhm-sudo-oci-mail/build.log: a buildx failure on attempt 1/3
        # produced an immediate "FATAL: step 'docker-push' failed" with attempts
        # 2 and 3 silently skipped — the retry logic has never actually run.
        set +e; trap - ERR
        # --kill-after=30s: SIGKILL children 30s after SIGTERM if still alive
        timeout --kill-after=30s "${_timeout}s" "$@" 2>&1 | tee -a "$BUILD_LOG_FILE"
        _exit=${PIPESTATUS[0]}
        trap _on_error ERR; set -e

        if [ "$_exit" -eq 0 ]; then
            log "OK: $_desc (attempt $_try)"
            return 0
        fi

        # exit 124 = SIGTERM from timeout, 137 = SIGKILL from --kill-after
        if [ "$_exit" -eq 124 ] || [ "$_exit" -eq 137 ]; then
            log "TIMEOUT (exit $_exit) after ${_timeout}s: $_desc (attempt $_try/$_attempts)"
        else
            log "FAILED (exit $_exit): $_desc (attempt $_try/$_attempts)"
        fi

        if [ "$_try" -lt "$_attempts" ]; then
            if [ -n "${RETRY_RECOVERY_CMD:-}" ]; then
                log "Recovery hook: $RETRY_RECOVERY_CMD"
                # trap - ERR: see run_logged. A recovery hook is EXPECTED to fail
                # sometimes (that is why its exit code is logged rather than
                # checked); without disarming the trap, a failing hook killed the
                # deploy outright instead of falling through to the next attempt.
                set +e; trap - ERR
                bash -c "$RETRY_RECOVERY_CMD" 2>&1 | tee -a "$BUILD_LOG_FILE"
                _rec_exit=${PIPESTATUS[0]}
                trap _on_error ERR; set -e
                log "Recovery hook exit: $_rec_exit"
            fi
            log "Retrying in ${_backoff}s..."
            sleep "$_backoff"
        fi
    done

    log "FAILED after $_attempts attempts: $_desc"
    return "$_exit"
}

# ── SSH config (data-driven from build.json — Fire Rule #4) ─────────
# Inside cloud-builder container, ~/.ssh/config has no Host alias for
# DEPLOY_HOST (e.g. "gcp-proxy"). step_compose / step_deploy do
# `ssh "$DEPLOY_HOST"` and fail with "Could not resolve hostname".
# Write a Host stanza from build.json's vm.network.wg_ip + hm.user once
# at engine-load time. Idempotent: if the Host alias already exists in
# ~/.ssh/config, do not duplicate.
ensure_ssh_host_alias() {
    [ -z "${DEPLOY_HOST:-}" ] && return 0
    [ "$DEPLOY_HOST" = "local" ] && return 0
    local wg_ip user pub_ip
    wg_ip="$(get_config vm.network.wg_ip)"
    pub_ip="$(get_config vm.network.public_ip)"
    user="${HM_USER:-ubuntu}"
    # Prefer wg_ip (works when WireGuard is up); fall back to public_ip.
    local host="${wg_ip:-$pub_ip}"
    [ -z "$host" ] && return 0
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    # Resolve the right private key from cloud-data's consolidated JSON.
    # vms[*].gha.ssh_secret names the env var (e.g. GCP_PROXY_SSH_KEY).
    # The runner only writes id_deploy from OCI_SSH_KEY, so for non-OCI VMs
    # id_deploy is the wrong key; we materialise the correct one here.
    local cons="" cand secret key_val key_file="$HOME/.ssh/id_deploy"
    # Workspace root: env override > /root/git default (CI mount path).
    # Bare /root/git/... literals are forbidden by test_engine_workspace_paths_derived.
    local _ws="${WORKSPACE:-/root/git}"
    for cand in "$_ws/cloud/1_cloud-configs/dist/_cloud-data-consolidated.json" \
                "$_ws/cloud-data/_cloud-data-consolidated.json" \
                "${HOME}/git/cloud-t-infra/1_cloud-configs/dist/_cloud-data-consolidated.json"; do
        [ -f "$cand" ] && cons="$cand" && break
    done
    if [ -n "$cons" ] && command -v jq >/dev/null 2>&1; then
        secret=$(jq -r --arg a "$DEPLOY_HOST" '.vms | to_entries[] | select(.value.ssh_alias==$a) | .value.gha.ssh_secret // empty' "$cons" 2>/dev/null | head -1)
        if [ -n "$secret" ]; then
            eval "key_val=\${$secret:-}"
            if [ -n "$key_val" ]; then
                key_file="$HOME/.ssh/id_${secret}"
                printf '%s\n' "$key_val" > "$key_file"
                chmod 600 "$key_file"
            fi
        fi
    fi
    if [ -f "$HOME/.ssh/config" ] && grep -q "^Host ${DEPLOY_HOST}\$" "$HOME/.ssh/config" 2>/dev/null; then
        return 0
    fi
    cat >> "$HOME/.ssh/config" <<EOF
Host ${DEPLOY_HOST}
  HostName ${host}
  User ${user}
  IdentityFile ${key_file}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ServerAliveInterval 30
  ServerAliveCountMax 10

EOF
    chmod 600 "$HOME/.ssh/config"
    log "[ssh] Host ${DEPLOY_HOST} → ${user}@${host} (key=${key_file##*/})"
}
ensure_ssh_host_alias

# ── SSH multiplexing ────────────────────────────────────────────────
# TIMEOUTS AND KEEPALIVES ARE LOAD-BEARING — do not drop them for brevity.
# Every deploy SSH rides the WireGuard mesh, which can stall or drop without
# ever closing the socket. With no options beyond multiplexing, that produced
# two distinct failure shapes, both observed 2026-08-12:
#   * exit 255 mid-step, preceded by "mux_client_request_session: read from
#     master failed: Broken pipe" — the control master died and nothing
#     detected it until the next write.
#   * a job hanging until its 45-minute timeout-minutes cap and being
#     cancelled (oci-analytics, 14:12:28 -> 14:57:54), because a connect that
#     never completes has no deadline of its own.
# ConnectTimeout bounds the initial handshake; ServerAlive* detects a dead
# tunnel in ~60s (4 x 15s) instead of blocking on an unacknowledged write;
# BatchMode makes a missing/locked key fail immediately rather than waiting on
# a prompt that no CI runner will ever answer.
#
# These INTENTIONALLY override the weaker values ensure_ssh_host_alias writes
# into ~/.ssh/config above (ServerAliveInterval 30 / CountMax 10 = 300s to
# notice a dead link, and no ConnectTimeout or BatchMode at all): command-line
# -o beats the config file, so the effective detection window is 60s. Do not
# "deduplicate" these against that block — the config file is also used by
# humans running the engine by hand, where longer keepalives are reasonable.
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-hm-%r@%h -o ControlPersist=120"
SSH_OPTS="$SSH_OPTS -o ConnectTimeout=15 -o BatchMode=yes"
SSH_OPTS="$SSH_OPTS -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
# Bootstrap-time overrides for new VMs not yet in trusted SSH topology
# (e.g., freshly provisioned via Terraform with ephemeral IP, before WG
# is up). Setting SSH_HOST_OVERRIDE/SSH_KEY_OVERRIDE lets the engine
# target the new VM's raw IP using a bootstrap key, without requiring
# edits to ~/.ssh/config (which is read-only when home-manager owns it).
# Once the VM is in the trusted topology, unset these to resume normal
# alias-based routing.
if [ -n "${SSH_HOST_OVERRIDE:-}" ]; then
    SSH_OPTS="$SSH_OPTS -o HostName=${SSH_HOST_OVERRIDE}"
    log "[ssh] HostName override: ${SSH_HOST_OVERRIDE}"
fi
if [ -n "${SSH_KEY_OVERRIDE:-}" ]; then
    SSH_OPTS="$SSH_OPTS -o IdentityFile=${SSH_KEY_OVERRIDE} -o IdentitiesOnly=yes"
    log "[ssh] IdentityFile override: ${SSH_KEY_OVERRIDE}"
fi
if [ -n "${SSH_USER_OVERRIDE:-}" ]; then
    SSH_OPTS="$SSH_OPTS -o User=${SSH_USER_OVERRIDE}"
fi
# Transport-level retry for the short one-shot round trips (pre-flight df,
# prune, secrets mkdir/chmod, post-activate GC). Only exit 255 — ssh's own
# "could not connect / connection dropped" code — is retried; any other exit
# is the remote command's verdict and is returned as-is. Activation already
# had its own 255-retry, but these calls did not, so a single WireGuard blip
# from the runner (connect timeout on oci-mail, scp closed mid-transfer on
# oci-analytics, run 37152832299, #856) failed the whole VM's ship. Every
# caller is idempotent and none pipes stdin, so a resend is safe.
_SSH_RETRY_ATTEMPTS="${SSH_RETRY_ATTEMPTS:-4}"
_ssh_retry() {
    local _t=1 _rc
    while :; do
        "$@" && _rc=0 || _rc=$?
        [ "$_rc" -ne 255 ] && return "$_rc"
        [ "$_t" -ge "$_SSH_RETRY_ATTEMPTS" ] && { log "ssh transport to ${DEPLOY_HOST} failed (255) after ${_t} attempts"; return 255; }
        log "ssh transport to ${DEPLOY_HOST} dropped (255) — retry ${_t}/$((_SSH_RETRY_ATTEMPTS-1)) in $((10*_t))s"
        sleep $((10*_t)); _t=$((_t+1))
    done
}
ssh_vm() {
    _ssh_retry ssh $SSH_OPTS -o ConnectTimeout=20 "$DEPLOY_HOST" "$@"
}
scp_vm() {
    _ssh_retry scp $SSH_OPTS -o ConnectTimeout=20 "$@"
}

REMOTE_PATH="${DEPLOY_PATH:-\~/.config/home-manager}"

# ── Source step files ─────────────────────────────────────────────────
STEPS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
INJECT_HEADER="$STEPS_DIR/../../../9_others/src/inject-header.sh"
ENGINE_NAME="1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh"
export INJECT_HEADER ENGINE_NAME
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-pull-pilot.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-build-flake.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-secrets-decrypt.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-rsync.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-closure.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-activate.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-build-docker.sh"
. "$STEPS_DIR/cloud-ship-nix-homemanager-step-deploy-push.sh"

# ── Main ──────────────────────────────────────────────────────────────
# image | closure (step-deploy-closure.sh): <=1 GB VMs never docker-pull.
HM_TRANSPORT="$(hm_transport)"
if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ] && [ "$HM_TRANSPORT" = "closure" ]; then
    STRATEGY="closure built on runner → delta streamed to VM (low-memory, no docker pull)"
elif [ "$HM_DELIVERY" = "docker" ]; then
    STRATEGY="docker image → GHCR → VM pulls"
elif [ "$REMOTE_BUILD" = "true" ]; then
    STRATEGY="remote build on VM"
else
    STRATEGY="local build + nix copy"
fi

log "========================================"
log "  Home Manager: $SERVICE_NAME"
log "  Strategy: $STRATEGY"
log "  Transport: $HM_TRANSPORT"
log "  Host: ${DEPLOY_HOST:-none}"
log "  HM config: ${HM_CONFIG:-none}"
log "  Image: ${HM_IMAGE:-none}"
log "  Log: $BUILD_LOG_FILE"
log "========================================"

case "${1:-all}" in
    build)           CURRENT_STEP=build; step_build ;;
    secrets)         CURRENT_STEP=secrets; step_secrets ;;
    deploy)          CURRENT_STEP=deploy; step_deploy ;;
    compose)         CURRENT_STEP=compose; step_compose ;;
    docker-package)  CURRENT_STEP=build; step_build; CURRENT_STEP=secrets; step_secrets; CURRENT_STEP=docker-package; step_docker_package ;;
    docker-push)     CURRENT_STEP=docker-push; step_docker_push ;;
    all)             CURRENT_STEP=build; step_build; CURRENT_STEP=secrets; step_secrets ;;
    ship)
        if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ] && [ "$HM_TRANSPORT" = "closure" ]; then
            # Low-memory VM: same closure build, no image push, no VM pull.
            CURRENT_STEP=build;          step_build
            CURRENT_STEP=secrets;        step_secrets
            CURRENT_STEP=docker-package; step_docker_package
            CURRENT_STEP=compose;        step_compose
        elif [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
            CURRENT_STEP=build;          step_build
            CURRENT_STEP=secrets;        step_secrets
            CURRENT_STEP=docker-package; step_docker_package
            CURRENT_STEP=docker-push;    step_docker_push
            CURRENT_STEP=compose;        step_compose
        elif [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" = "true" ]; then
            log "Remote builder: deploy+compose (skip docker packaging)"
            CURRENT_STEP=build;   step_build
            CURRENT_STEP=secrets; step_secrets
            CURRENT_STEP=deploy;  step_deploy
            CURRENT_STEP=compose; step_compose
        else
            CURRENT_STEP=build;   step_build
            CURRENT_STEP=secrets; step_secrets
            CURRENT_STEP=deploy;  step_deploy
            CURRENT_STEP=compose; step_compose
        fi
        ;;
    clean)  [ -d "$DIST_DIR" ] && chmod -R u+w "$DIST_DIR" 2>/dev/null || true; rm -rf "$DIST_DIR" "$SERVICE_DIR/.closure-path"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|deploy|compose|docker-package|docker-push|all|ship|clean]"
        echo ""
        echo "  build           Prepare dist/ from src/ (resolve symlinks)"
        echo "  secrets         Decrypt secrets -> dist/.secrets"
        echo "  deploy          Build + copy closure (local) or rsync flake (remote)"
        echo "  compose         Activate home-manager on VM"
        echo "  docker-package  Build nix closure → Docker context with closure"
        echo "  docker-push     Build Docker image + push to GHCR"
        echo "  all             build + secrets (default)"
        echo "  ship            Full pipeline (docker or legacy based on hm.delivery)"
        echo "  clean           Remove dist/"
        ;;
esac

log "Done."
