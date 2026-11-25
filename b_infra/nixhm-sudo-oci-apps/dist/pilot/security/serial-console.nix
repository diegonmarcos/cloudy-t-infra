# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/security/serial-console.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Serial console autologin — passwordless serial getty for OCI/GCP serial rescue
# Detects arch: ARM uses ttyAMA0, x86 uses ttyS0
# Drops a systemd override for serial-getty@<tty> with --autologin
{ config, pkgs, lib, ... }:

{
  home.activation.serialConsoleAutologin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[serial-autologin] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    LOG="[serial-autologin]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$LOG WARN: sudo not found — skipping"
      exit 0
    fi

    # Detect current user for autologin
    AUTOLOGIN_USER="$(whoami)"

    # Detect TTY: ARM (aarch64) uses ttyAMA0, x86 uses ttyS0
    ARCH="$(uname -m)"
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
      TTY_DEV="ttyAMA0"
    else
      TTY_DEV="ttyS0"
    fi

    OVERRIDE_DIR="/etc/systemd/system/serial-getty@$TTY_DEV.service.d"
    OVERRIDE_FILE="$OVERRIDE_DIR/autologin.conf"

    DESIRED="[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTOLOGIN_USER --noclear --keep-baud 115200,57600,38400,9600 %I \$TERM"

    # Check if already correct
    if $SUDO test -f "$OVERRIDE_FILE"; then
      CURRENT="$($SUDO cat "$OVERRIDE_FILE" 2>/dev/null)"
      if [ "$CURRENT" = "$DESIRED" ]; then
        echo "$LOG already configured for $AUTOLOGIN_USER on $TTY_DEV"
        exit 0
      fi
    fi

    echo "$LOG configuring autologin on $TTY_DEV for user $AUTOLOGIN_USER"
    $SUDO mkdir -p "$OVERRIDE_DIR"
    echo "$DESIRED" | $SUDO tee "$OVERRIDE_FILE" >/dev/null
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart "serial-getty@$TTY_DEV.service" 2>/dev/null || true
    echo "$LOG done ($TTY_DEV)"
    )
  '';
}
