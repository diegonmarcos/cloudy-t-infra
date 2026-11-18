# Step: Activate home-manager on VM
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly

# ── Docker socket API helpers ───────────────────────────────────────────
# When docker CLI is missing on the VM (e.g. nix GC'd docker-client),
# fall back to curl against the Docker Engine unix socket.
DOCKER_SOCK="/var/run/docker.sock"

# Build the remote script that runs on the VM via SSH.
# This script auto-detects docker CLI vs socket API and uses the right one.
_build_docker_activate_script() {
    cat <<'REMOTE_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
DOCKER_SOCK="/var/run/docker.sock"
IMAGE="@@IMAGE@@"
TAG="@@TAG@@"
HM_USER="@@HM_USER@@"
FULL_IMAGE="${IMAGE}:${TAG}"
# image: pull + activation container (Steps 0-3.5). closure: the runner has
# already streamed the store paths and left the DB dump + activation path
# (step-deploy-closure.sh), so dockerd is not needed: skip straight to Step 4.
HM_TRANSPORT="@@TRANSPORT@@"

export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

if [ "$HM_TRANSPORT" = closure ]; then
    echo "[hm-docker] Transport: closure (no docker pull, no activation container)"
else

# ── Self-heal: corrupt /etc/docker/daemon.json blocks dockerd entirely ──
# 2026-07-03 oci-mail: a torn write left two concatenated JSON objects and
# dockerd refused to boot — the docker-image HM delivery then can't repair
# itself (pull needs the daemon). Restore the DECLARED copy (HM activation
# output of the current generation) when the live file isn't valid JSON.
DAEMON_JSON="/etc/docker/daemon.json"
DECLARED_JSON="$HOME/.local/share/container-init/daemon.json"
if command -v python3 >/dev/null 2>&1; then
    if ! sudo python3 -c "import json; json.load(open('$DAEMON_JSON'))" 2>/dev/null; then
        # The declared copy may itself carry the concatenation bug (duplicate
        # home.file.text defs merged by types.lines) — salvage the FIRST JSON
        # document from whichever source parses, so dockerd can boot and pull
        # the fixed generation.
        SALVAGE=$(sudo python3 - "$DECLARED_JSON" "$DAEMON_JSON" <<'PYEOF'
import json, sys
for path in sys.argv[1:]:
    try:
        raw = open(path).read()
    except OSError:
        continue
    try:
        obj, _ = json.JSONDecoder().raw_decode(raw.lstrip())
        print(json.dumps(obj)); sys.exit(0)
    except Exception:
        continue
sys.exit(1)
PYEOF
        ) || SALVAGE=""
        if [ -n "$SALVAGE" ]; then
            echo "[hm-docker] daemon.json invalid — salvaging first JSON document"
            printf '%s\n' "$SALVAGE" | sudo tee "$DAEMON_JSON.tmp" > /dev/null
            sudo mv -f "$DAEMON_JSON.tmp" "$DAEMON_JSON"
            sudo systemctl restart docker 2>/dev/null || true
            sleep 3
        fi
    fi
fi

# ── Pre-check: Docker daemon running? ──
if [ -S "$DOCKER_SOCK" ]; then
    echo "[hm-docker] Docker socket found"
elif command -v systemctl >/dev/null 2>&1; then
    echo "[hm-docker] Starting Docker daemon..."
    sudo systemctl start docker 2>/dev/null || true
    sleep 2
    if [ ! -S "$DOCKER_SOCK" ]; then
        echo "[hm-docker] ERROR: Docker daemon failed to start"
        exit 1
    fi
else
    echo "[hm-docker] ERROR: Docker socket not found at $DOCKER_SOCK"
    exit 1
fi

# ── Transport detection ──
# A `command -v docker` hit isn't enough — there might be a wrapper that exec's
# a stale docker-real or a now-purged nix-profile target. Probe `docker version`
# to verify the binary chain actually resolves before choosing the CLI path.
if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    USE_CLI=true
    echo "[hm-docker] Transport: docker CLI"
else
    USE_CLI=false
    if command -v curl >/dev/null 2>&1; then
        echo "[hm-docker] Transport: socket API (docker CLI missing or broken)"
    else
        echo "[hm-docker] ERROR: neither working docker CLI nor curl+socket available"
        exit 1
    fi
fi

# ── Helper: docker API via socket ──
dock_api() {
    _method="$1"; _endpoint="$2"; shift 2
    curl -sf --unix-socket "$DOCKER_SOCK" -X "$_method" "http://localhost$_endpoint" "$@"
}

# ── Step 1: Pull image (bounded retry) ──
# >>> hm-pull-retry (extracted by 9_others/test/test_hm_docker_pull_retry.sh)
# oci-analytics (1 GB E2 Micro) failed ship twice on 2026-11-18: runs
# 44259524045 (registry timeout awaiting headers) and 44294316188 (layer
# stream "unexpected EOF"). One bad network moment killed the whole ship.
# Retry transient registry/network errors with exponential backoff (5
# attempts: waits 15s 30s 60s 120s); layers already fetched are reused by
# dockerd on the next attempt. Auth / manifest / reference errors are not
# transient and fail at once. After the pull the image must resolve locally,
# with the digest the registry advertised when it advertised one.
HM_PULL_ATTEMPTS="${HM_PULL_ATTEMPTS:-5}"
HM_PULL_BACKOFF="${HM_PULL_BACKOFF:-15 30 60 120}"
HM_PULL_SLEEP="${HM_PULL_SLEEP:-sleep}"
HM_PULL_OUT="${HM_PULL_OUT:-/tmp/.hm-pull-out}"
# dockerd itself can die mid-pull on the 1 GB VMs (run 44315729287,
# oci-analytics: attempt 2 hit "Cannot connect to the Docker daemon" and was
# wrongly treated as permanent). That is classified "daemon": wait up to
# HM_DAEMON_WAIT seconds for dockerd to answer again, starting it through
# systemd if the unit is not active, then retry the pull. Never resets the VM.
HM_DAEMON_WAIT="${HM_DAEMON_WAIT:-180}"
HM_DAEMON_POLL="${HM_DAEMON_POLL:-5}"

# Classify a failed pull's output: prints "daemon", "permanent" or
# "transient". "daemon" (dockerd unreachable) is checked first: it says
# nothing about the image. Permanent wins over transient when both match
# (e.g. a 401 wrapped in a retry message). Anything unrecognised is treated
# as permanent: only known-transient failures are retried.
hm_pull_classify() {
    if grep -qiE 'Cannot connect to the Docker daemon|Is the docker daemon running|docker\.sock: connect: (connection refused|no such file)|dial unix .*docker\.sock|^HTTP 000$' "$1" 2>/dev/null; then
        echo daemon
    elif grep -qiE 'unauthorized|authentication required|denied|forbidden|manifest unknown|manifest for .* not found|not found: manifest|repository does not exist|name unknown|invalid reference format|no matching manifest|HTTP (401|403|404)\b' "$1" 2>/dev/null; then
        echo permanent
    elif grep -qiE 'timeout|timed out|deadline exceeded|unexpected EOF|\bEOF\b|connection reset|connection refused|broken pipe|request canceled|TLS handshake|i/o timeout|no such host|temporary failure in name resolution|network is unreachable|toomanyrequests|too many requests|\b429\b|\b50[0-9]\b|internal server error|bad gateway|service unavailable|gateway timeout' "$1" 2>/dev/null; then
        echo transient
    else
        echo permanent
    fi
}

# Last error-looking line of a pull's output, for the attempt log. Pull
# output is registry/daemon text (no credentials); strip any bearer/basic
# token fragment defensively anyway.
hm_pull_reason() {
    { grep -iE 'error|fail|EOF|timeout|denied|unauthorized|refused|reset|unknown|not found|HTTP [0-9]{3}' "$1" 2>/dev/null || tail -1 "$1" 2>/dev/null; } \
        | tail -1 | sed -E 's/(Bearer|Basic|token=)[^ "]*/\1<redacted>/Ig' | cut -c1-300
}

# One pull attempt; output to $HM_PULL_OUT; non-zero on failure.
hm_pull_once() {
    : > "$HM_PULL_OUT"
    if [ "$USE_CLI" = true ]; then
        docker pull "$FULL_IMAGE" > "$HM_PULL_OUT" 2>&1
        return $?
    fi
    _code=$(curl -s --unix-socket "$DOCKER_SOCK" -o "$HM_PULL_OUT" -w '%{http_code}' \
        -X POST "http://localhost/images/create?fromImage=${IMAGE}&tag=${TAG}") || _code=000
    if [ "${_code:-000}" -ge 400 ] 2>/dev/null || [ "${_code:-000}" = 000 ]; then
        printf '\nHTTP %s\n' "${_code:-000}" >> "$HM_PULL_OUT"
        return 1
    fi
    # /images/create answers 200 and streams the failure as errorDetail.
    if grep -q '"errorDetail"' "$HM_PULL_OUT" 2>/dev/null; then
        return 1
    fi
    return 0
}

# Digest the registry advertised in this pull ("Digest: sha256:..."), if any.
hm_pull_digest() {
    grep -oE 'Digest: sha256:[0-9a-f]{64}' "$HM_PULL_OUT" 2>/dev/null | tail -1 | sed 's/^Digest: //'
}

# RepoDigests of the local image, one per line; non-zero if it does not resolve.
hm_image_repodigests() {
    if [ "$USE_CLI" = true ]; then
        docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$FULL_IMAGE" 2>/dev/null
    else
        _j=$(curl -sf --unix-socket "$DOCKER_SOCK" "http://localhost/images/${FULL_IMAGE}/json" 2>/dev/null) || return 1
        printf '%s' "$_j" | grep -oE '"[^"]*@sha256:[0-9a-f]{64}"' | tr -d '"'
        return 0
    fi
}

# Does dockerd answer?
hm_daemon_up() {
    if [ "$USE_CLI" = true ]; then
        docker info >/dev/null 2>&1
    else
        curl -sf --max-time 5 --unix-socket "$DOCKER_SOCK" http://localhost/_ping >/dev/null 2>&1
    fi
}

# Wait for dockerd to come back (up to HM_DAEMON_WAIT s, polling every
# HM_DAEMON_POLL s). If systemd owns docker and the unit is not active
# (crashed, OOM-killed, failed restart), start it. Non-zero on timeout.
hm_wait_daemon() {
    _waited=0
    while [ "$_waited" -lt "$HM_DAEMON_WAIT" ]; do
        if hm_daemon_up; then
            echo "[hm-docker] Docker daemon answering again after ${_waited}s"
            return 0
        fi
        if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet docker 2>/dev/null; then
            echo "[hm-docker] docker.service not active — starting it"
            sudo systemctl start docker 2>&1 | tail -2 || true
        fi
        "$HM_PULL_SLEEP" "$HM_DAEMON_POLL"
        _waited=$((_waited + HM_DAEMON_POLL))
    done
    hm_daemon_up && { echo "[hm-docker] Docker daemon answering again after ${_waited}s"; return 0; }
    echo "[hm-docker] ERROR: Docker daemon did not answer within ${HM_DAEMON_WAIT}s"
    return 1
}

hm_pull_with_retry() {
    _attempt=1
    set -- $HM_PULL_BACKOFF
    while :; do
        echo "[hm-docker] Pull attempt ${_attempt}/${HM_PULL_ATTEMPTS}: $FULL_IMAGE"
        if hm_pull_once; then
            tail -3 "$HM_PULL_OUT" 2>/dev/null || true
            _want=$(hm_pull_digest)
            if _have=$(hm_image_repodigests); then
                if [ -z "$_want" ]; then
                    echo "[hm-docker] Pull complete (image resolves; registry advertised no digest)"
                    rm -f "$HM_PULL_OUT"; return 0
                elif printf '%s\n' "$_have" | grep -qF "@${_want}"; then
                    echo "[hm-docker] Pull complete (verified digest $_want)"
                    rm -f "$HM_PULL_OUT"; return 0
                fi
                echo "[hm-docker] ERROR: pulled image digest mismatch: registry advertised $_want, local RepoDigests: $(printf '%s' "$_have" | tr '\n' ' ')"
                rm -f "$HM_PULL_OUT"; return 1
            fi
            _class=transient
            _reason="pull reported success but 'docker image inspect' does not resolve $FULL_IMAGE"
        else
            _class=$(hm_pull_classify "$HM_PULL_OUT")
            _reason=$(hm_pull_reason "$HM_PULL_OUT")
        fi
        if [ "$_class" = permanent ]; then
            echo "[hm-docker] Pull attempt ${_attempt}/${HM_PULL_ATTEMPTS} failed (permanent, not retrying): ${_reason}"
            cat "$HM_PULL_OUT" 2>/dev/null | tail -5 || true
            rm -f "$HM_PULL_OUT"; return 1
        fi
        if [ "$_attempt" -ge "$HM_PULL_ATTEMPTS" ]; then
            echo "[hm-docker] Pull attempt ${_attempt}/${HM_PULL_ATTEMPTS} failed (transient): ${_reason}"
            echo "[hm-docker] ERROR: pull failed after ${HM_PULL_ATTEMPTS} attempts: $FULL_IMAGE"
            rm -f "$HM_PULL_OUT"; return 1
        fi
        if [ "$_class" = daemon ]; then
            echo "[hm-docker] Pull attempt ${_attempt}/${HM_PULL_ATTEMPTS} failed (daemon unreachable): ${_reason} — waiting up to ${HM_DAEMON_WAIT}s for dockerd"
            if ! hm_wait_daemon; then
                rm -f "$HM_PULL_OUT"; return 1
            fi
            _attempt=$((_attempt + 1))
            continue
        fi
        _wait="${1:-120}"; [ "$#" -gt 1 ] && shift
        echo "[hm-docker] Pull attempt ${_attempt}/${HM_PULL_ATTEMPTS} failed (transient): ${_reason} — retrying in ${_wait}s"
        "$HM_PULL_SLEEP" "$_wait"
        _attempt=$((_attempt + 1))
    done
}
# <<< hm-pull-retry

echo "[hm-docker] Pulling $FULL_IMAGE"
hm_pull_with_retry || exit 1

# ── Step 2: Clean up any previous hm-activate container ──
# Kill EVERY hm-activate-* container, not just the same-PID one. Orphans
# from prior failed/interrupted ships otherwise race the new one for
# /nix/store writes and corrupt the cp -aR (oci-mail incident 2026-05-06).
CONTAINER_NAME="hm-activate-$$"
if [ "$USE_CLI" = true ]; then
    OLD_IDS=$(docker ps -a --filter name=hm-activate --format '{{.ID}}' 2>/dev/null || true)
    for _cid in $OLD_IDS; do
        docker rm -f "$_cid" 2>/dev/null || true
    done
else
    OLD_IDS=$(dock_api GET '/containers/json?all=true&filters={"name":["hm-activate"]}' 2>/dev/null \
        | grep -o '"Id":"[^"]*"' | sed 's/"Id":"//;s/"//' || true)
    for _cid in $OLD_IDS; do
        dock_api POST "/containers/$_cid/stop" 2>/dev/null || true
        dock_api DELETE "/containers/$_cid" 2>/dev/null || true
    done
fi

# ── Step 3: Run activation container ──
echo "[hm-docker] Running activation container"
if [ "$USE_CLI" = true ]; then
    # --runtime runc: activation must survive a broken default-runtime in
    # daemon.json (2026-07-03: youki default bricked activation on oci-mail).
    docker run --rm --runtime runc --name "$CONTAINER_NAME" -v /:/host -e HM_HOST_ROOT=/host "$FULL_IMAGE" 2>&1
else
    CREATE_BODY="{
        \"Image\": \"${FULL_IMAGE}\",
        \"Env\": [\"HM_HOST_ROOT=/host\"],
        \"HostConfig\": {
            \"Binds\": [\"/:/host\"]
        }
    }"
    CREATE_RESP=$(dock_api POST "/containers/create?name=${CONTAINER_NAME}" \
        -H "Content-Type: application/json" -d "$CREATE_BODY" 2>&1)
    CID=$(printf '%s' "$CREATE_RESP" | grep -o '"Id":"[^"]*"' | head -1 | sed 's/"Id":"//;s/"//')
    if [ -z "$CID" ]; then
        echo "[hm-docker] ERROR: container create failed: $CREATE_RESP"
        exit 1
    fi
    echo "[hm-docker] Container created: ${CID:0:12}"

    dock_api POST "/containers/$CID/start" >/dev/null 2>&1
    echo "[hm-docker] Container started"

    WAIT_RESP=$(dock_api POST "/containers/$CID/wait" 2>&1 || true)
    WAIT_CODE=$(printf '%s' "$WAIT_RESP" | grep -o '"StatusCode":[0-9]*' | sed 's/"StatusCode"://')
    WAIT_CODE="${WAIT_CODE:-999}"

    echo "[hm-docker] Container logs:"
    curl -s --unix-socket "$DOCKER_SOCK" "http://localhost/containers/$CID/logs?stdout=true&stderr=true" \
        2>/dev/null | tr -d '\000-\010' || true

    dock_api DELETE "/containers/$CID?force=true" 2>/dev/null || true

    if [ "$WAIT_CODE" -ne 0 ]; then
        echo "[hm-docker] ERROR: activation container exited with code $WAIT_CODE"
        exit 1
    fi
