{ config, pkgs, lib, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager + .home_manager]
  consolidated = builtins.fromJSON (builtins.readFile ./pilot/_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    home_manager = consolidated.home_manager or { state_version = "24.11"; };
  };
  vmData = cloudData.vms."oci-analytics";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "oci-analytics"; })
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # dockerd pulls up to 3 layers in parallel by default. On this 1 GB E2 Micro
  # the home-manager image pull timed out / hit "unexpected EOF" twice on
  # 2026-11-18 (ship runs 44259524045, 44294316188) while the other VMs pulled
  # fine. Two parallel layer streams is gentler on its CPU and link; the pull
  # itself also retries with backoff (hm-pull-retry in the HM activate step).
  # Live-reloadable key: daemon.nix applies it with a reload, not a restart.
  docker.daemon.settings."max-concurrent-downloads" = 2;

  # VM-specific aliases (analytics tools)
  programs.bash.shellAliases = { };
}
