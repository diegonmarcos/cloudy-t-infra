#!/bin/sh
# #1886: an unsandboxed nix build fails when /homeless-shelter exists, and
# `nix develop` exports HOME=/homeless-shelter. The home-manager docker-package
# step must remove it before every attempt and give the inner build the real
# HOME. Mutation: a copy without the removal must be reported red.
set -eu
ROOT="${CLOUD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
F="$ROOT/1_cicd/src/scripts/cloud-ship-nix-homemanager-step-build-docker.sh"
check() {
  awk '/_nix_try=\$\(\( _nix_try \+ 1 \)\)/{l=1} l&&/rm -rf \/homeless-shelter/{r=1} l&&/nix develop/{exit} END{exit !r}' "$1" || { echo "RED $1: no /homeless-shelter removal inside the retry loop before nix develop"; return 1; }
  grep -q "export HOME='\$_hm_home'" "$1" || { echo "RED $1: inner devShell build does not restore HOME"; return 1; }
}
check "$F"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
grep -v 'rm -rf /homeless-shelter' "$F" > "$TMP"
if check "$TMP" >/dev/null; then echo "RED mutation: removal deleted but check still green"; exit 1; fi
echo "OK hm docker-package clears /homeless-shelter and restores HOME; mutation caught"