fi

# ── Step 3.5: Reclaim image overlay BEFORE native activate ──
# The activation container has finished cp'ing the closure to host's /nix/store.
# Native activate (step 5) only needs files on host — never reaches back into
# the image's overlay. Removing the image NOW (before nix-build /tmp/* runs)
# frees ~6 GB right when nix-build wants peak transient room. Drops cumulative
# peak from ~11 GB to ~8 GB.
if [ "$USE_CLI" = true ]; then
    docker rmi -f "$FULL_IMAGE" >/dev/null 2>&1 \
      && echo "[hm-docker] Reclaimed image overlay (pre-activate): $FULL_IMAGE" \
      || echo "[hm-docker] Image rmi non-fatal (still referenced)"
else
    IMG_ID=$(dock_api GET "/images/json?filters=%7B%22reference%22%3A%5B%22${IMAGE}%22%5D%7D" 2>/dev/null \
        | grep -o '"Id":"[^"]*"' | head -1 | sed 's/"Id":"//;s/"//')
    [ -n "$IMG_ID" ] && dock_api DELETE "/images/${IMG_ID}?force=true" >/dev/null 2>&1 \
      && echo "[hm-docker] Reclaimed image overlay (pre-activate, socket): $IMG_ID" \
      || true
fi

fi  # HM_TRANSPORT != closure

