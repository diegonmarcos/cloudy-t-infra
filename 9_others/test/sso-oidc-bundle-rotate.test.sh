#!/usr/bin/env bash
# #1917: sso-oidc-bundle.py rotate replaces ONLY the named client (secret + verifying digest), keeps the JWKS key and
# every other client byte-identical, masks the new secret, and refuses an unknown client. Synthetic fixtures only.
# Mutations (rotate everything, change the key, no mask) must each be caught.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/1_cicd/src/scripts/sso-oidc-bundle.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo '{"clients":[{"client_id":"a","secret_var":"VA"},{"client_id":"b","secret_var":"VB"}]}' > "$T/c.json"
echo '{"issued":"x","jwks_key_pem":"FAKEKEY","clients":{"a":{"secret_var":"VA","secret":"sa","digest":"da"},"b":{"secret_var":"VB","secret":"sb","digest":"db"}}}' > "$T/old.json"
check() {
  local s="$1" out
  out="$(python3 -I "$s" rotate "$T/c.json" "$T/old.json" "$T/o.json" a 2>&1)" || return 1
  python3 -I - "$T/old.json" "$T/o.json" "$out" <<'PY'
import base64, hashlib, json, sys
o, n, out = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
if n["jwks_key_pem"] != o["jwks_key_pem"] or n["clients"]["b"] != o["clients"]["b"]: sys.exit(1)
a = n["clients"]["a"]
if a["secret"] == "sa" or a["secret_var"] != "VA" or len(a["secret"]) < 40: sys.exit(1)
if "::add-mask::" + a["secret"] not in out.splitlines(): sys.exit(1)
p = a["digest"].split("$")
u = lambda x: base64.b64decode(x.replace(".", "+") + "=" * (-len(x) % 4))
sys.exit(0 if hashlib.pbkdf2_hmac("sha512", a["secret"].encode(), u(p[3]), 310000, 64) == u(p[4]) else 1)
PY
}
fail=0
check "$S" && echo "ok   rotate keeps the rest" || { echo "FAIL rotate"; fail=1; }
python3 -I "$S" rotate "$T/c.json" "$T/old.json" "$T/o2.json" nope >/dev/null 2>&1 && { echo "FAIL unknown client accepted"; fail=1; } || echo "ok   unknown client refused"
sed 's/b\["clients"\]\[cid\] = new_client(declared\[cid\])/b["clients"] = {k: new_client(v["secret_var"]) for k, v in b["clients"].items()}/' "$S" > "$T/m1.py"
sed 's/b.setdefault("rotated"/b["jwks_key_pem"] = "X"; b.setdefault("rotated"/' "$S" > "$T/m2.py"
sed 's/print("::add-mask::" + pw, flush=True)/pass/' "$S" > "$T/m3.py"
for m in m1 m2 m3; do cmp -s "$S" "$T/$m.py" && { echo "FAIL mutant $m not applied"; fail=1; continue; }; check "$T/$m.py" && { echo "FAIL mutant $m survived"; fail=1; } || echo "ok   mutant $m caught"; done
exit $fail
