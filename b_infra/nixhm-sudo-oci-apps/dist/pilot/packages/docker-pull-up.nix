# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/packages/docker-pull-up.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Docker Pull & Up — serial image pull + compose up for all VM services
# Reads from cloud-data-containers-{vm}.json manifest (deployed by GHA)
# or falls back to filesystem discovery in /opt/containers/
#
# Script is standalone POSIX sh — Nix just copies it.
# Source: _shared/modules/vm-images-pull-up.sh
{ config, lib, ... }:

{
  home.file.".local/share/docker-pull-up/vm-images-pull-up.sh" = {
    executable = true;
    source = ./vm-images-pull-up.sh;
  };

  home.activation.installDockerPullUp = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$HOME/.local/share/docker-pull-up/vm-images-pull-up.sh" /opt/scripts/vm-images-pull-up.sh
    $SUDO chmod +x /opt/scripts/vm-images-pull-up.sh
    echo "[docker-pull-up] deployed: /opt/scripts/vm-images-pull-up.sh"
    ) || echo "[docker-pull-up] FAILED — activation continues"
  '';
}
