#!/usr/bin/env bash
# Test: hm-docker image pull retries transient registry errors with bounded
# exponential backoff and fails fast on permanent ones.
#
# Incident 2026-11-18, "Ship → home-manager" on oci-analytics only:
#   run 44259524045  docker pull → "Client.Timeout exceeded while awaiting headers"
#   run 44294316188  docker pull → "unexpected EOF" mid-layer
# Both aborted the ship ("FAILED (exit 1): Docker HM activate on oci-analytics")
# on a single bad network moment.
#
# Extracts the hm-pull-retry block from the remote activation script and
# drives it with a fake `docker` on PATH:
#   1. transient error twice, then success → passes on attempt 3, waits 15 30
#   2. permanent error (unauthorized / manifest unknown) → fails at attempt 1
#   3. transient every time → fails after 5 attempts, waits 15 30 60 120
#   4. advertised digest is verified against `docker image inspect`
#   5. pull "succeeds" but image does not resolve → retried
#   6. the script calls the retry wrapper (no bare `docker pull` left)
set -u

REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
SCRIPT="$REPO_ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-step-deploy-activate.sh"
[ -f "$SCRIPT" ] || { echo "::error::$SCRIPT not found"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hm-pull-retry-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sed -n '/^# >>> hm-pull-retry/,/^# <<< hm-pull-retry/p' "$SCRIPT" > "$WORK/retry.sh"
[ -s "$WORK/retry.sh" ] || { echo "::error::hm-pull-retry block not found in $SCRIPT"; exit 1; }

DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"
OTHER="sha256:$(printf 'b%.0s' $(seq 64))"

mkdir -p "$WORK/bin"
# Fake docker. Behaviour per pull call is read from $FAKE_PLAN (one line per
# call: ok | timeout | eof | reset | 503 | 429 | unauth | manifest); the last
# line repeats. `image inspect` answers from $FAKE_INSPECT (digest|none|fail).
cat > "$WORK/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pull "*)
    n=$(( $(cat "$FAKE_STATE/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_STATE/count"
    step=$(sed -n "${n}p" "$FAKE_PLAN"); [ -n "$step" ] || step=$(tail -1 "$FAKE_PLAN")
    case "$step" in
      ok)       echo "latest: Pulling from x"; echo "Download complete"; echo "Digest: $FAKE_DIGEST"; echo "Status: Downloaded newer image for $2"; exit 0 ;;
      timeout)  echo 'Error response from daemon: Get "https://ghcr.io/v2/": net/http: request canceled while waiting for connection (Client.Timeout exceeded while awaiting headers)' >&2; exit 1 ;;
      eof)      echo "Download complete"; echo "unexpected EOF" >&2; exit 1 ;;
      reset)    echo "read tcp 10.0.0.1:1->1.2.3.4:443: read: connection reset by peer" >&2; exit 1 ;;
      503)      echo "Error response from daemon: received unexpected HTTP status: 503 Service Unavailable" >&2; exit 1 ;;
      429)      echo "Error response from daemon: toomanyrequests: retry later" >&2; exit 1 ;;
      unauth)   echo 'Error response from daemon: Head "https://ghcr.io/v2/x/manifests/latest": unauthorized' >&2; exit 1 ;;
      manifest) echo "Error response from daemon: manifest unknown" >&2; exit 1 ;;
    esac ;;
  "image inspect")
    case "${FAKE_INSPECT:-digest}" in
      digest) echo "ghcr.io/diegonmarcos/nixhm-sudo-oci-analytics@$FAKE_INSPECT_DIGEST"; exit 0 ;;
      none)   exit 0 ;;
      fail)   echo "Error: No such image" >&2; exit 1 ;;
      flip)   # fails the first time, resolves after
              if [ -e "$FAKE_STATE/inspected" ]; then echo "x@$FAKE_INSPECT_DIGEST"; exit 0; fi
              touch "$FAKE_STATE/inspected"; exit 1 ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/docker"
# Fake sleep records requested waits instead of sleeping.
cat > "$WORK/bin/fake-sleep" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_STATE/sleeps"
FAKE
chmod +x "$WORK/bin/fake-sleep"

FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; FAIL=1; }

# run_case PLAN INSPECT [INSPECT_DIGEST] → sets RC, OUT, COUNT, SLEEPS
run_case() {
    local plan="$1" inspect="$2" idig="${3:-$DIGEST}"
    rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    printf '%s\n' $plan > "$WORK/plan"
    OUT=$(
        PATH="$WORK/bin:$PATH" FAKE_PLAN="$WORK/plan" FAKE_STATE="$WORK/state" \
        FAKE_DIGEST="$DIGEST" FAKE_INSPECT="$inspect" FAKE_INSPECT_DIGEST="$idig" \
        HM_PULL_SLEEP="$WORK/bin/fake-sleep" HM_PULL_OUT="$WORK/state/pull-out" \
        bash -c 'set -euo pipefail
                 USE_CLI=true IMAGE=ghcr.io/diegonmarcos/nixhm-sudo-oci-analytics TAG=latest
                 FULL_IMAGE="$IMAGE:$TAG" DOCKER_SOCK=/nonexistent
                 . "$1"; hm_pull_with_retry' _ "$WORK/retry.sh" 2>&1
    ); RC=$?
    COUNT=$(cat "$WORK/state/count" 2>/dev/null || echo 0)
    SLEEPS=$( { tr '\n' ' ' < "$WORK/state/sleeps"; } 2>/dev/null | sed 's/ $//')
}

