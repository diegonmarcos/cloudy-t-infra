#!/usr/bin/env bash
# Guards #1683: a re-render of a service's .secrets.d must update the files IN
# PLACE and never replace the directory. Containers bind-mount ./.secrets.d at
# /run/secrets; a bind mount pins the directory inode, so the old
# `rm -rf .secrets.d && scp -r` left google-workspace-mcp (2026-11-12 14:13)
# with an empty /run/secrets until it was restarted.
#
# Runs deploy_secrets_d end to end on a local "VM" (ssh/scp stubbed to run
# locally) and proves:
#   1  a first deploy creates .secrets.d with the rendered content
#   2  a re-render with the SAME keys keeps the directory inode and content,
#      and reports nothing changed (no needless recreate)
#   3  a re-render with a changed key keeps the directory inode, updates the
#      content, and sets SECRETS_CHANGED/CONFIG_CHANGED (service recreated)
#   4  a key dropped from sops is removed as a file; the directory stays
#   5  an open handle on the directory (what a bind mount holds) sees the new
#      content: the directory the container pinned is the live one
#   6  no temp files and no staging dir are left behind
#   7  a sync whose script never ran (drained stdin on an ssh retry) is RED
#   8  the step no longer contains an `rm -rf` of the live .secrets.d
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="$ROOT/1_cicd/src/scripts/cloud-ship-container-step-deploy-rsync.sh"
TMP="$(mktemp -d)"; trap 'exec 9>&-; rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

log() { echo "    [log] $1"; }; log_error() { echo "    [error] $1"; }; log_warn() { :; }
DEPLOY_HOST="test-vm"
# shellcheck source=/dev/null
. "$STEP"
# "remote" commands run locally; the host part is dropped.
ssh_with_retry() { shift; sh -c "$1"; }
# after sourcing: the step defines its own scp_secret
scp_secret() { shift; [ "$1" = "-r" ] && shift; cp -rp "$1" "${2#*:}"; }

DIST_DIR="$TMP/dist"; DEPLOY_PATH="$TMP/vm/opt/containers/svc"
mkdir -p "$DIST_DIR/.secrets.d" "$DEPLOY_PATH"
render() { printf '%s' "$2" > "$DIST_DIR/.secrets.d/$1"; chmod 0644 "$DIST_DIR/.secrets.d/$1"; }
T="$DEPLOY_PATH/.secrets.d"
ino() { stat -c %i "$1"; }

render KEY_A "alpha"; render KEY_B "bravo"
SECRETS_CHANGED=""; CONFIG_CHANGED=""
deploy_secrets_d >"$TMP/out" 2>&1 && [ "$(cat "$T/KEY_A")" = alpha ] && [ "$(cat "$T/KEY_B")" = bravo ] \
    && ok "1: first deploy renders .secrets.d" || bad "1: $(cat "$TMP/out")"
ino0="$(ino "$T")"
exec 9<"$T"   # hold the directory like a bind mount does

SECRETS_CHANGED=""; CONFIG_CHANGED=""
deploy_secrets_d >"$TMP/out" 2>&1
[ "$(ino "$T")" = "$ino0" ] && [ "$(cat "$T/KEY_A")" = alpha ] && [ "$(cat "$T/KEY_B")" = bravo ] \
    && ok "2: same re-render keeps dir inode and content" || bad "2: inode $(ino "$T") vs $ino0; $(cat "$TMP/out")"
[ -z "$SECRETS_CHANGED" ] && grep -q 'unchanged' "$TMP/out" && ok "2b: unchanged keys do not force a recreate" || bad "2b: unchanged render flagged as change"

render KEY_A "alpha-2"
SECRETS_CHANGED=""; CONFIG_CHANGED=""
deploy_secrets_d >"$TMP/out" 2>&1
[ "$(ino "$T")" = "$ino0" ] && [ "$(cat "$T/KEY_A")" = alpha-2 ] && [ "$(cat "$T/KEY_B")" = bravo ] \
    && ok "3: changed key updated in place, dir inode kept" || bad "3: $(cat "$TMP/out")"
[ "$SECRETS_CHANGED" = true ] && [ "$CONFIG_CHANGED" = true ] && ok "3b: a changed key forces the service recreate" || bad "3b: change not signalled"

rm -f "$DIST_DIR/.secrets.d/KEY_B"
SECRETS_CHANGED=""
deploy_secrets_d >"$TMP/out" 2>&1
[ ! -e "$T/KEY_B" ] && [ "$(ino "$T")" = "$ino0" ] && [ "$SECRETS_CHANGED" = true ] \
    && ok "4: dropped key removed, directory kept" || bad "4: $(cat "$TMP/out")"

[ "$(cat "/proc/$$/fd/9/KEY_A" 2>/dev/null)" = alpha-2 ] \
    && ok "5: the pinned directory handle sees the new content" || bad "5: pinned handle does not see the live content"

left="$(find "$DEPLOY_PATH" -name '*.tmp.*' -o -name '.secrets.d.incoming' | head -1)"
[ -z "$left" ] && ok "6: no temp files or staging dir left" || bad "6: left behind: $left"

ssh_with_retry() { shift; sh -c "$1" </dev/null; }
secrets_d_sync_script() { :; }
if deploy_secrets_d >"$TMP/out" 2>&1; then bad "7: a sync that never ran passed"; else ok "7: a sync that never ran is RED"; fi

if grep -nE "rm -rf[^|;]*\\\$DEPLOY_PATH/\\.secrets\\.d'" "$STEP"; then bad "8: step still removes the live .secrets.d"; else ok "8: no rm -rf of the live .secrets.d"; fi

echo "--- secrets-d-inplace: $([ $fail = 0 ] && echo GREEN || echo RED)"
exit $fail
