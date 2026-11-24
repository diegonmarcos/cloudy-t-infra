#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_ship_deploy_gate.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# A Ship run that detected services to ship and then did not ship them must be RED.
#
# 2026-09-09, run 34334421319: detect logged "detect: a_solutions
# af913083..902bbba9" and "VMs: 1 - oci-apps", Build -> oci-apps pushed the
# my-ai_claude-api image successfully, and Deploy -> oci-apps then ran ZERO
# steps. It was evicted from the fleet-wide ship-wg-runner concurrency group
# (GitHub keeps exactly one pending entry per group, so the next
# containers-push displaces the one waiting) while a wedged cgc-db run held
# the slot. The run ended "cancelled": grey in the UI, no notification,
# indistinguishable from a human pressing cancel. The commit sat in git, the
# image sat in GHCR, and oci-apps kept serving three-hour-old code behind a
# Ship page that looked idle.
#
# The gate turns that silence into a failure. `always()` is load-bearing: a job
# cancelled by concurrency does not cancel the run, which is the only reason a
# downstream job can observe the eviction at all.
set -eu
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }

# ── Structure: the gate exists and is wired to see a cancelled deploy ──
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  ck "$f: deploy-gate job declared" \
     "$(python3 -c 'import yaml,sys; print("deploy-gate" in yaml.safe_load(open(sys.argv[1]))["jobs"])' "$Y")" "True"
  # Without detect in needs its outputs are not guaranteed to be readable, and
  # without deploy the gate has no result to judge.
  ck "$f: deploy-gate needs detect, build and deploy" \
     "$(python3 -c 'import yaml,sys; print(sorted(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["needs"]))' "$Y")" \
     "['build', 'deploy', 'detect']"
  ck "$f: deploy-gate runs unconditionally (always())" \
     "$(python3 -c 'import yaml,sys; print("always()" in yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["if"])' "$Y")" "True"
done

# ── Guard: a registered service resolving to zero VMs must not report success ──
for f in 1_cicd/src/cicd/ship.yml .github/workflows/ship.yml; do
  Y="$REPO_ROOT/$f"
  ck "$f: zero-VM guard fails on a registered service" \
     "$(grep -c 'the service→vm mapping in build-gha.json is broken' "$Y" || true)" "1"
  ck "$f: zero-VM guard stays green for a non-service dir" \
     "$(grep -c '::notice::changed but not a deployable container service' "$Y" || true)" "1"
done

# ── Behaviour: run the gate's own script, as shipped ──
# Extracted from the generated workflow rather than restated here, so the test
# cannot drift into asserting a copy of the logic that no longer ships.
GATE="$(mktemp)"
YML="$REPO_ROOT/.github/workflows/ship.yml"
python3 -c 'import yaml,sys; sys.stdout.write(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["steps"][0]["run"])' \
  "$YML" > "$GATE"

# The gate body runs `set -eu`. An env var it reads that this test never sets is
# therefore an UNBOUND VARIABLE: sh dies with exit 2 before printing a single
# line, and every behavioural case below degrades into a meaningless
# "want '1', got '2'" that says nothing about the gate's actual behaviour.
#
# That is not hypothetical. This test was written 2026-09-09 against a gate that
# read three variables. #401's rewrite (c942be58f) added DETECT_RESULT, VERDICT
# and HAS_VMS, this test kept exporting the original three, and all five
# behavioural cases silently stopped testing the gate — they were asserting the
# exit code of an unbound-variable crash. Phase 55 caught it the first time it
# ever ran to completion (run 35169520755).
#
# So assert the agreement rather than assume it: every env key the step declares
# must be one this test knows how to supply. When someone extends the gate
# again, this fails FIRST, by name, instead of poisoning everything below it.
KNOWN_ENV=' DETECT_RESULT VERDICT HAS_VMS BUILD_RESULT DEPLOY_RESULT MATRIX HELD '
UNSUPPLIED=''
for k in $(python3 -c 'import yaml,sys; print(" ".join(sorted(yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy-gate"]["steps"][0].get("env",{}))))' "$YML"); do
  case "$KNOWN_ENV" in *" $k "*) ;; *) UNSUPPLIED="$UNSUPPLIED $k" ;; esac
done
ck "every env var the gate declares is one this test supplies" "${UNSUPPLIED# }" ""

MATRIX='{"include":[{"vm":"oci-apps","changed_dirs":"user-ai_my-ai_claude-api"}]}'
# Deliberately NOT exported. ce2cc7698 fixed the crash by exporting a known-good
# env once at the top, which works — but an inherited default is how this test
# drifted in the first place: a case that forgets a variable silently borrows the
# previous one's value instead of failing. run_gate below passes all six
# explicitly per case, so each case states its own whole run-shape.

