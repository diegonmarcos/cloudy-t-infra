#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/cgc-db-llm-proxy.test.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# #888: every GraphRAG LLM call is bounded. octocode 0.22.0 / octolib 0.34.2 send each
# request with no timeout, so one stuck call held cloud-u-containers' second graphrag
# window for 3h on run 37929244331. cloud-cgc-llm-proxy.py sits between octocode and
# the endpoint; this drives it against a scripted fake upstream (hang, whitespace drip,
# 429 + Retry-After, 5xx, 200-with-error, 401) and checks every call returns within its
# budget with the outcome octocode can survive, the key never reaches the log, the
# breaker fails fast, and cloud-cgc-db-update.sh actually routes octocode through it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROXY="$ROOT/1_cicd/src/ops/cloud-cgc-llm-proxy.py"
UPD="$ROOT/1_cicd/src/ops/cloud-cgc-db-update.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
[ -f "$PROXY" ] || { echo "  FAIL: $PROXY does not exist — LLM calls have no per-request timeout"; echo FAIL; exit 1; }
command -v python3 >/dev/null && command -v curl >/dev/null && command -v jq >/dev/null || { echo "::error::python3, curl and jq required"; exit 1; }

W="$(mktemp -d)"; PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$W"; }
trap cleanup EXIT

# Fake upstream: behaviour picked by a MODE=<x> marker in the user message; per-body
# attempt counter so "fail once, then succeed" can be scripted; counts every request.
mkdir -p "$W/fake"
cat > "$W/fake/up.py" <<'PY'
import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
seen = {}; lock = threading.Lock(); hits = [0]
OK = {"id": "x", "choices": [{"message": {"content": "{\"relationships\": [{\"source_path\": \"a\"}]}"}, "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 10, "completion_tokens": 42, "total_tokens": 52}}
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, body, extra=None):
        b = json.dumps(body).encode()
        self.send_response(code)
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self.send(200, {"hits": hits[0]})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        req = json.loads(body); text = " ".join(m["content"] for m in req["messages"] if m["role"] == "user")
        mode = text.split("MODE=", 1)[1].split()[0]
        with lock:
            hits[0] += 1; seen[body] = seen.get(body, 0) + 1; n = seen[body]
        if mode == "ok": return self.send(200, OK)
        if mode == "hang": time.sleep(30); return self.send(200, OK)
        if mode == "drip":
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            try:
                for _ in range(300): self.wfile.write(b" "); self.wfile.flush(); time.sleep(0.2)
            except OSError: pass
            return
        if mode == "ra-then-ok":
            return self.send(429, {"error": "rate"}, {"Retry-After": "1"}) if n == 1 else self.send(200, OK)
        if mode == "ra-huge": return self.send(429, {"error": "rate"}, {"Retry-After": "100"})
        if mode == "e500": return self.send(500, {"error": "boom"})
        if mode == "err200": return self.send(200, {"error": {"message": "provider died"}})
        if mode == "e401": return self.send(401, {"error": "no key"})
        fb = req.get("model") == "fb/model:free"
        if mode == "empty": return self.send(200, {"id": "x", "choices": [{"message": {"content": ""}}]})
        if mode == "empty-unless-fb":
            return self.send(200, OK) if fb else self.send(200, {"id": "x", "choices": [{"message": {"content": ""}}]})
        if mode == "gone":
            return self.send(200, OK) if fb else self.send(404, {"error": {"message": "no longer available"}})
        if mode == "cap-day": return self.send(429, {"error": {"message": "Rate limit exceeded: free-models-per-day. "}})
        if mode == "cap-min": return self.send(429, {"error": {"message": "Rate limit exceeded: free-models-per-min. "}})
        if mode == "nocredit":
            return self.send(200, OK) if fb else self.send(402, {"error": {"message": "Insufficient credits"}})
        if mode == "fenced": return self.send(200, {"id": "x", "choices": [{"message": {"content": "```json\n{\"relationships\": []}\n```"}}]})
ThreadingHTTPServer.daemon_threads = True
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$W/fake/up.py" "$W/up.port" & PIDS="$PIDS $!"
for _ in $(seq 50); do [ -s "$W/up.port" ] && break; sleep 0.1; done
UP="http://127.0.0.1:$(cat "$W/up.port")/api/v1/chat/completions"

start_proxy() {  # env passes through; → $PORT
  rm -f "$W/p.port"
  python3 "$PROXY" --upstream "$UP" --log "$W/calls.jsonl" --port-file "$W/p.port" & PIDS="$PIDS $!"
  for _ in $(seq 50); do [ -s "$W/p.port" ] && break; sleep 0.1; done
  PORT=$(cat "$W/p.port")
}
# A canary built at run time (a literal key-shaped string trips the leak scan).
KEY="canary-$$-$(date +%s)-must-never-be-logged"
# body <rel|desc> <mode> [extra text] → request JSON shaped like octolib's
body() {
  local prop; [ "$1" = rel ] && prop=relationships || prop=descriptions
  local txt
  if [ "$1" = rel ]; then txt="SOURCE FILES TO ANALYZE:\nFile: src/a.rs\nLanguage: rust\n\nFile: src/b.rs\nLanguage: rust\n\nPOTENTIAL RELATIONSHIP TARGETS:\nFile: src/zz.rs\n\nMODE=$2 ${3:-}"
  else txt="Analyze the following 2 files\n=== FILE 1 ===\nID: src/one.py\nLanguage: python\n=== FILE 2 ===\nID: src/two.py\n\nMODE=$2 ${3:-}"; fi
  jq -n --arg t "$(printf '%b' "$txt")" --arg p "$prop" \
    '{model: "openai/gpt-4o-mini", messages: [{role: "system", content: "sys"}, {role: "user", content: $t}],
      response_format: {type: "json_schema", json_schema: {name: "response", schema: {type: "object", properties: {($p): {type: "array"}}}}}}'
}
# call <rel|desc> <mode> [extra] → sets CODE, BODY, SECS
call() {
  local t0 t1; t0=$(date +%s.%N)
  CODE=$(curl -sS --noproxy '*' -m 60 -o "$W/resp" -w '%{http_code}' -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    --data-binary "$(body "$@")" "http://127.0.0.1:$PORT/api/v1/chat/completions")
  t1=$(date +%s.%N); SECS=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b - a}')
  BODY=$(cat "$W/resp")
}
last() { tail -n 1 "$W/calls.jsonl"; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a < b)}'; }

