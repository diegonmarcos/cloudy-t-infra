# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/protection/disk-ballast.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Disk Ballast (declarative reserve, replaces ext4 -m 5)
#
# Pre-allocates a userland file at /var/disk-reserve/ballast.bin sized to the
# HM-activation reservation declared in 9_others/src/inputs/hm-config.json
# (single SoT, also read by the engine). Acts as the universal buffer area:
#
#   1. HM activation pre-flight (cloud-ship-nix-homemanager-step-deploy-activate.sh:264)
#      `rm -f /var/disk-reserve/ballast.bin` releases N% instantly when the
#      VM goes under the activation_min_free_gb threshold.
#
#   2. Watchdog EMERG tier deletes ballast BEFORE swap to relieve disk
#      pressure without OOM consequences.
#
#   3. Any other root-level disk-pressure recovery has a known release knob.
#
# Why this exists (ext4's 5% reserved blocks isn't enough):
#   ext4 `tune2fs -m 5` is set imperatively by the cloud provider's mke2fs
#   default (Oracle/GCP base images). It only protects uid 0 — useless when
#   the daemon FILLING the disk IS root (docker, journalctl, nix-daemon).
#   It's also FS-baked, not in our terraform, not declarable.
#   This module SUPERSEDES it: tune2fs -m 0 on ext4 (frees the cloud-default
#   reserve to general use) + a userland ballast we own and can release on
#   demand. Btrfs (gcp-proxy) doesn't have ext4-style reserved blocks at all,
#   so this is its only declarative reservation mechanism.
#
# Imported by: system-protection.nix orchestrator
#
# Single source of truth for the ballast/activation-reservation size:
#   9_others/src/inputs/hm-config.json :: .min_size_ballast_file_gb
# Symlinked into vm-pilot via _shared/modules/hm-config.json.
# Engine pre-flight reads the same JSON. ONE field, ONE place.
{ config, pkgs, lib, ... }:

let
  hmConfig = builtins.fromJSON (builtins.readFile ../hm-config.json);
  ballastGB = hmConfig.min_size_ballast_file_gb;
  ballastPath = "/var/disk-reserve/ballast.bin";
  recreateThreshold = 70;  # only allocate when /<70%
in {
  home.file.".local/share/system-protection/disk-ballast-create.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Allocate ${toString ballastGB} GB at / as the HM-activation reserve.
      # Idempotent: skips if file already exists at target size.
      # Safe: refuses to allocate if /<${toString recreateThreshold}% would be exceeded.
      set -euo pipefail
      BALLAST="${ballastPath}"
      DIR=$(dirname "$BALLAST")
      mkdir -p "$DIR"
      chmod 700 "$DIR"

      WANT_MB=$(( ${toString ballastGB} * 1024 ))

      if [ -f "$BALLAST" ]; then
        HAVE_MB=$(($(stat -c%s "$BALLAST" 2>/dev/null || echo 0) / 1024 / 1024))
        if [ "$HAVE_MB" -ge "$WANT_MB" ]; then
          echo "[disk-ballast] OK ''${HAVE_MB}MB present (target ''${WANT_MB}MB) — no-op"
          exit 0
        fi
        echo "[disk-ballast] Resizing: ''${HAVE_MB}MB → ''${WANT_MB}MB"
        rm -f "$BALLAST"
      fi

      USAGE=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
      if [ "$USAGE" -ge ${toString recreateThreshold} ]; then
        echo "[disk-ballast] Usage ''${USAGE}% ≥ ${toString recreateThreshold}% — refusing to allocate (free disk first)"
        exit 0
      fi

      echo "[disk-ballast] Allocating ''${WANT_MB}MB at $BALLAST (${toString ballastGB} GB — HM activation reserve)"
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "''${WANT_MB}M" "$BALLAST"
      else
        dd if=/dev/zero of="$BALLAST" bs=1M count="$WANT_MB" status=none
      fi
      chmod 600 "$BALLAST"
      echo "[disk-ballast] Reserved ''${WANT_MB}MB for rescue"
    '';
  };

  home.file.".local/share/system-protection/disk-ballast-create.service".text = ''
    [Unit]
    Description=Pre-allocate disk ballast (${toString ballastGB} GB HM-activation reserve)
    After=local-fs.target
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/disk-ballast-create.sh
  '';

  # Recreate after engine pre-flight or watchdog releases the ballast.
  home.file.".local/share/system-protection/disk-ballast-create.timer".text = ''
    [Unit]
    Description=Recreate disk ballast when /<${toString recreateThreshold}%
    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=1h
    [Install]
    WantedBy=timers.target
  '';

  home.activation.installDiskBallast = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[disk-ballast] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[disk-ballast] no sudo — skipping" && exit 0

    # ── Step 1: Remove cloud-provider's imperative ext4 5% reserve ──
    # Only on ext4 (btrfs has no equivalent). This frees the cloud-default
    # 5% reservation that protected only uid 0 — replaced by our ballast.
    ROOT_DEV=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE / 2>/dev/null || echo "")
    ROOT_FS=$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE / 2>/dev/null || echo "")
    if [ "$ROOT_FS" = "ext4" ] && [ -n "$ROOT_DEV" ]; then
      CUR=$($SUDO ${pkgs.e2fsprogs}/bin/tune2fs -l "$ROOT_DEV" 2>/dev/null | ${pkgs.gawk}/bin/awk -F: '/Reserved block count/ {gsub(/ /,"",$2); print $2}')
      if [ -n "$CUR" ] && [ "$CUR" -gt 0 ]; then
        echo "[disk-ballast] ext4 reserved blocks: $CUR → 0 (releasing cloud-default 5%)"
        $SUDO ${pkgs.e2fsprogs}/bin/tune2fs -m 0 "$ROOT_DEV" >/dev/null
      fi
    fi

    # ── Step 2: Install + start ballast creator ──
    SRC="$HOME/.local/share/system-protection"
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/disk-ballast-create.sh" /opt/scripts/disk-ballast-create.sh
    $SUDO chmod +x /opt/scripts/disk-ballast-create.sh
    $SUDO cp -f "$SRC/disk-ballast-create.service" /etc/systemd/system/disk-ballast-create.service
    $SUDO cp -f "$SRC/disk-ballast-create.timer" /etc/systemd/system/disk-ballast-create.timer
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable disk-ballast-create.timer 2>/dev/null || true
    $SUDO systemctl start disk-ballast-create.service 2>/dev/null || true

    echo "[disk-ballast] deployed: ${toString ballastGB} GB reserve at ${ballastPath}"
    ) || echo "[disk-ballast] FAILED — activation continues"
  '';
}