# Positional, so every case states the whole run-shape it is describing rather
# than inheriting half of it from an earlier export.
#   run_gate <detect_result> <verdict> <has_vms> <build_result> <deploy_result> [held]
# held (#1886) is the auth-plane dirs detect held out; empty unless a case names it.
run_gate() {
  env DETECT_RESULT="$1" VERDICT="$2" HAS_VMS="$3" BUILD_RESULT="$4" \
      DEPLOY_RESULT="$5" MATRIX="$MATRIX" HELD="${6:-}" sh "$GATE" >"$GATE.out" 2>&1
}

# ── A deploy WAS required (verdict=ship) ──
run_gate success ship true success success && rc=0 || rc=$?
ck "gate passes when the deploy succeeded" "$rc" "0"

run_gate success ship true success cancelled && rc=0 || rc=$?
ck "gate FAILS on an evicted (cancelled) deploy" "$rc" "1"
ck "gate names the undeployed service" \
   "$(grep -c 'user-ai_my-ai_claude-api' "$GATE.out" || true)" "1"
ck "gate points at unjam-ship for a cancelled deploy" \
   "$(grep -c 'unjam-ship' "$GATE.out" || true)" "1"

# #560: the deploy engine now FAILS on a declared container left in `created`
# (step_compose's liveness gate). The gate is where that reaches the run, and
# it must say what a failed deploy may mean — ps and digests both lied.
run_gate success ship true success failure && rc=0 || rc=$?
ck "gate FAILS on a failed deploy" "$rc" "1"
ck "gate points a failed deploy at the liveness verdict (#560)" \
   "$(grep -c "liveness: DEAD" "$GATE.out" || true)" "1"
run_gate success ship true success cancelled && rc=0 || rc=$?
ck "a cancelled deploy is not told about liveness" \
   "$(grep -c "liveness: DEAD" "$GATE.out" || true)" "0"

# skipped is what a build failure leaves behind; the services are still absent
# from the fleet, so the gate must be just as loud.
run_gate success ship true skipped skipped && rc=0 || rc=$?
ck "gate FAILS when deploy was skipped" "$rc" "1"

# A containers-push whose diff resolved to no deployable service. detect did not
# prove there was nothing to ship, it failed to find what there was — so this is
# the #401 hollow green and must be red, with the reason named.
run_gate success empty false skipped skipped && rc=0 || rc=$?
ck "gate FAILS on verdict=empty" "$rc" "1"
# Anchored on the explanatory clause, not on "verdict='empty'" alone: the
# generic error line above it interpolates $VERDICT too, so the bare string
# matches twice and a count of 1 would be wrong.
ck "gate explains what verdict=empty means" \
   "$(grep -c "the containers-push diff resolved to no deployable service" "$GATE.out" || true)" "1"

# #1886: every changed service was auth plane and the fan-out hold kept it out.
# Nothing deployed, so the run is red, and it must name the approved dispatch.
run_gate success held false skipped skipped infra-sec_caddy && rc=0 || rc=$?
ck "gate FAILS on verdict=held" "$rc" "1"
ck "gate names the explicit dispatch for a held auth plane" \
   "$(grep -c "services=infra-sec_caddy" "$GATE.out" || true)" "2"
# A shipped run that also held something stays green, with the hold as a warning.
run_gate success ship true success success infra-sec_authelia && rc=0 || rc=$?
ck "a run that shipped and held the auth plane is green" "$rc" "0"
ck "...and warns about the hold" "$(grep -c "auth plane held out of this Ship" "$GATE.out" || true)" "1"

# ── Green BY DECLARATION, not by omission — the other half of #401 ──
# Untested until 2026-09-17: the gate's whole purpose is telling these two
# legitimate no-ops apart from the hollow green above, and nothing asserted it.
run_gate success nothing-to-ship false skipped skipped && rc=0 || rc=$?
ck "gate is GREEN when detect proved nothing to ship" "$rc" "0"

run_gate success '' '' skipped skipped && rc=0 || rc=$?
ck "gate is GREEN for a path-irrelevant upstream commit" "$rc" "0"

# detect itself is the basis for every judgement above. If it did not succeed,
# there is no basis, and no amount of downstream green may conclude success.
run_gate failure '' '' skipped skipped && rc=0 || rc=$?
ck "gate FAILS when detect itself did not succeed" "$rc" "1"
ck "gate names detect as the thing to investigate" \
   "$(grep -c 'Investigate the detect job itself' "$GATE.out" || true)" "1"

rm -f "$GATE" "$GATE.out"
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
