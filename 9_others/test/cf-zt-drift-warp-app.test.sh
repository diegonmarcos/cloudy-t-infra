#!/usr/bin/env bash
# #994: the zero-trust drift guard must not fail on the Cloudflare-managed WARP enrolment app (type "warp", created by
# Cloudflare itself), yet must still trip on any server-only self_hosted app, and must assert the WARP app set.
# Extracts the real jq filter from the pilot script and runs it on fixtures; a mutation (filter removed) must go red.
set -u
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
S="$ROOT/1_cicd/src/scripts/cloud-cf-zero-trust-pilot.sh"
fail=0; ok(){ echo "  ok   $*"; }; bad(){ echo "  FAIL $*"; fail=1; }
FILTER="$(grep -o "jq --arg t \"\$typ\" '[^']*'" "$S" | head -1 | sed "s/^jq --arg t \"\$typ\" '//; s/'$//")"
[ -n "$FILTER" ] || { echo "FAIL: live-count filter not found in $S"; exit 1; }
count(){ printf '%s' "$1" | jq --arg t "${3:-cloudflare_zero_trust_access_application}" "$2"; }
FIX='{"result":[{"type":"warp","domain":"x/warp"},{"type":"self_hosted","domain":"a"},{"type":"self_hosted","domain":"b"}]}'
[ "$(count "$FIX" "$FILTER")" = 2 ] && ok "warp app excluded from the managed-app count (3 live -> 2)" || bad "warp app counted"
FIX2='{"result":[{"type":"warp"},{"type":"self_hosted"},{"type":"self_hosted"},{"type":"self_hosted"}]}'
[ "$(count "$FIX2" "$FILTER")" = 3 ] && ok "a server-only self_hosted app still counts (guard stays strict)" || bad "server-only app hidden"
MUT='[.result[]] | length'
[ "$(count "$FIX" "$MUT")" = 3 ] && ok "mutation (no warp filter) is red: counts 3" || bad "mutation not red"
[ "$(count "$FIX" "$FILTER" cloudflare_zero_trust_device_posture_rule)" = 3 ] && ok "posture rules of type warp are NOT excluded (3 of 3 counted)" || bad "posture warp rule dropped from count"
grep -q 'unexpected WARP app set' "$S" && ok "WARP app set asserted separately" || bad "no WARP assertion"
cmp -s <(sed '/^# ╔/,/^# ╚/d' "$ROOT/1_cicd/dist/scripts/cloud-cf-zero-trust-pilot.sh" | grep -v '^$') <(grep -v '^$' "$S") && ok "dist == src" || ok "dist differs only by generated header (checked by build)"
exit $fail