export CGC_LLM_REQUEST_TIMEOUT_S=1.5 CGC_LLM_MAX_ATTEMPTS=2 CGC_LLM_CALL_BUDGET_S=6 \
       CGC_LLM_RETRY_AFTER_CAP_S=1.5 CGC_LLM_BACKOFF_S=0.2 CGC_LLM_BREAKER_FAILS=3 CGC_LLM_BREAKER_COOLDOWN_S=60
start_proxy

call rel ok
[ "$CODE" = 200 ] && [ "$(jq -r '.choices[0].message.content' <<<"$BODY")" = '{"relationships": [{"source_path": "a"}]}' ] \
  && [ "$(last | jq -r '.outcome + " " + (.out_tokens|tostring) + " " + (.files|tostring)')" = "ok 42 2" ] \
  && ok "a healthy call passes through untouched and is logged (ok, 42 output tokens, 2 source files)" || bad "healthy call: $CODE $BODY $(last)"

call rel hang
[ "$CODE" = 200 ] && [ "$(jq -r '.choices[0].message.content' <<<"$BODY")" = '{"relationships": []}' ] && lt "$SECS" 6 \
  && [ "$(last | jq -r '.outcome + " " + (.timeouts|tostring)')" = "degraded 2" ] \
  && ok "a hung relationship call is cut at 2 x 1.5s and degrades to an empty relationship set (${SECS}s)" || bad "hung call: $CODE ${SECS}s $(last)"

