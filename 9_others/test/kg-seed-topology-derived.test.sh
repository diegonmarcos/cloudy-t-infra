#!/usr/bin/env bash
# Guards seed_from_config.sh against the defect it was named for (#387).
#
# The script is called seed_from_config.sh and it did read the topology
# declaration — for VM identity, service lists and hosted_on edges. But the
# WireGuard addresses, arch, CPU and RAM were restated inside it as literals
# under the comment "hardcoded from cloud architecture", and they drifted:
#
#   - oci-A1-f_1 (10.0.0.2) and oci-A1-p_0 (10.0.0.7) stayed in the table after
#     both VMs were decommissioned. Neither is a typo; their declarations are
#     archived under b_infra/z_archive/vm_oci-A1-f_1/ and vm_oci-A1-p_0/. The
#     declared mesh is four VMs.
#   - the generator built the WireGuard mesh from those keys, so it emitted 15
#     connected_to edges where the declaration supports 6, and 9 of the 15
#     RELATEd to vm: nodes it had never CREATEd. A dangling edge in a knowledge
#     graph does not raise; it answers questions wrongly.
#   - it also recorded oci-A1-f_0 as 3 CPU / 16 GB against a declared 4 / 24.
#
# Correcting the literals would have left the next decommission free to do this
# again, so the tables are derived now. These assertions are what stops them
# coming back, and they are behavioural: a grep alone would not have caught the
# dangling edges, which were the actual damage.
#
# A missing script or declaration is a FAILURE, never a skip (#368).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED="$ROOT/a_solutions/user-ai_cloud-me-cgc-pvt-graph-api/scripts/seed_from_config.sh"
SEED_PUB="$ROOT/a_solutions/user-ai_cloudy-cgc-pub-graph-api/scripts/seed_from_config.sh"
TOPOLOGY="$ROOT/1_cloud-configs/dist/_cloud-data-consolidated.json"

failed=0

for required in "$SEED" "$TOPOLOGY"; do
    if [ ! -f "$required" ]; then
        echo "::error::$required not found — cloud-u-containers is checked out into a_solutions by the workflow; without it this guard is unrun, not passing."
        exit 1
    fi
done

command -v python3 >/dev/null || { echo "::error::python3 is required"; exit 1; }

# ── 1. No WireGuard address may be written into the script ──────────────
# The mesh is declared per VM as vms[*].wg_ip. Any 10.0.0.x literal here is the
# table growing back.
wg_literals="$(grep -nE '"?10\.0\.0\.[0-9]+"?' "$SEED" | grep -vE '^[0-9]+: *#' || true)"
if [ -n "$wg_literals" ]; then
    echo "$wg_literals"
    echo "::error::seed_from_config.sh contains a hardcoded WireGuard address. The mesh is declared at vms[*].wg_ip in the topology this script already opens; restating it here is what #387 was."
    failed=$((failed + 1))
else
    echo "  ok — no WireGuard address is hardcoded in the seeder"
fi

# ── 2. The second copy must not be a second source of truth ─────────────
# kg-store-pub carried a byte-identical copy. #170 is the standing warning that
# a classification restated in a second file drifts, and two copies of one
# 300-line generator is the worst case of it.
if [ ! -L "$SEED_PUB" ]; then
    echo "::error::$SEED_PUB is not a symlink. It was a byte-identical duplicate of the kg-store seeder; a second copy drifts (#170). It must point at the original, not restate it."
    failed=$((failed + 1))
elif [ ! -e "$SEED_PUB" ]; then
    echo "::error::$SEED_PUB is a symlink that does not resolve. A dangling link is not single-sourcing."
    failed=$((failed + 1))
else
    echo "  ok — kg-store-pub links to the kg-store seeder rather than copying it"
fi

# ── 3. Behavioural: the emitted mesh matches the declaration exactly ─────
# Captured in ONE invocation so the exit status belongs to python3 and not to a
# pipe.
verdict="$(ROOT="$ROOT" SEED="$SEED" TOPOLOGY="$TOPOLOGY" python3 <<'PYEOF' 2>&1
import itertools, json, os, re, subprocess, sys, tempfile

seed = open(os.environ["SEED"]).read()
try:
    generator = seed.split("SEED_SQL=$(python3 << 'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
except IndexError:
    print("FAIL: could not find the embedded python generator in seed_from_config.sh")
    sys.exit(1)

topology = os.environ["TOPOLOGY"]
declared = json.load(open(topology))["vms"]

with tempfile.TemporaryDirectory() as tmp:
    gen_path = os.path.join(tmp, "generator.py")
    open(gen_path, "w").write(generator)
    counts_path = os.path.join(tmp, "counts")
    env = dict(os.environ, CONFIG_JSON=topology, SEED_COUNTS=counts_path)
    run = subprocess.run([sys.executable, gen_path], capture_output=True, text=True, env=env)

if run.returncode != 0:
    print(f"FAIL: generator exited {run.returncode}\n{run.stderr}")
    sys.exit(1)

sql = run.stdout
created = set(re.findall(r"CREATE vm:([A-Za-z0-9_]+)", sql))
edges = re.findall(r"RELATE vm:([A-Za-z0-9_]+)->connected_to->vm:([A-Za-z0-9_]+)", sql)

if not created:
    print("FAIL: the generator emitted no vm nodes at all — it cannot have read the declaration")
    sys.exit(1)

# Every endpoint of every mesh edge must be a node the same run created.
dangling = [f"{a}->{b}" for a, b in edges if a not in created or b not in created]
if dangling:
    print("FAIL: connected_to edges naming a vm node that was never CREATEd: " + ", ".join(dangling))
    sys.exit(1)

# The mesh is exactly the declared wg_ip holders that also became nodes.
mesh = sorted(
    k.replace("-", "_")
    for k, v in declared.items()
    if v.get("wg_ip") and k.replace("-", "_") in created
)
expected = len(list(itertools.combinations(mesh, 2)))
if len(edges) != expected:
    print(f"FAIL: {len(edges)} connected_to edges for a declared mesh of {len(mesh)} VMs; expected {expected}")
    sys.exit(1)

# Hardware facts must match the declaration, not a remembered number.
for vm_id, vm in declared.items():
    node = vm_id.replace("-", "_")
    if node not in created:
        continue
    block = re.search(r"CREATE vm:" + node + r" CONTENT \{(.*?)\n\};", sql, re.S)
    if not block:
        print(f"FAIL: could not read back the emitted node for {vm_id}")
        sys.exit(1)
    body = block.group(1)
    specs = vm.get("specs") or {}
    for field, declared_value in (("cpu_count", specs.get("cpu")), ("ram_gb", specs.get("ram_gb"))):
        emitted = re.search(field + r": ([^,\n]+)", body)
        if not emitted:
            print(f"FAIL: {vm_id} emitted no {field}")
            sys.exit(1)
        got = emitted.group(1).strip()
        want = "NONE" if not declared_value else str(declared_value)
        if got != want:
            print(f"FAIL: {vm_id} {field} emitted {got}, declaration says {want}")
            sys.exit(1)

print(f"PASS: {len(mesh)} declared mesh VMs, {len(edges)} connected_to edges, 0 dangling, hardware facts match the declaration")
PYEOF
)"
status=$?
echo "$verdict"

if [ "$status" -ne 0 ] || ! echo "$verdict" | grep -q '^PASS: '; then
    echo "::error::the seeder's emitted topology does not match the declaration"
    failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
    echo "::error::$failed kg-seed topology assertion(s) failed"
    exit 1
fi

echo "kg-store seeder is derived from the topology declaration: all assertions passed"
