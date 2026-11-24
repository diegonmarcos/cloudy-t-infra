#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-detect-engine-consumers.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Which services does a change to _shared/ ship? ──
#
# Two kinds of file live under _shared/, and they fan out very differently:
#
#   ENGINE files: _shared/engine.nix and everything it reads, transitively
#     (`import ./x.nix`, `builtins.readFile ./x.json`). Every service whose
#     src/ imports `../../_shared/engine.nix` renders through them, so a change
#     ships every engine consumer. The closure is DERIVED from engine.nix's own
#     references, never hardcoded.
#   DATA / helper files: everything else (fleet-addressing.json, edge-auth.nix,
#     geo-fence.json, jev-gate/, ...). Only the services whose declarations name
#     the file ship: a non-comment line in <svc>/src/{*.nix,Dockerfile*,*.sh}
#     carrying `_shared/<path>` (or `_shared/<dir>` for a file inside <dir>), or
#     a non-doc build.json value naming it. A file nobody names ships nothing.
#   CI-only files (test-*, test/, *.md, lib/*.tests/) ship nothing.
#
# Why (#451, #1886): `_shared/engine.nix` once mapped to ZERO services (the
# first-segment classifier saw only `_shared`), so the engine was fixed to fan
# out -- but EVERY _shared/ path then fanned out to the whole fleet. On
# 2026-11-24 734f4621 changed only _shared/fleet-addressing.json (read by
# infra-sec_caddy alone) plus a test, Ship 45308011308 selected the whole fleet,
# and the gcp-proxy deploy took the auth plane down for ~40 minutes. The
# auth-plane hold itself lives in cloud-ship-guard-auth-plane.sh; this script
# only answers "who consumes it".
#
# Usage: cloud-ship-detect-engine-consumers.sh < <changed-paths>
#   cwd (or any parent) must be the cloud-infra checkout, with a_solutions/
#   populated (a_solutions is the cloud-u-containers checkout).
#   stdin: one a_solutions-relative changed path per line (ship.yml's
#          $SUB_CHANGED verbatim).
#   stdout: ONE line, the space-separated service dirs to ship (EMPTY when no
#           changed _shared/ path has a consumer).
#   stderr: reasoning -- per path, the class and the consumers it resolved to.
#
# Proven both directions by 9_others/test/test_detect_engine_consumers.sh.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 1
A=a_solutions

# ── Which changed paths are under _shared/ and not CI-only? ──────────────────
SHARED_PATHS=""
while IFS= read -r _p; do
  case "$_p" in
    # Guard scripts and docs under _shared/ are CI-only: nothing is built from
    # them, so they must not fan out (2026-10-30: a test-fleet-addressing.mjs
    # edit redeployed 9 gcp-proxy services and recreated authelia-redis).
    _shared/test-*|_shared/test/*|_shared/*.md|_shared/*/*.md|_shared/lib/*.tests/*) ;;
    _shared/?*) SHARED_PATHS="$SHARED_PATHS ${_p#_shared/}" ;;
  esac
done
[ -n "$SHARED_PATHS" ] || exit 0
[ -d "$A/_shared" ] || {
  echo "::warning::detect: _shared/ changed but $A/_shared is absent -- cannot resolve consumers" >&2
  exit 0
}

# ── Engine closure: engine.nix + every _shared file it reads, transitively ──
# A reference is `./<path>` on a non-comment line (not `../`), resolved against
# the referencing file's directory and kept only if it exists under _shared/.
_refs() {  # $1 = _shared-relative file; prints _shared-relative referenced paths
  local f="$A/_shared/$1" d
  d=$(dirname "$1")
  [ -f "$f" ] || return 0
  sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$f" \
    | grep -oE '(^|[^.A-Za-z0-9_])\./[A-Za-z0-9_][A-Za-z0-9_./-]*' \
    | sed -E 's|^[^.]?\./||; s|/+$||' \
    | while IFS= read -r r; do
        [ "$d" = "." ] || r="$d/$r"
        [ -e "$A/_shared/$r" ] && printf '%s\n' "$r"
      done
}
ENGINE_SET=" engine.nix "
_queue="engine.nix"
while [ -n "$_queue" ]; do
  _next=""
  for _f in $_queue; do
    case "$_f" in *.nix) ;; *) continue ;; esac
    for _r in $(_refs "$_f"); do
      case "$ENGINE_SET" in *" $_r "*) ;; *) ENGINE_SET="$ENGINE_SET$_r "; _next="$_next $_r" ;; esac
    done
  done
  _queue="$_next"
done

_in_engine() {  # $1 = _shared-relative path; true if it is, or lies inside, an engine file/dir
  local e
  for e in $ENGINE_SET; do
    case "$1" in "$e"|"$e"/*) return 0 ;; esac
  done
  return 1
}

# ── Consumers ────────────────────────────────────────────────────────────────
# Engine consumers: services whose src *.nix imports the engine (archived and
# _shared itself excluded; dist/ and node_modules are output, not declarations).
engine_consumers() {
  grep -rl --include='*.nix' \
        --exclude-dir=dist --exclude-dir=node_modules --exclude-dir=.git \
        '_shared/engine.nix' "$A"/*/src 2>/dev/null \
    | awk -F/ '$2 != "z_archive" && $2 != "_shared" {print $2}' | sort -u
}

