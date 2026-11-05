#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/overlay-private-secrets.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# overlay-private-secrets.sh <vault_root> <containers_dir> — #1064
#
# The sops-encrypted secrets of the containers live ONLY in the private repo
# cloud-me-pvt-vault (Linux-Containers/<svc>/src/secrets*.yaml, jwks_key.yaml),
# not in the public cloudy-u-containers. Every job that checks the containers
# repo out (a_solutions) runs this once afterwards: it copies each vault file
# over to the same relative path inside <containers_dir>, so every consumer
# (engine step_secrets, lint, guards) keeps reading <svc>/src/secrets.yaml.
#
# Staged with `git add -f` (index only, never committed): nix flakes see only
# the git index, and _shared/engine.nix gates the secrets auto-mount on
# builtins.pathExists (srcDir + "/secrets.yaml").
#
# Only files that carry a sops metadata block are copied, only into service
# directories that exist, never anything under _shared/. Values are never read
# or printed. Only counts and paths are logged.
#
# Env: OVERLAY_MIN (default 50) minimum files overlaid, else exit 1 (a stale or
#      empty vault mount must not produce a green ship without secrets).
#      OVERLAY_OPTIONAL=1: vault missing -> warn and exit 0, but only while the
#      containers tree itself still tracks sops files (transition safety).
set -eu
VAULT="${1:?usage: overlay-private-secrets.sh <vault_root> <containers_dir>}"
DEST="${2:?usage: overlay-private-secrets.sh <vault_root> <containers_dir>}"
SRC="$VAULT/Linux-Containers"
MIN="${OVERLAY_MIN:-50}"

if [ ! -d "$SRC" ]; then
  if [ "${OVERLAY_OPTIONAL:-0}" = "1" ] && [ -d "$DEST/.git" ] \
     && git -C "$DEST" grep -qlE '^sops:' -- '*secrets*.yaml' 2>/dev/null; then
    echo "overlay-private-secrets: WARN no $SRC; using the sops files still tracked in $DEST" >&2
    exit 0
  fi
  echo "overlay-private-secrets: ERROR private vault not available at $SRC" >&2
  exit 1
fi

n=0; skipped=0; list="$(mktemp)"
trap 'rm -f "$list"' EXIT
( cd "$SRC" && find . -type f \( -name 'secrets*.yaml' -o -name 'jwks_key.yaml' \) -print ) | sed 's|^\./||' | sort > "$list"
# #1450: the vault keeps the pre-rebrand service dir names. An optional
# <containers>/_rebrand-1450/vault-dir-renames.txt ("<old-dir> <new-dir>" per
# line) lets a renamed service dir receive the secrets of its old vault dir,
# unless the vault already has its own file at the new path.
RENAMES="$DEST/_rebrand-1450/vault-dir-renames.txt"
map_dir() { # <old-dir> -> new dir (empty when not renamed)
  [ -f "$RENAMES" ] || return 0
  awk -v o="$1" '$1==o && $1!~/^#/ {print $2; exit}' "$RENAMES"
}
while IFS= read -r rel; do
  case "$rel" in _shared/*|src/*|*..*) continue ;; esac
  out="$rel"
  top="${rel%%/*}"; new="$(map_dir "$top")"
  if [ -n "$new" ] && [ -d "$DEST/$new" ]; then
    out="$new/${rel#*/}"
    [ -f "$SRC/$out" ] && out="$rel"
  fi
  dst_dir="$DEST/$(dirname "$out")"
  [ -d "$dst_dir" ] || { skipped=$((skipped+1)); continue; }
  grep -q '^sops:' "$SRC/$rel" || { echo "overlay-private-secrets: ERROR $rel is not sops-encrypted; refusing" >&2; exit 1; }
  cp -f "$SRC/$rel" "$DEST/$out"
  n=$((n+1))
  if [ -d "$DEST/.git" ] || git -C "$DEST" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$DEST" add -f -- "$out" 2>/dev/null || true
  fi
done < "$list"

echo "overlay-private-secrets: overlaid $n sops file(s) from the private vault into $DEST ($skipped skipped: no service dir)"
if [ "$n" -lt "$MIN" ]; then
  echo "overlay-private-secrets: ERROR only $n file(s) overlaid, expected >= $MIN (OVERLAY_MIN)" >&2
  exit 1
fi
