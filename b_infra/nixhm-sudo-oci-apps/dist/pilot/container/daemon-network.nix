# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/container/daemon-network.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — network topology
#
# Network is PERMISSIVE by default — all containers can communicate freely.
# Traffic restrictions are enforced by network-firewall.nix (iptables FORWARD chain),
# not by Docker daemon settings.
#
# Rules:
#   dns   Internal Hickory DNS (10.0.0.1) as primary, Cloudflare (1.1.1.1) as fallback.
#         Read from _cloud-data-consolidated.json at nix eval time.
# 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[.native.dns]
{ config, pkgs, lib, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    dns = consolidated.native.dns or {};
  };
in {
  docker.daemon.settings = {
    dns = [ cloudData.dns.primary cloudData.dns.fallback ];
  };
}
