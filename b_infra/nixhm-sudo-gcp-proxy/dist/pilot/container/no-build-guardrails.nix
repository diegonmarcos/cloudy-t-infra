# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/pilot/container/no-build-guardrails.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# container-control-no-build-guardrails.nix — HARD BLOCKER wrapper for docker
#
# BLOCKS docker build / buildx / compose --build on small VMs (<2GB RAM).
# A build on a 1GB E2 Micro saturates CPU/IO + OOMs → the box freezes and
# its WireGuard mesh goes dark (SSH/dagu unreachable). Builds MUST run on a
# runner — oci-apps (ARM, 24GB) or GHA — and small VMs only ever PULL the
# prebuilt GHCR image and `compose up --no-build`.
#
# RAM-conditional so the SAME module is safe everywhere: on the oci-apps
# runner (>=2GB) it warns-and-allows; on any <2GB VM it refuses (exit 1).
{ config, pkgs, lib, ... }:

{
  # Docker wrapper: hard-blocks build commands on small VMs, passes through otherwise.
  home.file.".local/bin/docker" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Total RAM (MB). Unknown → treat as large (fail-open for the wrapper,
      # never block a host we cannot size).
      _mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 99999999)
      _mem_mb=$(( _mem_kb / 1024 ))
      _SMALL=0
      [ "$_mem_mb" -lt 2048 ] && _SMALL=1

      _refuse() {
        echo "" >&2
        echo "╔══════════════════════════════════════════════════════════════╗" >&2
        echo "║  ⛔ BLOCKED: docker $1 on a small VM (''${_mem_mb}MB < 2GB)" >&2
        echo "║  A build here saturates the box and drops the WireGuard mesh.  ║" >&2
        echo "║  Build on a RUNNER (oci-apps ARM / GHA) → push to GHCR →       ║" >&2
        echo "║  pull the prebuilt image here with: compose up -d --no-build.  ║" >&2
        echo "╚══════════════════════════════════════════════════════════════╝" >&2
        exit 1
      }

      case "$1" in
        build|buildx)
          [ "$_SMALL" = 1 ] && _refuse "$1"
          echo "⚠  docker $1 on a ''${_mem_mb}MB host — prefer a runner (oci-apps/GHA)." >&2
          ;;
        compose)
          for arg in "$@"; do
            case "$arg" in
              --build)
                [ "$_SMALL" = 1 ] && _refuse "compose --build"
                echo "⚠  docker compose --build on a ''${_mem_mb}MB host — prefer --no-build + prebuilt image." >&2
                ;;
            esac
          done
          ;;
      esac
      # Strip .local/bin from PATH (avoid wrapper recursion), then ensure
      # canonical bin paths are present so non-interactive SSH shells
      # (which get a stripped PATH) can still find docker on both NixOS
      # (/run/current-system/sw/bin) and Debian/Ubuntu (/usr/bin).
      PATH="$(printf "%s" "$PATH" | tr ':' '\n' | grep -v '\.local/bin' | tr '\n' ':')"
      PATH="/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
      exec docker "$@"
    '';
  };
}
