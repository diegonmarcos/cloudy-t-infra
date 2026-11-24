# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-container-step-deploy-health.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Post-deploy health check — waits for all containers to be healthy
# Sourced by cloud-ship-container-engine.sh

# Assert every PUBLISHED port actually accepts a connection on the host.
#
# Container health is not service health: on 2026-08-29 a stalwart deploy
# recreated stalwart_default, the container moved to a new bridge IP, and
# docker left 10 DNAT rules pointing at the OLD address on a bridge that no
# longer existed. Zero rules pointed at the live container. Every published
# port — JMAP, IMAP, SMTP, ManageSieve — refused connections while the
# container reported `healthy`, because its healthcheck curls 127.0.0.1 from
# *inside* the netns and never crosses the NAT that was broken. The deploy
# went green and the mail server was dark.
#
# ponytail: a TCP connect, not a protocol probe. Anything deeper needs
# per-service knowledge the engine does not have, and a refused connect is
# the failure mode NAT breakage actually produces.
# Re-point published-port DNAT at the containers' current addresses, by piping
# cloud-ship-container-sync-dnat.sh to the host. See that script for why.
# Non-fatal: it is a repair, and _assert_published_ports is the actual verdict.
_sync_published_port_dnat() {
    local cf="$1"
    # STEPS_DIR is where the engine sourced this file from (it resolves the
    # build.sh symlink first), so the helper sits beside us.
    local helper="${STEPS_DIR:-$(dirname "$0")}/cloud-ship-container-sync-dnat.sh"
    [ -f "$helper" ] || { log "  dnat: helper missing, skipping repair"; return 0; }

    local out
    out=$(ssh -o ConnectTimeout=15 -o BatchMode=yes "$DEPLOY_HOST" \
              "cd '$DEPLOY_PATH' && sudo bash -s -- '$cf'" < "$helper" 2>/dev/null || true)
    [ -z "$out" ] && return 0
    # Only surface real changes; a fully correct fleet prints "ok ..." per port.
    # A case, not `grep -v '^ok '`: on an all-ok host that grep matches nothing
    # and exits 1, and CI exports pipefail into this `set -e` engine, so the
    # whole ship died here silently with every port answering.
    echo "$out" | while read -r l; do
        case "$l" in ''|'ok '*) ;; *) log "  dnat: $l" ;; esac
    done
    return 0
}

_assert_published_ports() {
    local cf="$1"
    local probe
    probe='for c in $(docker compose '"$cf"' ps --format "{{.Name}}" 2>/dev/null); do
        docker port "$c" 2>/dev/null | while read -r line; do
            hp=${line##*-> }
            [ "$hp" = "$line" ] && continue
            port=${hp##*:}
            ip=${hp%:*}
            case "$ip" in 0.0.0.0|::|"[::]") ip=127.0.0.1 ;; esac
            ip=${ip#[}; ip=${ip%]}
            if ! timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
                echo "DEAD $c $ip:$port"
            fi
        done
    done'

    # Retry: "healthy" is the container's own healthcheck, which can pass
    # before the service has finished binding its listeners. The 2026-08-30
    # 08:30 stalwart deploy failed here 6s after `All containers healthy (0s)`
    # while every port was in fact fine minutes later -- a false negative that
    # failed a deploy whose activate step had already succeeded. Only a probe
    # that stays dead for the whole window is a real failure.
    local dead=""
    local waited=0
    local grace="${PORT_ASSERT_GRACE:-45}"
    while :; do
        dead=$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && $probe'" 2>/dev/null || true)
        [ -z "$dead" ] && return 0
        [ "$waited" -ge "$grace" ] && break
        sleep 5
        waited=$((waited + 5))
    done

    log "FAIL: ports still refusing after ${grace}s of healthy containers:"
    echo "$dead" | while read -r l; do log "  $l"; done
    log "  (typically orphaned docker DNAT rules after a network recreate --"
    log "   compare 'iptables -t nat -S DOCKER' against the live container IP)"
    return 1
}

# ── #560: a container in `created` is DEAD, not stale ─────────────────
# An evicted deploy left my-ai-api in state `created`: never started, no logs,
# ExitCode 0. `docker ps -a` listed it, its image digest matched the registry,
# and both telegram bots were down behind a deploy that looked fine. Every
# cheap probe read healthy because none of them asked the one question that
# matters: did this container ever START? `docker compose ps` (no -a) does not
# even list a created container, so the wait loop below never saw it.
#
# The declared list comes from build.json's containers{}, not from whatever
# compose happens to list — a container compose never started is exactly the
# one a compose listing can omit.
#
# Pure, so the tester can drive it without a VM:
#   $1     declared container names (whitespace separated)
#   $2     declared one-shot names (containers{}.<k>.one_shot == true)
#   stdin  "<name>|<State.Status>|<State.ExitCode>" per line, as docker inspect prints
#   stdout "DEAD <name> <why>" / "MISSING <name>" per finding
#   rc     1 iff any declared container is DEAD
# Live = running, or restarting (step_health's crash-loop check owns that one,
# with logs). exited is live ONLY for a declared one-shot that exited 0.
#
# ponytail: MISSING is reported, not fatal — some declared containers are
# on-demand or run outside compose (the reconcile's `absent` list). Make it
# fatal once build.json can say which containers a deploy must create.
_container_liveness() {
    local declared="$1" oneshot="$2" states name line st code dead=0
    states="$(cat)"
    for name in $declared; do
        line="$(printf '%s\n' "$states" | awk -F'|' -v n="$name" '{sub(/^\//, "", $1)} $1 == n {print $2 "|" $3; exit}')"
        if [ -z "$line" ]; then echo "MISSING $name"; continue; fi
        st="${line%%|*}"; code="${line#*|}"
        case "$st" in
            running|restarting) ;;
            exited)
                case " $oneshot " in
                    *" $name "*) [ "$code" = "0" ] || { echo "DEAD $name one-shot exited $code"; dead=1; } ;;
                    *) echo "DEAD $name exited $code (not a declared one_shot)"; dead=1 ;;
                esac ;;
            created) echo "DEAD $name created — never started"; dead=1 ;;
            *) echo "DEAD $name $st"; dead=1 ;;
        esac
    done
    return "$dead"
}