# Direct consumers of one _shared-relative path. Declarations are read with
# comments stripped, so a "see _shared/x.json" note is not consumption; in
# JSON only a value under a non-doc key counts (keys starting with `_`,
# reason/description/note/comment and the CI-only test `cmd` do not).
# `grep >/dev/null`, never `grep -q`, at the end of these pipelines: -q exits on
# the first match, the upstream sed takes SIGPIPE, and under pipefail the match
# reads as a miss (infra-sec_caddy/src/caddyfile.nix, 1.7k lines, was dropped).
_ere() { printf '%s' "$1" | sed 's/[].[\*^$/+?(){}|]/\\&/g'; }
direct_consumers() {  # $1 = _shared-relative path
  local p="$1" pat anc
  pat="_shared/$(_ere "$p")([^A-Za-z0-9_.-]|\$)"
  anc=$(dirname "$p")
  while [ "$anc" != "." ]; do
    pat="$pat|_shared/$(_ere "$anc")([^A-Za-z0-9_./-]|\$)"
    anc=$(dirname "$anc")
  done
  {
    find "$A"/*/src \( -name dist -o -name node_modules -o -name .git \) -prune -o \
         -type f \( -name '*.nix' -o -name 'Dockerfile*' -o -name '*.sh' \) -print 2>/dev/null \
      | while IFS= read -r f; do
          sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$f" | grep -E "$pat" >/dev/null \
            && printf '%s\n' "$f"
        done
    # JSON declarations: build.json, and src JSON a service reads (stalwart's
    # mail-rules-general.json names _shared/mail-auth-patterns.json). Generated
    # copies that merely mention paths are not declarations: the consolidated
    # cloud-data copy, code-signature indexes, manifest.json.
    { ls "$A"/*/build.json 2>/dev/null
      find "$A"/*/src \( -name dist -o -name node_modules -o -name .git \) -prune -o \
           -type f -name '*.json' ! -name '_cloud-data-consolidated.json' \
           ! -name 'code-signatures-*.json' ! -name 'manifest.json' -print 2>/dev/null
    } | while IFS= read -r bj; do
      [ -f "$bj" ] || continue
      grep -E '"[^"_][^"]*"[[:space:]]*:[[:space:]]*"' "$bj" \
        | grep -vE '"(reason|description|note|comment|cmd)"[[:space:]]*:' \
        | grep -E "$pat" >/dev/null && printf '%s\n' "$bj"
    done
  } | awk -F/ '$2 != "z_archive" && $2 != "_shared" {print $2}' | sort -u
}

CONSUMERS=""
ENGINE_DONE=""
for p in $SHARED_PATHS; do
  if _in_engine "$p"; then
    if [ -n "$ENGINE_DONE" ]; then
      echo "detect: _shared/$p -> ENGINE file (consumers already added)" >&2
      continue
    fi
    ENGINE_DONE=1
    c=$(engine_consumers | tr '\n' ' ')
    echo "detect: _shared/$p -> ENGINE file: every engine consumer ($(printf '%s' "$c" | wc -w | tr -d ' '))" >&2
    [ -n "$c" ] || echo "::warning::detect: an engine change under _shared/ resolved to ZERO engine consumers -- is a_solutions/ populated and does any service's src import the shared engine?" >&2
  else
    c=$(direct_consumers "$p" | tr '\n' ' ')
    echo "detect: _shared/$p -> data/helper: ${c:-no consumer (ships nothing)}" >&2
  fi
  CONSUMERS="$CONSUMERS $c"
done

CONSUMERS=$(printf '%s\n' $CONSUMERS | grep -v '^$' | sort -u | tr '\n' ' ')
[ -z "$CONSUMERS" ] || echo "::notice::_shared consumers: $CONSUMERS" >&2
printf '%s' "$CONSUMERS"
