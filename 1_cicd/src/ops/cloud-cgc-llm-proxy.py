#!/usr/bin/env python3
"""cloud-cgc-llm-proxy.py -- bounded LLM calls for the cgc graphrag phase (#888).

octocode 0.22.0 builds every GraphRAG request through octolib 0.34.2, which sends it
with request_timeout None (octolib src/llm/types.rs ChatCompletionParams::new): no
per-request deadline at all. OpenRouter keeps a slow non-streaming request alive by
dripping whitespace before the JSON body, so one stuck upstream call can hold the
whole index forever. On run 37929244331 cloud-u-containers' second graphrag window
finished its description pass, entered "AI analyzing 1681 files for architectural
relationships" (211 sequential calls that ran at <= 7 s/call in window 1) and was
still there 3h later when the 204-min slice expired. octocode keeps every relationship
in memory until the last call returns, so the timeout threw the window's whole
relationship pass away.

octolib honours OPENROUTER_API_URL, so cloud-cgc-db-update.sh points octocode at this
proxy on 127.0.0.1 and the proxy forwards to the real endpoint with:
  * a hard wall-clock deadline per attempt (CGC_LLM_REQUEST_TIMEOUT_S, default 120),
    enforced while reading the body too, so a whitespace drip cannot outlive it;
  * at most CGC_LLM_MAX_ATTEMPTS attempts (3) inside CGC_LLM_CALL_BUDGET_S (360) per
    logical call; 429/5xx honour Retry-After, capped at CGC_LLM_RETRY_AFTER_CAP_S (60);
  * a bounded outcome when the budget is spent, chosen so the window still COMPLETES
    (a completed window is the only durable progress the chunk planner records):
      - relationship call -> 200 with {"relationships": []}: those files keep their
        rule-based edges and lose the AI architectural ones (octocode would otherwise
        abort the whole index: ai.rs maps that failure to "Stopping indexing");
      - description call  -> 400 (non-retryable in octolib): octocode defers exactly
        those files (builder.rs "Deferring N files to next run"), and the proxy logs
        their paths so the planner keeps them outstanding instead of marking them done;
  * a circuit breaker: CGC_LLM_BREAKER_FAILS consecutive exhausted calls open it for
    CGC_LLM_BREAKER_COOLDOWN_S; while open every call fails fast (degraded 200), the
    window finishes in minutes, and the update script stops the repo for this run;
  * #1817 content check: a rel/desc 200 whose message content is empty or not JSON
    (after stripping a ```json fence) is a failed attempt ("badjson"), retried and
    bounded like any other, never handed to octocode (which aborts the whole index
    on "LLM returned unparseable JSON");
  * #1817 model fallback: CGC_LLM_FALLBACK_MODELS (comma list, from build.json
    .runtime.octocode.update.llm_fallback_models) are tried in order after the
    client's own model. A model OpenRouter answers 404 for ("no longer available")
    is dropped for the rest of the run, so free models retired mid-run cost one
    attempt, not the window; a badjson/429/5xx attempt moves to the next model;
  * one JSON line per logical call in --log (kind, outcome, attempts, latency, timeouts,
    429s, Retry-After waited, tokens, deferred paths). Headers are never logged, so the
    API key the client sends never reaches the log.

Stdlib only. Usage:
  cloud-cgc-llm-proxy.py --upstream URL --log FILE --port-file FILE [--port N]
"""
import argparse
import hashlib
import http.client
import json
import os
import re
import sys
import threading
import time
from email.utils import parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def _env(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


REQ_TIMEOUT = _env("CGC_LLM_REQUEST_TIMEOUT_S", 120)
MAX_ATTEMPTS = max(1, int(_env("CGC_LLM_MAX_ATTEMPTS", 3)))
CALL_BUDGET = _env("CGC_LLM_CALL_BUDGET_S", 360)
RA_CAP = _env("CGC_LLM_RETRY_AFTER_CAP_S", 60)
BACKOFF = _env("CGC_LLM_BACKOFF_S", 2)
BREAKER_FAILS = max(1, int(_env("CGC_LLM_BREAKER_FAILS", 5)))
BREAKER_COOLDOWN = _env("CGC_LLM_BREAKER_COOLDOWN_S", 300)
FALLBACK_MODELS = [m.strip() for m in os.environ.get("CGC_LLM_FALLBACK_MODELS", "").split(",") if m.strip()]

FORWARD_HEADERS = ("content-type", "authorization", "http-referer", "x-title", "accept")


class Upstream(Exception):
    """One failed attempt: kind is timeout | net | 429 | 5xx | bad200 | badjson | gone."""

    def __init__(self, kind, retry_after=None, status=None):
        super().__init__(kind)
        self.kind = kind
        self.retry_after = retry_after
        self.status = status


def retry_after_s(value):
    if not value:
        return None
    value = value.strip()
    try:
        return max(0.0, float(value))
    except ValueError:
        pass
    try:
        return max(0.0, parsedate_to_datetime(value).timestamp() - time.time())
    except (TypeError, ValueError):
        return None


def user_text(req):
    out = []
    for m in req.get("messages") or []:
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, str):
            out.append(c)
        elif isinstance(c, list):
            out.extend(p.get("text", "") for p in c if isinstance(p, dict))
    return "\n".join(out)


