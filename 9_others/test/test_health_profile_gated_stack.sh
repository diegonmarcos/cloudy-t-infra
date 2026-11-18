#!/usr/bin/env bash
# #1686: step_health skips a compose project that resolves to zero services (every service behind an inactive
# cloud-run profile) instead of timing out on "liveness: MISSING"; a project with services, or one that does not
# resolve, still goes through the normal wait. Sources the REAL step with ssh stubbed to run locally and a fake docker.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-health.sh"
fails=0; ok(){ echo "ok:   $1"; }; bad(){ echo "FAIL: $1"; fails=$((fails+1)); }
T_DIR="$(mktemp -d)"; trap 'rm -rf "$T_DIR"' EXIT; mkdir -p "$T_DIR/bin" "$T_DIR/vm"
mkfake(){ cat > "$T_DIR/bin/docker" <<EOF
#!/bin/sh
case "\$*" in *"config --services"*) printf '%s' "$1"; exit $2;; *" ps"*) exit 0;; esac
exit 0
EOF
chmod +x "$T_DIR/bin/docker"; }
log(){ echo "$*" >> "$T_DIR/log"; }
ssh_with_retry(){ shift; PATH="$T_DIR/bin:$PATH" bash -c "$1"; }
# shellcheck disable=SC1090
. "$STEP"
DEPLOY_HOST=vm DEPLOY_PATH="$T_DIR/vm" REMOTE_COMPOSE_REL=compose/docker-compose.yml DIST_DIR="$T_DIR/dist" HEALTH_TIMEOUT=1 HEALTH_INTERVAL=1
export DEPLOY_HOST DEPLOY_PATH REMOTE_COMPOSE_REL DIST_DIR HEALTH_TIMEOUT HEALTH_INTERVAL
mkfake "" 0; : > "$T_DIR/log"; ( step_health ) >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q "profile-gated" "$T_DIR/log" && ok "H1 zero-service project: skipped, rc 0" || bad "H1 gated (rc=$rc: $(tail -2 "$T_DIR/log" | tr '\n' ';'))"
mkfake "app" 0; : > "$T_DIR/log"; ( step_health ) >/dev/null 2>&1
! grep -q "profile-gated" "$T_DIR/log" && ok "H2 a project with services is not skipped" || bad "H2"
mkfake "" 1; : > "$T_DIR/log"; ( step_health ) >/dev/null 2>&1
! grep -q "profile-gated" "$T_DIR/log" && ok "H3 an unresolvable project is not skipped" || bad "H3"
echo "$((3-fails)) passed, $fails failed"; [ $fails -eq 0 ]