# ── Step 4: Register nix paths in host DB (native, not container) ──
echo "[hm-docker] Registering nix paths (native)..."
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
if [ -f /tmp/.hm-nix-db-dump.txt ]; then
    sudo nix-store --load-db < /tmp/.hm-nix-db-dump.txt 2>&1 | tail -5
    echo "[hm-docker] Paths registered via --load-db"
    sudo rm -f /tmp/.hm-nix-db-dump.txt
else
    echo "[hm-docker] WARN: no DB dump found — paths may not be registered"
fi

# ── Step 4.5: Re-own /nix to HM_USER (post-cp, pre-activate) ──
# The activation container ran cp -aR /nix/store → /host/nix/store as root,
# preserving image-internal ownership (root). When sudo -u $HM_USER runs
# `activate` next, nix-env tries to create a lock file inside /nix/store
# and fails with EACCES on the freshly-cp'd root-owned dir entries.
# Determinate-Nix multi-user mode would normally route writes through the
# nix-daemon as root, but on freshly-bootstrapped GCP VMs (and any VM where
# nix-daemon is disabled) the user-side write path needs ownership.
# Idempotent: chown -R is a no-op once converged.
echo "[hm-docker] Reclaiming /nix ownership for $HM_USER"
sudo chown -R "$HM_USER:$HM_USER" /nix 2>/dev/null || true

# ── Step 5: Activate generation ──
# HM's activate script does `nix-build --quiet --expr '{}'` as a sanity check
# (line 170 of generation/activate). sudo -u strips PATH; nix-build is normally
# at /nix/var/nix/profiles/default/bin (multi-user) or ~/.nix-profile/bin
# (single-user). On VMs where the previous generation never linked nix into
# the user's profile (oci-mail, 2026-05-05), the bare default PATH lacks
# nix-build → activate dies "command not found". Resolve nix-build's actual
# directory at runtime and prepend it to the activation PATH.
echo "[hm-docker] Activating generation"
ACTIVATE=$(cat /tmp/.hm-activation-path 2>/dev/null)
if [ -n "$ACTIVATE" ] && [ -x "$ACTIVATE/activate" ]; then
    rm -f "/home/$HM_USER/.local/bin/docker" 2>/dev/null
    NIX_BIN_DIR=""
    for _candidate in /nix/var/nix/profiles/default/bin /home/$HM_USER/.nix-profile/bin /nix/var/nix/profiles/per-user/$HM_USER/profile/bin; do
        if [ -x "$_candidate/nix-build" ]; then
            NIX_BIN_DIR="$_candidate"
            break
        fi
    done
    if [ -z "$NIX_BIN_DIR" ]; then
        # Fallback: scan /nix/store for the newest nix-2.* package.
        NIX_BIN_DIR=$(ls -1d /nix/store/*-nix-2.*/bin 2>/dev/null | grep -v -- '-man' | sort -V | tail -1)
    fi
    if [ -n "$NIX_BIN_DIR" ] && [ -x "$NIX_BIN_DIR/nix-build" ]; then
        echo "[hm-docker] Using nix-build from $NIX_BIN_DIR"
        sudo -u "$HM_USER" HOME="/home/$HM_USER" USER="$HM_USER" \
            PATH="$NIX_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            "$ACTIVATE/activate" 2>&1
    else
        echo "[hm-docker] WARN: no nix-build found — activation may fail"
        sudo -u "$HM_USER" HOME="/home/$HM_USER" USER="$HM_USER" "$ACTIVATE/activate" 2>&1
    fi
    echo "[hm-docker] Generation activated successfully"
    # Image already reclaimed at step 3.5 (before native nix-build). Nothing to do here.
