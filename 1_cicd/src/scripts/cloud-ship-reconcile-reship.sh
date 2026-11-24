#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ cloud-ship-reconcile-reship.sh — choose what the reconcile re-ships       ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# The half of #354 that was missing. The deploy gate in ship.yml already
# DETECTS an evicted deploy and fails loudly; what never existed is anything
# that puts the lost deploy back on the queue. cloud-ship-reconcile.sh finds
# the services the fleet is behind on; this decides which of them to actually
# dispatch, and refuses to dispatch more than the WG runner can absorb.
#
# Kept separate from the reconcile itself for one reason: the reconcile is
# read-only and must stay that way, so that running it to ask a question can
# never move the fleet. This script is the only place that decides to act.
#
#   stdin  : cloud-ship-reconcile.sh findings — <vm> <dir> <class> <detail>
#   stdout : comma-separated service dirs for ship.yml's `services` input,
#            empty when there is nothing to do
#   stderr : what was selected, what was held back, and why
#   exit 0 : always. "nothing to re-ship" is a normal outcome, not a failure;
#            the reconcile itself already exited non-zero to report the drift.
#
# Bounds come from 9_others/ship-reconcile.json — see that file for why each
# one exists. Nothing about which classes are safe or how many services fit in
# one lock hold is encoded here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CLOUD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
CONFIG="${RESHIP_CONFIG:-$REPO_ROOT/9_others/ship-reconcile.json}"

note() { printf '%s\n' "$*" >&2; }

# No config is a STOP, not a default. Silently falling back to built-in bounds
# would mean the operator's cap could be deleted without anything noticing,
# which is the failure mode the cap exists to prevent.
[ -f "$CONFIG" ] || { note "::error::$CONFIG not found — refusing to guess re-ship bounds"; exit 0; }

CLASSES="$(jq -r '(.reship_classes // []) | join(" ")' "$CONFIG")"
CAP="$(jq -r '.max_reships_per_run // empty' "$CONFIG")"
if [ -z "$CLASSES" ] || [ -z "$CAP" ]; then
  note "::error::$CONFIG is missing reship_classes or max_reships_per_run — refusing to act"
  exit 0
fi

FINDINGS="$(cat)"
if [ -z "$FINDINGS" ]; then
  note "reconcile reported no findings — nothing to re-ship"
  exit 0
fi

# Select by class, then collapse to unique service dirs. One service can
# produce several findings: user-ai_cloud-cgc-pub-mcp runs two containers
# (cloud-cgc-pub-mcp and cloud-cgc-pvt-mcp) off one image, so a single stale
# deploy reports twice and must still be shipped once.
SELECTED=""
for cls in $CLASSES; do
  SELECTED="$SELECTED$(printf '%s\n' "$FINDINGS" | awk -F'\t' -v c="$cls" '$3==c {print $2}')
"
done
SELECTED="$(printf '%s\n' "$SELECTED" | grep -v '^$' | sort -u || true)"

# Everything the classes did not pick up is reported, never silently dropped.
HELD="$(printf '%s\n' "$FINDINGS" | awk -F'\t' '{print $3}' | sort | uniq -c \
        | awk -v sel="$CLASSES" '{ split(sel, k, " "); keep=0; for (i in k) if ($2==k[i]) keep=1; if (!keep) print "  " $2 ": " $1 " finding(s) — reported, not re-shipped" }')"
[ -n "$HELD" ] && note "$HELD"

# #1886: the auth plane never ships from a reconcile. A reconcile dispatch
# names services explicitly, which the Ship guard treats as an operator ask,
# so the hold has to be applied here. Drift on those dirs is reported for an
# approved Ship; it is never auto-deployed (a joint authelia redeploy took the
# gated edge down twice on 2026-11-24).
AUTH_POLICY="${SHIP_AUTH_PLANE_POLICY:-$REPO_ROOT/1_cicd/src/ship-auth-plane.json}"
if [ ! -f "$AUTH_POLICY" ]; then
  note "::error::$AUTH_POLICY not found — refusing to re-ship without the auth-plane hold"
  exit 0
fi
AUTH_DIRS="$(jq -r '(.services // [])[]' "$AUTH_POLICY")"
if [ -z "$AUTH_DIRS" ]; then
  note "::error::$AUTH_POLICY lists no services — refusing to re-ship without the auth-plane hold"
  exit 0
fi
AUTH_HELD="$(printf '%s\n' "$SELECTED" | grep -Fxf <(printf '%s\n' "$AUTH_DIRS") || true)"
if [ -n "$AUTH_HELD" ]; then
  note "::warning::auth plane drifted but held out of the reconcile (#1886); ship it only by an approved Ship: $(printf '%s\n' "$AUTH_HELD" | paste -sd, -)"
  SELECTED="$(printf '%s\n' "$SELECTED" | grep -vFxf <(printf '%s\n' "$AUTH_DIRS") || true)"
fi

if [ -z "$SELECTED" ]; then
  note "no findings in re-shippable classes ($CLASSES) — nothing to dispatch"
  exit 0
fi

TOTAL="$(printf '%s\n' "$SELECTED" | wc -l | tr -d ' ')"
TAKE="$(printf '%s\n' "$SELECTED" | head -n "$CAP")"

if [ "$TOTAL" -gt "$CAP" ]; then
  note "::warning::$TOTAL services are behind the registry but only $CAP will be re-shipped this run."
  note "The cap protects ship-wg-runner, the fleet's single deploy lock (#179). The"
  note "remainder is not lost — the next scheduled reconcile ships it. Deferred:"
  printf '%s\n' "$SELECTED" | tail -n +"$((CAP + 1))" | sed 's|^|    |' >&2
fi

note "re-shipping $(printf '%s\n' "$TAKE" | wc -l | tr -d ' ') of $TOTAL drifted service(s):"
printf '%s\n' "$TAKE" | sed 's|^|    |' >&2

printf '%s\n' "$TAKE" | paste -sd, -
