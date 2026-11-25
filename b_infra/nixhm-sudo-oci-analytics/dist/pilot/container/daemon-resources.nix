# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/container/daemon-resources.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — resource limits (documentation only)
#
# Docker resource limits are NOT configured in daemon.json.
# They are managed by systemd drop-ins in system-protection-resource-bouncer.nix,
# which calculates limits dynamically from VM RAM specs in cloud-data.
#
# ┌─────────────────────────────────────────────────────────────────┐
# │ This file exists for organizational consistency across the      │
# │ container-control-daemon module family. No active config here.  │
# └─────────────────────────────────────────────────────────────────┘
#
# === Actual enforcement ===
#
# Deployed to: /etc/systemd/system/docker.service.d/memory-cap.conf
# Source:      system-protection-resource-bouncer.nix
#
#   MemoryMax       = RAM - 350MB (1GB VMs) to RAM - 1GB (24GB VMs)
#   MemoryHigh      = MemoryMax × 90%  (triggers kernel memory pressure)
#   OOMScoreAdjust  = 500              (high priority for OOM killer)
#
# CPUQuota = 80% is in the docker.service unit (container-control-init.nix)
#
{ config, pkgs, lib, ... }:

{
  # NO config here — 2026-07-03 oci-mail incident: this file wrote a SECOND
  # competing /etc/docker/daemon.json (ulimits/log object) racing with
  # container/init.nix's youki object; a torn write during a watchdog reboot
  # concatenated both and bricked dockerd. Single writer = container/init.nix.
}
