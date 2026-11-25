# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/oci-mail.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager + .home_manager]
  consolidated = builtins.fromJSON (builtins.readFile ./pilot/_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    home_manager = consolidated.home_manager or { state_version = "24.11"; };
  };
  vmData = cloudData.vms."oci-mail";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "oci-mail"; })
    ./tls-acme.nix
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # VM-specific packages
  home.packages = with pkgs; [ swaks ];

  # VM-specific aliases (mail tools)
  programs.bash.shellAliases = {
    mailogs = "docker logs -f mailu-front-1";
    mailqueue = "docker exec -it mailu-smtp-1 postqueue -p";
  };
}
