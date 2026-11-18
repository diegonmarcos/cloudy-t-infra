#!/bin/sh
# #842 — a Ship → home-manager run evicted from ship-wg-runner BEFORE IT STARTS
# must be re-queued: bounded, never on a real failure, never authorising
# anything the original run could not (#414 [deploy-fleet] consent gate).
#
# Incident: home-manager holds ship-wg-runner at workflow level, so a queued
# run sits in the group's single pending slot and is cancelled whole by the
# next entrant. 12 consecutive runs (e.g. 37136779792, 37137915925,
# 37139060658) were dropped that way on 2026-10-03.
#
# 2026-10-14 redesign (also under test): home-manager no longer holds
# ship-wg-runner at workflow level. Its runs sit in their OWN group
# `ship-home-manager` (one running + one pending: a newer run supersedes the
# older queued one, which is safe because the gate diffs from the last covering
# run — cloud-ship-hm-supersede-range.sh), and each per-VM job takes
# ship-wg-runner itself. So Ship churn can no longer evict a home-manager run,
# and the requeue net below becomes a safety net, still verified against the
# old shared-lock premise (LEGACY scenarios) so it works if that ever returns.
#
# Fix under test: ship-reconcile.yml's out-of-group `requeue-evicted-run` job
# (sibling of #840's `requeue`). This tester reads its trigger, job `if:`, jq
# filters (EXECUTED with jq against model state), attempt bound and the API
# call straight from the workflow (source AND deployed .github copy), and runs
# them in a discrete-event model of GitHub concurrency (1 running + 1 pending
# per group; a newer entrant cancels the pending one). Sibling of
# test_ship_burst_no_dropped_deploy.sh; built-in mutation test below.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
command -v python3 >/dev/null || { echo "::error::needs python3"; exit 1; }
command -v jq >/dev/null || { echo "::error::needs jq"; exit 1; }
python3 - "$REPO_ROOT" <<'PY'
import copy, json, os, re, subprocess, sys, yaml
root = sys.argv[1]
fails = 0
HM = "Ship → home-manager"

def load(p):
    y = yaml.safe_load(open(f"{root}/{p}"))
    if True in y and "on" not in y:
        y["on"] = y.pop(True)
    return y

def expr(e, ctx):
    e = re.sub(r"\$\{\{|\}\}", "", str(e))
    e = re.sub(r"\b(github|steps|needs)(\.[A-Za-z_][\w-]*)+", lambda m: repr(ctx.get(m.group(0), "")), e)
    e = re.sub(r"\balways\(\)", "true", e)
    e = e.replace("&&", " and ").replace("||", " or ").replace("!=", " NE ").replace("!", " not ").replace(" NE ", "!=")
    return bool(eval(e, {"true": True, "false": False}, {}))

def jq(f, data, **env):
    r = subprocess.run(["jq", "-r", f], input=json.dumps(data), capture_output=True, text=True,
                       env=dict(os.environ, **{k: str(v) for k, v in env.items()}))
    if r.returncode: raise RuntimeError("jq failed: %s" % r.stderr.strip())
    return r.stdout.strip()

