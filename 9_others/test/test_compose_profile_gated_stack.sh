#!/usr/bin/env bash
# #1686: a compose stack whose every service sits behind an inactive profile (cloud-run) must deploy as
# "served elsewhere": no `down`, no `up`, exit 0. A stack with an active service, or a compose file that does not
# resolve, must still reach down/up (and fail loudly in the second case). Drives the REAL GATED_PROBE string
# extracted from the deploy step against a fake `docker`; mutation: dropping the probe from a PAYLOAD fails S1.
set -u
ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-compose.sh"
fails=0; ok(){ echo "ok:   $1"; }; bad(){ echo "FAIL: $1"; fails=$((fails+1)); }
T_DIR="$(mktemp -d)"; trap 'rm -rf "$T_DIR"' EXIT
probe_line="$(grep -m1 "^        GATED_PROBE=" "$STEP")"
[ -n "$probe_line" ] || { echo "FAIL: GATED_PROBE not found"; exit 1; }
CF="-f compose/docker-compose.yml --project-directory ."
eval "${probe_line#        }"
mkfake(){ # mkfake <services output> <config rc>
  mkdir -p "$T_DIR/bin"; cat > "$T_DIR/bin/docker" <<EOF
#!/bin/sh
echo "docker \$*" >> "$T_DIR/calls"
case "\$*" in *"config --services"*) printf '%s' "$1"; exit $2;; esac
exit 0
EOF
  chmod +x "$T_DIR/bin/docker"; : > "$T_DIR/calls"; }
run(){ PATH="$T_DIR/bin:$PATH" bash -c "ENV_FILE_FLAG=; $GATED_PROBE; docker compose $CF down --remove-orphans; docker compose $CF up -d"; }
mkfake "" 0; out="$(run)"; rc=$?
[ $rc -eq 0 ] && ! grep -q " down" "$T_DIR/calls" && ! grep -q " up " "$T_DIR/calls" && printf '%s' "$out" | grep -q "profile-gated" \
  && ok "S1 all services gated: exit 0, no down, no up" || bad "S1 all services gated (rc=$rc, calls: $(tr '\n' ';' < "$T_DIR/calls"))"
mkfake "app" 0; run >/dev/null; grep -q " down" "$T_DIR/calls" && grep -q " up -d" "$T_DIR/calls" && ok "S2 an active service: down and up still run" || bad "S2 active service"
mkfake "" 1; run >/dev/null; grep -q " up -d" "$T_DIR/calls" && ok "S3 compose config failing is not 'gated': up still runs (and fails loudly)" || bad "S3 config failure"
n=$(grep -c 'PAYLOAD="cd \\"$DEPLOY_PATH\\" && $ENV_FILE_PROBE; $GATED_PROBE;' "$STEP")
[ "$n" -eq 2 ] && ok "S4 both PAYLOAD branches run the probe before down" || bad "S4 probe in $n of 2 PAYLOAD branches"
# mutation: without the probe, S1's stack would run down and up
GATED_PROBE=":"; mkfake "" 0; run >/dev/null; grep -q " down" "$T_DIR/calls" && ok "MUT without the probe a gated stack is torn down (S1 catches it)" || bad "MUT"
echo "$((5-fails)) passed, $fails failed"; [ $fails -eq 0 ]
