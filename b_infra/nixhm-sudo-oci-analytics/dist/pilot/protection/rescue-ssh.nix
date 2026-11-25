# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/protection/rescue-ssh.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Rescue SSH (Dropbear)
# UNTOUCHABLE — OOM=-1000, FIFO scheduling, MemoryMin=20M
# Binds to WireGuard IP (wg0), falls back to 127.0.0.1
#
# Split from: system-protection-watchdog-petter-dropbear-health-agent.nix
# Imported by: default.nix (via system-protection.nix orchestrator)
#
{ config, pkgs, lib, rescuePort ? 2200, ... }:

let
  dropbearBin = "${pkgs.dropbear}/bin/dropbear";
  dropbearKeyBin = "${pkgs.dropbear}/bin/dropbearkey";
in {
  home.packages = [ pkgs.dropbear ];

  home.file.".local/share/system-protection/rescue-ssh.service".text = ''
    [Unit]
    Description=Rescue SSH (Dropbear on port ${toString rescuePort}) — UNTOUCHABLE
    After=network.target wg-quick@wg0.service
    Wants=wg-quick@wg0.service
    Before=docker.service
    [Service]
    Slice=connectivity.slice
    Type=simple
    ExecStartPre=/opt/scripts/rescue-ssh-setup.sh
    ExecStartPre=/opt/scripts/rescue-ssh-bind.sh
    ExecStart=/bin/sh -c '. /run/dropbear-bind; exec ${dropbearBin} -F -E -p $DROPBEAR_BIND:${toString rescuePort} -r /etc/dropbear/dropbear_ed25519_host_key'
    Restart=always
    RestartSec=2
    OOMScoreAdjust=-1000
    OOMPolicy=continue
    MemoryMin=20M
    MemoryMax=30M
    MemoryHigh=25M
    CPUSchedulingPolicy=fifo
    CPUSchedulingPriority=1
    IOSchedulingClass=realtime
    IOSchedulingPriority=0
    Nice=-20
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/rescue-ssh-bind.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      WG_IP=$(ip -4 addr show wg0 2>/dev/null | awk '/inet / { split($2,a,"/"); print a[1] }' || echo "")
      if [ -n "$WG_IP" ]; then
        echo "DROPBEAR_BIND=$WG_IP" > /run/dropbear-bind
      else
        echo "DROPBEAR_BIND=127.0.0.1" > /run/dropbear-bind
      fi
    '';
  };

  home.file.".local/share/system-protection/rescue-ssh-setup.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      mkdir -p /etc/dropbear
      if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
        ${dropbearKeyBin} -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
        echo "[rescue-ssh] Generated ed25519 host key"
      fi
      echo "[rescue-ssh] Ready on port ${toString rescuePort}"
    '';
  };

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installRescueSsh = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[rescue-ssh] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[rescue-ssh] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts /etc/dropbear
    $SUDO cp -f "$SRC/rescue-ssh-setup.sh" /opt/scripts/rescue-ssh-setup.sh
    $SUDO cp -f "$SRC/rescue-ssh-bind.sh" /opt/scripts/rescue-ssh-bind.sh
    $SUDO chmod +x /opt/scripts/rescue-ssh-setup.sh /opt/scripts/rescue-ssh-bind.sh
    $SUDO cp -f "$SRC/rescue-ssh.service" /etc/systemd/system/rescue-ssh.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable rescue-ssh.service 2>/dev/null || true
    $SUDO systemctl restart rescue-ssh.service 2>/dev/null || true

    echo "[rescue-ssh] deployed: port=${toString rescuePort}"
    ) || echo "[rescue-ssh] FAILED — activation continues"
  '';
}
