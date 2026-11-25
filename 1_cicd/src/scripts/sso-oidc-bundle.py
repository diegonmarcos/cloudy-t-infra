#!/usr/bin/env python3
"""SSO OIDC bundle builder (#1147, #994). Runs on the EPHEMERAL runner of sso-oidc-issue only.

  new <oidc-clients.json> <jwks.key> <out.json>
      Fresh bundle: the given JWKS key + one new secret (and Authelia pbkdf2-sha512 digest) per client.
  add <oidc-clients.json> <in.json> <out.json>
      Add-only: copy the decrypted bundle <in.json> unchanged (JWKS key, `issued`, every existing
      client entry byte-for-byte) and append a new secret only for each client declared in
      oidc-clients.json that the bundle lacks. Exit 3 when nothing is missing (no write).

  rotate <oidc-clients.json> <in.json> <out.json> <client_id>
      Single-client rotation (#1917): copy the decrypted bundle unchanged and replace ONLY the secret and
      digest of <client_id> (it must be declared and present). JWKS key and every other client stay as is.

Prints nothing but `::add-mask::` lines for new secrets and client IDs / counts. Never a secret.
"""
import base64, hashlib, json, os, secrets, subprocess, sys


def adapt(b):  # Authelia "adapted" base64: standard alphabet, no padding, '+' -> '.'
    return base64.b64encode(b).decode().rstrip("=").replace("+", ".")


def new_client(var):
    pw = secrets.token_urlsafe(48)
    print("::add-mask::" + pw, flush=True)
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha512", pw.encode(), salt, 310000, 64)
    return {"secret_var": var, "secret": pw,
            "digest": "$pbkdf2-sha512$310000$" + adapt(salt) + "$" + adapt(dk)}


def now():
    return subprocess.check_output(["date", "-u", "+%FT%TZ"]).decode().strip()


def cmd_new(clients_path, key_path, out_path):
    clients = json.load(open(clients_path))["clients"]
    out = {"issued": now(), "jwks_key_pem": open(key_path).read(), "clients": {}}
    for c in clients:
        out["clients"][c["client_id"]] = new_client(c["secret_var"])
    json.dump(out, open(out_path, "w"))
    print("new bundle: %d clients" % len(out["clients"]))
    return 0


def cmd_add(clients_path, in_path, out_path):
    clients = json.load(open(clients_path))["clients"]
    b = json.load(open(in_path))
    for k in ("jwks_key_pem", "clients"):
        if k not in b:
            print("::error::existing bundle has no %s; refusing" % k)
            return 1
    for c in b["clients"].values():
        print("::add-mask::" + c["secret"], flush=True)
    added = []
    for c in clients:
        cid = c["client_id"]
        if cid in b["clients"]:
            continue
        b["clients"][cid] = new_client(c["secret_var"])
        added.append(cid)
    if not added:
        print("nothing to add: every declared client already has a secret")
        return 3
    b.setdefault("added", []).append({"at": now(), "clients": added})
    json.dump(b, open(out_path, "w"))
    print("added %d client(s): %s; kept %d existing client secret(s) and the JWKS key"
          % (len(added), " ".join(added), len(b["clients"]) - len(added)))
    return 0


def cmd_rotate(clients_path, in_path, out_path, cid):
    declared = {c["client_id"]: c["secret_var"] for c in json.load(open(clients_path))["clients"]}
    b = json.load(open(in_path))
    for k in ("jwks_key_pem", "clients"):
        if k not in b:
            print("::error::existing bundle has no %s; refusing" % k)
            return 1
    if cid not in declared or cid not in b["clients"]:
        print("::error::client %s is not declared and present in the bundle; refusing" % cid)
        return 1
    for c in b["clients"].values():
        print("::add-mask::" + c["secret"], flush=True)
    b["clients"][cid] = new_client(declared[cid])
    b.setdefault("rotated", []).append({"at": now(), "client": cid})
    json.dump(b, open(out_path, "w"))
    print("rotated client %s; kept %d other client secret(s) and the JWKS key" % (cid, len(b["clients"]) - 1))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 4 and a[0] == "new":
        sys.exit(cmd_new(*a[1:]))
    if len(a) == 4 and a[0] == "add":
        sys.exit(cmd_add(*a[1:]))
    if len(a) == 5 and a[0] == "rotate":
        sys.exit(cmd_rotate(*a[1:]))
    print("usage: sso-oidc-bundle.py new <clients> <jwks.key> <out> | add <clients> <in> <out> | rotate <clients> <in> <out> <client_id>", file=sys.stderr)
    sys.exit(2)
