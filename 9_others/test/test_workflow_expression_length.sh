#!/bin/sh
# GitHub refuses to parse a workflow when any string that carries a ${{ }}
# expression is 21000 chars or longer ("Exceeded max expression length"):
# the run is never created, push-triggered or dispatched. Ship broke this way
# after #1886 (the detect matrix script grew past the cap). Every workflow in
# .github/workflows must keep each expression-bearing string under the cap.
# Mutation: a synthetic workflow with a 21000-char expression-bearing run
# block must be reported red, so the check cannot pass vacuously.
set -eu
ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
check() {
python3 - "$@" <<'PY'
import sys, yaml
CAP = 21000
bad = 0
def walk(o, path, f):
    global bad
    if isinstance(o, dict):
        for k, v in o.items(): walk(v, f"{path}/{k}", f)
    elif isinstance(o, list):
        for i, v in enumerate(o): walk(v, f"{path}[{i}]", f)
    elif isinstance(o, str) and "${{" in o and len(o) >= CAP:
        print(f"RED {f}{path}: {len(o)} chars with an expression (cap {CAP})")
        bad = 1
for f in sys.argv[1:]:
    try:
        walk(yaml.safe_load(open(f)), "", f)
    except yaml.YAMLError as e:
        print(f"RED {f}: YAML error {e}"); bad = 1
sys.exit(bad)
PY
}
check "$ROOT"/.github/workflows/*.yml "$ROOT"/1_cicd/src/cicd/*.yml
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 -c "
print('on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |')
print('          echo \"\${{ github.event_name }}\"')
for i in range(400): print('          # ' + 'x'*60)
" > "$TMP/mut.yml"
if check "$TMP/mut.yml" >/dev/null; then
  echo "RED mutation: a 21000+ char expression-bearing run block was not caught"; exit 1
fi
echo "OK workflow expression strings are under 21000 chars; mutation caught"
