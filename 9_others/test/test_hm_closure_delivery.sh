#!/usr/bin/env bash
# Test: low-memory home-manager delivery (closure transport) + edge guard.
#
# 2026-11-18, oci-analytics (954 MB, the public edge): docker-pulling the
# ~2 GB nixhm-sudo image killed dockerd mid-pull on every attempt (ship runs
# 44315729287, 44362022871) and took the public site down 30-60 min each
# time. VMs declared at <= 1 GB now get the closure built on the runner and
# only the missing store paths streamed over ssh; no docker on the VM.
#
# Drives the REAL step file with a fake ssh (runs each remote command locally
# against a fake VM root), fake nix-store, docker and curl:
#   1. transport: <=1024 MB → closure, larger/unknown → image, override wins
#   2. empty VM: every closure path arrives byte-identical, hand-off files
#      (DB dump, activation path) and nix-* symlinks are written
#   3. delta: present paths are skipped, an empty (half-copied) path is redone
#   4. batches are size-bounded
#   5. a stream cut mid-batch never leaves a partial store path; the retry
#      completes; a batch that keeps failing fails the transfer
#   6. edge guard: unhealthy Caddy aborts before the first byte / between
#      batches; no declaration = no probe
#   7. wiring: engine skips image push for closure; the closure remote script
#      never pulls or runs a container; oci-analytics declares the guard
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
STEP="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-step-deploy-closure.sh"
ACT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-step-deploy-activate.sh"
ENGINE="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh"
BJ="$REPO_ROOT/b_infra/nixhm-sudo-oci-analytics/build.json"
for f in "$STEP" "$ACT" "$ENGINE" "$BJ"; do [ -f "$f" ] || { echo "::error::$f not found"; exit 1; }; done

W="$(mktemp -d "${TMPDIR:-/tmp}/hm-closure-test.XXXXXX")"
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -15 | sed 's/^/       | /'; FAIL=1; }

# ── fixture store on the "runner": 5 paths, ~1 MB each, read-only like nix ──
SRC="$W/src-store"; mkdir -p "$SRC"
NAMES="aaaa-glibc bbbb-bash cccc-coreutils dddd-hm-files eeee-home-manager-generation"
for n in $NAMES; do
    mkdir -p "$SRC/$n/bin" "$SRC/$n/share"
    head -c 1048576 /dev/urandom > "$SRC/$n/share/blob"
    printf '#!/bin/sh\necho %s\n' "$n" > "$SRC/$n/bin/run"; chmod 555 "$SRC/$n/bin/run"
    ln -s ../share/blob "$SRC/$n/bin/link"