else
    echo "[hm-docker] ERROR: activation path not found or not executable: $ACTIVATE"
    exit 1
fi
REMOTE_SCRIPT_EOF
}

# ── Detached activation: launch an uploaded script, wait for its verdict ──
# The script runs under setsid+nohup, so a dropped SSH session cannot kill it,
# and short ssh round trips poll for the exit code it leaves behind while its
# log streams here. The return value IS that exit code.
#
# #657: the wait ends at the JOB's deadline (HM_DEADLINE_EPOCH, set by
# ship-home-manager.yml), not at a constant of its own. It used to be a fixed
# 120 x 15s = 30 min inside a 45-min job, and a docker activation on the 1 GB
# VMs takes 36-64 min (measured 2026-09-29/30 from the rc markers those
# activations left behind: oci-analytics 36-49, oci-mail 44, gcp-proxy 52-64,
# every one exit 0). Every ship to those VMs went red while its generation
# went live, and the cleanup after the timeout deleted the log of the
# activation that was still running. Now:
#   rc marker present          that is the verdict
#   wrapper gone, no marker    never started or was killed (OOM, reboot): fail
#                              now instead of waiting out the deadline
#   deadline reached           fail as STILL RUNNING and leave the markers, so
#                              the real outcome can still be read on the VM
# Remote logic stays behind `sh -c '...'` with no quote or backslash inside:
# oci-mail's login shell is fish.
_hm_detached_wait() {  # <uploaded-script> <label>
    local _rsh="$1" _label="$2"
    local _rlog="${1%.sh}.log" _rrc="${1%.sh}.rc" _rpid="${1%.sh}.pid"
    local _ka="-o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o ConnectTimeout=20"
    local _poll="${HM_POLL_SECS:-15}" _deadline="${HM_DEADLINE_EPOCH:-}"
    # ponytail: 2h cap only when run outside CI; the workflow passes the real deadline
    case "$_deadline" in ''|*[!0-9]*) _deadline=$(( $(date +%s) + 7200 )) ;; esac
    local _seen=0 _out _pc _rest _state _rcval _sz _chunk

    ssh $SSH_OPTS $_ka "$DEPLOY_HOST" \
      "rm -f '$_rrc' '$_rpid'; : > '$_rlog'; nohup setsid sh -c 'echo \$\$ > \"$_rpid\"; bash \"$_rsh\" > \"$_rlog\" 2>&1; echo \$? > \"$_rrc\"' </dev/null >/dev/null 2>&1 & echo HM_LAUNCHED" \
      2>&1 | tee -a "$BUILD_LOG_FILE" || true
    log "$_label on $DEPLOY_HOST (detached; polling for up to $(( (_deadline - $(date +%s)) / 60 ))min)"

    while :; do
        sleep "$_poll"
        # One round trip: new log bytes, "<alive>:<rc>", log size. Liveness is
        # read BEFORE the rc marker: the wrapper writes rc and only then exits,
        # so "gone" can never race a verdict that is still being written.
        _pc=0
        _out=$(ssh $SSH_OPTS $_ka "$DEPLOY_HOST" \
          "tail -c +$(( _seen + 1 )) '$_rlog' 2>/dev/null; printf '\\n__HMRC__'; sh -c 'kill -0 \"\$(cat \"\$1\" 2>/dev/null)\" 2>/dev/null && printf 1: || printf 0:; cat \"\$2\" 2>/dev/null' _ '$_rpid' '$_rrc'; printf '__HMSZ__'; stat -c %s '$_rlog' 2>/dev/null || printf 0") || _pc=$?
        if [ "$_pc" -ne 0 ]; then
            log "poll reconnect (ssh $_pc) — activation still running on $DEPLOY_HOST"
        else
            _chunk="${_out%%__HMRC__*}"; _chunk="${_chunk%$'\n'}"
            _rest="${_out#*__HMRC__}"
            _state="${_rest%%__HMSZ__*}"
            _rcval="$(printf '%s' "${_state#*:}" | tr -dc '0-9')"
            _sz="$(printf '%s' "${_rest#*__HMSZ__}" | tr -dc '0-9')"
            [ -n "$_chunk" ] && printf '%s' "$_chunk" | tee -a "$BUILD_LOG_FILE"
            [ -n "$_sz" ] && _seen="$_sz"
            if [ -n "$_rcval" ]; then
                ssh $SSH_OPTS $_ka "$DEPLOY_HOST" "rm -f '$_rsh' '$_rlog' '$_rrc' '$_rpid'" 2>/dev/null || true
                return "$_rcval"
            fi
            if [ "${_state%%:*}" = 0 ]; then
                log "activation on $DEPLOY_HOST is not running and left no exit code (never started, or killed: OOM, reboot) — log kept at $_rlog"
                return 1
            fi
        fi
        if [ $(( $(date +%s) + _poll )) -ge "$_deadline" ]; then
            if [ "$_pc" -ne 0 ]; then
                log "could not reach $DEPLOY_HOST at the job deadline — verdict unknown, the activation may still be running"
            else
                log "activation on $DEPLOY_HOST is STILL RUNNING at the job deadline — verdict unknown, not a failed activation"
            fi
            log "  its exit code will land in $DEPLOY_HOST:$_rrc (log: $_rlog); markers left in place on purpose"
            return 1
        fi
    done
}

step_compose() {
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host — skipping compose"; return 0; }
    [ -z "$HM_CONFIG" ] && { log "ERROR: hm.config not set in build.json"; return 1; }

    if [ "$HM_DELIVERY" = "docker" ] && [ "$HM_REMOTE_BUILDER" != "true" ]; then
        # ── Docker delivery: pull image on VM, run activation container ──
        [ -z "$HM_IMAGE" ] && { log "ERROR: hm.image not set"; return 1; }
        HM_TRANSPORT="${HM_TRANSPORT:-$(hm_transport)}"
        if [ "$HM_TRANSPORT" = closure ]; then
            log "Docker delivery, closure transport (low-memory VM): activating on $DEPLOY_HOST without pulling $HM_IMAGE"
        else
            log "Docker delivery: activating $HM_IMAGE on $DEPLOY_HOST"
        fi
        # Edge VMs: never start while their own public Caddy is unhealthy.
        hm_edge_guard "pre-flight" || return 1

        # ── Pre-flight: ensure VM has disk headroom for activation ──
        # HM activation is a 3-stage pipeline that all writes to the VM's /:
        #   1. docker pull HM image (~2-5GB compressed → overlay2)
        #   2. activation container cp -aR /nix/store → host (~5-7GB)
        #   3. nix-build derivations in /tmp/nix-build-* (~1-3GB transient)
        # Cumulative peak: ~10-15GB headroom required. Without it the
        # activation hits ENOSPC at nix-build mkdir (incident 2026-05-02
        # on oci-mail: 7.8GB free → activation peaks at 100% disk usage →
        # error: creating directory ... No space left on device).
        # Fix: pre-flight prune docker + truncate runaway logs + journal
        # vacuum before any pull/cp/activate runs. Data-driven threshold:
        #   build.json:.vm.disk.activation_min_free_gb (default 10).
        # Single source of truth: 1_cloud-configs/src/inputs/hm-config.json
        # ALSO read by b_infra/_shared/vm-pilot/src/modules/protection/disk-ballast.nix
        # via symlinked b_infra/_shared/modules/hm-config.json.
        # hm-config.json moved to 1_cloud-configs with the rest of the derive
        # inputs; $STEPS_DIR is 1_cicd/src/scripts, so reach it via
        # CLOUD_ROOT rather than counting ../ across two modules.
        HM_CONFIG_FILE="${CLOUD_ROOT:-$STEPS_DIR/../../../..}/1_cloud-configs/src/inputs/hm-config.json"
        MIN_FREE_GB=$(jq -r '.min_size_ballast_file_gb' "$HM_CONFIG_FILE" 2>/dev/null)
        : "${MIN_FREE_GB:=10}"  # fallback if the JSON read fails for any reason
        log "Pre-flight: ensuring ≥${MIN_FREE_GB}GB free on $DEPLOY_HOST"
        # POSIX df: column 4 is Available KB. Convert to GB.
        # DISTINGUISH "CANNOT REACH THE VM" FROM "VM IS FULL".
        # This used to be `FREE_KB=$(ssh_vm ... 2>/dev/null); : "${FREE_KB:=0}"`,
        # which discarded both the SSH stderr and its exit status. An
        # unreachable VM therefore produced FREE_KB=0 -> FREE_GB=0 -> "below
        # threshold" -> the engine ran the whole prune/cleanup path (more SSH
        # calls, each also failing) before dying with a bare exit 255 and no
        # statement anywhere that the host was simply unreachable. On
        # 2026-08-12 all four VMs failed this way and the logs said only
        # "FATAL: step 'compose' failed (exit 255)" — the disk was never the
        # problem, and the message actively pointed at the wrong subsystem.
        # Fail loudly and immediately instead: a connectivity fault is not a
        # capacity fault and must not be silently reinterpreted as one.
        set +e
        FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'")
        SSH_RC=$?
        set -e
        if [ "$SSH_RC" -ne 0 ]; then
            log "FATAL: cannot reach $DEPLOY_HOST over SSH (exit $SSH_RC) — aborting before cleanup."
            log "  This is a CONNECTIVITY failure, not a disk-space failure."
            log "  The deploy SSH rides the WireGuard mesh; check the runner's"
            log "  wg peer and that $DEPLOY_HOST is up, then re-run."
            exit "$SSH_RC"
        fi
        # Non-numeric (or empty) output means df/awk misbehaved, which is also
        # not a capacity signal — treat it as a hard error rather than 0.
        case "${FREE_KB:-}" in
            ''|*[!0-9]*)
                log "FATAL: unparseable df output from $DEPLOY_HOST: '${FREE_KB:-<empty>}'"
                exit 1
                ;;
        esac
        FREE_GB=$(( FREE_KB / 1024 / 1024 ))
        log "  free: ${FREE_GB}GB / threshold: ${MIN_FREE_GB}GB"
        if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
            log "  insufficient — running cleanup (docker prune + log truncate + journal vacuum)"
            # Prune list, in order of safety (most-conservative → most-aggressive):
            #   1. truncate runaway container json-log files (>50M)
            #   2. /containers/prune          — stopped containers only
            #   3. /images/prune dangling     — only <none> tagged images
            #   4. /build/prune?all=true      — buildkit cache (rare on non-builder VMs)
            #   5. /images/prune until=720h   — UNUSED tagged images older than 30d.
            #      Surfaced 2026-05-05 (oci-mail incident): /var/lib/containerd
            #      held 12 GB of old tagged-but-unreferenced images that the prior
            #      4 steps couldn't touch. `until=720h` filter only removes images
            #      with no running/stopped container referencing them AND last
            #      used > 30 days ago — safe for steady-state VMs, cleans the
            #      historical pulls that accumulate over months.
            #   6. journalctl --vacuum-time=<floor>d — #413: never --vacuum-size, it
            #      deletes by volume regardless of age and erased 16 days of oci-apps
            #      journal. Floor: config.json native.protection.journal_retention_floor_days;
            #      undeclared → no vacuum (an undeclared floor must not delete).
            #   7. rm /var/disk-reserve/ballast.bin (engineered safety net)
            #
            # REVERTED 2026-05-05: an "orphan /var/lib/containerd" cleanup step
            # was added between (5) and (6) on the assumption that the absence
            # of a `containerd.service` systemd unit meant the directory was
            # leftover from a removed install. That assumption is FALSE on
            # modern docker installs: dockerd ships an embedded containerd
            # binary that does NOT register a separate systemd unit but still
            # uses /var/lib/containerd as its content store. The cleanup
            # destroyed docker's image cache and forced a re-pull on every
            # ship — directly counterproductive on the disk-pressure VMs the
            # cleanup was meant to help. Real fix for runaway containerd
            # content store: docker's own /images/prune (steps 3+5 above) GCs
            # via the containerd content reference graph; if that's not
            # reclaiming, the issue is upstream (manifest staleness) and
            # outside engine scope.
            # Additional safe prunes (added 2026-05-05 from oci-mail incident
            # post-mortem: 38 GB used, 4 GB free, blocked HM activation):
            #   - vm-system.tar.gz from /var/backups/evidence/* — these are
            #     legacy heavy snapshots from the pre-2026-04-20 evidence-
            #     collector script. The .nix source has been refactored to
            #     a lightweight version that doesn't write vm-system.tar.gz,
            #     but VMs whose HM ship has been failing still run the OLD
            #     deployed script (oci-mail had 4×793 MB = 3.2 GB of these
            #     orphan files). Safe to remove: lightweight script never
            #     regenerates them; heavy script's existing 7-day retention
            #     handles the next cycle if ship continues to fail.
            #   - apt cache (apt-get clean) — regenerable, cheap to clear.
            JOURNAL_FLOOR_DAYS=$(jq -r '.native.protection.journal_retention_floor_days // empty' "${CLOUD_ROOT:-$STEPS_DIR/../../../..}/config.json" 2>/dev/null)
            case "$JOURNAL_FLOOR_DAYS" in
                ''|*[!0-9]*) JOURNAL_VACUUM_CMD=true ;;
                *) JOURNAL_VACUUM_CMD="sudo journalctl --vacuum-time=${JOURNAL_FLOOR_DAYS}d >/dev/null 2>&1" ;;
            esac
            ssh_vm "sudo find /var/lib/docker/containers -name '*-json.log' -size +50M -exec truncate -s 0 {} + 2>/dev/null || true; \
                    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST http://localhost/containers/prune >/dev/null 2>&1 || true; \
                    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST 'http://localhost/images/prune?filters=%7B%22dangling%22%3A%7B%22true%22%3Atrue%7D%7D' >/dev/null 2>&1 || true; \
                    curl -sf --max-time 30 --unix-socket /var/run/docker.sock -X POST 'http://localhost/build/prune?all=true' >/dev/null 2>&1 || true; \
                    curl -sf --max-time 60 --unix-socket /var/run/docker.sock -X POST 'http://localhost/images/prune?filters=%7B%22until%22%3A%5B%22720h%22%5D%7D' >/dev/null 2>&1 || true; \
                    sudo find /var/backups/evidence -name 'vm-system.tar.gz' -delete 2>/dev/null || true; \
                    sudo apt-get clean -qq 2>/dev/null || true; \
                    $JOURNAL_VACUUM_CMD || true; \
                    sudo rm -f /var/disk-reserve/ballast.bin 2>/dev/null || true" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
            FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
            : "${FREE_KB:=0}"
            FREE_GB=$(( FREE_KB / 1024 / 1024 ))
            log "  after cleanup pass 1: ${FREE_GB}GB free"

            # Pass 2 (aggressive): if still under threshold, prune ALL unused
            # images regardless of age. "Unused" = no container references it
            # (running OR stopped). Running containers' images stay; everything
            # else — old HM image versions, prior pulls — is fair game.
            # Triggered ONLY when pass 1 left us short, so steady-state VMs
            # are unaffected.
            #
            # KEY DETAIL: Docker's /images/prune defaults to dangling-only.
            # To prune ALL unused (including tagged), pass dangling=false:
            #   filters={"dangling":["false"]}
            #     URL-encoded: %7B%22dangling%22%3A%5B%22false%22%5D%7D
            # This DOES catch the prior failed-ship HM image (tagged
            # ghcr.io/diegonmarcos/nixhm-sudo-<vm>:latest) when no exited
            # activation container still references it.
            if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
                log "  pass 2 (aggressive): pruning ALL unused images (incl. tagged) + gcroots + caches"
                ssh_vm "curl -sf --max-time 60 --unix-socket /var/run/docker.sock -X POST 'http://localhost/containers/prune?filters=%7B%22until%22%3A%5B%221m%22%5D%7D' >/dev/null 2>&1 || true; \
                        curl -sf --max-time 180 --unix-socket /var/run/docker.sock -X POST 'http://localhost/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D' >/dev/null 2>&1 || true; \
                        sudo find /nix/var/nix/gcroots/auto -maxdepth 1 -type l -mtime +7 -delete 2>/dev/null || true; \
                        sudo find /var/cache -mindepth 2 -type f -atime +14 -delete 2>/dev/null || true; \
                        sudo find /var/backups/evidence -maxdepth 1 -mindepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
                FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
                : "${FREE_KB:=0}"
                FREE_GB=$(( FREE_KB / 1024 / 1024 ))
                log "  after cleanup pass 2: ${FREE_GB}GB free"
            fi

            # Pass 3 (last resort): nix-store --gc on orphan store paths.
            # When prior failed ships' activation containers crashed mid-cp,
            # they left ~5GB of /nix/store paths with no HM generation root —
            # docker prune can't see them, only nix can. Resolve nix-store
            # binary at runtime (HM-managed VMs vary).
            #
            # IMPORTANT: pipe through `bash -s` — VMs default to fish/zsh
            # which can't parse `VAR=$(...)` bash syntax. Same pattern as
            # the docker-real preflight nuke above.
            if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
                log "  pass 3 (nix GC): collecting orphan /nix/store paths"
                NIX_GC_SCRIPT='#!/bin/bash
