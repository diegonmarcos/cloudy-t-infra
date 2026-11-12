# Step: Deploy this run's freshly rendered dist/ to VM via rsync + manifest cleanup
# Sourced by cloud-ship-container-engine.sh — do not execute directly

# ── Transport-error CLASSIFICATION for the secrets scp path ───────────
# ssh_run_detached and rsync_with_retry already know that exit 255 (ssh) and
# 12/30 (rsync) mean the LINK dropped rather than the payload being wrong, and
# they say so out loud ("upload dropped (255) — retry N/5"). The scp calls in
# step_deploy below did not: they printed a bare ".secrets.d scp failed" and
# let the ship die with an anonymous `exit 255`, indistinguishable from a real
# failure of the shipped code. Run 33969346081 went red for exactly that
# reason, on code that was correct.
#
# The fix is NAMING, not retrying. A dropped WireGuard link is a fact to
# report; stacking another retry layer under the one ssh_with_retry already
# provides would only make a red ship arrive later, not more correct. So a
# transport-class failure gets its own log prefix (TRANSPORT:) and its own
# exit code, and everything else keeps exit 1.
SHIP_EXIT_TRANSPORT=75   # EX_TEMPFAIL — "the link faulted, re-run the ship"

# scp one secrets artifact, classifying the failure. Both outcomes are FATAL:
# a warning here was itself a silent skip of the same family this engine was
# audited for — without .secrets the container comes up with no credentials,
# and that is not a green deploy.
#   $1 = human label, rest = scp arguments
scp_secret() {
    _ss_label="$1"; shift
    if _ss_err=$(scp $SSH_OPTS "$@" 2>&1); then
        log "Deployed $_ss_label via scp"
        return 0
    else
        _ss_ec=$?
    fi
    # Stderr used to go to /dev/null, which is why a failed upload left nothing
    # to read but the word "failed".
    [ -n "$_ss_err" ] && printf '%s\n' "$_ss_err" | sed 's|^|    scp: |'
    case "$_ss_ec" in
        255|12|30)
            log_error "TRANSPORT: $_ss_label scp dropped (exit $_ss_ec) — ssh link fault to $DEPLOY_HOST, NOT a fault in the shipped code; re-run the ship"
            return "$SHIP_EXIT_TRANSPORT"
            ;;
    esac
    log_error "$_ss_label scp failed (exit $_ss_ec) — secrets are NOT on $DEPLOY_HOST"
    return 1
}

# ── .secrets.d: update IN PLACE, never replace the directory (#1683) ──────
#
# Containers bind-mount ./.secrets.d at /run/secrets. A bind mount pins the
# directory INODE it saw at container start. The previous deploy did
# `rm -rf $DEPLOY_PATH/.secrets.d` then `scp -r` a fresh one: a new inode on
# the host, while every running container kept the old, now-empty one. On
# 2026-11-12 14:13 google-workspace-mcp lost /run/secrets/GOOGLE_SERVICE_ACCOUNT_KEY
# that way and every Drive call failed until the container was restarted.
#
# Now: scp the rendered tree to a sibling STAGING dir, then on the host copy
# each changed key to a temp file in the target directory and rename(2) it
# over the target key (atomic, same filesystem). Keys dropped from sops are
# removed as files; the directory itself is never removed or replaced, so its
# inode survives and a running container sees the new content at once. The
# stage dir lands at exactly one depth (scp into a path that does not exist
# yet), which also keeps the old `.secrets.d/.secrets.d` nesting bug fixed.
#
# Any changed, added or removed key sets SECRETS_CHANGED/CONFIG_CHANGED so
# step_compose force-recreates the service: an app that read its secret once
# at start-up must be restarted to use the new value.
#
# The sync is a POSIX sh script (secrets_d_sync_script) fed to the host on
# stdin; its last line must be SECRETS_D_SYNC_OK, so an ssh retry that re-ran
# with an already-drained stdin can never pass as a silent success.
SECRETS_D_STAGE_SUFFIX=".incoming"

