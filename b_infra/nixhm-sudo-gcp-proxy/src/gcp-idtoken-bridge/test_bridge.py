import base64, json, sys, threading, time, unittest, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
sys.path.insert(0, __import__("os").path.dirname(__file__))
import bridge


def jwt(exp):
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    return b({"alg": "RS256"}) + "." + b({"exp": exp}) + ".sig"


class Up(BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        Up.seen.append((self.path, dict(self.headers), self.rfile.read(n)))
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    do_GET = do_POST

    def log_message(self, *a): pass


class T(unittest.TestCase):
    def test_resolve(self):
        r = {"a": "https://a.run.app/"}
        self.assertEqual(bridge.resolve(r, "/a/x/y?q=1"), ("https://a.run.app", "/x/y?q=1"))
        self.assertEqual(bridge.resolve(r, "/a"), ("https://a.run.app", "/"))
        self.assertIsNone(bridge.resolve(r, "/b/x"))
        self.assertIsNone(bridge.resolve(r, "/"))

    def test_cache_until_expiry(self):
        bridge._cache.clear(); calls = []
        def f(aud): calls.append(aud); return jwt(1000)
        self.assertEqual(bridge.token_for("u", now=lambda: 100, fetch=f), jwt(1000))
        bridge.token_for("u", now=lambda: 500, fetch=f); self.assertEqual(len(calls), 1)
        bridge.token_for("u", now=lambda: 900, fetch=f); self.assertEqual(len(calls), 2)  # inside skew -> refresh
        bridge.token_for("other", now=lambda: 100, fetch=f); self.assertEqual(len(calls), 3)  # per audience

    def test_forward_headers(self):
        bridge._cache.clear()
        up = HTTPServer(("127.0.0.1", 0), Up); threading.Thread(target=up.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:%d" % up.server_port
        br = HTTPServer(("127.0.0.1", 0), bridge.make_handler({"svc": base}, fetch=lambda a: jwt(int(time.time()) + 3600)))
        threading.Thread(target=br.serve_forever, daemon=True).start()
        rq = urllib.request.Request("http://127.0.0.1:%d/svc/v1/x" % br.server_port, data=b"hi", method="POST",
                                    headers={"Authorization": "Bearer app-token", "X-Serverless-Authorization": "evil"})
        self.assertEqual(urllib.request.urlopen(rq).read(), b"ok")
        path, h, body = Up.seen[-1]
        self.assertEqual(path, "/v1/x"); self.assertEqual(body, b"hi")
        self.assertEqual(h["Authorization"], "Bearer app-token")
        self.assertTrue(h["X-Serverless-Authorization"].startswith("Bearer ey") or h["X-Serverless-Authorization"].startswith("Bearer "))
        self.assertNotEqual(h["X-Serverless-Authorization"], "evil")
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen("http://127.0.0.1:%d/nope/x" % br.server_port)
        self.assertEqual(e.exception.code, 404)

    def test_routes_match_registry(self):
        import os
        reg = os.path.join(os.path.dirname(__file__), "../../../../c_vps/vps_gcloud/src/terraform.json")
        if not os.path.exists(reg): self.skipTest("registry not in tree")
        routes = json.load(open(os.path.join(os.path.dirname(__file__), "routes.json")))
        svc = {s["name"]: s for s in json.load(open(reg))["cloud_run_services"]}
        for n, u in routes.items():
            self.assertIn(n, svc); self.assertEqual(svc[n].get("invoker", "iam"), "iam")
            self.assertTrue(u.startswith("https://%s-" % n) and u.endswith(".a.run.app"))


if __name__ == "__main__":
    unittest.main()
