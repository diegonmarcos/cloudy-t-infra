#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/agents/test-my-stack-retire-user-watchdog.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: the user my-watchdog is retired under the ship's real activation
# environment — a strict PATH with NO systemctl on it (the 2026-10-02
# oci-analytics log: "systemctl: command not found") and XDG_RUNTIME_DIR
# stripped by `sudo -u` — and nothing is called when there is no user manager.
# Runs the SHIPPED snippet out of my-stack.nix against a stub systemctl and a
# real UNIX socket, not a grep for the fix's spelling.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/my-stack.nix"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok()   { printf "  [ok] %s\n"   "$1"; }
nope() { printf "  [FAIL] %s\n" "$1"; fail=1; }

# The snippet, nix-unescaped (''${ -> ${), with the host systemctl and
# /run/user rooted in $T so every branch runs without root.
sed -n '/^ *SYSTEMCTL=""$/,/^ *fi$/p' "$SRC" \
  | sed "s/''\\\${/\${/; s|/usr/bin/systemctl|$T/bin/systemctl|; s|/run/user/|$T/run/user/|" > "$T/snip.sh"
grep -q -- '--user disable --now my-watchdog.service' "$T/snip.sh" \
  || { echo "[test] FAILED: retirement snippet not found in my-stack.nix"; exit 1; }

mkdir -p "$T/bin" "$T/strict"
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
echo "XDG=\$XDG_RUNTIME_DIR \$*" >> "$T/calls"
EOF
chmod +x "$T/bin/systemctl"
# Strict PATH: only what the snippet needs besides systemctl.
for b in sh id; do ln -s "$(command -v $b)" "$T/strict/$b"; done
run() { rm -f "$T/calls"; env -u XDG_RUNTIME_DIR PATH="$T/strict" "$@" sh "$T/snip.sh"; }

uid=$(id -u)
mkdir -p "$T/run/user/$uid"

# 1. No user manager (no bus socket) -> systemctl never called.
run
[ ! -e "$T/calls" ] && ok "no bus socket: nothing called" || nope "called systemctl with no user manager"

# 2. The ship's env: no systemctl on PATH, XDG_RUNTIME_DIR stripped, user
#    manager alive -> retired via the host binary and /run/user/<uid>.
python3 -c "import socket,sys;socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$T/run/user/$uid/bus"
run
grep -qx "XDG=$T/run/user/$uid --user disable --now my-watchdog.service" "$T/calls" 2>/dev/null \
  && ok "strict PATH + stripped XDG_RUNTIME_DIR: user copy retired" \
  || nope "user copy not retired under the ship's env: $(cat "$T/calls" 2>/dev/null)"

# 3. An inherited XDG_RUNTIME_DIR wins over the default.
mkdir -p "$T/own"; python3 -c "import socket,sys;socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$T/own/bus"
run XDG_RUNTIME_DIR="$T/own"
grep -q "^XDG=$T/own --user disable --now" "$T/calls" 2>/dev/null \
  && ok "inherited XDG_RUNTIME_DIR respected" || nope "inherited XDG_RUNTIME_DIR ignored"

[ $fail -eq 0 ] && { echo "[test] ALL CHECKS PASSED"; exit 0; }
echo "[test] FAILED"; exit 1
