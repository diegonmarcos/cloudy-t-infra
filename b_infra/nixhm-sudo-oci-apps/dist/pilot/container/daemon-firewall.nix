# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/container/daemon-firewall.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — firewall policy
#
# Docker is FORBIDDEN from touching iptables/nftables.
# network-firewall.nix is the SINGLE OWNER of all packet filtering rules.
# It flushes ALL tables on every run and rebuilds from scratch.
#
# Rules:
#   iptables    false — Docker creates zero iptables rules (no DNAT, no FORWARD, no NAT)
#   ip6tables   false — same for IPv6
#
# Consequence: automatic port publishing (docker run -p) will NOT work.
# This is intentional — all containers use network_mode: host and bind
# directly to localhost ports. Caddy reverse-proxies them via WireGuard.
{ config, pkgs, lib, ... }:

{
  docker.daemon.settings = {
    iptables = false;
    ip6tables = false;
  };
}