def model(hm, rec, sc):
    assert hm["name"] == HM
    hm_group = (hm.get("concurrency") or {}).get("group")
    hm_g = "wg" if hm_group == "ship-wg-runner" else "hm"
    wr = (rec.get("on") or {}).get("workflow_run") or {}
    on_hm = HM in (wr.get("workflows") or [])
    rjob = rec["jobs"].get("requeue-evicted-run")
    recon_if = rec["jobs"]["reconcile"].get("if", "true")
    if rjob:
        step = rjob["steps"][0]; env = step.get("env") or {}; run_txt = str(step.get("run", ""))
        MAX = int(env.get("MAX_EVICTION_REQUEUES", "1000000"))
        f_started, f_newer = env.get("EVICTED_BEFORE_START", "true"), env.get("NEWER_COVERING", "empty")
        api_rerun = re.search(r"/actions/runs/\$RUN_ID/rerun", run_txt) is not None
        api_dispatch = "dispatches" in run_txt
    if not rjob: MAX = 1
    runs = {}   # id -> run
    st = {"fleet": 0, "hist": [0], "rollback": False, "overlap": False,
          "reconcile_on_hm": 0, "ship_reruns": 0, "red": [], "reruns": 0, "bad": []}
    G = {"wg": {"running": None, "pending": None}, "hm": {"running": None, "pending": None}}
    live = set()   # home-manager runs in progress (any group): must never exceed 1
    q = []; seq = [0]
    def at(t, k, p): seq[0] += 1; q.append((t, seq[0], k, p))
    nid = [100]
    def new_run(kind, **kw):
        nid[0] += 1; r = dict(id=nid[0], kind=kind, status="queued", conclusion=None, attempt=1, started=False, **kw)
        runs[r["id"]] = r; return r
    def complete(r, concl, t):
        r["status"] = "completed"; r["conclusion"] = concl
        if concl == "failure": st["red"].append(r["id"])
        at(t + 0.01, "wr", r["id"])
    def begin(r, t):
        r["status"] = "in_progress"; r["started"] = True
        if r["kind"] == "hm":
            live.add(r["id"])
            if len(live) > 1: st["overlap"] = True
        at(t + r.get("dur", 3), "done", r["id"])
        if r.get("human_cancel_at") is not None: at(t + r["human_cancel_at"], "hcancel", r["id"])
    def start(t, g):
        g = G[g]
        if g["running"] is None and g["pending"] is not None:
            r = g["pending"]; g["pending"] = None; g["running"] = r
            begin(r, t)
    def enqueue(r, t, g):
        r["g"] = g; old = G[g]["pending"]; G[g]["pending"] = r
        if old is not None: complete(old, "cancelled", t)   # evicted before start
        start(t, g)
    def release(r, t):
        live.discard(r["id"])
        g = r.get("g")
        if g and G[g]["running"] is r: G[g]["running"] = None; start(t, g)
    for p in sc["hm"]:
        r = new_run("hm", ver=p["ver"], consent=p.get("consent", True), fail=p.get("fail", False),
                    human_cancel_at=p.get("human_cancel_at"), skipped=p.get("skipped", False))
        at(p["t"], "hm", r["id"])
    for t in sc.get("churn", []):
        at(t, "ship", None)
    while q:
        q.sort(); t, _, k, p = q.pop(0)
        if t > 3000 or len(runs) > 5000: return False, "no quiescence (requeue loop)"
        if k == "hm":
            r = runs[p]
            if r["skipped"]:     # job `if:` false (upstream gen-configs failed): no step ever runs
                r["started"] = False; complete(r, "skipped", t); continue
            if hm_group: enqueue(r, t, hm_g)
            else: begin(r, t)
        elif k == "ship":
            enqueue(new_run("ship", dur=2), t, "wg")
        elif k == "hcancel":
            r = runs[p]
            if r["status"] == "in_progress":
                complete(r, "cancelled", t); release(r, t)
        elif k == "done":
            r = runs[p]
            if r["status"] != "in_progress": continue
            if r["kind"] == "hm":
                if not r["consent"] or r["fail"]: complete(r, "failure", t)   # #414 gate red / real failure
                else:
                    if r["ver"] < st["fleet"]: st["rollback"] = True
                    st["fleet"] = r["ver"]; st["hist"].append(r["ver"]); complete(r, "success", t)
            else: complete(r, "success", t)
            release(r, t)
        elif k == "wr":
            r = runs[p]
            name = HM if r["kind"] == "hm" else "Ship"
            if name not in (wr.get("workflows") or []): continue
            ctx = {"github.event_name": "workflow_run", "github.event.workflow_run.name": name,
                   "github.event.workflow_run.conclusion": r["conclusion"],
                   "github.event.workflow_run.event": "push"}
            if r["kind"] == "hm" and expr(recon_if, ctx): st["reconcile_on_hm"] += 1
            if not rjob or not expr(rjob.get("if", "true"), ctx): continue
            jobs = {"jobs": [{"started_at": "x", "steps": [{"n": 1}]}] if r["started"] else []}
            if jq(f_started, jobs) != "true": continue
            same = [x for x in runs.values() if x["kind"] == r["kind"]]
            fx = {"workflow_runs": [{"id": x["id"], "status": x["status"], "conclusion": x["conclusion"]} for x in same]}
            if jq(f_newer, fx, RUN_ID=r["id"]): continue
            if r["attempt"] >= MAX: st["red"].append(("bound", r["id"])); continue
            if r["kind"] == "ship": st["ship_reruns"] += 1
            if r["started"] or r["conclusion"] != "cancelled":
                st["bad"].append("run %d re-queued although it was not evicted before start (%s)" % (r["id"], r["conclusion"]))
            if api_rerun:          # same run, same commit, same consent
                r.update(status="queued", conclusion=None, attempt=r["attempt"] + 1, started=False)
                st["reruns"] += 1; enqueue(r, t, hm_g if r["kind"] == "hm" else "wg")
            elif api_dispatch:     # a fresh dispatch carries its own confirm input: authorises
                n = new_run(r["kind"], ver=r.get("ver", 0), consent=True, fail=r.get("fail", False),
                            human_cancel_at=None, skipped=False)
                enqueue(n, t, hm_g if n["kind"] == "hm" else "wg")
    hmruns = [r for r in runs.values() if r["kind"] == "hm"]
    if st["overlap"]: return False, "two home-manager runs in progress at once (same VM deployed twice concurrently / order lost)"
    if st["rollback"]: return False, "fleet rolled back to an older generation: %s" % st["hist"]
    if st["reconcile_on_hm"]: return False, "home-manager completion chained a ship.yml reconcile"
    if st["ship_reruns"]: return False, "requeue re-ran %d Ship runs (not its job; #840 owns Ship)" % st["ship_reruns"]
    bad = [r["ver"] for r in hmruns if not r["consent"]]
    if any(v in st["hist"] for v in bad): return False, "unconsented generation %s reached the fleet (#414 bypassed)" % bad
    if any(r["attempt"] > MAX for r in hmruns): return False, "attempt bound exceeded"
    if st["bad"]: return False, st["bad"][0]
    if sc.get("no_red") and st["red"]: return False, "clean burst ended red (requeue thrash?): %s" % st["red"][:3]
    if sc.get("max_reruns") is not None and st["reruns"] > sc["max_reruns"]:
        return False, "%d re-runs for a burst that needs %d (evictees requeue each other)" % (st["reruns"], sc["max_reruns"])
    if sc.get("need_evictions") and not st["reruns"]: return False, "scenario never re-ran an evicted run"
    if sc.get("want_bound_red") and not any(isinstance(x, tuple) for x in st["red"]):
        return False, "persistent eviction ended without a loud (red) bound report"
    # Every consented delivery is on the fleet, or a NEWER run ended red (loud).
    want = max([r["ver"] for r in hmruns if r["consent"] and not r["fail"] and not r["skipped"]
                and r.get("human_cancel_at") is None] or [0])
    loud = any(isinstance(x, tuple) or runs[x]["kind"] == "hm" for x in st["red"])
    if st["fleet"] < want and not loud:
        return False, "delivery v%d silently dropped (fleet at v%d, reruns=%d)" % (want, st["fleet"], st["reruns"])
    if sc.get("must_reach") and st["fleet"] < sc["must_reach"]:
        return False, "fleet at v%d, expected v%d (reruns=%d)" % (st["fleet"], sc["must_reach"], st["reruns"])
    return True, "ok (fleet=v%d reruns=%d)" % (st["fleet"], st["reruns"])

