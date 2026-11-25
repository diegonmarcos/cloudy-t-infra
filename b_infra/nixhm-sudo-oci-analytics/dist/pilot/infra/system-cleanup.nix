# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/infra/system-cleanup.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Declarative system package cleanup
# Removes OS-level packages that conflict with nix-profile binaries.
# Runs on every home-manager activation to prevent drift.
#
# Why: Ubuntu/Fedora ship docker, containerd, runc, snapd etc. that
# shadow or conflict with nix-managed versions. This module ensures
# only nix binaries are used.
{ config, lib, pkgs, ... }:

let
  # Packages to remove — these conflict with nix-profile binaries
  # or are unnecessary on declaratively managed VMs
  debPackages = [
    "docker.io"
    "docker-ce"
    "docker-ce-cli"
    "docker-ce-rootless-extras"
    "docker-buildx-plugin"
    "docker-compose-plugin"
    "docker-model-plugin"
    "docker-compose"
    "containerd"
    "containerd.io"
    "runc"
    "snapd"
    "cloudflared"
  ];

  rpmPackages = [
    "moby-engine"
    "moby-engine-nano"
    "moby-filesystem"
    "docker-cli"
    "docker-buildx"
    "containerd"
  ];

  debList = lib.concatStringsSep " " debPackages;
  rpmList = lib.concatStringsSep " " rpmPackages;

in {
  home.activation.systemCleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[system-cleanup] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    CLEANUP_PREFIX="[system-cleanup]"
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "$CLEANUP_PREFIX no sudo found, skipping" && exit 0

    # ── Kill bloatware services before package removal ──────────────
    # Oracle Cloud Agent: 3 Go processes eating ~20% CPU + 36MB on 1GB VMs
    # cloudflared: Cloudflare tunnel not needed (traffic via gcp-proxy Caddy)
    for svc in snap.oracle-cloud-agent.oracle-cloud-agent.service \
               snap.oracle-cloud-agent.oracle-cloud-agent-updater.service \
               cloudflared.service; do
      if $SUDO systemctl is-active "$svc" >/dev/null 2>&1; then
        $SUDO systemctl stop "$svc" 2>/dev/null || true
        $SUDO systemctl disable "$svc" 2>/dev/null || true
        $SUDO systemctl mask "$svc" 2>/dev/null || true
        echo "$CLEANUP_PREFIX stopped+masked $svc"
      fi
    done

    # Kill processes directly (catches non-systemd installs)
    for proc in cloudflared oracle-cloud-agent; do
      if $SUDO pkill -f "$proc" 2>/dev/null; then
        echo "$CLEANUP_PREFIX killed $proc processes"
      fi
    done

    # Remove Oracle Cloud Agent snap + snapd itself (frees ~80MB disk + RAM)
    if command -v snap >/dev/null 2>&1; then
      for s in oracle-cloud-agent core18; do
        if snap list "$s" >/dev/null 2>&1; then
          $SUDO snap stop "$s" 2>/dev/null || true
          $SUDO snap disable "$s" 2>/dev/null || true
          $SUDO snap remove "$s" 2>/dev/null || true
          echo "$CLEANUP_PREFIX removed snap: $s"
        fi
      done
      # Stop snapd itself — saves 5% CPU on E2 Micros
      $SUDO systemctl stop snapd snapd.socket snapd.seeded 2>/dev/null || true
      $SUDO systemctl disable snapd snapd.socket 2>/dev/null || true
      $SUDO systemctl mask snapd snapd.socket 2>/dev/null || true
      echo "$CLEANUP_PREFIX stopped+masked snapd"
    fi

    if command -v dpkg >/dev/null 2>&1; then
      # Debian/Ubuntu
      TO_REMOVE=""
      for pkg in ${debList}; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
          TO_REMOVE="$TO_REMOVE $pkg"
        fi
      done
      if [ -n "$TO_REMOVE" ]; then
        echo "$CLEANUP_PREFIX removing conflicting system packages:$TO_REMOVE"
        $SUDO apt-get remove -y $TO_REMOVE 2>&1 | tail -3
        $SUDO systemctl daemon-reload 2>/dev/null || true
      else
        echo "$CLEANUP_PREFIX no conflicting system packages found"
      fi

    elif command -v rpm >/dev/null 2>&1; then
      # Fedora/RHEL
      TO_REMOVE=""
      for pkg in ${rpmList}; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
          TO_REMOVE="$TO_REMOVE $pkg"
        fi
      done
      if [ -n "$TO_REMOVE" ]; then
        echo "$CLEANUP_PREFIX removing conflicting system packages:$TO_REMOVE"
        $SUDO dnf remove -y $TO_REMOVE 2>&1 | tail -3
        $SUDO systemctl daemon-reload 2>/dev/null || true
      else
        echo "$CLEANUP_PREFIX no conflicting system packages found"
      fi
    fi
    ) || echo "[system-cleanup] FAILED — see errors above, activation continues"
  '';
}