# 1. transient twice (timeout, EOF), then success
run_case "timeout eof ok" digest
if [ "$RC" -eq 0 ] && [ "$COUNT" -eq 3 ] && [ "$SLEEPS" = "15 30" ]; then
    ok "timeout, EOF, then success → passes on attempt 3 (waits: $SLEEPS)"
else bad "transient×2 then ok: rc=$RC pulls=$COUNT waits='$SLEEPS'" "$OUT"; fi
printf '%s\n' "$OUT" | grep -q 'attempt 1/5 failed (transient): .*Timeout exceeded' \
    && printf '%s\n' "$OUT" | grep -q 'attempt 2/5 failed (transient): .*unexpected EOF' \
    && printf '%s\n' "$OUT" | grep -q "verified digest $DIGEST" \
    && ok "each attempt logged with its reason; digest verified" \
    || bad "attempt log / digest verification missing" "$OUT"

# 1b. other transient classes
for t in reset 503 429; do
    run_case "$t ok" digest
    [ "$RC" -eq 0 ] && [ "$COUNT" -eq 2 ] && ok "'$t' is retried" || bad "'$t' not retried: rc=$RC pulls=$COUNT" "$OUT"
done

# 2. permanent errors fail at once, no sleep
for p in unauth manifest; do
    run_case "$p ok" digest
    if [ "$RC" -ne 0 ] && [ "$COUNT" -eq 1 ] && [ -z "$SLEEPS" ] && printf '%s\n' "$OUT" | grep -q 'permanent, not retrying'; then
        ok "'$p' fails fast (1 attempt, no backoff)"
    else bad "'$p' should fail fast: rc=$RC pulls=$COUNT waits='$SLEEPS'" "$OUT"; fi
done

# 3. exhausted retries fail, with the full backoff schedule
run_case "timeout" digest
if [ "$RC" -ne 0 ] && [ "$COUNT" -eq 5 ] && [ "$SLEEPS" = "15 30 60 120" ] \
   && printf '%s\n' "$OUT" | grep -q 'pull failed after 5 attempts'; then
    ok "always-transient → fails after 5 attempts (waits: $SLEEPS)"
else bad "exhaustion: rc=$RC pulls=$COUNT waits='$SLEEPS'" "$OUT"; fi

# 4. digest mismatch fails; no advertised digest only needs the image to resolve
run_case "ok" digest "$OTHER"
[ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q 'digest mismatch' \
    && ok "local digest ≠ advertised digest → fails" || bad "digest mismatch not caught: rc=$RC" "$OUT"

# 5. pull says ok but image does not resolve → retried, then ok
run_case "ok" flip
[ "$RC" -eq 0 ] && [ "$COUNT" -eq 2 ] && [ "$SLEEPS" = "15" ] \
    && ok "unresolvable image after 'successful' pull is retried" || bad "inspect-fail retry: rc=$RC pulls=$COUNT waits='$SLEEPS'" "$OUT"
run_case "ok" fail
[ "$RC" -ne 0 ] && [ "$COUNT" -eq 5 ] \
    && ok "image never resolves → fails after 5 attempts" || bad "inspect never resolves: rc=$RC pulls=$COUNT" "$OUT"

# 6. wiring: Step 1 goes through the wrapper; defaults are 5 / 15 30 60 120
grep -q '^hm_pull_with_retry || exit 1$' "$SCRIPT" && ok "Step 1 calls hm_pull_with_retry" || bad "Step 1 does not call hm_pull_with_retry"
grep -q 'HM_PULL_ATTEMPTS="${HM_PULL_ATTEMPTS:-5}"' "$SCRIPT" && grep -q 'HM_PULL_BACKOFF="${HM_PULL_BACKOFF:-15 30 60 120}"' "$SCRIPT" \
    && ok "defaults: 5 attempts, 15 30 60 120" || bad "retry defaults changed"
[ "$(sed -n '/^# >>> hm-pull-retry/,/^# <<< hm-pull-retry/!p' "$SCRIPT" | grep -v '^[[:space:]]*#' | grep -c 'docker pull ')" -eq 0 ] \
    && ok "no unwrapped docker pull outside the retry block" || bad "a bare docker pull remains outside the retry block"

[ "$FAIL" -eq 0 ] && echo "PASS: hm-docker pull retry" || echo "FAIL: hm-docker pull retry"
exit "$FAIL"
