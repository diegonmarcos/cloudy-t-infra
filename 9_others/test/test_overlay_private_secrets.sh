#!/usr/bin/env bash
# Tester for overlay-private-secrets.sh (#1064): the containers' sops files come
# from the private vault, not the public repo. Fake sops-looking fixtures only.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/1_cicd/src/ops/overlay-private-secrets.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASSES=0; FAILS=0
ok()  { PASSES=$((PASSES+1)); echo "  ok   $1"; }
bad() { FAILS=$((FAILS+1));  echo "  FAIL $1"; }

mk_vault() { # <dir>
  mkdir -p "$1/Linux-Containers/svc-a/src" "$1/Linux-Containers/_shared" "$1/Linux-Containers/orphan/src"
  printf 'K: ENC[AES256_GCM,data:x]\nsops:\n  version: 3.9.4\n' > "$1/Linux-Containers/svc-a/src/secrets.yaml"
  printf 'K: ENC[AES256_GCM,data:y]\nsops:\n  version: 3.9.4\n' > "$1/Linux-Containers/svc-a/src/secrets.sso-oidc.yaml"
  printf 'K: ENC[AES256_GCM,data:z]\nsops:\n  version: 3.9.4\n' > "$1/Linux-Containers/_shared/aa-secrets.yaml"
  printf 'K: ENC[AES256_GCM,data:w]\nsops:\n  version: 3.9.4\n' > "$1/Linux-Containers/orphan/src/secrets.yaml"
}
mk_dest() { # <dir>
  mkdir -p "$1/svc-a/src"; echo '{}' > "$1/svc-a/build.json"
  git -C "$1" init -q . ; git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init
}

V="$TMP/v"; D="$TMP/d"; mk_vault "$V"; mkdir -p "$D"; mk_dest "$D"
if OVERLAY_MIN=2 bash "$SCRIPT" "$V" "$D" >"$TMP/o1" 2>&1; then ok "overlay exits 0"; else bad "overlay failed"; cat "$TMP/o1"; fi
[ -f "$D/svc-a/src/secrets.yaml" ] && [ -f "$D/svc-a/src/secrets.sso-oidc.yaml" ] && ok "files copied to the same relative path" || bad "files not copied"
git -C "$D" ls-files --error-unmatch svc-a/src/secrets.yaml >/dev/null 2>&1 && ok "overlaid file staged (nix sees the index)" || bad "not staged"
[ ! -e "$D/_shared/aa-secrets.yaml" ] && [ ! -e "$D/orphan" ] && ok "_shared and service dirs that do not exist are skipped" || bad "copied where it must not"
grep -q 'overlaid 2 ' "$TMP/o1" && ok "count logged" || bad "count line missing"

# mutation 1: a non-sops file in the vault is refused
V2="$TMP/v2"; mk_vault "$V2"; printf 'PLAIN: value\n' > "$V2/Linux-Containers/svc-a/src/secrets.yaml"
D2="$TMP/d2"; mkdir -p "$D2"; mk_dest "$D2"
if OVERLAY_MIN=1 bash "$SCRIPT" "$V2" "$D2" >/dev/null 2>&1; then bad "plaintext file was accepted"; else ok "mutation: non-sops file refused"; fi
# mutation 2: too few files (stale/empty mount) fails closed
D3="$TMP/d3"; mkdir -p "$D3"; mk_dest "$D3"
if OVERLAY_MIN=50 bash "$SCRIPT" "$V" "$D3" >/dev/null 2>&1; then bad "short vault accepted"; else ok "mutation: below OVERLAY_MIN fails closed"; fi
# mutation 3: vault missing fails closed (nothing tracked in dest)
D5="$TMP/d5"; mkdir -p "$D5"; mk_dest "$D5"
if OVERLAY_OPTIONAL=1 bash "$SCRIPT" "$TMP/none" "$D5" >/dev/null 2>&1; then bad "missing vault accepted with no sops tracked"; else ok "mutation: missing vault fails closed"; fi
# transition: missing vault tolerated only while dest still tracks sops files
D4="$TMP/d4"; mkdir -p "$D4"; mk_dest "$D4"; cp "$V/Linux-Containers/svc-a/src/secrets.yaml" "$D4/svc-a/src/secrets.yaml"; git -C "$D4" add svc-a/src/secrets.yaml
if OVERLAY_OPTIONAL=1 bash "$SCRIPT" "$TMP/none" "$D4" >/dev/null 2>&1; then ok "transition: missing vault tolerated while public tree still tracks sops"; else bad "transition case failed"; fi

# #1450: a renamed service dir receives the secrets of its pre-rebrand vault dir
V6="$TMP/v6"; D6="$TMP/d6"; mkdir -p "$V6/Linux-Containers/old-svc/src" "$D6/new-svc/src" "$D6/_rebrand-1450"; echo '{}' > "$D6/new-svc/build.json"
printf 'K: ENC[AES256_GCM,data:r]\nsops:\n  version: 3.9.4\n' > "$V6/Linux-Containers/old-svc/src/secrets.yaml"
printf 'old-svc new-svc\n' > "$D6/_rebrand-1450/vault-dir-renames.txt"
git -C "$D6" init -q .; git -C "$D6" add -A >/dev/null 2>&1; git -C "$D6" -c user.email=t@t -c user.name=t commit -q -m init
if OVERLAY_MIN=1 bash "$SCRIPT" "$V6" "$D6" >/dev/null 2>&1 && [ -f "$D6/new-svc/src/secrets.yaml" ] && [ ! -e "$D6/old-svc" ]; then ok "rebrand: old vault dir overlaid onto the renamed dir"; else bad "rebrand rename mapping failed"; fi

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