# #1686: true (rc 0) iff the deployed compose project RESOLVES (config exit 0) to zero services, i.e. every service
# sits behind an inactive profile (cloud-run) and the stack is served elsewhere. step_compose then changes nothing on
# the VM, so neither the health wait nor the liveness assertion applies: containers left on the VM from before the
# move (stopped on purpose, volumes kept under Rule 16) are not this deploy's output. A compose file that does not
# resolve is NOT gated and goes through the normal checks.
_profile_gated() {
    [ -n "${REMOTE_COMPOSE_REL:-}" ] && [ -n "${DEPLOY_PATH:-}" ] || return 1
    local cf="-f $REMOTE_COMPOSE_REL --project-directory ."
    [ -f "${DIST_DIR:-/nonexistent}/.secrets" ] && cf="--env-file .secrets $cf"
    local g
    g=$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && _s=\$(docker compose $cf config --services 2>/dev/null) && [ -z \"\$_s\" ] && echo GATED'" 2>/dev/null || true)
    [ "$g" = "GATED" ]
}

# Observe the declared containers on the VM and fail the step on any DEAD one.
# Called at the end of step_compose (the deploy cannot END in created) and by
# step_health (the post-deploy guard), so both `ship` and `rollout` see it.
assert_declared_containers_live() {
    local bj="$SERVICE_DIR/build.json" names oneshot out verdict rc=0
    names="$(declared_container_names "$bj")" || return 1
    names="$(printf '%s' "$names" | tr '\n' ' ')"
    [ -n "${names// /}" ] || { log "liveness: no containers{}.container_name declared — nothing to check"; return 0; }
    if _profile_gated; then log "liveness: every service is profile-gated (served elsewhere, e.g. Cloud Run); containers left on this VM are not this deploy's output"; return 0; fi
    oneshot="$(jq -r '(.containers // {}) | to_entries[] | .value
                      | select(type == "object" and .one_shot == true)
                      | .container_name // empty' "$bj" | tr '\n' ' ')" || return 1

    # The trailing marker separates "VM answered, nothing matched" from "VM did
    # not answer": without it an unreachable host reads as all-MISSING, which is
    # only a warning — the silent pass this function exists to delete.
    out="$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'docker inspect --format \"{{.Name}}|{{.State.Status}}|{{.State.ExitCode}}\" $names 2>/dev/null; echo __liveness_probed__'" 2>/dev/null || true)"
    case "$out" in
        *__liveness_probed__*) ;;
        *) log_error "liveness: $DEPLOY_HOST did not answer the container-state probe — refusing to call $names live"; return 1 ;;
    esac

    verdict="$(printf '%s\n' "$out" | grep -v '^__liveness_probed__$' | _container_liveness "$names" "$oneshot")" || rc=$?
    [ -n "$verdict" ] && printf '%s\n' "$verdict" | while read -r l; do log "  liveness: $l"; done
    if [ "$rc" -ne 0 ]; then
        log_error "liveness: declared container(s) are not live on $DEPLOY_HOST — the deploy did not finish (#560)."
        log_error "  'created' = compose created it and never started it; docker ps -a lists it and every digest matches, but it is DEAD."
        return 1
    fi
    log "Declared containers live: $names"
}