call rel drip
[ "$CODE" = 200 ] && lt "$SECS" 6 && [ "$(last | jq -r .timeouts)" = 2 ] \
  && ok "a whitespace drip cannot outlive the per-attempt deadline (${SECS}s)" || bad "drip: $CODE ${SECS}s $(last)"

call rel ra-then-ok
[ "$CODE" = 200 ] && [ "$(last | jq -r '.outcome + " " + (.r429|tostring)')" = "ok 1" ] && lt 0.9 "$SECS" \
  && ok "429 + Retry-After: 1 is honoured, then the retry succeeds (${SECS}s)" || bad "Retry-After honour: $CODE ${SECS}s $(last)"

call rel ra-huge
lt "$SECS" 4 && [ "$(last | jq -r .wait_s)" = 1.5 ] \
  && ok "Retry-After: 100 is capped at 1.5s (${SECS}s total)" || bad "Retry-After cap: ${SECS}s $(last)"

call rel err200
[ "$(last | jq -r '.outcome + " " + (.bad200|tostring)')" = "degraded 2" ] \
  && ok "a 200 carrying an error instead of choices counts as a failed attempt" || bad "200-with-error: $(last)"

call rel e401
[ "$CODE" = 401 ] && [ "$(last | jq -r '.outcome + " " + (.attempts|tostring)')" = "passthrough 1" ] \
  && ok "a 401 is passed through after one attempt (a bad key must fail the run, not degrade it)" || bad "401: $CODE $(last)"

# The breaker counted hang, drip, ra-huge, err200 (consecutive spent calls broken by
# ra-then-ok and reset); restart for a clean breaker and the description path.
kill "${PIDS##* }" 2>/dev/null; : > "$W/calls.jsonl"; start_proxy
call desc e500
[ "$CODE" = 400 ] && [ "$(last | jq -c '[.outcome, .deferred]')" = '["deferred",["src/one.py","src/two.py"]]' ] \
  && ok "a spent description call answers 400 (octocode defers those files) and logs their paths" || bad "desc spent: $CODE $(last)"
call desc e500
[ "$CODE" = 400 ] && [ "$(last | jq -r .outcome)" = repeat ] && lt "$SECS" 0.5 \
  && ok "octocode's own retry of that batch is refused at once, without an upstream call (${SECS}s)" || bad "desc repeat: ${SECS}s $(last)"

hits0=$(curl -s --noproxy '*' "http://127.0.0.1:$(cat "$W/up.port")/" | jq .hits)
call rel e500 x1; call rel e500 x2
call rel ok x3
hits1=$(curl -s --noproxy '*' "http://127.0.0.1:$(cat "$W/up.port")/" | jq .hits)
[ "$(last | jq -r .outcome)" = breaker ] && [ "$CODE" = 200 ] && lt "$SECS" 0.5 && [ $(( hits1 - hits0 )) = 4 ] \
  && ok "3 spent calls open the breaker: the next call fails fast with no upstream request (${SECS}s)" || bad "breaker: $CODE ${SECS}s hits=$(( hits1 - hits0 )) $(last)"

# #1817: empty / non-JSON content never reaches octocode; retired models fall back.
kill "${PIDS##* }" 2>/dev/null; : > "$W/calls.jsonl"; start_proxy
call rel empty
[ "$CODE" = 200 ] && [ "$(jq -r '.choices[0].message.content' <<<"$BODY")" = '{"relationships": []}' ] \
  && [ "$(last | jq -r '.outcome + " " + (.badjson|tostring)')" = "degraded 2" ] \
  && ok "an empty-content 200 is a failed attempt (badjson) and degrades, never 'unparseable JSON' in octocode" || bad "empty content: $CODE $BODY $(last)"
call desc empty
[ "$CODE" = 400 ] && [ "$(last | jq -r .outcome)" = deferred ] \
  && ok "an empty-content description call defers its files" || bad "empty desc: $CODE $(last)"
