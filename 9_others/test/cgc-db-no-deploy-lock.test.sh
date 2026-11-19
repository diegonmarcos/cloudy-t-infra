#!/bin/sh
# #1817 - cgc-db (and every non-deploy workflow) must not sit on the fleet deploy lock.
#
# Incident: the scheduled cgc-db run (1.5-4 h) queued production Ships behind it for
# hours. The lock is the concurrency group `ship-wg-runner`. Rules enforced here, by
# parsing the workflow YAML (source 1_cicd/src/cicd and the deployed .github/workflows):
#   1. cgc-db.yml / cgc-db-index.yml: no workflow-level ship-wg-runner; the only job
#      that holds it is `restore-all` (the oci-apps step), bounded to <= 120 min.
#   2. cgc-db.yml itself serialises on its OWN group (`cgc-db`) with queue: max
#      (no-eviction semantics stay; see cgc-db-queue-no-eviction.test.sh).
#   3. Outside the Ship/deploy family (ship*.yml, unjam-ship.yml), a workflow may hold
#      the lock at workflow level only if it is a single-job workflow (so lock time ==
#      that job's time); any job holding it must have timeout-minutes <= 120.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
command -v python3 >/dev/null || { echo "::error::needs python3"; exit 1; }
python3 - "$REPO_ROOT" <<'PY'
import sys, glob, os, yaml
root = sys.argv[1]; LOCK = "ship-wg-runner"; MAXMIN = 120
fails = 0; checks = 0
def ck(name, ok):
    global fails, checks
    checks += 1
    print(("  ok   " if ok else "  FAIL ") + name)
    if not ok: fails += 1
def grp(c): return c.get("group") if isinstance(c, dict) else c
def holds(c): return LOCK in str(grp(c) or "")
def family(path):
    b = os.path.basename(path); return b.startswith("ship") or b.startswith("unjam-ship")
for d in ("1_cicd/src/cicd", ".github/workflows"):
    files = sorted(glob.glob(os.path.join(root, d, "*.yml")))
    ck(f"{d}: workflows found (guards a vacuous pass)", len(files) > 20)
    for f in files:
        y = yaml.safe_load(open(f)); jobs = y.get("jobs") or {}; b = f"{d}/{os.path.basename(f)}"
        wl = holds(y.get("concurrency"))
        if family(f):
            continue
        if wl:
            ck(f"{b}: workflow-level lock only on a single-job workflow",
               len(jobs) == 1 and not any("uses" in j for j in jobs.values()))
        for n, j in jobs.items():
            if holds(j.get("concurrency")) or wl:
                t = j.get("timeout-minutes")
                ck(f"{b}: job {n} holds the lock with timeout <= {MAXMIN} min (got {t})",
                   isinstance(t, int) and t <= MAXMIN)
    for n in ("cgc-db.yml", "cgc-db-index.yml"):
        p = os.path.join(root, d, n)
        if not os.path.exists(p): ck(f"{d}/{n} exists", False); continue
        y = yaml.safe_load(open(p))
        ck(f"{d}/{n}: no workflow-level {LOCK}", not holds(y.get("concurrency")))
        holders = sorted(k for k, j in (y.get("jobs") or {}).items() if holds(j.get("concurrency")))
        ck(f"{d}/{n}: only restore-all may hold the lock (holders: {holders})", holders in ([], ["restore-all"]))
        if n == "cgc-db-index.yml":
            ck(f"{d}/{n}: restore-all holds it (the oci-apps step needs the mesh)", holders == ["restore-all"])
            ck(f"{d}/{n}: index job holds no concurrency group", not (y["jobs"]["index"].get("concurrency")))
        else:
            c = y.get("concurrency") or {}
            ck(f"{d}/{n}: own group cgc-db, queue max, no cancel",
               c.get("group") == "cgc-db" and c.get("queue") == "max" and c.get("cancel-in-progress") is False)
print(f"--- {checks - fails} passed, {fails} failed")
sys.exit(1 if fails else 0)
PY