secrets_d_sync_script() {
    cat <<'EOF_SECRETS_D_SYNC'
set -eu
stage="$1"; target="$2"
[ -d "$stage" ] || { echo "SECRETS_D_SYNC_ERR staging dir missing"; exit 1; }
[ -L "$target" ] && { echo "SECRETS_D_SYNC_ERR target is a symlink"; exit 1; }
[ -d "$target" ] || mkdir "$target"
chmod "$(stat -c %a "$stage")" "$target"
changed=0
for f in "$stage"/* "$stage"/.[!.]*; do
    [ -f "$f" ] || continue
    k="${f##*/}"; t="$target/$k"
    if [ -f "$t" ] && [ ! -L "$t" ] && cmp -s "$f" "$t"; then
        [ "$(stat -c %a "$f")" = "$(stat -c %a "$t")" ] || chmod "$(stat -c %a "$f")" "$t"
        continue
    fi
    tmp="$target/.$k.tmp.$$"
    cp -p "$f" "$tmp"
    mv -f "$tmp" "$t"
    changed=$((changed + 1)); echo "SECRETS_D_SYNC_CHANGED $k"
done
for t in "$target"/* "$target"/.[!.]*; do
    [ -e "$t" ] || [ -L "$t" ] || continue
    k="${t##*/}"
    [ -f "$stage/$k" ] && continue
    rm -rf -- "$t"
    changed=$((changed + 1)); echo "SECRETS_D_SYNC_REMOVED $k"
done
rm -rf -- "$stage"
echo "SECRETS_D_SYNC_COUNT $changed"
echo "SECRETS_D_SYNC_OK"
EOF_SECRETS_D_SYNC
}

deploy_secrets_d() {
    [ -z "$DEPLOY_PATH" ] && { log_error ".secrets.d: refusing to sync into an empty DEPLOY_PATH"; return 1; }
    _sd_target="$DEPLOY_PATH/.secrets.d"
    _sd_stage="$_sd_target$SECRETS_D_STAGE_SUFFIX"
    # Only the STAGING dir is ever removed; the live directory never is.
    ssh_with_retry "$DEPLOY_HOST" "rm -rf '$_sd_stage'" >/dev/null 2>&1 \
        || { log_error "could not clear staging $DEPLOY_HOST:$_sd_stage"; return 1; }
    scp_secret ".secrets.d (staging)" -r "$DIST_DIR/.secrets.d" "$DEPLOY_HOST:$_sd_stage" || return $?
    _sd_out=$(secrets_d_sync_script | ssh_with_retry "$DEPLOY_HOST" "sh -s -- '$_sd_stage' '$_sd_target'" 2>&1) || true
    case "$_sd_out" in
        *SECRETS_D_SYNC_OK*) ;;
        *)  printf '%s\n' "$_sd_out" | grep '^SECRETS_D_SYNC_' | sed 's|^|    |'
            log_error ".secrets.d in-place sync did not complete on $DEPLOY_HOST — secrets NOT updated"
            return 1 ;;
    esac
    _sd_n=$(printf '%s\n' "$_sd_out" | sed -n 's/^SECRETS_D_SYNC_COUNT //p')
    if [ "${_sd_n:-0}" -gt 0 ]; then
        printf '%s\n' "$_sd_out" | grep -E '^SECRETS_D_SYNC_(CHANGED|REMOVED) ' | sed 's|^SECRETS_D_SYNC_|    .secrets.d |'
        SECRETS_CHANGED=true; CONFIG_CHANGED=true
        log ".secrets.d updated in place ($_sd_n key(s) changed) — the service will be recreated"
    else
        log ".secrets.d unchanged (in place, directory kept)"
    fi
    return 0
}

