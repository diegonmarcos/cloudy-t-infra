#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/test-scheduler-no-readonly-rm.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test H8b: scheduler.nix must NOT contain the dead `rm -f ~/.nix-profile/bin/docker`
# block. That path is a symlink into a read-only nix store merged directory, so
# the rm silently no-ops and emits misleading success messages. The real fix for
# stale docker-real wrappers is a fresh `home-manager switch` (per H8).
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/scheduler.nix"
fail=0
ok()   { printf "  [ok] %s\n"   "$1"; }
nope() { printf "  [FAIL] %s\n" "$1"; fail=1; }

# 1. The dead block must be gone
if grep -q 'rm -f "\$_nix_docker"' "$SRC"; then
    nope "dead nix-profile rm block still present"
else
    ok "dead nix-profile rm block removed"
fi

# 2. A comment must explain why (so future contributors don't re-add it)
if grep -q "read-only nix store" "$SRC"; then
    ok "comment explaining the read-only-store pitfall is present"
else
    nope "comment explaining the pitfall is missing"
fi

# 3. The still-valid `/usr/local/bin` wrapper cleanup must remain
if grep -q "stale docker wrappers" "$SRC" && grep -q "/usr/local/bin/docker-real" "$SRC"; then
    ok "valid /usr/local/bin wrapper cleanup loop kept"
else
    nope "valid /usr/local/bin cleanup loop missing"
fi

[ $fail -eq 0 ] && { echo "[test] ALL CHECKS PASSED"; exit 0; }
echo "[test] FAILED"; exit 1