done
chmod -R a-w "$SRC"/*
RESULT="$SRC/eeee-home-manager-generation"

mkdir -p "$W/bin"
# Fake ssh: drop -o options, host; run the command locally with /tmp mapped
# into the fake VM root. FAKE_CUT=<n>: the n-th "recv" gets a truncated
# stream and the connection "drops" (255).
cat > "$W/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift   # host
cmd="$*"; cmd="${cmd// put \/tmp\// put @PUT@}"   # receiver prefixes HM_XFER_ROOT itself
cmd="${cmd//\/tmp\//$VMROOT/tmp/}"; cmd="${cmd//@PUT@//tmp/}"
# Model fs.protected_regular in sticky /tmp: a plain (non-root) redirect onto
# an existing hand-off file owned by someone else is refused.
case "$cmd" in *"cat > $VMROOT/tmp/.hm-"*)
  f="${cmd##*cat > }"; [ -e "$f" ] && [ -e "$STATE/stale-root-owned" ] && { echo "bash: $f: Permission denied" >&2; exit 1; } ;;
esac
case "$cmd" in
  *" recv "*)
    n=$(( $(cat "$STATE/recv" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/recv"
    echo "$cmd" >> "$STATE/recv.log"
    for c in ${FAKE_CUT:-}; do
      if [ "$c" = "$n" ]; then head -c 4000 | HM_XFER_ROOT="$VMROOT" bash -c "$cmd" >/dev/null 2>&1; cat >/dev/null; exit 255; fi
    done ;;
  "bash -s") echo probe >> "$STATE/probes" ;;
esac
HM_XFER_ROOT="$VMROOT" bash -c "$cmd"
EOF
cat > "$W/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-n" ] && shift
exec "$@"
EOF
cat > "$W/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -qR) for n in $NAMES; do echo "$SRC/$n"; done ;;
  --dump-db) shift; echo "DBDUMP $#" ;;
esac
EOF
# Fake docker/curl for the edge probe: state from $STATE/caddy (running|unhealthy|down|deaf)
cat > "$W/bin/docker" <<'EOF'
#!/usr/bin/env bash
s=$(cat "$STATE/caddy" 2>/dev/null || echo running)
[ -f "$STATE/caddy-after" ] && [ "$(cat "$STATE/probes" 2>/dev/null | wc -l)" -ge "$(cat "$STATE/caddy-after")" ] && s=unhealthy
case "$s" in running|deaf) echo "running|healthy" ;; unhealthy) echo "running|unhealthy" ;; down) echo "exited|" ;; esac
EOF
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ "$(cat "$STATE/caddy" 2>/dev/null)" = deaf ] && { printf 000; exit 7; }
printf 200
EOF
cat > "$W/bin/fake-sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$STATE/sleeps"
EOF
chmod +x "$W/bin/"*

# run_xfer <guard: yes|no> → RC, OUT
run_xfer() {
    OUT=$(
        PATH="$W/bin:$PATH" VMROOT="$VMROOT" STATE="$STATE" SRC="$SRC" NAMES="$NAMES" \
        HM_XFER_SRC_STORE="$SRC" HM_XFER_SLEEP="$W/bin/fake-sleep" HM_EDGE_GAP=1 \
        GUARD="$1" BATCH="${BATCH:-256}" TRIES="${TRIES:-3}" \
        bash -c 'set -Eeuo pipefail
            log() { printf "%s\n" "$1"; }
            get_config() { case "$1" in
                hm.edge_guard.container) [ "$GUARD" = yes ] && echo caddy-public || true ;;
                hm.edge_guard.host) [ "$GUARD" = yes ] && echo example.org || true ;;
                *) true ;; esac; }
            SSH_OPTS="-o BatchMode=yes"; DEPLOY_HOST=vm
            HM_XFER_BATCH_MB=$BATCH HM_XFER_TRIES=$TRIES
            . "$1"
            HM_XFER_BATCH_MB=$BATCH; HM_XFER_TRIES=$TRIES
            hm_closure_transfer "$2"' _ "$STEP" "$RESULT" 2>&1
    ); RC=$?
}
fresh() {
    chmod -R u+w "$W/vm" 2>/dev/null; rm -rf "$W/vm" "$W/state"
    VMROOT="$W/vm"; STATE="$W/state"
    mkdir -p "$VMROOT/tmp" "$VMROOT/nix/store" "$VMROOT/nix/var/nix/profiles/default/bin" "$STATE"
    touch "$VMROOT/nix/var/nix/profiles/default/bin/nix"; chmod +x "$VMROOT/nix/var/nix/profiles/default/bin/nix"
}
same_store() {  # every fixture path present and identical on the VM
    for n in $NAMES; do diff -r --no-dereference "$SRC/$n" "$VMROOT/nix/store/$n" >/dev/null 2>&1 || return 1; done
}

# 1. transport selection
tr_of() {  # <ram_mb> [override]
    bash -c 'get_config() { case "$1" in vm.resources.ram_mb) echo "$R" ;; hm.transport) echo "$T" ;; esac; }
             . "$0"; hm_transport' "$STEP" 2>/dev/null
}
t1=$(R=1024 T= tr_of); t2=$(R=954 T= tr_of); t3=$(R=24576 T= tr_of); t4=$(R= T= tr_of); t5=$(R=1024 T=image tr_of); t6=$(R=24576 T=closure tr_of)
export R T 2>/dev/null
[ "$t1/$t2/$t3/$t4/$t5/$t6" = "closure/closure/image/image/image/closure" ] \
    && ok "transport: 1024/954 MB → closure, 24 GB → image, unknown → image, hm.transport override wins" \
    || bad "transport selection: $t1/$t2/$t3/$t4/$t5/$t6"

# 2. empty VM
fresh; run_xfer no
if [ "$RC" -eq 0 ] && same_store && [ "$(cat "$VMROOT/tmp/.hm-activation-path")" = "$RESULT" ] \
   && grep -q '^DBDUMP' "$VMROOT/tmp/.hm-nix-db-dump.txt" \
   && [ -L "$VMROOT/nix/var/nix/profiles/default/bin/nix-build" ] \
   && [ ! -e "$VMROOT/nix/.hm-xfer-staging/b1" ] \
   && printf '%s\n' "$OUT" | grep -q 'Store paths: 5 copied, 0 skipped'; then
    ok "empty VM: all 5 paths byte-identical (modes, symlinks), DB dump + activation path + nix-* links handed off"
else bad "empty VM transfer rc=$RC" "$OUT"; fi
[ ! -e "$STATE/probes" ] && ok "no edge_guard declared → no probe" || bad "probe ran without an edge_guard declaration"

# 2b. stale root-owned hand-off files from the old docker path (run 44405057517)
fresh; touch "$STATE/stale-root-owned"
echo /nix/store/old-generation > "$VMROOT/tmp/.hm-activation-path"; echo OLDDUMP > "$VMROOT/tmp/.hm-nix-db-dump.txt"
chmod 0400 "$VMROOT/tmp/.hm-activation-path" "$VMROOT/tmp/.hm-nix-db-dump.txt"
run_xfer no
mode=$(stat -c %a "$VMROOT/tmp/.hm-activation-path" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$(cat "$VMROOT/tmp/.hm-activation-path")" = "$RESULT" ] \
   && grep -q '^DBDUMP' "$VMROOT/tmp/.hm-nix-db-dump.txt" && [ "$mode" = 644 ] \
   && [ -z "$(ls -A "$VMROOT/tmp" | grep -E '^\.hm-put\.|^hm-xfer-recv')" ]; then
    ok "stale root-owned hand-off files are replaced atomically via sudo (0644, no temp or receiver left)"
else bad "stale hand-off overwrite rc=$RC mode=$mode" "$OUT"; fi

# 3. delta + half-copied path
fresh
cp -a "$SRC/aaaa-glibc" "$SRC/bbbb-bash" "$VMROOT/nix/store/"; mkdir "$VMROOT/nix/store/cccc-coreutils"
run_xfer no
if [ "$RC" -eq 0 ] && same_store && printf '%s\n' "$OUT" | grep -q '5 store paths, 3 missing' \
   && printf '%s\n' "$OUT" | grep -q 'Store paths: 3 copied, 2 skipped' \
   && ! grep -q 'aaaa-glibc\|bbbb-bash' <(cat "$STATE/recv.log"); then
    ok "delta: 2 present paths skipped, empty half-copied path re-sent, only 3 paths streamed"
else bad "delta rc=$RC" "$OUT"; fi

# 4. batching
fresh; BATCH=2 run_xfer no
nb=$(cat "$STATE/recv" 2>/dev/null || echo 0)
[ "$RC" -eq 0 ] && same_store && [ "$nb" -ge 3 ] \
    && ok "batches bounded by HM_XFER_BATCH_MB (2 MB → $nb batches)" || bad "batching rc=$RC batches=$nb" "$OUT"

# 5. dropped stream → no partial path, retry completes
fresh; FAKE_CUT=1 BATCH=2 run_xfer no
[ "$RC" -eq 0 ] && same_store && printf '%s\n' "$OUT" | grep -q 'try 1/3 failed (rc 255)' \
    && [ -z "$(ls -A "$VMROOT/nix/.hm-xfer-staging" 2>/dev/null)" ] \
    && ok "stream cut mid-batch → batch resent, store complete, staging cleaned" \
    || bad "dropped-stream retry rc=$RC" "$OUT"
fresh; FAKE_CUT="1 2 3" TRIES=3 BATCH=256 run_xfer no
partial=0; for n in $NAMES; do [ -e "$VMROOT/nix/store/$n" ] && partial=1; done
[ "$RC" -ne 0 ] && [ "$partial" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'failed after 3 tries' \
    && [ ! -s "$VMROOT/tmp/.hm-activation-path" ] \
    && ok "batch keeps failing → transfer fails, no partial store path, no activation hand-off" \
    || bad "persistent failure rc=$RC partial=$partial" "$OUT"

# 4b. zstd codec path (fake zstd = gzip on both ends, when both have it)
printf '#!/usr/bin/env bash\ncase " $* " in *" -dc "*) exec gzip -dc ;; *) exec gzip -c ;; esac\n' > "$W/bin/zstd"; chmod +x "$W/bin/zstd"
fresh; run_xfer no
[ "$RC" -eq 0 ] && same_store && grep -q ' recv b1 zstd' "$STATE/recv.log" && printf '%s\n' "$OUT" | grep -q '(zstd)' \
    && ok "zstd used when runner and VM both have it" || bad "zstd path rc=$RC" "$OUT"
rm -f "$W/bin/zstd"

# 6. edge guard
fresh; echo running > "$STATE/caddy"; run_xfer yes
[ "$RC" -eq 0 ] && same_store && grep -q probe "$STATE/probes" \
    && ok "healthy edge → probed before each batch, transfer completes" || bad "healthy edge rc=$RC" "$OUT"
for st in unhealthy down deaf; do
    fresh; echo "$st" > "$STATE/caddy"; run_xfer yes
    sent=$(cat "$STATE/recv" 2>/dev/null || echo 0)
    [ "$RC" -ne 0 ] && [ "$sent" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'EDGE GUARD (before batch 1)' \
        && [ "$(grep -c . "$STATE/sleeps")" -eq 2 ] \
        && ok "edge $st → re-probed 3x, aborted before the first byte" || bad "edge $st rc=$RC sent=$sent" "$OUT"
done
fresh; echo running > "$STATE/caddy"; echo 2 > "$STATE/caddy-after"; BATCH=2 run_xfer yes
sent=$(cat "$STATE/recv" 2>/dev/null || echo 0)
[ "$RC" -ne 0 ] && [ "$sent" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'EDGE GUARD (before batch 2)' \
    && [ ! -s "$VMROOT/tmp/.hm-activation-path" ] \
    && ok "edge goes unhealthy mid-transfer → stops after batch 1, never activates" || bad "mid-transfer guard rc=$RC sent=$sent" "$OUT"

# 7. wiring (static)
SHIPC=$(awk '/^        if .*HM_TRANSPORT" = "closure" \]; then/ {f=1; next} f && /elif/ {exit} f' "$ENGINE")
printf '%s\n' "$SHIPC" | grep -q 'step_docker_package' && printf '%s\n' "$SHIPC" | grep -q 'step_compose' \
  && ! printf '%s\n' "$SHIPC" | grep -q 'step_docker_push' \
  && ok "engine: closure ship = build, secrets, docker-package, compose (no image push)" \
  || bad "engine closure ship branch wrong"
GEN=$( (source <(sed -n '/^_build_docker_activate_script()/,/^REMOTE_SCRIPT_EOF/p' "$ACT"; echo '}'); _build_docker_activate_script) )
SKIPPED=$(printf '%s\n' "$GEN" | awk '/^if \[ "\$HM_TRANSPORT" = closure \]; then/ {f=1} /^fi  # HM_TRANSPORT != closure/ {f=0} f')
printf '%s\n' "$SKIPPED" | grep -q '^hm_pull_with_retry || exit 1' && printf '%s\n' "$SKIPPED" | grep -q 'docker run --rm' \
  && printf '%s\n' "$GEN" | sed -n '/^fi  # HM_TRANSPORT != closure/,$p' | grep -q 'nix-store --load-db' \
  && printf '%s\n' "$GEN" | sed 's/@@TRANSPORT@@/closure/' | bash -n \
  && ok "remote script: closure transport skips pull + activation container, keeps native register/activate" \
  || bad "remote script closure gating"
grep -q 's|@@TRANSPORT@@|$HM_TRANSPORT|g' "$ACT" && grep -q 'hm_edge_guard "pre-flight"' "$ACT" \
  && grep -q 'hm_edge_guard "before activation"' "$ACT" && grep -q 'hm_edge_guard "after activation"' "$ACT" \
  && ok "step_compose: transport substituted; edge guard pre-flight, before and after activation" \
  || bad "step_compose wiring"
[ "$(jq -r '.hm.edge_guard.container' "$BJ")" = caddy-public ] && [ "$(jq -r '.vm.resources.ram_mb' "$BJ")" -le 1024 ] \
  && ok "oci-analytics: declared ≤1 GB (→ closure) and edge_guard caddy-public" || bad "oci-analytics build.json declarations"

[ "$FAIL" -eq 0 ] && echo "PASS: hm closure delivery" || echo "FAIL: hm closure delivery"
exit "$FAIL"