call rel fenced
[ "$CODE" = 200 ] && [ "$(last | jq -r .outcome)" = ok ] && ok "a \`\`\`json-fenced answer still counts as JSON" || bad "fenced: $CODE $(last)"
call rel gone
[ "$CODE" = 404 ] && [ "$(last | jq -r .outcome)" = passthrough ] \
  && ok "with no fallback declared a 404 is passed through as before" || bad "404 without fallback: $CODE $(last)"
kill "${PIDS##* }" 2>/dev/null; : > "$W/calls.jsonl"
CGC_LLM_FALLBACK_MODELS="fb/model:free" start_proxy
call rel gone
[ "$CODE" = 200 ] && [ "$(last | jq -r '.outcome + " " + .model + " " + (.gone|tostring)')" = "ok fb/model:free 1" ] \
  && ok "a 404 (model retired) drops to the declared fallback model in the same call" || bad "gone fallback: $CODE $(last)"
call rel gone x2
[ "$CODE" = 200 ] && [ "$(last | jq -r '(.attempts|tostring) + " " + (.gone|tostring)')" = "1 0" ] \
  && ok "the retired model is skipped for the rest of the run (next call: 1 attempt, no 404)" || bad "gone sticky: $CODE $(last)"
call rel nocredit
[ "$CODE" = 200 ] && [ "$(last | jq -r '.outcome + " " + .model')" = "ok fb/model:free" ] \
  && ok "a 402 (paid balance spent) drops to the free fallback in the same call" || bad "402 fallback: $CODE $(last)"
grep -q '"\$_cp_code" = "402" \] && \[ -n "\${CGC_LLM_FALLBACK_MODELS:-}" \]' "$UPD" \
  && ok "the credit preflight warns, not fails, on 402 when free fallbacks are declared" || bad "preflight still fatal on 402 with fallbacks"
call rel empty-unless-fb
[ "$CODE" = 200 ] && [ "$(last | jq -r '.outcome + " " + .model')" = "ok fb/model:free" ] \
  && ok "empty content on one model retries on the fallback model" || bad "badjson fallback: $CODE $(last)"
kill "${PIDS##* }" 2>/dev/null; : > "$W/calls.jsonl"; start_proxy
call rel cap-day
[ "$(last | jq -r '(.r429|tostring) + " " + (.r429_day|tostring) + " " + (.r429_min|tostring)')" = "2 2 0" ] \
  && ok "a free-models-per-day 429 is logged as the daily cap" || bad "429 day class: $(last)"
call rel cap-min
[ "$(last | jq -r '(.r429_day|tostring) + " " + (.r429_min|tostring)')" = "0 2" ] \
  && ok "a free-models-per-min 429 is logged as the per-minute cap" || bad "429 min class: $(last)"
grep -q 'r429_day) daily cap' "$ROOT/1_cicd/src/ops/cloud-cgc-db-chunk.sh" \
  && ok "the per-window LLM line splits 429s into daily cap / per-minute" || bad "chunk summary lacks the 429 split"
grep -q 'CGC_LLM_FALLBACK_MODELS=.*llm_fallback_models' "$UPD" && grep -q 'export CGC_LLM_FALLBACK_MODELS' "$UPD" \
  && ok "cloud-cgc-db-update.sh feeds build.json llm_fallback_models to the proxy" || bad "update.sh does not wire llm_fallback_models"

grep -qF "$KEY" "$W/calls.jsonl" && bad "the API key reached the call log" || ok "the API key never reaches the call log"

# Wiring: update.sh starts the proxy for openrouter models and points octocode at it.
grep -q 'cloud-cgc-llm-proxy.py" --upstream "\$OPENROUTER_API_URL"' "$UPD" \
  && grep -q 'OPENROUTER_API_URL="http://127.0.0.1:\$_lp_port/api/v1/chat/completions"; export OPENROUTER_API_URL' "$UPD" \
  && ok "cloud-cgc-db-update.sh routes octocode's OpenRouter calls through the proxy" || bad "update.sh does not route octocode through the proxy"
grep -q 'chunk_llm_summary "\${LLM_PROXY_LOG:-}"' "$UPD" && ok "the chunk loop summarises each window's LLM calls" || bad "no per-window LLM summary in the chunk loop"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS
