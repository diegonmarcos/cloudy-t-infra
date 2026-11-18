# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-nix-homemanager-step-deploy-closure.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: low-memory home-manager delivery (closure transfer, no docker on VM)
# Sourced by cloud-ship-nix-homemanager-engine.sh — do not execute directly
#
# Why (2026-11-18, ship runs 44315729287 and 44362022871, oci-analytics):
# docker-pulling the ~2 GB nixhm-sudo image on a 954 MB VM killed dockerd
# mid-pull on every attempt, and because that VM is the public edge
# (caddy-public), each attempt took the public site down for 30-60 min.
#
# On VMs declared at <= HM_LOWMEM_MAX_MB of RAM (build.json
# vm.resources.ram_mb; default 1024, i.e. ram_gb <= 1) the image is not pulled
# at all. The runner, which already builds the closure for the image, sends
# only the store paths the VM is missing, as a compressed tar stream in
# size-bounded batches, into a staging dir on the VM's /nix filesystem; each
# batch is moved into /nix/store only once it has fully arrived, so a dropped
# stream never leaves a half-copied store path behind. The DB dump and the
# activation path then go exactly where the activation container used to put
# them (/tmp/.hm-nix-db-dump.txt, /tmp/.hm-activation-path), and the native
# Steps 4-5 of the activation script register and activate as before.
# Memory on the VM: one tar + one zstd/gzip decoder, at nice 10 / idle IO.
#
# Edge guard: a VM that declares build.json hm.edge_guard.container is
# never touched while that container (its public Caddy) is unhealthy. It is
# checked before anything runs, before every batch, before activation and
# after it; a failure aborts with a report instead of degrading the edge.
#
# Overrides: build.json hm.transport = "image" | "closure" forces a transport.

HM_LOWMEM_MAX_MB="${HM_LOWMEM_MAX_MB:-1024}"
HM_XFER_BATCH_MB="${HM_XFER_BATCH_MB:-256}"
HM_XFER_TRIES="${HM_XFER_TRIES:-3}"
HM_XFER_SRC_STORE="${HM_XFER_SRC_STORE:-/nix/store}"
HM_XFER_SLEEP="${HM_XFER_SLEEP:-sleep}"
HM_EDGE_TRIES="${HM_EDGE_TRIES:-3}"
HM_EDGE_GAP="${HM_EDGE_GAP:-10}"
HM_XFER_RECV="/tmp/hm-xfer-recv.sh"

# image | closure — declared override first, then the declared VM RAM.
# Unknown RAM keeps the image transport (unchanged behaviour).
hm_transport() {
    local _t _ram
    _t="$(get_config hm.transport)"
    case "$_t" in image|closure) printf '%s\n' "$_t"; return 0 ;; esac
    _ram="$(get_config vm.resources.ram_mb)"
    case "$_ram" in ''|*[!0-9]*) printf 'image\n'; return 0 ;; esac
    if [ "$_ram" -le "$HM_LOWMEM_MAX_MB" ]; then printf 'closure\n'; else printf 'image\n'; fi
}

# ── Edge guard ─────────────────────────────────────────────────────────
# Remote probe: prints "ok" or "FAIL <reason>". Plain bash on stdin (the
# login shell may be fish). Container must be running and not "unhealthy";
# when a host is declared, Caddy must answer HTTPS on 127.0.0.1:443 for it
# (any HTTP status; 000 = no answer).
_hm_edge_probe_script() {  # <container> <host>
    cat <<PROBE_EOF
c='$1'; h='$2'
st=\$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "\$c" 2>/dev/null \\
     || sudo -n docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "\$c" 2>/dev/null) \\
     || { echo "FAIL cannot inspect container \$c (dockerd down?)"; exit 0; }
case "\$st" in
  running\|unhealthy) echo "FAIL \$c is running but unhealthy"; exit 0 ;;
  running\|*) ;;
  *) echo "FAIL \$c is not running (\${st%%|*})"; exit 0 ;;
esac
if [ -n "\$h" ]; then
  code=\$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' --resolve "\$h:443:127.0.0.1" "https://\$h/" 2>/dev/null)
  case "\$code" in ''|000) echo "FAIL \$c does not answer HTTPS for \$h on 127.0.0.1:443"; exit 0 ;; esac
fi
echo ok
PROBE_EOF
}

