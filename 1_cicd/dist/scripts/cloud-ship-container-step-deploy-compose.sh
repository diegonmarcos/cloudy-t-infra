# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Run containers on VM via docker compose (standard or custom)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_compose() {
    CURRENT_STEP="compose"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping compose"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    # Ensure Docker daemon is running
    if ! ssh_with_retry "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
        log_warn "Docker not running on $DEPLOY_HOST — starting"
        ssh_with_retry "$DEPLOY_HOST" "sudo systemctl start docker" 2>/dev/null || true
        sleep 5
        if ! ssh_with_retry "$DEPLOY_HOST" "docker info >/dev/null 2>&1"; then
            log_error "Docker failed to start on $DEPLOY_HOST"
            return 1
        fi
    fi

    # ── GHCR credentials on the VM ─────────────────────────────────────────
    # Repair first: /root/.docker/config.json may exist as a DIRECTORY due to a
    # historical `docker run -v /root/.docker/config.json:...` bind-mount where
    # the host path was missing — docker auto-creates such paths as
    # directories, and every `sudo docker compose pull` then fails with
    # auth/manifest errors. Idempotent: no-op when it is a file or missing.
    # Use bash -c explicitly: target VMs may use fish/zsh as login shell.
    ssh_with_retry "$DEPLOY_HOST" 'bash -c '"'"'
        if sudo test -d /root/.docker/config.json; then
            echo "[deploy-compose] /root/.docker/config.json is a DIRECTORY — repairing"
            sudo rm -rf /root/.docker/config.json
        fi
        sudo mkdir -p /root/.docker
    '"'" 2>&1 | while IFS= read -r line; do log "$line"; done

    # Which token logs the VM in. Only a LONG-LIVED token may be written into a
    # VM's docker config: whatever lands there is what every later pull on that
    # box (this ship's compose, vm-images-pull-up.sh, a manual `docker pull`)
    # authenticates with.
    #
    #   1. GHCR_PULL_TOKEN  — env, a dedicated read:packages PAT. Preferred.
    #   2. the vault token file, but ONLY if it actually holds a token.
    #
    # Deliberately NOT GITHUB_TOKEN. It is an Actions installation token
    # (ghs_...): it expires when the job ends and ghcr.io refuses it for the
    # private packages linked to their own source repos (kg-store-binaries,
    # session-memory-binaries — see cloud-ship-registry-digest.sh). Writing it
    # into the VM's config would REPLACE a working credential with one that
    # cannot pull those images now and cannot pull anything an hour later.
    #
    # Why the shape check (2026-10-10, runs 38066044682 / 38073435379): the
    # vault's b0-github/api-key_opaque/token was scrubbed from history and now
    # holds the 14-byte placeholder `***REMOVED***`. The old `[ -f ]` test took
    # that as a token, `docker login` failed on every service of every deploy,
    # the failure was a warning, and the deploy user (ubuntu on oci-apps) was
    # left with NO ghcr.io credential — so the first private image that was not
    # already cached locally (kg-store-binaries, after a prune) failed
    # `unauthorized` and the deploy died. The value is never printed: only its
    # shape is tested.
    _ghcr_token_usable() {
        case "$1" in
            *[!A-Za-z0-9_]*|'') return 1 ;;          # placeholder (`*`), whitespace, empty
            ghp_*|github_pat_*|gho_*|ghu_*) [ "${#1}" -ge 36 ] ;;
            *) return 1 ;;                          # ghs_ (ephemeral) and anything else
        esac
    }
    GHCR_TOKEN_VAL=""; _ghcr_src=""
    GHCR_TOKEN_FILE="${HOME}/git/cloud-vault/Shared/Providers/B_SERVICES-CLOUD/b0-github/api-key_opaque/token"
    if _ghcr_token_usable "${GHCR_PULL_TOKEN:-}"; then
        GHCR_TOKEN_VAL="$GHCR_PULL_TOKEN"; _ghcr_src="GHCR_PULL_TOKEN"
    elif [ -n "${GHCR_PULL_TOKEN:-}" ]; then
        log_warn "GHCR_PULL_TOKEN is set but is not a PAT (ghp_/github_pat_) — ignoring it"
    fi
    if [ -z "$GHCR_TOKEN_VAL" ] && [ -f "$GHCR_TOKEN_FILE" ]; then
        _ghcr_file_tok="$(tr -d '[:space:]' < "$GHCR_TOKEN_FILE")"
        if _ghcr_token_usable "$_ghcr_file_tok"; then
            GHCR_TOKEN_VAL="$_ghcr_file_tok"; _ghcr_src="vault token file"
        else
            log_warn "vault GHCR token file holds no usable token (scrubbed placeholder?) — not logging $DEPLOY_HOST in with it"
        fi
        unset _ghcr_file_tok
    fi

    if [ -n "$GHCR_TOKEN_VAL" ]; then
        # Login as root AND as the deploy user. Docker reads registry auth from
        # the CALLING user's ~/.docker/config.json, not the daemon's — and
        # step_compose runs `docker compose pull` WITHOUT sudo.
        #
        # Detached, not ssh_with_retry: `docker login` does a network round-trip
        # to ghcr.io from the VM and takes ~60s on a loaded/distant host; held
        # over one ssh session it dropped with 255 (runs 30756461937 /
        # 30757890274). The token goes over stdin into a umask-077 file rather
        # than into the uploaded payload, which sits on /tmp while it runs.
        _ghcr_tok="/tmp/.ghcr-tok-$$"
        printf '%s\n' "$GHCR_TOKEN_VAL" \
            | ssh $SSH_OPTS "$DEPLOY_HOST" "umask 077; cat > $_ghcr_tok" || true
        if ssh_run_detached "$DEPLOY_HOST" \
               "sudo docker login ghcr.io -u diegonmarcos --password-stdin < $_ghcr_tok >/dev/null 2>&1; _rc=\$?; docker login ghcr.io -u diegonmarcos --password-stdin < $_ghcr_tok >/dev/null 2>&1 || _rc=1; rm -f $_ghcr_tok; exit \$_rc" \
               "ghcr-login-$(basename "$DEPLOY_PATH")"; then
            log "GHCR login OK on $DEPLOY_HOST (token: $_ghcr_src)"
        else
            log_warn "GHCR login on $DEPLOY_HOST with $_ghcr_src failed — falling back to the VM's existing credential"
            ssh $SSH_OPTS "$DEPLOY_HOST" "rm -f $_ghcr_tok" >/dev/null 2>&1 || true
        fi
    else
        log_warn "no long-lived GHCR pull token (set GHCR_PULL_TOKEN: a classic PAT with read:packages only) — using the VM's existing ghcr.io credential"
    fi
    unset GHCR_TOKEN_VAL

    # Make sure the DEPLOY USER can pull, whatever happened above. Its
    # ~/.docker/config.json is the one `docker compose pull` reads. When it has
    # no working ghcr.io entry but root's does, mirror root's entry into it. All
    # VM-local: the credential is read and written on the VM, never crosses the
    # wire, never reaches a log. The deploy user already runs passwordless sudo
    # (every step here uses it), so this widens nobody's access. Validity is
    # tested against api.github.com (200 = live PAT), never printed.
    _ghcr_ensure_payload='set -u