# ── Ticket #1872: the container that is RUNNING must carry the source just built ──
# Run 45338386904 deployed green with the old image: the build's push had failed
# unnoticed, the VM pulled the unchanged :latest, the container was healthy, and
# every other check here (healthy, live, ports answering) is blind to which
# image it is. Ask the image: its src-hash label must equal the source hash
# (or, for an unlabelled legacy image, it must not predate the last source
# commit) — the same predicate step_docker's skip path uses (image_stale_reason).
#
# Pure, so the tester can drive it without a VM:
#   $1     repos this service builds (whitespace separated, no tag/digest)
#   $2     source hash the build computed
#   $3     epoch of the last source commit (empty = unknown)
#   stdin  "<container>|<image ref>|<src-hash label>|<image created RFC3339>"
#   stdout "STALE <container> <why>" per finding
#   rc     1 iff any container running one of those repos is stale
_deployed_image_verdict() {
    local repos="$1" want="$2" srcep="$3" bad=0 name ref label created repo why
    while IFS='|' read -r name ref label created; do
        [ -n "$name" ] || continue
        repo="${ref%%@*}"
        case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
        case " $repos " in *" $repo "*) ;; *) continue ;; esac
        case "$label" in "<no value>") label="" ;; esac
        if why="$(image_stale_reason "$label" "$want" "$(image_iso_epoch "$created")" "$srcep")"; then
            echo "STALE ${name#/} $why"; bad=1
        fi
    done
    return "$bad"
}

assert_deployed_image_carries_source() {
    case "${DOCKER_IMAGE:-}" in ""|null) return 0 ;; esac
    command -v image_stale_reason >/dev/null 2>&1 || { log_warn "provenance: image_stale_reason missing (engine drift) — skipping the image check"; return 0; }
    local bj="$SERVICE_DIR/build.json" names full repos want probe out verdict rc=0
    names="$(declared_container_names "$bj")" || return 1
    names="$(printf '%s' "$names" | tr '\n' ' ')"
    [ -n "${names// /}" ] || return 0
    full="${DOCKER_REGISTRY:+$DOCKER_REGISTRY/}$DOCKER_IMAGE"
    repos="$full ${full}-binaries"
    want="$(docker_src_hash "${DOCKER_ARCH:-amd64}")"
    probe='for n in '"$names"'; do
  r=$(docker inspect -f "{{.Config.Image}}|{{.Image}}" "$n" 2>/dev/null) || continue
  m=$(docker image inspect -f "{{index .Config.Labels \"'"$IMAGE_SRC_HASH_LABEL"'\"}}|{{.Created}}" "${r#*|}" 2>/dev/null) || continue
  echo "$n|${r%%|*}|$m"
done
echo __provenance_probed__'
    out="$(printf '%s\n' "$probe" | base64 -w0 | { read -r b; ssh_with_retry "$DEPLOY_HOST" "echo $b | base64 -d | bash" 2>/dev/null; } || true)"
    case "$out" in
        *__provenance_probed__*) ;;
        *) log_error "provenance: $DEPLOY_HOST did not answer the running-image probe — refusing to call the deploy verified"; return 1 ;;
    esac
    verdict="$(printf '%s\n' "$out" | grep -v '^__provenance_probed__$' | _deployed_image_verdict "$repos" "$want" "$(service_src_commit_epoch)")" || rc=$?
    [ -n "$verdict" ] && printf '%s\n' "$verdict" | while read -r l; do log "  provenance: $l"; done
    if [ "$rc" -ne 0 ]; then
        log_error "provenance: a running container is NOT built from the source this ship built (ticket #1872) — the push/pull delivered an older image; failing the ship."
        return 1
    fi
    log "Running image carries the built source ($want)"
}

