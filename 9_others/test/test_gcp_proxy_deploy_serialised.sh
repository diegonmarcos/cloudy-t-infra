#!/bin/sh
# #1898: the 944 MB gcp-proxy hub thrashed 2026-11-24 23:25Z (edge dark ~90 s) while a services
# recreate and a home-manager run overlapped there. Every job that deploys to the hub (ship.yml
# deploy, ship-home-manager.yml deploy, ship-reconcile.yml requeue/deploy) must sit in the SAME
# job-level concurrency group, with cancel-in-progress:false (a cancelled deploy is a half
# recreated hub) and queue:max (FIFO, no eviction), so two of them can never run side by side.
# Mutation-proven: SHIP_ROOT=<copy> with a deploy job moved to another group, or with
# cancel-in-progress:true, must make this exit 1.
# Usage: sh 9_others/test/test_gcp_proxy_deploy_serialised.sh [workflows-src-dir]
set -eu
ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DIR="${1:-$ROOT/1_cicd/src/cicd}"
GROUP="ship-wg-runner"
python3 - "$DIR" "$GROUP" <<'PY'
import sys, os, yaml
d, group = sys.argv[1], sys.argv[2]
fail = 0
def ck(name, ok, detail=""):
    global fail
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else " (" + detail + ")"))
    if not ok: fail += 1
def load(f):
    with open(os.path.join(d, f)) as fh: return yaml.safe_load(fh)
def conc(n):
    c = (n or {}).get("concurrency")
    if isinstance(c, str): return {"group": c}
    return c if isinstance(c, dict) else {}
# (workflow, job) pairs that touch gcp-proxy
targets = [("ship.yml", "deploy"), ("ship-home-manager.yml", "deploy")]
for wf, job in targets:
    w = load(wf)
    j = (w.get("jobs") or {}).get(job)
    ck(f"{wf}:{job} exists", j is not None)
    if j is None: continue
    c = conc(j)
    ck(f"{wf}:{job} job-level group is {group}", c.get("group") == group, str(c.get("group")))
    ck(f"{wf}:{job} cancel-in-progress is false", c.get("cancel-in-progress") is False, str(c.get("cancel-in-progress")))
    ck(f"{wf}:{job} queue is max", c.get("queue") == "max", str(c.get("queue")))
    wc = conc(w)
    ck(f"{wf} workflow-level group (if any) never cancels", wc.get("cancel-in-progress") in (None, False), str(wc))
# the home-manager fleet must still list gcp-proxy (so the guard is about a real path)
hm = open(os.path.join(d, "ship-home-manager.yml")).read()
ck("home-manager fleet includes gcp-proxy", "gcp-proxy" in hm)
# no OTHER workflow job that deploys gcp-proxy may declare a different group
for f in sorted(os.listdir(d)):
    if not f.endswith(".yml") or f in dict(targets): continue
    w = load(f)
    for jn, j in (w.get("jobs") or {}).items():
        c = conc(j)
        if "ship-" in str(c.get("group", "")) and c.get("group") != group and "gcp-proxy" in str(j):
            ck(f"{f}:{jn} gcp-proxy job uses {group}", False, str(c.get("group")))
print("FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
PY
