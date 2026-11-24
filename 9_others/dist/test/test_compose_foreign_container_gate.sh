#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_compose_foreign_container_gate.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: the compose deploy never evicts a declared container its own compose
# does not recreate, and fails BEFORE `down` when such a container is not live.
#
# #1886: infra-sec_authelia's build.json declares postlite-authelia, but only
# infra-db_postlite's compose renders it. The deploy force-removed every
# declared name, `up` recreated authelia + authelia-redis only, and Ship
# 45308011308's Deploy -> gcp-proxy ended "liveness: MISSING postlite-authelia"
# after the old containers were already gone. Drives the real construction
# lines of cloud-ship-container-step-deploy-compose.sh against a stub docker.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"
[ -f "$STEP" ] || { echo "FAIL: $STEP missing"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (expected '$3', got '$2')"; fi; }

# Stub docker: `inspect` answers Running from $WORK/running; `rm` records.
cat > "$WORK/bin/docker" <<STUB
case "\$1" in
  inspect) n="\$(eval echo \\\${\$#})"; grep -qxF "\$n" "$WORK/running" && echo true || echo false ;;
  rm) shift; while [ "\$1" = "-f" ]; do shift; done; echo "\$1" >> "$WORK/removed" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"; export PATH

# The construction block: from `_composed=` to the FOREIGN_GATE assignment.
START=$(grep -n '^    _composed="\$(grep' "$STEP" | cut -d: -f1)
END=$(grep -n '^    \[ -n "\$_foreign" \] && FOREIGN_GATE=' "$STEP" | cut -d: -f1)
[ -n "$START" ] && [ -n "$END" ] || { echo "FAIL: eviction construction not found in $STEP"; exit 1; }
BLOCK=$(sed -n "${START},${END}p" "$STEP")
# Both payload paths must run FOREIGN_GATE before their `down`.
[ "$(grep -c '\${FOREIGN_GATE:+\$FOREIGN_GATE; }\${LEGACY_COMPOSE_CLEANUP' "$STEP")" = 2 ] \
  && grep -B3 '\[ -n "\$EVICT_SOCKET_PRE" \] && printf' "$STEP" | grep -q 'FOREIGN_GATE' \
  && { pass=$((pass+1)); echo "  ok   FOREIGN_GATE precedes down on the standard and custom paths"; } \
  || { fail=$((fail+1)); echo "  FAIL FOREIGN_GATE is not ahead of down on both payload paths"; }

run() {  # $1 = declared names, $2 = compose text, $3 = running names
  : > "$WORK/removed"; printf '%s\n' $3 > "$WORK/running"
  COMPOSE_FILE="$WORK/docker-compose.yml"; printf '%s\n' "$2" > "$COMPOSE_FILE"
  _cnames="$1"; EVICT_NAMED=""
  eval "$BLOCK"
  rc=0
  [ -z "$FOREIGN_GATE" ] || (eval "$FOREIGN_GATE") 2>/dev/null || rc=$?
  [ -z "$EVICT_NAMED" ] || [ "$rc" -ne 0 ] || eval "$EVICT_NAMED"
  echo "rc=$rc removed=$(sort "$WORK/removed" | tr '\n' ' ')"
}
AUTH='{"services":{"authelia":{"container_name":"authelia"},"redis":{"container_name":"authelia-redis"}}}'

check "authelia shape, postlite-authelia live: it is NOT evicted, deploy proceeds" \
  "$(run 'authelia postlite-authelia authelia-redis' "$AUTH" 'postlite-authelia authelia authelia-redis')" \
  "rc=0 removed=authelia authelia-redis "
check "authelia shape, postlite-authelia absent: fails before down, nothing removed" \
  "$(run 'authelia postlite-authelia authelia-redis' "$AUTH" 'authelia authelia-redis')" \
  "rc=1 removed="
check "every declared name rendered: all evicted, no gate (unchanged behaviour)" \
  "$(run 'authelia authelia-redis' "$AUTH" '')" "rc=0 removed=authelia authelia-redis "
check "YAML compose is parsed too" \
  "$(run 'postlite-npm postlite-authelia' $'services:\n  a:\n    container_name: postlite-npm\n  b:\n    container_name: "postlite-authelia"' '')" \
  "rc=0 removed=postlite-authelia postlite-npm "
check "unparseable compose keeps evict-everything (no guessing)" \
  "$(run 'x y' 'garbage' '')" "rc=0 removed=x y "

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