churn = [0.2 + 0.7 * i for i in range(14)]
SCEN = {
  "burst": {"hm": [{"t": 0.5 + i, "ver": i + 1} for i in range(6)], "churn": churn, "must_reach": 6, "need_evictions": True, "no_red": True},
  "hm-evicts-hm": {"hm": [{"t": 0, "ver": 1}, {"t": 0.5, "ver": 2}, {"t": 0.6, "ver": 3}, {"t": 0.7, "ver": 4}], "churn": [], "must_reach": 4, "no_red": True, "max_reruns": 0},
  "unconsented-newest": {"hm": [{"t": 0.5, "ver": 1}, {"t": 1.5, "ver": 2}, {"t": 2.5, "ver": 3, "consent": False}], "churn": churn},
  "real-failure-not-requeued": {"hm": [{"t": 0.5, "ver": 1, "fail": True}], "churn": churn},
  "human-cancel-not-requeued": {"hm": [{"t": 0.0, "ver": 1, "human_cancel_at": 1}], "churn": [5]},
  "skipped-not-requeued": {"hm": [{"t": 0.5, "ver": 1, "skipped": True}], "churn": churn},
  "persistent-eviction-bounded": {"hm": [{"t": 0.5, "ver": 1}], "churn": [0.2 + 0.4 * i for i in range(400)], "want_bound_red": True},
}
# The 2026-10-14 design: home-manager in its own group, so churn never evicts
# it and a newer home-manager run supersedes the older queued one with ZERO
# re-runs (the evictee is covered by its evictor, which ships a descendant).
SCEN_OWN = {
  "own-group-burst": {"hm": [{"t": 0.5 + i, "ver": i + 1} for i in range(6)], "churn": churn, "must_reach": 6, "no_red": True, "max_reruns": 0},
  "own-group-hm-evicts-hm": SCEN["hm-evicts-hm"],
  "own-group-unconsented-newest": SCEN["unconsented-newest"],
  "own-group-real-failure": SCEN["real-failure-not-requeued"],
  "own-group-human-cancel": SCEN["human-cancel-not-requeued"],
  "own-group-skipped": SCEN["skipped-not-requeued"],
  "own-group-churn-never-evicts-hm": {"hm": [{"t": 0.5, "ver": 1}], "churn": [0.2 + 0.4 * i for i in range(400)], "must_reach": 1, "no_red": True, "max_reruns": 0},
}
def legacy(hm):
    """The same workflow under the OLD premise (workflow-level ship-wg-runner,
    one pending slot) — keeps the #842 requeue net verified as a safety net."""
    h = copy.deepcopy(hm); h["concurrency"] = {"group": "ship-wg-runner", "cancel-in-progress": False}
    return h
