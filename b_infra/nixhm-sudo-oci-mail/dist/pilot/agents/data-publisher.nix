# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/agents/data-publisher.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Data publisher — collect containers.json + journal-errors.json every 5 min
# Writes to /opt/pilot/data/. Served via dashboard-httpd symlink (no standalone httpd).
#
{ config, pkgs, lib, ... }:
{
  home.file.".local/share/vm-pilot/data-publisher.sh" = {
    executable = true;
    source = ../scripts/data-publisher.sh;
  };

  home.file.".local/share/vm-pilot/data-publisher.service".text = ''
    [Unit]
    Description=Data publisher — collect VM data JSONs
    After=network.target docker.service

    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/data-publisher.sh
    User=root
    TimeoutStartSec=30
  '';

  home.file.".local/share/vm-pilot/data-publisher.timer".text = ''
    [Unit]
    Description=Data publisher timer (every 5 min)

    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min

    [Install]
    WantedBy=timers.target
  '';

  home.activation.installDataPublisher = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/vm-pilot"
    $SUDO mkdir -p /opt/scripts /opt/pilot/data
    $SUDO cp -f "$SRC/data-publisher.sh" /opt/scripts/data-publisher.sh
    $SUDO chmod +x /opt/scripts/data-publisher.sh
    $SUDO cp -f "$SRC/data-publisher.service" /etc/systemd/system/data-publisher.service
    $SUDO cp -f "$SRC/data-publisher.timer" /etc/systemd/system/data-publisher.timer

    # Remove legacy standalone httpd (now served via dashboard-httpd symlinks)
    if $SUDO systemctl is-active data-httpd >/dev/null 2>&1; then
      $SUDO systemctl stop data-httpd 2>/dev/null || true
      $SUDO systemctl disable data-httpd 2>/dev/null || true
    fi
    $SUDO rm -f /etc/systemd/system/data-httpd.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable data-publisher.timer 2>/dev/null || true
    $SUDO systemctl start data-publisher.timer 2>/dev/null || true
    $SUDO systemctl start data-publisher.service 2>/dev/null || true
    echo "[data-publisher] deployed: timer=5min (served via dashboard-httpd)"
    ) || echo "[data-publisher] FAILED — activation continues"
  '';
}