step_health() {
    CURRENT_STEP="health"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping health"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }

    local timeout="${HEALTH_TIMEOUT:-120}"
    local interval="${HEALTH_INTERVAL:-10}"
    local elapsed=0

    # Compose file resolution — same as step_compose. Without -f the v2 layout
    # (compose at compose/docker-compose.yml, not project root) makes
    # `docker compose ps` find NO compose file → empty listing → false "No
    # containers found". bash -c because the oci-apps login shell is fish.
    local cf="-f $REMOTE_COMPOSE_REL --project-directory ."
    # Same interpolation source as the `compose up` that just ran
    # (step_compose: --env-file .secrets). Without it compose cannot render a
    # `${VAR:?}` that only sops provides, `ps` fails, its stderr is dropped
    # below, and a healthy deploy times out as "No containers listed" (#760:
    # matomo, once its plaintext DB-password fallback was removed). The scp
    # step puts .secrets at $DEPLOY_PATH/.secrets exactly when this exists.
    [ -f "$DIST_DIR/.secrets" ] && cf="--env-file .secrets $cf"

    # #1686: the same gate as step_compose. A stack whose every service sits behind an inactive profile (cloud-run)
    # starts nothing on this VM by design, so there is no container to wait for or to prove alive; waiting would
    # time out as "liveness: MISSING" on every Cloud Run-moved service. Only a project that RESOLVES (config exit 0)
    # to zero services is skipped; a compose file that fails to resolve still goes through the normal wait and fails.
    if _profile_gated; then
        log "Health: every service is profile-gated (served elsewhere, e.g. Cloud Run); no container on this VM to check"
        return 0
    fi

    log "Waiting for containers to be healthy (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        # Get all container statuses from compose project
        local statuses
        statuses=$(ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && docker compose $cf ps --format \"{{.Name}}|{{.State}}|{{.Health}}\" 2>/dev/null'" || true)

        if [ -z "$statuses" ]; then
            # Transient during recreate — keep waiting rather than hard-fail.
            log "No containers listed yet (${elapsed}s) — waiting"
            sleep "$interval"
            elapsed=$((elapsed + interval))
            continue
        fi

        local all_ok=true
        local has_health=false

        while IFS='|' read -r cname cstate chealth; do
            [ -z "$cname" ] && continue

            # Crash loop detection: "restarting" state
            if echo "$cstate" | grep -qi "restarting"; then
                log "FAIL: $cname is crash-looping"
                ssh_with_retry "$DEPLOY_HOST" "docker logs --tail 15 $cname 2>&1" | while read -r l; do log "  $l"; done
                return 1
            fi

            # Container with healthcheck defined
            if [ -n "$chealth" ] && [ "$chealth" != "" ]; then
                has_health=true
                if echo "$chealth" | grep -qi "healthy"; then
                    : # healthy, good
                elif echo "$chealth" | grep -qi "unhealthy"; then
                    log "FAIL: $cname is unhealthy"
                    ssh_with_retry "$DEPLOY_HOST" "docker logs --tail 15 $cname 2>&1" | while read -r l; do log "  $l"; done
                    return 1
                else
                    all_ok=false  # still starting
                fi
            else
                # No healthcheck — just verify running
                if ! echo "$cstate" | grep -qi "running"; then
                    if echo "$cstate" | grep -qi "exited"; then
                        : # one-shot containers (init, migrations) are OK
                    else
                        all_ok=false
                    fi
                fi
            fi
        done <<EOF
$statuses
EOF

        if [ "$all_ok" = "true" ]; then
            log "All containers healthy (${elapsed}s)"
            # "All healthy" above is over what `compose ps` LISTS, and it does
            # not list a created container (#560). Ask about the declared ones.
            assert_declared_containers_live || return 1
            assert_deployed_image_carries_source || return 1
            # Repair before asserting: on "iptables": false hosts the compose up
            # that just ran is itself what broke the published-port mapping, so
            # asserting first would only report a breakage we can fix here.
            _sync_published_port_dnat "$cf"
            _assert_published_ports "$cf" || return 1
            log "Published ports answering"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    # Timeout — show final state
    log "TIMEOUT: Not all containers healthy after ${timeout}s"
    ssh_with_retry "$DEPLOY_HOST" "bash -c 'cd \"$DEPLOY_PATH\" && docker compose $cf ps'" 2>/dev/null | while read -r l; do log "  $l"; done
    # A lone created container leaves `compose ps` empty and lands here; name it.
    assert_declared_containers_live || true
    return 1
}