def check_all(hm, rec):
    return ([(n,) + model(hm, rec, s) for n, s in SCEN_OWN.items()] +
            [("legacy-" + n,) + model(legacy(hm), rec, s) for n, s in SCEN.items()])

RJ = "requeue-evicted-run"
def _env(r): return r["jobs"][RJ]["steps"][0]["env"]
def mut_no_trigger(h, r): r["on"]["workflow_run"]["workflows"] = ["Ship"]
def mut_no_job(h, r): r["jobs"].pop(RJ)
def mut_no_name_guard(h, r): r["jobs"][RJ]["if"] = r["jobs"][RJ]["if"].replace("github.event.workflow_run.name == 'Ship → home-manager' &&", "")
def mut_no_cancelled_guard(h, r): r["jobs"][RJ]["if"] = r["jobs"][RJ]["if"].replace("github.event.workflow_run.conclusion == 'cancelled'", "true")
def mut_reconcile_on_hm(h, r): r["jobs"]["reconcile"]["if"] = r["jobs"]["reconcile"]["if"].replace("github.event.workflow_run.name == 'Ship' &&", "")
def mut_no_started_check(h, r): _env(r)["EVICTED_BEFORE_START"] = "true"
def mut_no_newer_check(h, r): _env(r)["NEWER_COVERING"] = "empty"
def mut_no_attempt_bound(h, r): _env(r)["MAX_EVICTION_REQUEUES"] = "1000000"
def mut_dispatch_not_rerun(h, r):
    s = r["jobs"][RJ]["steps"][0]; s["run"] = s["run"].replace("/actions/runs/$RUN_ID/rerun", "/actions/workflows/$wf/dispatches")