# Filter protected paths out of a deploy-manifest stream (stdin -> stdout).
#
# The manifest reconciler in step_deploy deletes everything the previous deploy
# left on the VM that this deploy does not re-ship. That rule is correct for
# stale code and catastrophic for the files that are NOT build output:
# .secrets / .secrets.json / .secrets.d are scp'd by a separate step and are
# absent from dist/ whenever the secrets step failed, and .dist-hash /
# .deploy-manifest are the deploy's own bookkeeping. One failed decrypt was
# therefore enough to strip a running container of its credentials on the very
# next ship — the reconciler saw them "missing from dist/" and rm -f'd them.
#
# Protection is declared per top-level dist entry, so ".secrets.d" covers
# "./.secrets.d/<KEY>" without any globbing or regex escaping of the paths.
drop_protected() {
    [ -z "$PROTECT_PATHS" ] && { cat; return 0; }
    awk -v protect="$PROTECT_PATHS" '
        BEGIN { n = split(protect, list, "\n"); for (i = 1; i <= n; i++) protected[list[i]] = 1 }
        { top = $0; sub(/^\.\//, "", top); sub(/\/.*$/, "", top); if (!(top in protected)) print }
    '
}

# ── deploy.host_sync: vault files for bind mounts OUTSIDE remote_path ──────
#
# build.json#deploy.host_sync.<name> = { vault_dir, host_dir, files[] }.
# The listed files are copied from the ship's own vault checkout (fetch-vault
# / ship.yml put it at ~/git/cloud-vault) to host_dir on the VM, the path the
# service's compose.nix bind-mounts from the SAME entry — one declaration.
#
# First user: c3-public-api's profile bundle (#586). Its compose bind-mounted
# /home/ubuntu/git/cloud-vault/configs, nothing in the pipeline ever wrote a
# file there, docker pre-created the missing source as an empty root-owned
# stub, and Profile ▸ Connect has served an empty bundle dir since #566 while
# every ship went green. Only the listed files travel — the vault itself never
# lands on a public-edge VM. A missing source is FATAL: a silent skip is
# exactly the empty mount this step exists to end.
host_sync_entries() {   # one TSV line per entry: name  vault_dir  host_dir  "file file"
    jq -r '.deploy.host_sync // {} | to_entries[] | select(.key | startswith("_") | not)
           | [.key, .value.vault_dir, .value.host_dir, (.value.files | join(" "))] | @tsv' "$CONFIG"
}

step_host_sync() {
    _hs_vault="${VAULT_DIR:-$HOME/git/cloud-vault}"
    _hs_entries="$(host_sync_entries)" \
        || { log_error "host_sync: deploy.host_sync in $CONFIG is malformed — each entry needs vault_dir, host_dir and files[]"; return 1; }
    [ -z "$_hs_entries" ] && return 0
    # heredoc, not a pipe: `return` must leave THIS function, not a subshell
    while IFS="$(printf '\t')" read -r _hs_name _hs_from _hs_to _hs_files; do
        [ -n "$_hs_name" ] || continue
        [ -n "$_hs_to" ] && [ -n "$_hs_files" ] \
            || { log_error "host_sync $_hs_name: host_dir and files[] are both required"; return 1; }
        _hs_src="$_hs_vault/$_hs_from"
        [ -d "$_hs_src" ] \
            || { log_error "host_sync $_hs_name: $_hs_src is not on this runner (no vault checkout?) — $DEPLOY_HOST:$_hs_to would stay empty"; return 1; }
        _hs_paths=""
        for _hs_f in $_hs_files; do
            [ -f "$_hs_src/$_hs_f" ] || { log_error "host_sync $_hs_name: $_hs_src/$_hs_f is missing"; return 1; }
            _hs_paths="$_hs_paths $_hs_src/$_hs_f"
        done
        # docker owns a pre-created bind source as root; take it so the ssh
        # user's rsync can write, then hand the files over read-only.
        ssh_with_retry "$DEPLOY_HOST" "sudo mkdir -p '$_hs_to' && sudo chown \$(whoami):\$(whoami) '$_hs_to'" \
            || { log_error "host_sync $_hs_name: could not prepare $DEPLOY_HOST:$_hs_to"; return 1; }
        # shellcheck disable=SC2086  # _hs_paths is a deliberate word list
        rsync_with_retry -az --checksum --chmod=F444 $_hs_paths "$DEPLOY_HOST:$_hs_to/" \
            || { log_error "host_sync $_hs_name: rsync to $DEPLOY_HOST:$_hs_to failed"; return 1; }
        log "host_sync $_hs_name: $_hs_files → $DEPLOY_HOST:$_hs_to (from $_hs_src)"
    done <<EOF_HOST_SYNC
$_hs_entries
EOF_HOST_SYNC
    return 0
}

step_deploy() {
    CURRENT_STEP="deploy"
    [ -z "$DEPLOY_HOST" ] && { log "No deploy.host -- skipping deploy"; return 0; }
    [ -z "$DEPLOY_PATH" ] && { log "ERROR: deploy.remote_path not set in build.json"; return 1; }
    [ ! -d "$DIST_DIR" ] && { log "No dist/ -- run build first"; return 1; }

    # ── Deploy source: ONLY the dist/ this run just rendered (#862) ──
    # This step used to `docker run` ghcr.io/<owner>/<svc>-configs:latest into
    # $DEPLOY_PATH first and rsync dist/ afterwards. `:latest` is a mutable tag
    # owned by whichever run pushed last (or by none, when configs-push failed —
    # it is best-effort), so the VM briefly — or, if anything compose-up'd in
    # between, durably — held a config this run never built. On 2026-10-04
    # gcp-proxy's redis compose was rewritten at 12:25:06Z from the 11:06
    # redis-configs image, two minutes before the run's own nix build (12:27Z).
    # step_build_nix wipes and re-renders $DIST_DIR in this same process, so it
    # is the one artifact that is provably this run's: deploy that, only that.
    # Deploying is the inverse of retiring: clear the marker `build.sh retire`
    # left behind, or vm-images-pull-up.sh keeps skipping this service and the
    # deploy silently does nothing on the host.
    ssh_with_retry "$DEPLOY_HOST" "rm -f $DEPLOY_PATH/.retired" >/dev/null 2>&1 || true
    # Earlier configs-image extractions ran as root inside the container and
    # may have left root-owned files that the ssh user's rsync cannot update.
    ssh_with_retry "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown -R \$(whoami):\$(whoami) $DEPLOY_PATH" >/dev/null 2>&1 \
        || log_warn "could not normalise ownership of $DEPLOY_PATH — a root-owned leftover will fail rsync"

    # Secrets: ALWAYS via scp (never in GHCR image).
    # See scp_secret above for why these are classified and fatal.
    if [ -f "$DIST_DIR/.secrets" ]; then
        scp_secret ".secrets" "$DIST_DIR/.secrets" "$DEPLOY_HOST:$DEPLOY_PATH/.secrets" || return $?
    fi
    if [ -d "$DIST_DIR/.secrets.d" ]; then
        # In place, never by replacing the directory (#1683). See
        # deploy_secrets_d above for why and how.
        deploy_secrets_d || return $?
    fi

    # Vault-sourced files for bind mounts outside DEPLOY_PATH (see step_host_sync).
    step_host_sync || return $?

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"

    # Include binary + runtime Dockerfile for local image build on VM
    BINARY_PATH="/tmp/${SERVICE_NAME}-binary"
    RUNTIME_DF="$SRC_DIR/Dockerfile.runtime"
    if [ -f "$BINARY_PATH" ] && [ -f "$RUNTIME_DF" ]; then
        cp "$BINARY_PATH" "$DIST_DIR/$DOCKER_BINARY_NAME"
        cp "$RUNTIME_DF" "$DIST_DIR/Dockerfile.runtime"
        log "Included binary + Dockerfile.runtime in deploy payload"
    fi

    log "Deploying dist/ -> $DEPLOY_HOST:$DEPLOY_PATH"

    # Ensure remote dir exists
    ssh_with_retry "$DEPLOY_HOST" "sudo mkdir -p $DEPLOY_PATH && sudo chown \$(whoami):\$(whoami) $DEPLOY_PATH"

    MANIFEST_FILE=".deploy-manifest"

    # 0. Paths the reconciler must never delete. build.json deploy.manifest_protect
    #    wins; the fleet default lives in a_solutions/_shared/compose-defaults.json
    #    under the same deploy.manifest_protect key, so the identical reader works
    #    on either file. Read in a command substitution so the CONFIG override
    #    stays inside that subshell.
    PROTECT_PATHS="$(get_config_array deploy.manifest_protect)"
    if [ -z "$PROTECT_PATHS" ]; then
        PROTECT_PATHS="$(CONFIG="$SERVICE_DIR/../_shared/compose-defaults.json"; get_config_array deploy.manifest_protect)"
    fi
    [ -n "$PROTECT_PATHS" ] && log "  manifest protect: $(echo "$PROTECT_PATHS" | tr '\n' ' ')"

    # 1. Build list of files we're about to deploy (relative paths).
    #    Protected paths are excluded here and from the stale list below, so the
    #    two sides of the comparison agree and neither can resurrect a delete.
    NEW_MANIFEST=$(cd "$DIST_DIR" && find . -type f | sort | drop_protected)

    # 2. Read old manifest from remote (may be empty on first deploy)
    OLD_MANIFEST=$(ssh_with_retry "$DEPLOY_HOST" "cat '$DEPLOY_PATH/$MANIFEST_FILE' 2>/dev/null" || true)

    # 3. Build rsync exclude flags from build.json array
    RSYNC_EXCLUDES=""
    EXCLUDES="$(get_config_array deploy.excludes)"
    if [ -n "$EXCLUDES" ]; then
        RSYNC_EXCLUDES=$(echo "$EXCLUDES" | while IFS= read -r ex; do
            [ -n "$ex" ] && printf " --exclude '%s'" "$ex"
        done)
    fi

    # 4. Additive rsync (NO --delete) — adds/updates files, never removes
    if command -v rsync >/dev/null 2>&1; then
        eval rsync_with_retry -az --compress-level=9 --checksum --partial --inplace --exclude='docs/' $RSYNC_EXCLUDES '"$DIST_DIR/"' '"$DEPLOY_HOST:$DEPLOY_PATH/"'
    elif command -v rclone >/dev/null 2>&1; then
        rclone copy "$DIST_DIR/" ":sftp:$DEPLOY_PATH/" \
            --sftp-host="$(ssh -G "$DEPLOY_HOST" | grep '^hostname ' | awk '{print $2}')" \
            --sftp-user="$(ssh -G "$DEPLOY_HOST" | grep '^user ' | awk '{print $2}')" \
            --sftp-key-file="$(ssh -G "$DEPLOY_HOST" | grep '^identityfile ' | head -1 | awk '{print $2}')" \
            --transfers=4
    else
        log "ERROR: No rsync or rclone available"
        return 1
    fi

    # 5. Clean stale files: in old manifest but not in new
    if [ -n "$OLD_MANIFEST" ]; then
        STALE_COUNT=0
        # Write manifests to temp files for reliable comparison (avoids subshell issues)
        OLD_TMP=$(mktemp)
        NEW_TMP=$(mktemp)
        echo "$OLD_MANIFEST" | sort > "$OLD_TMP"
        echo "$NEW_MANIFEST" | sort > "$NEW_TMP"
        # comm -23: lines only in old (stale files)
        STALE_FILES=$(comm -23 "$OLD_TMP" "$NEW_TMP" | drop_protected)
        rm -f "$OLD_TMP" "$NEW_TMP"
        if [ -n "$STALE_FILES" ]; then
            echo "$STALE_FILES" | while IFS= read -r f; do
                [ -z "$f" ] && continue
                log "  rm stale: $f"
                ssh_with_retry "$DEPLOY_HOST" "rm -f '$DEPLOY_PATH/$f'"
                STALE_COUNT=$((STALE_COUNT + 1))
            done
            log "Cleaned stale files from previous deploy"
        fi
    fi

    # 6. Save new manifest to remote
    echo "$NEW_MANIFEST" | ssh_with_retry "$DEPLOY_HOST" "cat > '$DEPLOY_PATH/$MANIFEST_FILE'"

    log "Deployed to $DEPLOY_HOST:$DEPLOY_PATH"
}