def classify(body):
    """-> (kind, files): rel | desc | other, and the file paths the call is about."""
    try:
        req = json.loads(body)
    except ValueError:
        return "other", []
    fmt = req.get("response_format") or {}
    props = ((fmt.get("json_schema") or {}).get("schema") or {}).get("properties") or {}
    text = user_text(req)
    if "relationships" in props:
        src = text.split("POTENTIAL RELATIONSHIP TARGETS:", 1)[0]
        return "rel", re.findall(r"^File: (.+)$", src, re.M)
    if "descriptions" in props:
        return "desc", re.findall(r"^ID: (.+)$", text, re.M)
    return "other", []


def content_ok(data):
    """True when the first choice's content parses as JSON (a ```json fence allowed)."""
    try:
        c = json.loads(data)["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError):
        return False
    if not isinstance(c, str):
        return False
    c = c.strip()
    m = re.match(r"^```[a-zA-Z]*\s*(.*?)\s*```$", c, re.S)
    if m:
        c = m.group(1).strip()
    if not c:
        return False
    try:
        json.loads(c)
        return True
    except ValueError:
        return False


def with_model(body, model):
    try:
        req = json.loads(body)
    except ValueError:
        return body
    if req.get("model") == model:
        return body
    req["model"] = model
    return json.dumps(req).encode()


def degraded_body(kind, n):
    content = {"relationships": []} if kind == "rel" else {"descriptions": []}
    return json.dumps({
        "id": "cgc-degraded-%d" % n, "object": "chat.completion",
        "created": int(time.time()), "model": "cgc-degraded",
        "choices": [{"index": 0, "finish_reason": "stop",
                     "message": {"role": "assistant", "content": json.dumps(content)}}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }).encode()


class Proxy:
    def __init__(self, upstream, log_path):
        self.up = urlsplit(upstream)
        self.log_path = log_path
        self.lock = threading.Lock()
        self.fails = 0           # consecutive exhausted logical calls
        self.open_until = 0.0    # breaker open while now < open_until
        self.exhausted = set()   # body hashes of description calls already given up on
        self.seq = 0
        self.gone = set()        # models the upstream answered 404 for: skipped all run

    def log(self, rec):
        line = json.dumps(rec, separators=(",", ":"))
        with self.lock:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(line + "\n")

    def candidates(self, body):
        try:
            first = json.loads(body).get("model")
        except (ValueError, AttributeError):
            first = None
        out = []
        for m in ([first] if first else []) + FALLBACK_MODELS:
            if m not in out:
                out.append(m)
        with self.lock:
            live = [m for m in out if m not in self.gone]
        return live or out[-1:]

    def attempt(self, body, headers, deadline, check_content=False):
        """One upstream POST under a hard wall-clock deadline -> (status, ctype, body)."""
        u = self.up
        cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
        left = deadline - time.monotonic()
        if left <= 0:
            raise Upstream("timeout")
        conn = cls(u.hostname, u.port, timeout=min(left, 20.0))
        try:
            path = (u.path or "/") + ("?" + u.query if u.query else "")
            conn.request("POST", path, body=body, headers=headers)
            # Keep our own handle: getresponse() drops conn.sock for a close-delimited body.
            sock = conn.sock
            sock.settimeout(max(0.05, deadline - time.monotonic()))
            resp = conn.getresponse()
            chunks = []
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise Upstream("timeout")
                sock.settimeout(max(0.05, left))
                c = resp.read1(65536)
                if not c:
                    break
                chunks.append(c)
            data = b"".join(chunks)
            status = resp.status
            if status == 429 or status >= 500:
                kind = "429" if status == 429 else "5xx"
                raise Upstream(kind, retry_after_s(resp.getheader("Retry-After")), status)
            if status == 404 and FALLBACK_MODELS:
                raise Upstream("gone", None, status)
            if status == 200:
                try:
                    ok = bool(json.loads(data).get("choices"))
                except (ValueError, AttributeError):
                    ok = False
                if not ok:  # OpenRouter reports a mid-request provider error as 200 + {"error": ...}
                    raise Upstream("bad200", None, status)
                if check_content and not content_ok(data):
                    raise Upstream("badjson", None, status)
            return status, resp.getheader("Content-Type") or "application/json", data
        except TimeoutError as e:
            raise Upstream("timeout") from e
        except (OSError, http.client.HTTPException) as e:
            raise Upstream("net") from e
        finally:
            conn.close()

    def handle(self, body, in_headers):
        """-> (status, content-type, body) for the client, and logs one record."""
        t0 = time.monotonic()
        kind, files = classify(body)
        h = hashlib.sha256(body).hexdigest()
        rec = {"t": round(time.time(), 3), "kind": kind, "files": len(files), "attempts": 0,
               "timeouts": 0, "r429": 0, "r5xx": 0, "neterr": 0, "bad200": 0, "badjson": 0, "gone": 0, "wait_s": 0.0}
        with self.lock:
            self.seq += 1
            seq = self.seq
            repeat = kind == "desc" and h in self.exhausted
            breaker_open = time.monotonic() < self.open_until
            if not breaker_open and self.open_until:
                self.open_until = time.monotonic() + 1e9  # half-open: this call probes alone
                probing = True
            else:
                probing = False
        if repeat:  # octocode's own retry of a description batch we already gave up on
            rec.update(outcome="repeat", status=400, ms=0)
            self.log(rec)
            return 400, "application/json", b'{"error":{"message":"cgc-llm-proxy: call budget spent"}}'
        if breaker_open:
            rec.update(outcome="breaker", status=200, ms=0)
            self.log(rec)
            return 200, "application/json", degraded_body(kind, seq)
        headers = {k: v for k, v in in_headers.items() if k.lower() in FORWARD_HEADERS}
        deadline_call = t0 + CALL_BUDGET
        result = None
        last = None
        mi = 0  # index into this call's live model list
        attempts = MAX_ATTEMPTS + len(FALLBACK_MODELS)  # a gone model costs one extra try, not the call
        n = 0
        while n < attempts:
            if time.monotonic() >= deadline_call:
                break
            models = self.candidates(body)
            model = models[mi % len(models)]
            rec["attempts"] = n + 1
            rec["model"] = model
            try:
                result = self.attempt(with_model(body, model), headers,
                                      min(deadline_call, time.monotonic() + REQ_TIMEOUT),
                                      check_content=kind in ("rel", "desc"))
                break
            except Upstream as e:
                last = e
                key = {"timeout": "timeouts", "net": "neterr", "429": "r429", "5xx": "r5xx",
                       "bad200": "bad200", "badjson": "badjson", "gone": "gone"}[e.kind]
                rec[key] += 1
                n += 1
                if e.kind == "gone":
                    with self.lock:
                        self.gone.add(model)
                    continue  # next live model at once, no backoff
                if FALLBACK_MODELS and e.kind in ("badjson", "429", "5xx", "bad200"):
                    mi += 1
            if n >= attempts or rec["attempts"] - rec["gone"] >= MAX_ATTEMPTS:
                break
            wait = last.retry_after if last.retry_after is not None else BACKOFF * (2 ** (n - 1))
            wait = min(wait, RA_CAP, max(0.0, deadline_call - time.monotonic()))
            rec["wait_s"] = round(rec["wait_s"] + wait, 3)
            time.sleep(wait)
        rec["ms"] = int((time.monotonic() - t0) * 1000)
        if result is not None:
            status, ctype, data = result
            with self.lock:
                if status == 200:
                    self.fails = 0
                    self.open_until = 0.0
                elif probing:
                    self.open_until = 0.0
            if status == 200:
                try:
                    usage = json.loads(data).get("usage") or {}
                    rec["out_tokens"] = usage.get("completion_tokens", usage.get("output_tokens"))
                except (ValueError, AttributeError):
                    pass
            rec.update(outcome="ok" if status == 200 else "passthrough", status=status)
            self.log(rec)
            return status, ctype, data
        # Budget spent: bounded outcome, never a hang.
        with self.lock:
            self.fails += 1
            if self.fails >= BREAKER_FAILS or probing:
                self.open_until = time.monotonic() + BREAKER_COOLDOWN
                rec["breaker_opened"] = True
            if kind == "desc":
                self.exhausted.add(h)
        rec["last_error"] = last.kind if last else "budget"
        if kind == "desc":
            rec.update(outcome="deferred", status=400, deferred=files)
            self.log(rec)
            return 400, "application/json", b'{"error":{"message":"cgc-llm-proxy: call budget spent"}}'
        if kind == "rel":
            rec.update(outcome="degraded", status=200)
            self.log(rec)
            return 200, "application/json", degraded_body(kind, seq)
        rec.update(outcome="failed", status=504)
        self.log(rec)
        return 504, "application/json", b'{"error":{"message":"cgc-llm-proxy: call budget spent"}}'


def make_handler(proxy):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_a):  # request lines would carry nothing useful; stay quiet
            pass

        def _send(self, status, ctype, data):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._send(200, "text/plain", b"ok\n")

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n > 0 else b""
            try:
                status, ctype, data = proxy.handle(body, dict(self.headers.items()))
            except Exception as e:  # never leave octocode waiting on a dead handler
                proxy.log({"t": round(time.time(), 3), "outcome": "proxy_error", "error": type(e).__name__})
                status, ctype, data = 502, "application/json", b'{"error":{"message":"cgc-llm-proxy error"}}'
            try:
                self._send(status, ctype, data)
            except OSError:
                pass

    return H


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--port", type=int, default=0)
    a = ap.parse_args(argv)
    if urlsplit(a.upstream).scheme not in ("http", "https"):
        print("cgc-llm-proxy: upstream must be http(s)", file=sys.stderr)
        return 2
    proxy = Proxy(a.upstream, a.log)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(proxy))
    srv.daemon_threads = True
    tmp = a.port_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("%d\n" % srv.server_address[1])
    os.replace(tmp, a.port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
