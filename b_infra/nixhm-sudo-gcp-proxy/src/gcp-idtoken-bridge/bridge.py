#!/usr/bin/env python3
"""gcp-idtoken-bridge (#1686): forwards /<service>/<path> to a Cloud Run service with a Google ID token.

The token comes from the VM metadata server (no key on disk), per target audience, cached until shortly before
exp, and is sent as X-Serverless-Authorization so the app's own Authorization header passes through untouched.
Only services listed in the routes file are reachable (no open proxy). stdlib only.
"""
import urllib.parse
import base64, json, os, sys, time, threading, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

META = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity"
SKEW = 120
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "host", "content-length", "x-serverless-authorization"}
_cache, _lock = {}, threading.Lock()


def jwt_exp(tok):
    p = tok.split(".")[1]
    p += "=" * (-len(p) % 4)
    return int(json.loads(base64.urlsafe_b64decode(p))["exp"])


def fetch_token(aud, opener=urllib.request.urlopen):
    req = urllib.request.Request(META + "?audience=" + urllib.parse.quote(aud, safe="") + "&format=full",
                                 headers={"Metadata-Flavor": "Google"})
    with opener(req, timeout=5) as r:
        return r.read().decode().strip()


def token_for(aud, now=time.time, fetch=fetch_token):
    with _lock:
        t = _cache.get(aud)
        if t and t[1] - SKEW > now():
            return t[0]
    tok = fetch(aud)
    with _lock:
        _cache[aud] = (tok, jwt_exp(tok))
    return tok


def resolve(routes, path):
    """'/svc/rest?q' -> (audience, upstream path) or None."""
    parts = path.split("/", 2)
    if len(parts) < 2 or not parts[1] or parts[1] not in routes:
        return None
    rest = "/" + parts[2] if len(parts) > 2 else "/"
    return routes[parts[1]].rstrip("/"), rest


def make_handler(routes, fetch=fetch_token):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _do(self):
            if self.path == "/_health":
                return self._reply(200, b'{"ok":true}', {"Content-Type": "application/json"})
            r = resolve(routes, self.path)
            if not r:
                return self._reply(404, b'{"error":"unknown service"}', {"Content-Type": "application/json"})
            aud, rest = r
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else None
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
            try:
                hdrs["X-Serverless-Authorization"] = "Bearer " + token_for(aud, fetch=fetch)
            except Exception as e:
                return self._reply(502, json.dumps({"error": "token mint failed", "detail": str(e)[:200]}).encode(),
                                   {"Content-Type": "application/json"})
            req = urllib.request.Request(aud + rest, data=body, headers=hdrs, method=self.command)
            try:
                with urllib.request.urlopen(req, timeout=300) as u:
                    self._reply(u.status, u.read(), dict(u.headers))
            except urllib.error.HTTPError as e:
                self._reply(e.code, e.read(), dict(e.headers))
            except Exception as e:
                self._reply(502, json.dumps({"error": "upstream", "detail": str(e)[:200]}).encode(),
                            {"Content-Type": "application/json"})

        def _reply(self, code, body, headers):
            self.send_response(code)
            for k, v in headers.items():
                if k.lower() not in HOP and k.lower() != "content-encoding":
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _do

        def log_message(self, *a):
            pass
    return H


def main():
    routes = json.load(open(os.environ.get("BRIDGE_ROUTES", "/etc/gcp-idtoken-bridge/routes.json")))
    addr = os.environ.get("BRIDGE_LISTEN", "10.0.0.1")
    port = int(os.environ.get("BRIDGE_PORT", "9120"))
    ThreadingHTTPServer((addr, port), make_handler(routes)).serve_forever()


if __name__ == "__main__":
    import urllib.parse  # noqa: F401
    main()
