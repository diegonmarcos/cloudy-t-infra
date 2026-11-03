#!/usr/bin/env python3
"""Guard for the Cloud Run fleet registry (c_vps/vps_gcloud/src/terraform.json cloud_run_services).

Asserts every entry is complete and carries no secret value: secrets are Secret Manager NAMES only, plain env holds no
credential-looking key, managed entries are real states. Each assertion is then proven red by its own mutation.
  python3 c_vps/vps_gcloud/test/test-cloud-run.py [terraform.json]
"""
import copy, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "src", "terraform.json")
REQ = ("name", "label", "managed", "state", "region", "source", "image", "port", "cpu", "memory", "max_instances",
       "invoker", "env", "secret_env", "volumes", "persistence", "route")
STATES = {"live-unmanaged", "live-managed", "declared"}
SECRETISH = re.compile(r"(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|PRIVATE)", re.I)
SM_NAME = re.compile(r"^[a-z][a-z0-9-]{2,62}$")
VALUE_LIKE = re.compile(r"(GOCSPX-|AIza|ghp_|github_pat_|-----BEGIN|\.apps\.googleusercontent\.com)")


def check(cfg):
    bad = []
    svcs = cfg.get("cloud_run_services")
    if not isinstance(svcs, list) or not svcs:
        return ["cloud_run_services missing or empty"]
    names = [s.get("name") for s in svcs]
    if len(names) != len(set(names)):
        bad.append("duplicate service names")
    for s in svcs:
        n = s.get("name", "?")
        miss = [k for k in REQ if k not in s]
        if miss:
            bad.append("%s: missing %s" % (n, miss))
            continue
        if s["state"] not in STATES:
            bad.append("%s: state %r not in %s" % (n, s["state"], sorted(STATES)))
        if s["managed"] and s["state"] == "live-unmanaged":
            bad.append("%s: managed=true on a live-unmanaged service (terraform import first, then state live-managed)" % n)
        if s["invoker"] not in ("iam", "public"):
            bad.append("%s: invoker must be iam or public" % n)
        if not str(s["image"]).startswith(("us-central1-docker.pkg.dev/", "europe-")):
            bad.append("%s: image must be an Artifact Registry path Cloud Run can pull" % n)
        for k, v in s["env"].items():
            if SECRETISH.search(k):
                bad.append("%s: env %s looks like a credential; use secret_env with a Secret Manager name" % (n, k))
            if VALUE_LIKE.search(str(v)):
                bad.append("%s: env %s carries a credential-looking value" % (n, k))
        for k, v in s["secret_env"].items():
            if not SM_NAME.match(str(v)) or VALUE_LIKE.search(str(v)):
                bad.append("%s: secret_env %s must be a Secret Manager name, not a value" % (n, k))
        for v in s["volumes"]:
            if not (v.get("name") and v.get("bucket") and str(v.get("mount_path", "")).startswith("/")):
                bad.append("%s: volume needs name, bucket, absolute mount_path" % n)
    blob = json.dumps(svcs)
    if VALUE_LIKE.search(blob):
        bad.append("a credential-looking value appears in cloud_run_services")
    return bad


def mutations(cfg):
    def m(f):
        c = copy.deepcopy(cfg); f(c["cloud_run_services"]); return c
    yield "missing key", m(lambda s: s[0].pop("image"))
    yield "bad state", m(lambda s: s[0].__setitem__("state", "running"))
    yield "managed live-unmanaged", m(lambda s: [x.__setitem__("managed", True) for x in s if x["state"] == "live-unmanaged"] or s[0].update(state="live-unmanaged", managed=True))
    yield "secret in env", m(lambda s: s[0]["env"].__setitem__("OAUTH_CLIENT_SECRET", "x"))
    yield "secret value in secret_env", m(lambda s: s[0]["secret_env"].__setitem__("X", "GOCSPX-abcdefabcdef"))
    yield "duplicate name", m(lambda s: s.append(copy.deepcopy(s[0])))
    yield "ghcr image", m(lambda s: s[0].__setitem__("image", "ghcr.io/x/y:latest"))
    yield "bad volume", m(lambda s: s[0]["volumes"].append({"name": "v"}))


def main():
    cfg = json.load(open(SRC, encoding="utf-8"))
    bad = check(cfg)
    for b in bad:
        print("FAIL", b)
    unproven = [name for name, mc in mutations(cfg) if not check(mc)]
    for u in unproven:
        print("NOT PROVEN RED:", u)
    if bad or unproven:
        return 1
    print("cloud run registry: %d services green, %d mutations proven red" % (len(cfg["cloud_run_services"]), sum(1 for _ in mutations(cfg))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
