# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/protection/no-build-guard.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# No-Build Guard — WARNING-ONLY for resource-constrained VMs
#
# Prints loud warnings when build commands are used on small VMs (<2GB RAM).
# Does NOT block or remove anything — just reminds operators to use --no-build.
#
# Only oci-apps* (ARM, 24GB) should be excluded from this module.
# All x86 VMs (gcp-proxy, oci-mail, oci-analytics) MUST import this.
{ config, lib, pkgs, ... }:

{
  # ── MOTD warning: remind operators this is a small VM ──────────
  home.file.".local/share/no-build-guard/motd-warning.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║  ⚠  SMALL VM (<2GB RAM) — DO NOT BUILD HERE               ║"
      echo "╠══════════════════════════════════════════════════════════════╣"
      echo "║  docker compose up -d --no-build   ← ALWAYS use --no-build║"
      echo "║  docker build / nix build           ← will OOM this VM    ║"
      echo "║                                                            ║"
      echo "║  Build via: GHA runner, local machine, or oci-apps (24GB) ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""
    '';
  };
}
