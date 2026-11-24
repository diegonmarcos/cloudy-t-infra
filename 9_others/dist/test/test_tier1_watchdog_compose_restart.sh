#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_tier1_watchdog_compose_restart.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: tier1-watchdog restarts a tier-1 container through its compose project,
# so its depends_on (authelia-redis) comes back with it (#1886).
#
# During 02:50-03:10Z on 2026-11-24 authelia-redis was stopped (exit 143) and
# authelia exited 1. The watchdog looked for /opt/containers/<name>/docker-
# compose.yml, which the v2 layout never has, fell back to `docker start
# authelia`, and authelia re-died without redis until the circuit opened.
# This extracts the rendered watchdog script from tier1-apps.nix (the nix ''
# string, with its ''${ escapes undone) and drives restart_tier1 against a
# stub docker that answers the compose labels the deploy stamps.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NIX="$ROOT/b_infra/_shared/vm-pilot/src/modules/protection/tier1-apps.nix"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (expected '$3', got '$2')"; fi; }

awk '/tier1-watchdog.sh" = \{/{f=1} f&&/text = '"''"'/{g=1;next} g&&/^    '"''"';/{exit} g' "$NIX" \
  | sed "s/''\\\${/\${/g" > "$WORK/wd.sh"
bash -n "$WORK/wd.sh" || { echo "FAIL: rendered watchdog script does not parse"; exit 1; }
grep -q '/opt/containers/\$svc' "$WORK/wd.sh" && { echo "FAIL: watchdog still guesses /opt/containers/<container>"; exit 1; }
# Only the function under test: from `restart_tier1() {` to its closing brace.
sed -n '/^      restart_tier1() {/,/^      }/p' "$WORK/wd.sh" > "$WORK/fn.sh"
[ -s "$WORK/fn.sh" ] || { echo "FAIL: restart_tier1 not found"; exit 1; }

mkdir -p "$WORK/bin" "$WORK/opt/authelia/compose"
touch "$WORK/opt/authelia/compose/.secrets"
cat > "$WORK/bin/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$WORK/calls"
case "\$1" in
  inspect)
    [ -f "$WORK/nolabels" ] && { echo ""; exit 0; }
    case "\$3" in
      *'"com.docker.compose.project"'*) echo authelia ;;
      *'"com.docker.compose.project.working_dir"'*) echo "$WORK/opt/authelia" ;;
      *'"com.docker.compose.project.config_files"'*) echo "$WORK/opt/authelia/compose/docker-compose.yml" ;;
      *'"com.docker.compose.service"'*) echo authelia ;;
      *'"com.docker.compose.depends_on"'*) echo "redis:service_healthy:false" ;;
    esac ;;
  compose) [ -f "$WORK/composefail" ] && exit 1; exit 0 ;;
  ps) echo redis-id ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/docker"
printf '#!/bin/sh\nshift; exec "$@"\n' > "$WORK/bin/timeout"; chmod +x "$WORK/bin/timeout"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/logger"; chmod +x "$WORK/bin/logger"

drive() { : > "$WORK/calls"; PATH="$WORK/bin:$PATH" bash -c ". '$WORK/fn.sh'; restart_tier1 authelia"; grep -v ' inspect ' "$WORK/calls" | tr '\n' ';'; }

check "labelled container: one compose up of its service, deps included, nothing recreated" \
  "$(drive)" \
  "docker compose -p authelia --project-directory $WORK/opt/authelia -f $WORK/opt/authelia/compose/docker-compose.yml --env-file $WORK/opt/authelia/compose/.secrets up -d --no-recreate --no-build --pull never authelia;"
touch "$WORK/composefail"
check "compose fails: dependency started by hand first, then the container" \
  "$(drive | sed 's/^docker compose[^;]*;//')" "docker ps -aq --filter label=com.docker.compose.project=authelia --filter label=com.docker.compose.service=redis;docker start redis-id;docker start authelia;"
rm -f "$WORK/composefail"; touch "$WORK/nolabels"
check "no compose labels: plain docker start" "$(drive)" "docker start authelia;"

grep -q '^    MemoryMax=32M' "$NIX" && { fail=$((fail+1)); echo "  FAIL MemoryMax=32M would OOM-kill docker compose"; } || { pass=$((pass+1)); echo "  ok   watchdog unit has room for docker compose"; }
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