umask 077
_live() { [ -n "$1" ] && [ "$(curl -s -m 20 -o /dev/null -w "%{http_code}" -H "Authorization: Basic $1" https://api.github.com/user)" = 200 ]; }
command -v jq >/dev/null 2>&1 || { echo "[ghcr] jq missing on VM — cannot check the deploy user credential"; exit 0; }
_me=$(id -un)
_u=$(jq -r ".auths[\"ghcr.io\"].auth // empty" "$HOME/.docker/config.json" 2>/dev/null || true)
if _live "$_u"; then echo "[ghcr] $_me: ghcr.io credential OK"; exit 0; fi
_r=$(sudo jq -r ".auths[\"ghcr.io\"].auth // empty" /root/.docker/config.json 2>/dev/null || true)
if ! _live "$_r"; then echo "[ghcr] $_me: NO working ghcr.io credential on this VM (neither $_me nor root) — private images will not pull"; exit 1; fi
mkdir -p "$HOME/.docker"
[ -s "$HOME/.docker/config.json" ] || echo "{}" > "$HOME/.docker/config.json"
jq --arg a "$_r" ".auths[\"ghcr.io\"] = {auth: \$a}" "$HOME/.docker/config.json" > "$HOME/.docker/config.json.tmp" \
  && mv "$HOME/.docker/config.json.tmp" "$HOME/.docker/config.json" && chmod 600 "$HOME/.docker/config.json"
