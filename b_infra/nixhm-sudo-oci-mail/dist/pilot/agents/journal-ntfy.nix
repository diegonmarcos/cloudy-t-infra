# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/agents/journal-ntfy.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Journal → ntfy publisher
# Long-running: tails journalctl -p err, publishes to ntfy health_resources topic
# Rate-limited: 1 message per service per 5 minutes
#
{ config, pkgs, lib, ... }:
{
  home.file.".local/share/vm-pilot/journal-ntfy.sh" = {
    executable = true;
    source = ../scripts/journal-ntfy.sh;
  };

  home.file.".local/share/vm-pilot/journal-ntfy.service".text = ''
    [Unit]
    Description=Journal → ntfy publisher (errors only, rate-limited)
    After=network.target

    [Service]
    Type=simple
    ExecStart=/opt/scripts/journal-ntfy.sh
    Restart=always
    RestartSec=30
    MemoryMax=16M
    CPUQuota=5%
    User=root

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installJournalNtfy = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/vm-pilot"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/journal-ntfy.sh" /opt/scripts/journal-ntfy.sh
    $SUDO chmod +x /opt/scripts/journal-ntfy.sh
    $SUDO cp -f "$SRC/journal-ntfy.service" /etc/systemd/system/journal-ntfy.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable journal-ntfy.service 2>/dev/null || true
    $SUDO systemctl restart journal-ntfy.service 2>/dev/null || true
    echo "[journal-ntfy] deployed"
    ) || echo "[journal-ntfy] FAILED — activation continues"
  '';
}