# Prefer profile-wrapper bins (env baked in via patchelf rpath), fallback to
# raw store binary with LD_LIBRARY_PATH from the same -nix-2.x package lib.
# Direct invocation of /nix/store/*-nix-2.*/bin/nix-store fails with
# `libseccomp.so.2: cannot open shared object file` because sudo strips
# the env that would normally let the dynamic linker find it.
NIX_STORE_BIN=""
for _candidate in /nix/var/nix/profiles/default/bin/nix-store /home/'"$HM_USER"'/.nix-profile/bin/nix-store /nix/var/nix/profiles/per-user/'"$HM_USER"'/profile/bin/nix-store /nix/var/nix/profiles/per-user/root/profile/bin/nix-store; do
  if [ -x "$_candidate" ]; then NIX_STORE_BIN="$_candidate"; break; fi
done
if [ -z "$NIX_STORE_BIN" ]; then
  # Fallback: raw store binary + LD_LIBRARY_PATH derived from same package
  NIX_STORE_BIN=$(ls -1d /nix/store/*-nix-2.*/bin/nix-store 2>/dev/null | grep -v -- "-man" | sort -V | tail -1)
  if [ -x "$NIX_STORE_BIN" ]; then
    NIX_LIB_DIR="$(dirname "$(dirname "$NIX_STORE_BIN")")/lib"
    # Discover libseccomp from /nix/store
    LIBSECCOMP_DIR=$(ls -1d /nix/store/*-libseccomp-*/lib 2>/dev/null | sort -V | tail -1)
    export LD_LIBRARY_PATH="$NIX_LIB_DIR:$LIBSECCOMP_DIR:${LD_LIBRARY_PATH:-}"
    echo "[hm-preflight] LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
  fi