echo "[ghcr] $_me: had no working ghcr.io credential — mirrored root'"'"'s (VM-local)"'
    if ssh_run_detached "$DEPLOY_HOST" "$_ghcr_ensure_payload" "ghcr-ensure-$(basename "$DEPLOY_PATH")"; then
        :
    else
        log_warn "GHCR: $DEPLOY_HOST has no working ghcr.io credential — pulls of PRIVATE ghcr.io images will fail with 'unauthorized' below; public images still work"
    fi
    unset _ghcr_ensure_payload

    # Pre-hook (runs on VM before containers start)
    if [ -n "$COMPOSE_PRE_HOOK" ]; then
        if ssh_with_retry "$DEPLOY_HOST" "grep -q 'entrypoint.*$COMPOSE_PRE_HOOK' $DEPLOY_PATH/$REMOTE_COMPOSE_REL 2>/dev/null"; then
            log "Skipping pre_hook '$COMPOSE_PRE_HOOK' — container entrypoint"
        else
            log "Running pre-hook: $COMPOSE_PRE_HOOK"
            # Detached, not ssh_with_retry: hooks are minute-scale remote work
            # (fetch-mcp-bearer.sh does an OIDC round-trip), and holding one ssh
            # session open for them hits the same transport drop the compose
            # payload hits. chat-mattermost → oci-apps, 2026-08-02: every attempt
            # died at ~60s with exit 255, and each retry re-ran the whole hook
            # from scratch — 4 runs, ~6 min, then the ship failed. Detached keeps
            # the hook running across a dropped poll and returns its REAL rc.
            ssh_run_detached "$DEPLOY_HOST" \
                "cd $DEPLOY_PATH && chmod +x $COMPOSE_PRE_HOOK && ./$COMPOSE_PRE_HOOK" \
                "prehook-$(basename "$DEPLOY_PATH")"
        fi
    fi

    # ── Compose up policy: NEVER build on the deploy VM. ──
    # All images are pre-built by the engine and pushed to GHCR (step_docker).
    # VMs only PULL — they never rebuild. --no-build (ALWAYS set) keeps 1GB
    # e2-micro VMs alive (compose `build` would OOM) and guarantees the running
    # image matches what was tested in CI. `--build` in build.json's
    # deploy.compose_flags is IGNORED; the engine logs a warning below.
    #
    # ── Recreate / pull policy: decoupled ensure-running vs. real redeploy ──
    # step_compose now ALWAYS runs in the ship pipeline — even when nothing
    # changed — so a container stopped out-of-band (load-shedder killing docker,
    # VM reboot) is brought back `up` (gcp-proxy's whole stack sat Exited while
    # two `ship` re-dispatches no-op'd, 2026-06). See the Phase-3 comment in
    # cloud-ship-container-engine.sh. To keep that cheap, pull + recreate are
    # derived from what actually changed:
    #   • --pull always    → only when the image changed ($DOCKER_IMAGE_CHANGED).
    #     The fleet pins :latest tags, so "missing" once let a stale locally
    #     cached image shadow a freshly-pushed GHCR image forever — crawlee's
    #     amd64 mispush (run 27409752538) kept winning over the corrected arm64
    #     build. When the image is UNCHANGED there is nothing new to fetch, so we
    #     use --pull missing (no needless registry hit; local cache authoritative).
    #   • --force-recreate → only when image OR config changed. A pure
    #     ensure-running `up -d` restarts stopped containers WITHOUT recreating
    #     already-running ones, so re-running ship on an unchanged stack is a
    #     near-no-op that still heals a shed/stopped container.
    #
    # DOCKER_IMAGE_CHANGED / CONFIG_CHANGED are set by the ship pipeline. When
    # step_compose is invoked standalone (`build.sh compose`) both are UNSET; we
    # then keep the historical full refresh (pull always + force-recreate) so the
    # manual command still forces a clean redeploy.
    if [ -z "${DOCKER_IMAGE_CHANGED+x}" ] && [ -z "${CONFIG_CHANGED+x}" ]; then
        _PULL_POLICY="--pull always"; _RECREATE="--force-recreate"; COMPOSE_PULL_FIRST="true"
    else
        if [ -n "${DOCKER_IMAGE_CHANGED:-}" ]; then
            _PULL_POLICY="--pull always"; COMPOSE_PULL_FIRST="true"
        else
            _PULL_POLICY="--pull missing"; COMPOSE_PULL_FIRST="false"
        fi
        if [ -n "${DOCKER_IMAGE_CHANGED:-}" ] || [ -n "${CONFIG_CHANGED:-}" ]; then
            _RECREATE="--force-recreate"
        else
            _RECREATE=""
        fi
    fi
    COMPOSE_UP_FLAGS="--no-build $_PULL_POLICY $_RECREATE"
    if echo "$COMPOSE_FLAGS" | grep -q -- '--build'; then
        log_warn "deploy.compose_flags contains --build but VM rebuilds are disabled — using --no-build (engine pushes pre-built images to GHCR)"
    fi

    # v1→v2 layout migration cleanup. Older deploys placed docker-compose.yml at
    # the project ROOT; v2 canonical is a subdir (compose/docker-compose.yml). A
    # lingering root file lets `docker compose` (or any `cd $dir && docker
    # compose up`, e.g. the cloud-infra-local MCP tool) start a SECOND compose
    # project that grabs the same explicit `container_name`. The canonical
    # `down --remove-orphans` only evicts its own project, so that foreign
    # container then blocks `up` with "container name already in use" (cloud-mail-mcp,
    # 2026-06-16). When canonical compose lives in a subdir, tear down + delete
    # any stale root file first so deploys stay idempotent. Runs on the VM; no
    # single quotes (embedded into a single-quote-wrapped bash -c PAYLOAD).
    LEGACY_COMPOSE_CLEANUP=""
    case "$REMOTE_COMPOSE_REL" in
        */*) LEGACY_COMPOSE_CLEANUP='if [ -f docker-compose.yml ]; then docker compose -f docker-compose.yml --project-directory . down --remove-orphans 2>/dev/null || true; rm -f docker-compose.yml; fi' ;;
    esac

    # Foreign-project container eviction. Our `down --remove-orphans` runs with
    # project = basename($DEPLOY_PATH) (via --project-directory .), so it ONLY
    # removes containers compose recorded under THAT project. A container created
    # under a DIFFERENT project with the same explicit container_name — e.g. a
    # manual `cd compose && docker compose up` (project="compose") or the
    # cloud-infra MCP devops_docker_compose_up — survives the `down`, then blocks
    # `up` with "container name already in use" (wireguard-mesh + etherpad_postgres,
    # 2026-06-22). Force-remove the declared container_names by hand first:
    # idempotent (no-op when `down` already removed them), data-driven from
    # build.json, and lossless — `docker rm -f` drops only the container, named
    # volumes persist.
    EVICT_NAMED=""
    # declared_container_names (engine) fails loudly on a malformed containers{}
    # instead of returning a silently truncated list — see #20/L3 there. A short
    # list here is not cosmetic: the containers it omits are the ones that never
    # get evicted, so `up` finds them still holding their names.
    # Two statements, not a pipeline: the function's exit status is what must be
    # checked, and in `f | tr` the shell reports tr's status, not f's.
    _cnames="$(declared_container_names "$SERVICE_DIR/build.json")" || return 1
    _cnames="$(printf '%s' "$_cnames" | tr '\n' ' ')"
    [ -n "$_cnames" ] && EVICT_NAMED="for c in $_cnames; do docker rm -f \"\$c\" 2>/dev/null || true; done"

    # EVICT_NAMED only knows the names we declare NOW, so it cannot see the one
    # container that matters after a rename: the predecessor, still running
    # under the OLD name, still holding the host port. `down` misses it too —
    # different project, different name — and `up` then dies with
    #   driver failed programming external connectivity on endpoint
    #   cloud-services-mcp: Bind for 10.0.0.6:3101 failed: port is already
    #   allocated
    # which is what happened to c3-services-mcp → cloud-services-mcp (and
    # mail-mcp, mattermost-mcp) on oci-apps. Renaming a service is supposed to
    # be an identity-only change, so it must not require hand-reaping the old
    # container on the box.
    #
    # A host ip:port in our compose file is OUR declaration of that binding —
    # the fleet gives each service a unique one. Anything else holding it is by
    # definition a stale predecessor, so evict on the binding, not on the name.
    # Scoped tightly: only exact host bindings this compose declares, and never
    # a container we ourselves named. `docker rm -f` drops the container only;
    # named volumes persist.
    # `|| true` is load-bearing, not defensive noise. A service with NO host
    # port bindings is normal (network_mode:host publishes nothing — maddy,
    # google-workspace-mcp, google-personal-mcp, ...), and then `grep` matches
    # nothing and exits 1. Under `set -o pipefail` that makes the whole
    # pipeline — and therefore this assignment — return 1, which `set -e`
    # turns into an immediate abort of the entire compose step.
    #
    # It only reproduces in CI: build.sh sets `-e` but not `pipefail`, while
    # GitHub Actions runs steps under `bash -eo pipefail` and exports
    # SHELLOPTS into child shells. So `build.sh compose` run by hand
    # succeeded while the identical code failed in every Ship run — which is
    # exactly how this hid since 1d43ef313. The symptom gave nothing away:
    # "Step 'compose' failed (exit 1)" logged ~9ms after the previous line,
    # no command having run, nothing reaching the VM.
    EVICT_PORTS=""
    _hostbinds="$(grep -oE '"[0-9][0-9.]*:[0-9]+:[0-9]+"' "$COMPOSE_FILE" 2>/dev/null \
        | tr -d '"' | sed 's/:[0-9]*$//' | sort -u | tr '\n' ' ' || true)"

    [ -n "$_hostbinds" ] && EVICT_PORTS="for hp in $_hostbinds; do for c in \$(docker ps --format '{{.Names}} {{.Ports}}' | grep -F \"\$hp->\" | cut -d' ' -f1); do case \" $_cnames \" in *\" \$c \"*) ;; *) echo \"[compose] evicting \$c — it holds \$hp, which this service declares\"; docker rm -f \"\$c\" >/dev/null 2>&1 || true ;; esac; done; done"

    # ...and the blind spot in the above: it reads bindings off the RENDERED
    # compose, so a service on network_mode:host declares none and _hostbinds
    # comes back empty — even though the app still binds its port on the VM.
    # c3-services-mcp -> cloud-services-mcp switched to network_mode:host in
    # the same change as the rename, so the predecessor kept 10.0.0.6:3101, the
    # new container died on bind, and health saw an empty `docker compose ps`
    # for 46h. c3-infra-mcp -> cloud-infra-mcp was the second shape: both sides
    # host-networked, the old container holding 10.0.0.6:3100 while
    # `docker ps` showed no ports at all.
    #
    # So for a host-network compose, the VM-side payload asks the kernel who
    # holds .ports.app (ss -> pid -> /proc/<pid>/cgroup -> container), plus
    # `docker ps` for a bridged holder whose socket belongs to docker-proxy.
    # ONLY .ports.app, deliberately: the other keys are container-internal
    # (chat-mattermost declares db:5432, api:8080).
    #
    # AND IT COMPARES THE LISTEN ADDRESS, NOT JUST THE PORT. Two sockets on
    # one port only collide when their addresses overlap: the same address, or
    # either side on a wildcard (0.0.0.0, ::, *). 127.0.0.1:8081 and
    # 10.0.0.6:8081 coexist on Linux. Matching the port alone is how the
    # c3-infra-api deploy on 2026-10-10 21:51 logged
    #   evicting matomo-hybrid — it holds :8081, which this service binds
    # for matomo's internal 127.0.0.1:8081 listener against its own
    # 10.0.0.6:8081, and matomo stayed gone for three days.
    #
    # The deploying service's own address is not declared anywhere (each app
    # reads it from its own env var: HOST, MCP_HTTP_HOST, LISTEN_HOST, ...), so
    # it is OBSERVED: before `down`, the payload records which addresses our
    # own declared containers listen on for .ports.app. Not running (first
    # deploy, an absent service, a rename) means unknown, and unknown is
    # treated as 0.0.0.0 — overlaps everything, which is exactly the old
    # port-only behaviour, so the rename cases above are still evicted.
    #
    # The VM-side logic lives in evict_socket_lib (below step_compose) so
    # 9_others/test/test_compose_evict_socket_address.sh runs the very text the
    # payload carries against stubbed ss/docker.
    EVICT_SOCKET_PRE=""
    EVICT_SOCKET=""
    if grep -q '"network_mode":"host"' "$COMPOSE_FILE" 2>/dev/null; then
        _appport="$(jq -r '.ports.app // empty' "$SERVICE_DIR/build.json" 2>/dev/null)"
        case "$_appport" in
            ''|*[!0-9]*) ;;
            *) EVICT_SOCKET_PRE="$(evict_socket_pre "$_appport" "$_cnames")"
               EVICT_SOCKET="$(evict_socket_run "$_appport")" ;;
        esac
    fi

    if [ "$COMPOSE_CUSTOM" = "true" ]; then
        # ── Custom compose script: self-contained, used by both ship + container-init ──
        # Generated in a tmpdir (ship transient — never pollutes dist/ or git working tree).
        SCRIPT_NAME="build-step-compose-custom.sh"
        TMP_SCRIPT="$(mktemp -t compose-custom.XXXXXX.sh)"
        trap 'rm -f "$TMP_SCRIPT"' EXIT
        log "Generating $SCRIPT_NAME (flags: $COMPOSE_UP_FLAGS)"
        {
            cat <<'COMPOSE_HEADER'
#!/bin/sh
set -e
if ! docker info >/dev/null 2>&1; then
  echo "[compose-custom] Docker not running — starting..."
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
  docker info >/dev/null 2>&1 || { echo "[compose-custom] ERROR: Docker failed to start" >&2; exit 1; }
fi
# v2 layout: secrets live at compose/.secrets (alongside docker-compose.yml).
# But --project-directory . forces docker-compose's env_file resolution to
# ./.secrets at project root. Symlink so env_file: [".secrets"] in the YAML
# AND --env-file CLI both resolve to the same file.
ENV_FILE_FLAG=""
if [ -f compose/.secrets ]; then
  [ -e .secrets ] || ln -sf compose/.secrets .secrets
  ENV_FILE_FLAG="--env-file .secrets"
elif [ -f .secrets ]; then
  ENV_FILE_FLAG="--env-file .secrets"
fi
COMPOSE_HEADER
            # v2: compose at compose/ subdir; force project-dir=CWD for env_file/volumes resolution
            echo "COMPOSE_FILE_FLAG='-f $REMOTE_COMPOSE_REL --project-directory .'"
            [ -n "$LEGACY_COMPOSE_CLEANUP" ] && echo "$LEGACY_COMPOSE_CLEANUP"
            # Pull-gate: when refreshing to a new image, OBTAIN it BEFORE tearing
            # down the running container. A pull that fails (private/denied GHCR,
            # registry down) must NOT proceed to `down` unless the image is
            # already cached locally — otherwise a healthy container is destroyed
            # for an image we can't start (dagu outage 2026-07-11: private
            # dagu-binaries → pull denied → down → up couldn't pull → no
            # container). Since the gate pulls explicitly, `up` uses --pull
            # missing (below) so the cache-fallback path doesn't re-trigger the
            # failing pull.
            if [ "$COMPOSE_PULL_FIRST" = "true" ]; then
                cat <<'PULL_GATE'
if ! docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG pull; then
  echo "[compose-custom] pull failed — verifying local image cache before teardown" >&2
  _miss=0
  for _img in $(docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG config --images 2>/dev/null); do
    docker image inspect "$_img" >/dev/null 2>&1 || { echo "[compose-custom] ERROR: $_img neither pullable nor cached locally" >&2; _miss=1; }
  done
  [ "$_miss" = 0 ] || { echo "[compose-custom] ERROR: refusing to tear down running container(s) for an unobtainable image" >&2; exit 1; }
  echo "[compose-custom] images present locally — proceeding with cache" >&2
fi
PULL_GATE
            fi
            # Before `down`: record which addresses our own containers listen on.
            [ -n "$EVICT_SOCKET_PRE" ] && printf '%s\n' "$EVICT_SOCKET_PRE"
            echo 'docker compose $COMPOSE_FILE_FLAG $ENV_FILE_FLAG down --remove-orphans 2>/dev/null || true'
            [ -n "$EVICT_NAMED" ] && echo "$EVICT_NAMED"
            [ -n "$EVICT_PORTS" ] && echo "$EVICT_PORTS"
            [ -n "$EVICT_SOCKET" ] && echo "$EVICT_SOCKET"
            # Gate already pulled → up must not re-pull (would re-hit the failure
            # on the cache-fallback path). Swap always→missing for the up line.
            _CUSTOM_UP_FLAGS="$COMPOSE_UP_FLAGS"
            [ "$COMPOSE_PULL_FIRST" = "true" ] && _CUSTOM_UP_FLAGS="${COMPOSE_UP_FLAGS/--pull always/--pull missing}"
            echo "docker compose \$COMPOSE_FILE_FLAG \$ENV_FILE_FLAG up -d $_CUSTOM_UP_FLAGS"
        } > "$TMP_SCRIPT"
        chmod +x "$TMP_SCRIPT"

        log "Deploying + running $SCRIPT_NAME on $DEPLOY_HOST"
        rsync -az "$TMP_SCRIPT" "$DEPLOY_HOST:$DEPLOY_PATH/$SCRIPT_NAME"
        # Same reasoning as the standard path below — this custom script also
        # pulls images, so it must not hold a single ssh session open either.
        # compose_run, not ssh_run_detached: a service that declares deploy.drain must not be
        # recreated under live agents (cloud-ship-container-step-deploy-drain.sh).
        compose_run \
            "cd $DEPLOY_PATH && sh $SCRIPT_NAME; _rc=\$?; rm -f $SCRIPT_NAME; exit \$_rc" \
            "compose-custom-$(basename "$DEPLOY_PATH")" "$_cnames"
        rm -f "$TMP_SCRIPT"
        trap - EXIT
    else
        # ── Standard: direct docker compose up ──
        # v2 layout: prefer compose/.secrets; fall back to ./.secrets. The flag
        # is resolved by the REMOTE shell, so the whole command MUST run under
        # bash — target VMs use fish as the login shell (e.g. oci-apps), and
        # fish rejects POSIX `$(...)` command substitution ("command
        # substitutions not allowed here"), silently dropping --env-file.
        # Without --env-file docker compose has NO interpolation source, so any
        # `${SECRET}` referenced inside an `environment:` value (e.g. a
        # DATABASE_URL embedding ${POSTGRES_PASSWORD}) renders EMPTY while
        # `env_file:` values still resolve via --project-directory — a silent,
        # asymmetric secret corruption (paca-api SASL auth failure, 2026-06-14).
        # Wrap in `bash -c` for guaranteed POSIX semantics — same pattern as the
        # GHCR-repair block above. PAYLOAD is built with double quotes only (no
        # single quotes) so it can be single-quote-wrapped for fish→bash verbatim.
        CF="-f $REMOTE_COMPOSE_REL --project-directory ."
        ENV_FILE_PROBE='ENV_FILE_FLAG="$([ -f compose/.secrets ] && echo --env-file compose/.secrets || { [ -f .secrets ] && echo --env-file .secrets; })"'
        # #1686: a service moved to Cloud Run keeps its compose under `profiles: [cloud-run]` (Rule 16: the
        # declaration stays). With every service profile-gated, `up` fails "no service selected" AFTER `down`
        # has already removed the running containers, which took cloudy-browser-headless and scrappers-api
        # off oci-apps on 2026-11-18 03:16 before their Cloud Run path was live. When the resolved project
        # selects no service, the stack is served elsewhere: change nothing on the VM and succeed. A compose
        # file that does not resolve at all (config exits non-zero) is NOT this case and goes on to fail loudly.
        GATED_PROBE='_svcs="$(docker compose '"$CF"' $ENV_FILE_FLAG config --services 2>/dev/null)"; _crc=$?; if [ "$_crc" -eq 0 ] && [ -z "$_svcs" ]; then echo "compose: every service is profile-gated (served elsewhere, e.g. Cloud Run); nothing started or stopped on this VM"; exit 0; fi'
        log "Running docker compose up on $DEPLOY_HOST:$DEPLOY_PATH (compose=$REMOTE_COMPOSE_REL)"
        if [ "$COMPOSE_PULL_FIRST" = "true" ]; then
            # Pull-gate: obtain the new image BEFORE `down`. On pull failure,
            # proceed only if every image is already cached locally; otherwise
            # abort BEFORE teardown (never destroy a running container for an
            # image we can't start — dagu outage 2026-07-11). Gate pulls
            # explicitly → `up` uses --pull missing so the cache-fallback path
            # doesn't re-hit the failing pull.
            _STD_UP_FLAGS="${COMPOSE_UP_FLAGS/--pull always/--pull missing}"
            PULL_GATE="docker compose $CF \$ENV_FILE_FLAG pull || { for _img in \$(docker compose $CF \$ENV_FILE_FLAG config --images 2>/dev/null); do docker image inspect \"\$_img\" >/dev/null 2>&1 || { echo \"ERROR: \$_img neither pullable nor cached — refusing teardown\" >&2; exit 1; }; done; }"
            PAYLOAD="cd \"$DEPLOY_PATH\" && $ENV_FILE_PROBE; $GATED_PROBE; ${LEGACY_COMPOSE_CLEANUP:+$LEGACY_COMPOSE_CLEANUP; }$PULL_GATE; ${EVICT_SOCKET_PRE:+$EVICT_SOCKET_PRE; }docker compose $CF \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; ${EVICT_NAMED:+$EVICT_NAMED; }${EVICT_PORTS:+$EVICT_PORTS; }${EVICT_SOCKET:+$EVICT_SOCKET; }docker compose $CF \$ENV_FILE_FLAG up -d $_STD_UP_FLAGS"
        else
            PAYLOAD="cd \"$DEPLOY_PATH\" && $ENV_FILE_PROBE; $GATED_PROBE; ${LEGACY_COMPOSE_CLEANUP:+$LEGACY_COMPOSE_CLEANUP; }${EVICT_SOCKET_PRE:+$EVICT_SOCKET_PRE; }docker compose $CF \$ENV_FILE_FLAG down --remove-orphans 2>/dev/null; ${EVICT_NAMED:+$EVICT_NAMED; }${EVICT_PORTS:+$EVICT_PORTS; }${EVICT_SOCKET:+$EVICT_SOCKET; }docker compose $CF \$ENV_FILE_FLAG up -d $COMPOSE_UP_FLAGS"
        fi
        # Detached + poll, NOT one long-held ssh: the pull/extract can run for
        # minutes with an almost-idle ssh channel, which is exactly when the
        # wg path to the CI runner lapses and drops the stream (exit 255).
        # See ssh_run_detached in cloud-ship-container-engine.sh.
        # compose_run = ssh_run_detached, behind the agent drain when deploy.drain is declared.
        compose_run "$PAYLOAD" "compose-$(basename "$DEPLOY_PATH")" "$_cnames"
    fi

    # ── Post-hook, with a REVISION-SCOPED run receipt ──────────────────
    # The hook is the only thing that turns freshly-synced config into live
    # state (stalwart's activate.sh creates the mail accounts). Before this
    # receipt existed there was NO durable evidence on the VM that it ever
    # ran for the revision just synced: ssh_run_detached DELETES its remote
    # /tmp log on success, so a green ship left nothing behind, and the only
    # log an operator could find was a LEFTOVER one from an earlier run that
    # never finished. On 2026-09-04 the fixed activate.sh sat on oci-mail
    # with mtime 23:11 while the newest post-hook log was 19:33 — four hours
    # stale — and four declared mail accounts did not exist for a day, with
    # the MX happily accepting their mail.
    #
    # Existence is NOT the check. A stale artifact satisfies "a log exists",
    # which is exactly the trap. The receipt is a token unique to THIS ship
    # (revision + epoch + pid), written by the remote payload only after the
    # hook exits 0, into a path the payload wipes first. So the file can only
    # hold this token if this run's hook actually ran to completion, and any
    # older receipt is a hard mismatch rather than a pass.
    #
    # The revision is the deployed service tree's own sha (a_solutions is a
    # submodule — that is the sha which defines the hook's contents), with
    # GITHUB_SHA as the fallback for a stripped checkout.
    if [ -n "$COMPOSE_POST_HOOK" ]; then
        _ph_rev="$(git -C "${SERVICE_DIR:-.}" rev-parse --short=12 HEAD 2>/dev/null || true)"
        [ -n "$_ph_rev" ] || _ph_rev="${GITHUB_SHA:-norev}"
        _ph_token="${_ph_rev}.$(date +%s).$$"
        _ph_receipt="$DEPLOY_PATH/.posthook-receipt"
        log "Running post-hook: $COMPOSE_POST_HOOK (receipt $_ph_token)"
        ssh_run_detached "$DEPLOY_HOST" \
            "cd $DEPLOY_PATH && rm -f '$_ph_receipt' && chmod +x $COMPOSE_POST_HOOK && SHIP_REVISION='$_ph_rev' ./$COMPOSE_POST_HOOK && printf '%s\n' '$_ph_token' > '$_ph_receipt'" \
            "posthook-$(basename "$DEPLOY_PATH")"
        _ph_seen="$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$_ph_receipt' 2>/dev/null" 2>/dev/null | tr -d ' \r\n' || true)"
        if [ "$_ph_seen" != "$_ph_token" ]; then
            log_error "post-hook receipt MISMATCH on $DEPLOY_HOST:$_ph_receipt"
            log_error "  expected: $_ph_token"
            log_error "  found:    ${_ph_seen:-<absent>}"
            log_error "  → $COMPOSE_POST_HOOK did not run to completion for revision $_ph_rev; the synced config is NOT active."
            return 1
        fi
        log "Post-hook receipt verified for revision $_ph_rev"
    fi

    # Verify — a gate, not a log line (#560). This used to print `docker ps`
    # filtered by name and return 0 whatever it said, so a deploy could END
    # with a container in `created` and still exit green. Compose completes
    # `up` for every declared container or this step goes red.
    log "Verifying declared containers are live..."
    sleep 3
    assert_declared_containers_live || return 1
    log "Done."
}

# ── Address-aware socket eviction: the VM-side text ─────────────────────────
# Emitted into the compose payload by step_compose for a network_mode:host
# service. POSIX sh on purpose: the custom-compose path runs it under `sh`
# with `set -e`, the standard path under bash. Every loop ends in `:` and every
# call site carries `|| true`, so a "no match" can never abort the deploy.
#
#   evict_socket_pre <port> <declared container names>
#       defines the helpers, then records in $_es_own the addresses OUR
#       declared containers listen on for <port>. Runs BEFORE `down`.
#   evict_socket_run <port>
#       evicts every other container whose listener on <port> overlaps an
#       address in $_es_own (unknown = 0.0.0.0, which overlaps everything).
#
# Overlap: the same address, or either side a wildcard (0.0.0.0, ::, *).
# 127.0.0.1, ::1 and 10.0.0.6 are distinct and never collide with each other.
# A v4-mapped v6 address (::ffff:10.0.0.6) is compared as its v4 form.
evict_socket_lib() {
    cat <<'EVICT_SOCKET_LIB'
_es_norm() { _es_a=${1%:*}; _es_a=${_es_a#\[}; _es_a=${_es_a%\]}; _es_a=${_es_a%%\%*}; _es_a=${_es_a#::ffff:}; [ "$_es_a" = "*" ] && _es_a=0.0.0.0; printf '%s\n' "$_es_a"; }
_es_wild() { case "$1" in 0.0.0.0|::|'') return 0 ;; esac; return 1; }
_es_overlap() { [ "$1" = "$2" ] && return 0; _es_wild "$1" && return 0; _es_wild "$2"; }
_es_mine() { case " $_es_cnames " in *" $1 "*) return 0 ;; esac; return 1; }
_es_cid() { sudo sed -nE 's#.*[-/]([0-9a-f]{64})(\.scope)?$#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -1; }
_es_name() { docker inspect --format '{{.Name}}' "$1" 2>/dev/null | sed 's#^/##'; }
_es_listeners() { sudo ss -lntpH "sport = :$1" 2>/dev/null | while read -r _es_st _es_rq _es_sq _es_loc _es_peer _es_proc; do _es_addr=$(_es_norm "$_es_loc"); for _es_p in $(printf '%s\n' "$_es_proc" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do printf '%s %s\n' "$_es_addr" "$_es_p"; done; :; done; }
_es_own_binds() { _es_listeners "$1" | while read -r _es_addr _es_p; do _es_c=$(_es_cid "$_es_p"); [ -n "$_es_c" ] || continue; _es_n=$(_es_name "$_es_c"); [ -n "$_es_n" ] || continue; if _es_mine "$_es_n"; then printf '%s\n' "$_es_addr"; fi; :; done | sort -u | tr '\n' ' '; }
_es_decide() { for _es_b in $5; do if _es_overlap "$_es_b" "$3"; then echo "[compose] evicting $1 — it holds $3:$4, which overlaps this service's bind $_es_b:$4"; docker rm -f "$2" >/dev/null 2>&1 || true; return 0; fi; done; echo "[compose] keeping $1 — it holds $3:$4, which does not overlap this service's bind ($5) on :$4"; }
_es_evict() { _es_bind=${2:-0.0.0.0}; _es_listeners "$1" | while read -r _es_addr _es_p; do _es_c=$(_es_cid "$_es_p"); [ -n "$_es_c" ] || continue; _es_n=$(_es_name "$_es_c"); [ -n "$_es_n" ] || continue; if ! _es_mine "$_es_n"; then _es_decide "$_es_n" "$_es_c" "$_es_addr" "$1" "$_es_bind"; fi; :; done; docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | while read -r _es_n _es_ports; do if ! _es_mine "$_es_n"; then for _es_pp in $(printf '%s\n' "$_es_ports" | tr ',' ' '); do case "$_es_pp" in *":$1->"*) _es_decide "$_es_n" "$_es_n" "$(_es_norm "${_es_pp%%->*}")" "$1" "$_es_bind"; break ;; esac; done; fi; :; done; }
EVICT_SOCKET_LIB
}

evict_socket_pre() {
    evict_socket_lib
    printf '_es_cnames="%s"\n' "$2"
    printf '_es_own=$(_es_own_binds %s) || _es_own=""\n' "$1"
    printf 'echo "[compose] :%s is bound by this service on: ${_es_own:-nothing running — treated as 0.0.0.0}"\n' "$1"
}

evict_socket_run() {
    printf '_es_evict %s "$_es_own" || true\n' "$1"
}
