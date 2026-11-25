# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/container/daemon-security.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Daemon — process isolation & security hardening
#
# Rules:
#   no-new-privileges  Containers cannot gain additional privileges via setuid/setgid
#   userland-proxy     Enabled — daemon-firewall.nix sets iptables = false, so Docker
#                      never programs DNAT rules for published ports. The userland
#                      proxy is then the only path from a published port to its
#                      container. With both disabled dockerd still binds the port,
#                      but nothing ever accepts: connections hang until they time out.
#   live-restore       Containers survive daemon restarts (upgrades, crashes)
#   log caps           10MB × 3 files per container — prevents disk exhaustion
#   ulimits            File descriptor cap at 65536 (soft + hard)
{ config, pkgs, lib, ... }:

{
  docker.daemon.settings = {
    no-new-privileges = true;
    userland-proxy = true;
    live-restore = true;

    log-driver = "json-file";
    log-opts = {
      max-size = "10m";
      max-file = "3";
    };

    default-ulimits = {
      nofile = {
        Name = "nofile";
        Hard = 65536;
        Soft = 65536;
      };
    };
  };
}
