#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_image_provenance.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# test_ship_image_provenance.sh — a Ship must not call an image "pushed" or
# "deployed" when the registry/VM image does not carry the source it built.
#
# Ticket #1872, run 45338386904 (cloudy-t-infra Ship, green): ghcr.io was
# unreachable from the builder, the classic-build fallback's `docker push`
# calls all failed ("unauthenticated"), and step_docker logged "Pushed", wrote
# .docker-src-hash (rsynced to the VM) and the deploy recreated the container
# on the unchanged :latest. step_docker runs under `|| return 1`, which turns
# `set -e` off for its whole body, so only an EXPLICIT status check can fail it.
#
# Runs against stubs only: no daemon, no registry, no VM.
set -u
_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done
ROOT="$_d"
BUILD="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-build-docker.sh"
HEALTH="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-health.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── 1) the classic-fallback push block, EXECUTED against a stub docker ──────
# Extract from the first push of the primary tag to the digest capture and run it
# inside a function; a push that fails must make the function return non-zero
# BEFORE reaching the code after the block ("Pushed" + hash marker).
awk '/docker push "\$FULL_IMAGE:\$_ptag"/ && !s {s=1} s {print} s && /_PUSHED_DIGEST="\$\(grep -oE/ {exit}' "$BUILD" > "$T/block.sh"
ck "classic push block extracted" "$([ -s "$T/block.sh" ] && echo yes || echo no)" "yes"
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'STUB'
#!/bin/sh
# push of the ref in $FAIL_REF (or any ref when FAIL_REF=all) fails like ghcr did
if [ "$1" = push ]; then
  if [ "${FAIL_REF:-}" = all ] || [ "${FAIL_REF:-}" = "$2" ]; then echo "error from registry: unauthenticated: User cannot be authenticated with the token provided." >&2; exit 1; fi
  echo "latest: digest: sha256:$(printf '%064d' 7) size: 1"; exit 0
fi
exit 0
STUB
chmod +x "$T/bin/docker"
run_block() { # $1 = FAIL_REF
  ( PATH="$T/bin:$PATH"; export FAIL_REF="$1"
    log_error() { echo "ERR $*" >&2; }
    FULL_IMAGE=r/x BINARIES_IMAGE=r/x-binaries _ptag=latest _btag=latest GIT_SHA12=abc123abc123 _PUSHLOG="$(mktemp)"
    f() { eval "$(cat "$T/block.sh")"; echo REACHED_PUSHED; }
    f 2>&1 ) | grep -x REACHED_PUSHED || true
}
ck "all pushes ok            -> build continues"            "$(run_block none)" "REACHED_PUSHED"
ck "every push rejected      -> build step FAILS"             "$(run_block all)"  ""
ck "only primary push fails  -> build step FAILS"             "$(run_block r/x:latest)" ""
ck "only -binaries push fails (the image the VM pulls) -> FAILS" "$(run_block r/x-binaries:latest)" ""
ck "only sha12 alias push fails -> FAILS"                     "$(run_block r/x-binaries:abc123abc123)" ""

# ── 2) provenance predicate, EXECUTED ────────────────────────────────────────
[ -f "$BUILD" ] && ( . "$BUILD" ) >/dev/null 2>&1
awk '/^IMAGE_SRC_HASH_LABEL=/{p=1} p&&/^step_docker\(\) \{/{exit} p{print}' "$BUILD" > "$T/prov.sh"
awk '/^_deployed_image_verdict\(\) \{/,/^}$/' "$HEALTH" > "$T/verdict.sh"
ck "provenance helpers present in the build step" "$(grep -c '^image_stale_reason()' "$T/prov.sh")" "1"
ck "deployed-image verdict present in the health step" "$(grep -c '^_deployed_image_verdict()' "$T/verdict.sh")" "1"
stale() { ( . "$T/prov.sh"; image_stale_reason "$@" >/dev/null && echo stale || echo fresh ); }
ck "label == built hash -> fresh"                      "$(stale h1-amd64 h1-amd64 100 9999)" "fresh"
ck "label != built hash -> stale"                      "$(stale h0-amd64 h1-amd64 100 9999)" "stale"
ck "legacy image older than last src commit -> stale (the #1872 shape)" "$(stale '' h1-amd64 1000 2000)" "stale"
ck "legacy image newer than last src commit -> fresh"  "$(stale '' h1-amd64 3000 2000)" "fresh"
ck "legacy image, clock skew inside 60s -> fresh"      "$(stale '' h1-amd64 1950 2000)" "fresh"
ck "commit time unknown (shallow clone) -> fresh, never a false alarm" "$(stale '' h1-amd64 1000 '')" "fresh"
ck "created unparsable -> fresh"                       "$(stale '' h1-amd64 '' 2000)" "fresh"

verdict() { # stdin = container lines; $1 = want ; $2 = src epoch
  ( . "$T/prov.sh"; . "$T/verdict.sh"; log() { :; }
    image_iso_epoch() { date -u -d "$1" +%s 2>/dev/null; }
    _deployed_image_verdict "ghcr.io/o/x ghcr.io/o/x-binaries" "$1" "$2"; echo "rc=$?" ) | tr '\n' ' '
}
OLD='x|ghcr.io/o/x-binaries:latest||2026-11-12T10:00:00Z'
NEW='x|ghcr.io/o/x-binaries:latest|h1-amd64|2026-11-24T06:30:00Z'
SRC=$(date -u -d 2026-11-24T06:08:00Z +%s)
ck "running unlabelled 11-12 image vs 11-24 source -> STALE, rc=1" "$(printf '%s\n' "$OLD" | verdict h1-amd64 "$SRC")" "STALE x unlabelled image created at epoch $(date -u -d 2026-11-12T10:00:00Z +%s) predates the last source commit (epoch $SRC) rc=1 "
ck "running image labelled with the built hash -> rc=0"           "$(printf '%s\n' "$NEW" | verdict h1-amd64 "$SRC")" "rc=0 "
ck "running image labelled with another hash -> STALE"            "$(printf '%s\n' "$NEW" | verdict h2-amd64 "$SRC" | cut -c1-8)" "STALE x "
ck "a sidecar from another repo is not judged"                    "$(printf 'side|docker.io/library/redis:7||2020-01-01T00:00:00Z\n' | verdict h1-amd64 "$SRC")" "rc=0 "
ck "digest-pinned ref of the built repo is judged"                "$(printf 'x|ghcr.io/o/x-binaries@sha256:aa||2020-01-01T00:00:00Z\n' | verdict h1-amd64 "$SRC" | cut -c1-8)" "STALE x "

# ── 3) wiring: every build path stamps the labels; skip path + deploy use them ──
ck "buildx path stamps labels"            "$(grep -c '"${LABEL_ARGS_ARR\[@\]}" \\' "$BUILD")" "2"
ck "remote ssh build stamps labels"       "$(grep -c '\$BUILD_ARGS_STR \$LABEL_ARGS_STR \.' "$BUILD")" "1"
ck "skip path verifies the registry image" "$(grep -c 'image_stale_reason "\$_chk_label"' "$BUILD")" "1"
ck "step_docker hash is the shared function" "$(grep -c 'LOCAL_HASH="\$(docker_src_hash "\$ARCH")"' "$BUILD")" "1"
ck "health step runs the running-image guard" "$(grep -c '^            assert_deployed_image_carries_source || return 1' "$HEALTH")" "1"
ck "buildx pipeline cannot hide a failure behind pipefail-off" "$(grep -c 'if ( set -o pipefail; docker buildx build' "$BUILD")" "1"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