hm_edge_guard() {  # <phase>
    local _c _h _try=1 _out
    _c="$(get_config hm.edge_guard.container)"
    [ -n "$_c" ] || return 0
    _h="$(get_config hm.edge_guard.host)"
    while :; do
        _out=$(_hm_edge_probe_script "$_c" "$_h" | ssh $SSH_OPTS "$DEPLOY_HOST" "bash -s" 2>/dev/null | tail -1) || true
        [ -n "$_out" ] || _out="FAIL edge probe got no answer from $DEPLOY_HOST"
        if [ "$_out" = ok ]; then
            log "Edge guard ($1): $_c healthy on $DEPLOY_HOST"
            return 0
        fi
        if [ "$_try" -ge "$HM_EDGE_TRIES" ]; then
            log "EDGE GUARD ($1): ${_out#FAIL } — aborting home-manager on $DEPLOY_HOST so the public edge is not degraded further"
            return 1
        fi
        log "Edge guard ($1): ${_out#FAIL } — re-probing in ${HM_EDGE_GAP}s ($_try/$HM_EDGE_TRIES)"
        "$HM_XFER_SLEEP" "$HM_EDGE_GAP"
        _try=$((_try + 1))
    done
}

# ── Receiver (runs on the VM as root) ──────────────────────────────────
#   query            stdin: store basenames; prints those missing or empty
#   recv <id> <codec> stdin: compressed tar of basenames; stage, then move
#   finish <nixbin>  create nix-* command symlinks next to nix
# HM_XFER_ROOT (tests only) prefixes every path.
_hm_xfer_receiver() {
    cat <<'RECV_EOF'
#!/bin/bash
set -euo pipefail
R="${HM_XFER_ROOT:-}"
STORE="$R/nix/store"
renice -n 10 $$ >/dev/null 2>&1 || true
ionice -c3 -p $$ >/dev/null 2>&1 || true
case "$1" in
  query)
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      p="$STORE/$b"
      if [ ! -e "$p" ] && [ ! -L "$p" ]; then echo "$b"
      elif [ -d "$p" ] && [ ! -L "$p" ] && [ -z "$(ls -A "$p" 2>/dev/null)" ]; then echo "$b"
      fi
    done ;;
  recv)
    STG="$R/nix/.hm-xfer-staging/$2"
    rm -rf "$STG"; mkdir -p "$STG" "$STORE"
    case "$3" in zstd) dec="zstd -dc" ;; *) dec="gzip -dc" ;; esac
    $dec | tar -C "$STG" --numeric-owner -xf -
    n=0
    for p in "$STG"/*; do
      [ -e "$p" ] || [ -L "$p" ] || continue
      d="$STORE/$(basename "$p")"
      if [ -d "$d" ] && [ ! -L "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null)" ]; then rm -rf "$d"; fi
      if [ -e "$d" ] || [ -L "$d" ]; then rm -rf "$p"; else mv "$p" "$d"; n=$((n + 1)); fi
    done
    rm -rf "$STG"
    echo "recv ok $n" ;;
  finish)
    nb="$R$2"
    if [ -x "$nb/nix" ]; then
      for c in nix-build nix-instantiate nix-env nix-store nix-channel; do
        [ -e "$nb/$c" ] || ln -sf nix "$nb/$c"
      done
    fi
    echo "finish ok" ;;
  *) echo "usage: query | recv <id> <codec> | finish <nixbin>" >&2; exit 2 ;;
esac
RECV_EOF
}

# ── Runner side ────────────────────────────────────────────────────────
# Sends the closure of $1 (a store path) to the VM; leaves
# /tmp/.hm-nix-db-dump.txt and /tmp/.hm-activation-path for the native
# activation steps. Non-zero on any failure (including the edge guard).
hm_closure_transfer() {  # <closure-store-path>
    local _result="$1" _paths _missing _codec _vmz _batch=() _bmb=0 _bid=0 _sent=0 _nb _mb _b _total
    [ -d "$_result" ] || { log "ERROR: closure $_result not found on runner"; return 1; }

    if ! _hm_xfer_receiver | ssh $SSH_OPTS "$DEPLOY_HOST" "cat > $HM_XFER_RECV"; then
        log "ERROR: could not upload the closure receiver to $DEPLOY_HOST"; return 1
    fi

    _paths=$(nix-store -qR "$_result" | sed 's|.*/||')
    _total=$(printf '%s\n' "$_paths" | grep -c . || true)
    if ! _missing=$(printf '%s\n' "$_paths" | ssh $SSH_OPTS "$DEPLOY_HOST" "sudo bash $HM_XFER_RECV query"); then
        log "ERROR: could not query $DEPLOY_HOST for missing store paths"; return 1
    fi
    _nb=$(printf '%s\n' "$_missing" | grep -c . || true)
    log "Closure: $_total store paths, $_nb missing on $DEPLOY_HOST (delta only is sent)"

    _codec=gzip
    if command -v zstd >/dev/null 2>&1; then
        _vmz=$(ssh $SSH_OPTS "$DEPLOY_HOST" "command -v zstd" 2>/dev/null || true)
        [ -n "$_vmz" ] && _codec=zstd
    fi

    _hm_send_batch() {
        local _try=1 _out _rc
        [ "${#_batch[@]}" -gt 0 ] || return 0
        _bid=$((_bid + 1))
        hm_edge_guard "before batch $_bid" || return 1
        while :; do
            set +e; trap - ERR
            if [ "$_codec" = zstd ]; then
                _out=$(tar -C "$HM_XFER_SRC_STORE" --owner=0 --group=0 --numeric-owner -cf - "${_batch[@]}" \
                    | zstd -3 -q -c | ssh $SSH_OPTS "$DEPLOY_HOST" "sudo bash $HM_XFER_RECV recv b$_bid zstd" 2>&1)
            else
                _out=$(tar -C "$HM_XFER_SRC_STORE" --owner=0 --group=0 --numeric-owner -cf - "${_batch[@]}" \
                    | gzip -1 -c | ssh $SSH_OPTS "$DEPLOY_HOST" "sudo bash $HM_XFER_RECV recv b$_bid gzip" 2>&1)
            fi
            _rc=$?
            declare -F _on_error >/dev/null && trap _on_error ERR; set -e
            if [ "$_rc" -eq 0 ] && printf '%s\n' "$_out" | grep -q '^recv ok'; then
                log "Batch $_bid: ${#_batch[@]} paths, ${_bmb}MB → $(printf '%s\n' "$_out" | grep '^recv ok' | tail -1) ($_codec)"
                _sent=$((_sent + ${#_batch[@]}))
                _batch=(); _bmb=0
                return 0
            fi
            if [ "$_try" -ge "$HM_XFER_TRIES" ]; then
                log "ERROR: batch $_bid failed after $_try tries (rc $_rc): $(printf '%s\n' "$_out" | tail -2 | tr '\n' ' ')"
                return 1
            fi
            log "Batch $_bid try $_try/$HM_XFER_TRIES failed (rc $_rc) — resending in $((15 * _try))s"
            "$HM_XFER_SLEEP" $((15 * _try))
            _try=$((_try + 1))
        done
    }

    while IFS= read -r _b; do
        [ -n "$_b" ] || continue
        _mb=$(du -sm "$HM_XFER_SRC_STORE/$_b" 2>/dev/null | cut -f1) || true; _mb=${_mb:-1}
        _batch+=("$_b"); _bmb=$((_bmb + _mb))
        if [ "$_bmb" -ge "$HM_XFER_BATCH_MB" ]; then _hm_send_batch || return 1; fi
    done <<< "$_missing"
    _hm_send_batch || return 1
    log "Store paths: $_sent copied, $((_total - _nb)) skipped (already on $DEPLOY_HOST)"

    # Same hand-off the activation container produced.
    if ! nix-store --dump-db $(nix-store -qR "$_result") \
        | ssh $SSH_OPTS "$DEPLOY_HOST" "cat > /tmp/.hm-nix-db-dump.txt"; then
        log "ERROR: could not send the nix DB dump to $DEPLOY_HOST"; return 1
    fi
    printf '%s\n' "$_result" | ssh $SSH_OPTS "$DEPLOY_HOST" "cat > /tmp/.hm-activation-path" \
        || { log "ERROR: could not write the activation path on $DEPLOY_HOST"; return 1; }
    ssh $SSH_OPTS "$DEPLOY_HOST" "sudo bash $HM_XFER_RECV finish /nix/var/nix/profiles/default/bin" >/dev/null 2>&1 || true
    log "Closure delivered to $DEPLOY_HOST: $_result"
}
