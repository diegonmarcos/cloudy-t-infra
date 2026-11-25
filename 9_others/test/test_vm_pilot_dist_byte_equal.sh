#!/usr/bin/env bash
# Guard (#1898): the committed vm-pilot renders must equal their source.
#   src : b_infra/_shared/vm-pilot/src/modules          (what home-manager reads: nixhm-sudo-<vm>/src/pilot links here)
#   dist: b_infra/_shared/vm-pilot/dist/modules         (shared render, b_infra/_shared/vm-pilot/build.sh)
#   dist: b_infra/nixhm-sudo-<vm>/dist/pilot            (per-VM render, the home-manager engine's step_build)
#
# Why: the ship engine re-renders the per-VM dist from src on every deploy, so a stale committed dist
# never reached a VM. But it misled every reader: on 2026-11-25 the shared dist and all four per-VM
# dist/pilot trees were stale (40 of 76 files differed, 6 files missing, among them the load-shedder
# recovery edge and boot-start-declared), so a read of dist said "recovery is a manual ship" while the
# deployed src declares a docker start. The committed copy is the one humans and reviewers read.
#
# Comparison ignores only the GENERATED banner (comment lines "# ╔ ║ ╚" plus the blank line the engine
# adds either side of it) and the "_generated" meta-key plus the GENERATED "description" of JSON files. Symlinks (out-of-tree inputs that
# test_hm_ship_path_relevance.sh requires to stay links) are compared by target, not content.
# Mutation self-check: a scratch copy with one changed line, one missing file and one extra file must
# each turn the comparison red.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
[ -e "$ROOT/.git" ] || ROOT="$(cd "$ROOT/.." && pwd)"
SRC="$ROOT/b_infra/_shared/vm-pilot/src/modules"
fail=0; ok(){ echo "  ok   $1"; }; bad(){ echo "  FAIL $1"; fail=1; }

cmp_tree() { # $1 src dir, $2 dist dir -> prints one line per drift, exit 1 when any
python3 -I - "$1" "$2" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
BAN = ("# ╔", "# ║", "# ╚", "// ╔", "// ║", "// ╚")
def norm(path):
    raw = open(path, "rb").read()
    try: txt = raw.decode("utf-8")
    except UnicodeDecodeError: return raw
    if path.endswith(".json"):
        try:
            d = json.loads(txt)
            if isinstance(d, dict):
                d.pop("_generated", None)
                if str(d.get("description", "")).startswith("\u26a0 GENERATED"): d.pop("description")
            return json.dumps(d, sort_keys=True).encode()
        except ValueError: pass
    lines = txt.split("\n"); out = []; i = 0
    while i < len(lines):
        if lines[i].startswith(BAN):
            if out and out[-1] == "": out.pop()
            while i < len(lines) and lines[i].startswith(BAN): i += 1
            if i < len(lines) and lines[i] == "": i += 1
            continue
        out.append(lines[i]); i += 1
    return "\n".join(out).encode()
def files(root):
    r = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if "__pycache__" in p: continue
            r[os.path.relpath(p, root)] = p
    return r
s, d = files(src), files(dst)
bad = 0
for rel in sorted(set(s) | set(d)):
    if rel not in d: print("MISSING in dist: " + rel); bad += 1; continue
    if rel not in s: print("EXTRA in dist (not in src): " + rel); bad += 1; continue
    ls, ld = os.path.islink(s[rel]), os.path.islink(d[rel])
    if ls or ld:
        if ls != ld or os.path.realpath(s[rel]) != os.path.realpath(d[rel]):
            print("LINK differs: " + rel); bad += 1
        continue
    if norm(s[rel]) != norm(d[rel]): print("DIFFERS: " + rel); bad += 1
sys.exit(1 if bad else 0)
PY
}

echo "1. shared dist and every per-VM dist/pilot equal src/modules"
trees="$ROOT/b_infra/_shared/vm-pilot/dist/modules"
for d in "$ROOT"/b_infra/nixhm-sudo-*/dist/pilot; do [ -d "$d" ] && trees="$trees $d"; done
n=0
for t in $trees; do
  n=$((n+1))
  if out=$(cmp_tree "$SRC" "$t"); then ok "${t#"$ROOT/"}"
  else bad "${t#"$ROOT/"} drifts from src ($(printf '%s\n' "$out" | wc -l) file(s)); run b_infra/_shared/vm-pilot/build.sh build and the nixhm build.sh build"; printf '%s\n' "$out" | head -8 | sed 's/^/         /'; fi
done
[ "$n" -ge 5 ] && ok "checked $n trees (shared + four VMs)" || bad "expected 5 trees, found $n"

echo "2. recovery edge is in every copy that a reader can open"
for t in $trees; do
  grep -q 'timeout 120 systemctl start docker.service' "$t/protection/load-shedder.nix" && ok "docker start in ${t#"$ROOT/"}" || bad "no docker start edge in ${t#"$ROOT/"}"
done

echo "3. mutation: the comparison must go red"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -a "$ROOT/b_infra/_shared/vm-pilot/dist/modules" "$T/dist"
# relative links break in the scratch dir: re-point each at the absolute path the original resolves to
( cd "$ROOT/b_infra/_shared/vm-pilot/dist/modules" && find . -type l ) | while read -r l; do
  ln -sfn "$(realpath "$ROOT/b_infra/_shared/vm-pilot/dist/modules/$l")" "$T/dist/$l"
done
cmp_tree "$SRC" "$T/dist" >/dev/null && ok "scratch copy of a clean dist is green" || bad "scratch copy not green (cannot mutate)"
f="$T/dist/protection/load-shedder.nix"
grep -v 'timeout 120 systemctl start docker.service' "$f" > "$f.n" && mv "$f.n" "$f"
cmp_tree "$SRC" "$T/dist" >/dev/null && bad "a removed line was NOT caught" || ok "removed recovery line caught"
cp "$ROOT/b_infra/_shared/vm-pilot/dist/modules/protection/load-shedder.nix" "$f"
rm -f "$T/dist/protection/boot-start-declared.nix"
cmp_tree "$SRC" "$T/dist" >/dev/null && bad "a missing file was NOT caught" || ok "missing file caught"
cp "$ROOT/b_infra/_shared/vm-pilot/dist/modules/protection/boot-start-declared.nix" "$T/dist/protection/"
echo "# stray" > "$T/dist/protection/stale-extra.nix"
cmp_tree "$SRC" "$T/dist" >/dev/null && bad "an extra file was NOT caught" || ok "extra file caught"

[ "$fail" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
