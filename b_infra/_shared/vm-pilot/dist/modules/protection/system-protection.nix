# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/protection/system-protection.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Orchestrator
#
# Reads VM specs from _cloud-data-consolidated.json[._home_manager.vms] (ram_gb, rescue_port)
# 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
# Imports sub-modules with derived parameters.
#
# Usage: (import ./protection/system-protection.nix { inherit config pkgs lib; vmName = "gcp-proxy"; })
{ config, pkgs, lib, vmName, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
  };
  vmData = cloudData.vms.${vmName};
  ramMB = vmData.specs.ram_gb * 1024;
  cpus = vmData.specs.cpu;
  rescuePort = vmData.rescue_port;
  userName = vmData.user;
  userId = 1000;
in {
  imports = [
    (import ./resource-bouncer.nix { inherit config pkgs lib ramMB vmName; })
    (import ./watchdog.nix { inherit config pkgs lib ramMB vmName; })
    (import ./load-shedder.nix { inherit config pkgs lib ramMB vmName; })
    (import ./rescue-ssh.nix { inherit config pkgs lib rescuePort; })
    (import ./scheduler.nix { inherit config pkgs lib ramMB; })
    (import ./layer2-identity.nix { inherit config pkgs lib ramMB cpus userName userId; })
    (import ./disk-ballast.nix { inherit config pkgs lib; })
    # Phase 2: tier-1 app cgroup reservations + circuit-breaker auto-restart
    (import ./tier1-apps.nix { inherit config pkgs lib vmName; })
    # #1886: one-shot per boot that brings the declared (non tier-1) containers back
    (import ./boot-start-declared.nix { inherit config pkgs lib vmName; })
    (import ../dashboard/dashboard.nix { inherit vmName; })
    (import ../agents/health-agent.nix { inherit config pkgs lib vmName; })
    # my-webserver + my-watchdog: the two jobs vm-pilot used to implement
    # itself, now their own products in cloud-u-linux. vm-pilot deploys them.
    (import ../agents/my-stack.nix { inherit vmName ramMB; })
    # guardrails.nix disabled (POSIX sh bug)
    # no-build-guard.nix imported by default.nix directly
  ];
}