def mut_hm_back_on_wg_lock(h, r): h["concurrency"] = {"group": "ship-wg-runner", "cancel-in-progress": False}
def mut_hm_no_own_group(h, r): h.pop("concurrency", None)
MUTANTS = [mut_no_trigger, mut_no_job, mut_no_name_guard, mut_no_cancelled_guard, mut_reconcile_on_hm,
           mut_no_started_check, mut_no_newer_check, mut_no_attempt_bound, mut_dispatch_not_rerun,
           mut_hm_back_on_wg_lock, mut_hm_no_own_group]

def static(hm, rec):
    out = []
    s = rec["jobs"].get(RJ) or {}
    out.append(("requeue job is outside ship-wg-runner", "concurrency" not in s))
    wc = hm.get("concurrency") or {}
    dj = hm["jobs"]["deploy"]; jc = dj.get("concurrency") or {}
    out.append(("home-manager run sits in its OWN group, not ship-wg-runner", wc.get("group") == "ship-home-manager"))
    out.append(("own group keeps only the newest pending run (no queue, no cancel-in-progress)",
                "queue" not in wc and wc.get("cancel-in-progress") is False))
    out.append(("each per-VM deploy job takes ship-wg-runner (FIFO, never cancels)",
                jc.get("group") == "ship-wg-runner" and jc.get("queue") == "max" and jc.get("cancel-in-progress") is False))
    out.append(("per-VM order kept: max-parallel 1, gcp-proxy last",
                dj["strategy"].get("max-parallel") == 1
                # matrix = plan's filtered list (cloud-ship-hm-matrix.sh keeps
                # HM_FLEET order); the declared fleet must end with gcp-proxy.
                and dj["strategy"]["matrix"]["vm"] == "${{ fromJSON(needs.plan.outputs.vms) }}"
                and hm["jobs"]["plan"]["env"]["HM_FLEET"].split()[-1] == "gcp-proxy"))
    gate = next(x for x in dj["steps"] if x.get("id") == "gate")
    out.append(("gate widens relevance to the superseded range", "cloud-ship-hm-supersede-range.sh paths" in gate["run"]))
    txt = json.dumps(s)
    out.append(("requeue never names the consent input", "confirm_fleet_deploy" not in txt))
    out.append(("dispatch token has no fallback", ("CLOUD_INFRA_DISPATCH" "_TOKEN |" "|") not in txt))
    return out

for pair in [("1_cicd/src/cicd/ship-home-manager.yml", "1_cicd/src/cicd/ship-reconcile.yml"),
             (".github/workflows/ship-home-manager.yml", ".github/workflows/ship-reconcile.yml")]:
    print("──", pair[1])
    hm, rec = load(pair[0]), load(pair[1])
    for name, ok in static(hm, rec):
        print("  %s %s" % ("ok  " if ok else "FAIL", name)); fails += (not ok)
    for name, ok, msg in check_all(hm, rec):
        print("  %s %s: %s" % ("ok  " if ok else "FAIL", name, msg)); fails += (not ok)
    for m in MUTANTS:
        h2, r2 = copy.deepcopy(hm), copy.deepcopy(rec)
        try:
            m(h2, r2); bad = [(n, msg) for n, ok, msg in check_all(h2, r2) if not ok]
        except Exception as e:
            bad = [("crash", repr(e))]
        if bad: print("  ok   mutant %s killed (%s: %s)" % (m.__name__, bad[0][0], bad[0][1][:90]))
        else:   print("  FAIL mutant %s SURVIVED" % m.__name__); fails += 1
print("FAILED: %d" % fails if fails else "PASS")
sys.exit(1 if fails else 0)
PY
