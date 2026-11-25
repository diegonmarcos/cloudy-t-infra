# systemd-control.nix — Disable Docker + Ubuntu bloat from systemd
#
# Two categories:
#   1. Docker — container-init.service owns Docker lifecycle
#   2. Ubuntu bloat — fwupd, snapd, unattended-upgrades, release-upgrader
#      These waste 300-400MB RAM on 1GB VMs for features we don't use
#      (nix manages packages, no physical firmware, no in-place OS upgrades)
#
# Runs AFTER all other activations — always has the last word.
# quiesce: units that must not run at all on this VM (low-memory class, #1898): disabled,
# stopped, and masked when the unit exists, so neither a timer nor a D-Bus/socket activation
# can start them. extraBlacklist keeps the old disable-only behaviour.
{ extraBlacklist ? [], quiesce ? [] }:

{ config, pkgs, lib, ... }:

let
  # Docker — container-init.sh handles its lifecycle
  dockerBlacklist = [
    "docker.service"
    "docker.socket"
  ];

  # Ubuntu bloat — useless on declaratively-managed cloud VMs
  # fwupd: firmware updater (no physical hardware on VMs) — 176MB RSS
  # snapd: snap package manager (we use nix + docker) — 40MB RSS
  # unattended-upgrades: apt auto-updates (we use nix) — 23MB RSS
  # apt-daily: apt metadata refresh — triggers unattended-upgrades
  # ubuntu-advantage: Ubuntu Pro telemetry
  ubuntuBloatBlacklist = [
    "fwupd.service"
    "fwupd-refresh.timer"
    "unattended-upgrades.service"
    "apt-daily.timer"
    "apt-daily-upgrade.timer"
    "snapd.service"
    "snapd.socket"
    "snapd.seeded.service"
    "snapd.snap-repair.timer"
    "ua-timer.timer"
    "ubuntu-advantage.service"
  ];

  blacklist = dockerBlacklist ++ ubuntuBloatBlacklist ++ extraBlacklist;

  blacklistBash = lib.concatMapStringsSep " " (u: ''"${u}"'') blacklist;

  quiesceBash = lib.concatMapStringsSep " " (u: ''"${u}"'') quiesce;

  allActivations = [
    "installContainerInit"
    "configureHickoryDns"
    "systemCleanup"
    "sshdHardening"
    "nixPathEtcEnvironment"
    "sshKeys"
    "authorizedKeys"
    "sharedNodeModules"
    "mcpNodeModulesSymlinks"
    "gitSubmoduleUpdate"
    "noBuildGuard"
    "installResourceBouncer"
    "installWatchdogDropbear"
    "installFirewall"
  ];

in {
  home.activation.systemdControl = lib.hm.dag.entryAfter allActivations ''
    (
    LOG="[systemd-control]"
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    DISABLED=0
    BLACKLIST=(${blacklistBash})
    for unit in "''${BLACKLIST[@]}"; do
      if $SUDO systemctl is-enabled "$unit" >/dev/null 2>&1; then
        # disable only — do NOT use --now (would kill running Docker during HM activation)
        # Docker lifecycle is owned by container-init, which starts it on boot
        $SUDO systemctl disable "$unit" 2>/dev/null
        DISABLED=$((DISABLED + 1))
        echo "$LOG DISABLED: $unit"
      fi
    done
    # quiesce list (low-memory VMs): disable, stop, mask. Absent units are skipped so no
    # dangling /dev/null symlink is created on a distro that does not ship them. Every
    # systemctl is timeout-capped: activation must never block on a thrashing box.
    QUIESCE=(${quiesceBash})
    for unit in "''${QUIESCE[@]}"; do
      if timeout 10 $SUDO systemctl cat "$unit" >/dev/null 2>&1; then
        timeout 10 $SUDO systemctl disable "$unit" >/dev/null 2>&1 || true
        timeout 20 $SUDO systemctl stop --no-block "$unit" >/dev/null 2>&1 || true
        timeout 10 $SUDO systemctl mask "$unit" >/dev/null 2>&1 || true
        DISABLED=$((DISABLED + 1))
        echo "$LOG QUIESCED: $unit"
      fi
    done
    $SUDO systemctl daemon-reload
    echo "$LOG Done: $DISABLED units disabled (Docker=container-init, Ubuntu bloat=removed)"
    ) || echo "[systemd-control] FAILED — activation continues"
  '';
}
