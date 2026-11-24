#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-guard-auth-plane.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Hold the auth plane out of every fan-out Ship (#1886) ──
#
# On 2026-11-24 two fleet-wide Ships recreated authelia + authelia-redis and the
# gated edge was down twice (00:30-00:39Z, ~02:30-03:10Z). The second was a
# _shared/ data edit that selected the whole fleet. The auth plane is too
# expensive to redeploy as a side effect, so this filter runs over the final
# selected set and removes it unless the Ship asked for it:
#
#   explicit: the operator named it (workflow_dispatch services=<list>) -> kept
#   auto:     kept only if its OWN directory changed (SHIP_DIRECT) AND the whole
#             selected set is at most fanout_max services; otherwise HELD
#
# Policy (service list, fanout_max): 1_cicd/src/ship-auth-plane.json.
#
# Usage: cloud-ship-guard-auth-plane.sh explicit|auto
#   env SHIP_CANDIDATES  space-separated selected service dirs
#   env SHIP_DIRECT      space-separated dirs whose own files changed (auto)
#   env SHIP_HELD_OUT    optional file: the held dirs are written there
#   stdout: the kept set, one line, space-separated
#   stderr: the reasoning; a ::warning:: naming every held dir and how to ship it
# Tested by 9_others/test/test_ship_guard_auth_plane.sh.
set -uo pipefail

MODE="${1:?mode: explicit|auto}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY="${SHIP_AUTH_PLANE_POLICY:-$REPO_ROOT/1_cicd/src/ship-auth-plane.json}"
[ -f "$POLICY" ] || { echo "::error::auth-plane policy $POLICY not found -- refusing to select without it" >&2; exit 1; }
AUTH=" $(jq -r '.services[]' "$POLICY" | tr '\n' ' ') "
MAX=$(jq -r '.fanout_max' "$POLICY")

CANDS=$(printf '%s\n' ${SHIP_CANDIDATES:-} | grep -v '^$' | sort -u | tr '\n' ' ')
DIRECT=" ${SHIP_DIRECT:-} "
N=$(printf '%s' "$CANDS" | wc -w | tr -d ' ')

KEPT=""; HELD=""
for d in $CANDS; do
  case "$AUTH" in
    *" $d "*)
      if [ "$MODE" = explicit ]; then
        KEPT="$KEPT $d"; echo "auth-plane: $d kept (named explicitly)" >&2
      else
        case "$DIRECT" in
          *" $d "*)
            if [ "$N" -le "$MAX" ]; then
              KEPT="$KEPT $d"; echo "auth-plane: $d kept (own directory changed, $N service(s) <= $MAX)" >&2
            else
              HELD="$HELD $d"; echo "auth-plane: $d HELD (own directory changed, but a fan-out of $N > $MAX services)" >&2
            fi ;;
          *) HELD="$HELD $d"; echo "auth-plane: $d HELD (selected by fan-out, not by its own change)" >&2 ;;
        esac
      fi ;;
    *) KEPT="$KEPT $d" ;;
  esac
done

if [ -n "$HELD" ]; then
  echo "::warning::auth plane held out of this Ship:$HELD. It ships only by an explicit, approved Ship: workflow_dispatch services=$(printf '%s' "$HELD" | sed 's/^ //; s/ /,/g') (see 1_cicd/src/ship-auth-plane.json, #1886)" >&2
fi
[ -z "${SHIP_HELD_OUT:-}" ] || printf '%s\n' "${HELD# }" > "$SHIP_HELD_OUT"
printf '%s' "${KEPT# }"