fi
if [ -x "$NIX_STORE_BIN" ]; then
  echo "[hm-preflight] running $NIX_STORE_BIN --gc"
  sudo LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$NIX_STORE_BIN" --gc 2>&1 | tail -5
else
  echo "[hm-preflight] no nix-store binary found"
fi'
                printf '%s' "$NIX_GC_SCRIPT" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE" || true
                FREE_KB=$(ssh_vm "df -P / 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)
                : "${FREE_KB:=0}"
                FREE_GB=$(( FREE_KB / 1024 / 1024 ))
                log "  after cleanup pass 3: ${FREE_GB}GB free"
            fi

            if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
                log "ERROR: $DEPLOY_HOST still under disk threshold (${FREE_GB}GB < ${MIN_FREE_GB}GB)"
                log "       activation would fail with ENOSPC at nix-build mkdir."
                log "       Free disk manually or increase VM disk size, then retry."
                return 1
            fi
        fi

        # ── Pre-flight: NUKE every docker-real wrapper anywhere on the VM ──
        # The retired guardrails.nix used to install a `pkgs.writeShellScriptBin
        # "docker"` overlay that exec'd `nice /usr/local/bin/docker-real "$@"`.
        # `docker-real` was a system-side wrapper that has since been removed
        # (commit a0774f4ce). On VMs whose nix-profile still points to that
        # stale 2-line wrapper (or whose /nix/store/.../docker file got
        # overwritten in place — yes that happened on gcp-proxy), the engine's
        # `docker pull` step dies with
        #   nice: '/usr/local/bin/docker-real': No such file or directory
        # BEFORE the activation container runs, so scheduler.nix's cleanup
        # hook is unreachable. Run the nuke here, every ship, idempotent on
        # healthy VMs (the grep filter returns nothing → nothing removed).
        # Targets:
        #   1. PATH-visible wrappers (~/.nix-profile/bin/docker, /usr/local/bin/docker*)
        #   2. The mutated /nix/store/*-docker-*/bin/docker file the wrapper
        #      points to — purge it so HM activation re-instantiates a clean
        #      docker derivation. (chmod +w needed: /nix/store is RO by default.)
        #   3. Any /usr/local/bin/docker-real* leftovers (broken targets).
        log "Pre-flight: nuking docker-real wrappers on $DEPLOY_HOST"
        # IMPORTANT: pipe through `bash -s` — VMs may default to fish/zsh which
        # cannot parse this bash script. Mirror the activation step's pattern.
        PREFLIGHT_NUKE=$(cat <<PREFLIGHT_EOF
#!/bin/bash
set +e
HM_USER="$HM_USER"
# 1. Remove every PATH-visible wrapper that exec's docker-real
for _p in /home/\$HM_USER/.nix-profile/bin/docker /usr/local/bin/docker /usr/local/bin/docker-real /usr/local/bin/docker-capped /usr/local/bin/docker-compose-capped /usr/local/bin/docker-buildx-capped; do
  if [ -e "\$_p" ] && head -2 "\$_p" 2>/dev/null | grep -q 'docker-real'; then
    sudo rm -f "\$_p" && echo "[hm-preflight] purged wrapper: \$_p"
  fi
done
# 2. Hunt mutated docker-real bytes inside /nix/store and rm so HM rebuilds clean.
#    nix-store paths are content-addressed; if contents drift the path is corrupt.
for _p in /nix/store/*-docker-*/bin/docker; do
  [ -e "\$_p" ] || continue
  if head -2 "\$_p" 2>/dev/null | grep -q 'docker-real'; then
    sudo chmod -R +w "\$(dirname "\$_p")" 2>/dev/null
    sudo rm -f "\$_p" && echo "[hm-preflight] purged corrupted nix-store wrapper: \$_p"
  fi
done
# 3. Remove broken docker-real targets entirely
sudo rm -f /usr/local/bin/docker-real* 2>/dev/null
exit 0
PREFLIGHT_EOF
)
        printf '%s' "$PREFLIGHT_NUKE" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE" || true

        # Deploy pre-decrypted secrets to VM via SSH
        if [ -f "$DIST_DIR/.secrets" ]; then
            log "Deploying secrets to $DEPLOY_HOST"
            ssh_vm "mkdir -p ~/.config/home-manager/.secrets.d"
            scp_vm "$DIST_DIR/.secrets" "$DEPLOY_HOST:~/.config/home-manager/.secrets"
            if [ -d "$DIST_DIR/.secrets.d" ]; then
                scp_vm -r "$DIST_DIR/.secrets.d/"* "$DEPLOY_HOST:~/.config/home-manager/.secrets.d/" 2>/dev/null || true
            fi
            ssh_vm "chmod 600 ~/.config/home-manager/.secrets ~/.config/home-manager/.secrets.d/* 2>/dev/null || true"
            log "Secrets deployed"
        fi

        # Build the remote script with variables substituted
        if [ "$HM_TRANSPORT" = closure ]; then
            _hm_closure=$(cat "$SERVICE_DIR/.closure-path" 2>/dev/null || true)
            [ -n "$_hm_closure" ] || { log "ERROR: no .closure-path — docker-package did not run"; return 1; }
            hm_closure_transfer "$_hm_closure" || { log "FAILED: closure transfer to $DEPLOY_HOST"; return 1; }
        fi
        hm_edge_guard "before activation" || return 1

        REMOTE_SCRIPT=$(_build_docker_activate_script)
        REMOTE_SCRIPT=$(printf '%s' "$REMOTE_SCRIPT" | sed "s|@@IMAGE@@|$HM_IMAGE|g; s|@@TAG@@|latest|g; s|@@HM_USER@@|$HM_USER|g; s|@@TRANSPORT@@|$HM_TRANSPORT|g")

        # ── Activate over SSH, with retry on transient tunnel drops ──
        # The activation streams a multi-minute remote script (pull image →
        # activation container cp -aR ~5-7GB closure → register → activate)
        # over a single SSH session. On the CPU-constrained E2-Micro hubs the
        # heavy cp starves WireGuard keepalive handling → the wg hub kicks the
        # 10.0.0.200 cloud-builder peer → SSH drops with exit 255 mid-copy and
        # the whole ship fails (oci-analytics wg-public-peer add, 2026-06-24).
        # exit 255 is SSH's own "connection lost" code — distinct from any code
        # the remote bash returns. The activation is fully idempotent (pull,
        # container cp, --load-db, chown, activate all re-runnable; a dropped
        # run rolls the generation back cleanly), so re-establishing the tunnel
        # and re-running is safe. Retry ONLY on 255 (transient transport); a
        # non-255 exit is a real remote-script error → fail fast, don't mask it.
        # Knobs reuse the same build.retry.* config as run_with_retry (buildx).
        # PRIMARY: detached activation + polling. Root cause of the E2-Micro 255
        # is that ONE ssh session is held open for the whole multi-minute
        # activation, so a mid-copy wg0 blip hard-drops it (a mux can't save a
        # single dropped stream — the master IS that connection). Instead: upload
        # the script, launch it DETACHED on the VM (survives our disconnect via
        # setsid+nohup), then POLL a result-marker over short commands — cheap
        # because they reuse the existing ControlMaster mux. A dropped poll just
        # reconnects; the activation keeps running. COMPOSE_RC becomes the job's
        # REAL exit code (via `echo $? > rc`), not ssh's transport 255.
        _ka="-o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o ConnectTimeout=20"
        # $$ alone repeats run after run (the builder container's PID namespace
        # hands out the same numbers: hm-act-207 exists on three VMs), and an
        # activation that outlives its job now keeps its markers — so the tag
        # carries the time too, or a later ship could read another's rc.
        _tag="hm-act-$(date +%s)-$$"; _rsh="/tmp/$_tag.sh"
        COMPOSE_RC=1
        _detach_started=0

        # 1) Upload the activation script (short transfer; retry on 255).
        _up=1
        for _t in 1 2 3 4 5; do
            set +e
            printf '%s' "$REMOTE_SCRIPT" | ssh $SSH_OPTS $_ka "$DEPLOY_HOST" "cat > '$_rsh'"
            _uc=$?; set -e
            if [ "$_uc" -eq 0 ]; then _up=0; break; fi
            [ "$_uc" -ne 255 ] && break
            log "activation upload dropped (255) — retry $_t/5"; sleep $(( 10 * _t ))
        done

        if [ "$_up" -eq 0 ]; then
            # 2+3) Launch detached, then wait for the activation's own exit code.
            _detach_started=1
            COMPOSE_RC=0
            _hm_detached_wait "$_rsh" "Docker HM activate" || COMPOSE_RC=$?
        fi

        # FALLBACK: detach couldn't even start the upload → original inline stream
        # with 255-retry, so the VM stays deployable if the detach path is unusable.
        if [ "$_detach_started" -eq 0 ]; then
            log "detached activation unavailable (upload failed) — falling back to inline stream"
            _hm_attempts="$(get_config build.retry.attempts)"; [ -z "$_hm_attempts" ] && _hm_attempts=8
            _hm_backoff="$(get_config build.retry.backoff_secs)"; [ -z "$_hm_backoff" ] && _hm_backoff=30
            _hm_try=0; COMPOSE_RC=1
            while [ "$_hm_try" -lt "$_hm_attempts" ]; do
                _hm_try=$(( _hm_try + 1 ))
                log "Docker HM activate on $DEPLOY_HOST (inline attempt $_hm_try/$_hm_attempts)"
                set +e
                printf '%s' "$REMOTE_SCRIPT" | ssh $SSH_OPTS \
                    -o ServerAliveInterval=20 -o ServerAliveCountMax=60 \
                    "$DEPLOY_HOST" "bash -s" 2>&1 | tee -a "$BUILD_LOG_FILE"
                COMPOSE_RC=${PIPESTATUS[1]}
                set -e
                if [ "$COMPOSE_RC" -eq 0 ]; then break; fi
                if [ "$COMPOSE_RC" -ne 255 ]; then break; fi
                if [ "$_hm_try" -lt "$_hm_attempts" ]; then
                    _hm_wait=$(( _hm_backoff * _hm_try ))
                    log "SSH dropped (exit 255) — retrying in ${_hm_wait}s..."
                    sleep "$_hm_wait"
                fi
            done
        fi
        if [ "$COMPOSE_RC" -ne 0 ]; then
            # _hm_try is set only by the inline fallback loop below. The detached
            # activation path never enters that loop, so under `set -u` this line
            # used to abort the script with "_hm_try: unbound variable" and lose
            # the real failure reason (a detach timeout). Report the attempt count
            # only when there were attempts.
            log "FAILED (exit $COMPOSE_RC): Docker HM activate on $DEPLOY_HOST${_hm_try:+ (after $_hm_try attempt(s))}"
            return 1
        fi
        log "Docker HM activated on $DEPLOY_HOST"
        hm_edge_guard "after activation" || { log "FAILED: public edge on $DEPLOY_HOST unhealthy after activation — investigate before the next ship"; return 1; }

    elif [ "$REMOTE_BUILD" = "true" ]; then
        # ── Remote build: full nix run on VM ──
        log "Activating on $DEPLOY_HOST (remote build)"
        SWITCH_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; cd $REMOTE_PATH && nix run home-manager/release-24.11 -- switch --option eval-cache false --flake .#$HM_CONFIG -b backup"
        log "Remote cmd: $SWITCH_CMD"
        # Apply the same detached activation pattern used for Docker delivery:
        # nix run home-manager -- switch takes 2-10 minutes and a blocking SSH
        # session dies (exit 255) when WireGuard blips mid-eval. Upload the
        # script, launch it detached (nohup+setsid, SIGHUP-immune), poll a
        # result marker over short cheap reconnections instead.
        _ka="-o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o ConnectTimeout=20"
        _tag="hm-rb-$(date +%s)-$$"; _rsh="/tmp/$_tag.sh"
        SWITCH_RC=1
        set +e
        printf '#!/bin/bash\nset -e\n%s\n' "$SWITCH_CMD" | ssh $SSH_OPTS $_ka "$DEPLOY_HOST" "cat > '$_rsh'"
        _up=$?; set -e
        if [ "$_up" -eq 0 ]; then
            SWITCH_RC=0
            _hm_detached_wait "$_rsh" "Remote build HM switch" || SWITCH_RC=$?
        fi
        if [ "$SWITCH_RC" -ne 0 ]; then
            log "FAILED (exit $SWITCH_RC): HM switch on $DEPLOY_HOST"
            return 1
        fi
    else
        # ── Local build: activate pre-built closure (no nix eval on VM) ──
        CLOSURE=$(cat "$SERVICE_DIR/.closure-path" 2>/dev/null || true)
        if [ -z "$CLOSURE" ]; then
            log "ERROR: no .closure-path — run deploy first"
            return 1
        fi
        log "Activating pre-built closure on $DEPLOY_HOST"
        ACTIVATE_CMD="export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true; for cmd in nix-build nix-instantiate; do if ! command -v \$cmd >/dev/null 2>&1; then NIX_BIN=\$(dirname \$(command -v nix)); ln -sf nix \$NIX_BIN/\$cmd 2>/dev/null || sudo ln -sf nix \$NIX_BIN/\$cmd; fi; done; $CLOSURE/activate"
        log "Remote cmd: $ACTIVATE_CMD"
        set +e
        ssh_vm "bash -c '$ACTIVATE_CMD'" 2>&1 | tee -a "$BUILD_LOG_FILE"
        ACTIVATE_RC=${PIPESTATUS[0]}
        set -e
        if [ "$ACTIVATE_RC" -ne 0 ]; then
            log "FAILED (exit $ACTIVATE_RC): HM activate on $DEPLOY_HOST"
            return 1
        fi
        rm -f "$SERVICE_DIR/.closure-path"
    fi

    log "Activated $HM_CONFIG on $DEPLOY_HOST"

    # ── Post-activation: profile health + cleanup ──
    set +e
    # Ensure nix default profile is healthy
    ssh_vm 'bash -c '\''
        PROFILE_DIR=/nix/var/nix/profiles/per-user/root
        DEFAULT=/nix/var/nix/profiles/default
        if [ -L "$DEFAULT" ] && [ -d "$PROFILE_DIR" ]; then
            CURRENT=$(readlink -f "$DEFAULT")
            if [ ! -x "$CURRENT/bin/nix-collect-garbage" ] 2>/dev/null; then
                echo "[hm] nix profile broken — nix-collect-garbage missing"
                for link in "$PROFILE_DIR"/profile-*-link; do
                    TARGET=$(readlink -f "$link" 2>/dev/null)
                    if [ -x "$TARGET/bin/nix-collect-garbage" ]; then
                        GOOD=$(basename "$link")
                        echo "[hm] Restoring default profile → $GOOD"
                        sudo ln -sfn "$GOOD" "$PROFILE_DIR/profile"
                        break
                    fi
                done
            fi
        fi
    '\''' 2>&1 | tee -a "$BUILD_LOG_FILE" || true

    # Trim to last 3 generations (bash -c for fish-shell VMs)
    ssh_vm 'bash -c "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; nix-env --delete-generations +3 2>/dev/null || true"' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    # Only GC if >2GB free RAM
    ssh_vm 'bash -c "export PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$PATH; MEM=\$(awk \"/MemAvailable/ {print int(\\\$2/1024)}\" /proc/meminfo); [ \"\$MEM\" -gt 2048 ] && nix-collect-garbage 2>/dev/null || echo \"[hm] Skipping GC (\${MEM}MB free < 2GB threshold)\""' 2>&1 | tee -a "$BUILD_LOG_FILE" || true
    set -e
    log "Generations trimmed on $DEPLOY_HOST"
}
