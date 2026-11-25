# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/container/tools.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Shared CLI tools — imported by ALL VMs.
# Containers mount ~/.nix-profile/bin to share these binaries.
# Cloud-specific SDKs (gcloud, oci) go in the VM-specific .nix file.
{ lib, pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── Code analysis ──
    (callPackage ../pkgs/octocode.nix {})

    # ── Secrets ──
    sops
    age

    # ── JSON/YAML ──
    jq
    yq-go

    # ── File transfer ──
    rsync
    rclone

    # ── Network ──
    curl
    wget
    netcat
    iputils        # ping
    openssl
    bind           # dig, nslookup
    socat
    tcpdump        # packet capture — operator network debugging

    # ── System ──
    htop
    btop
    tmux
    ttyd
    ncdu
    tree
    lsof
    iftop
    iotop
    sysstat      # iostat, mpstat, pidstat, sar
    bc
    inotify-tools

    # ── Git ──
    git
    gh
    cacert          # CA certificates — needed by nix git/curl inside containers

    # ── Text ──
    ripgrep
    fd
    bat

    # ── Compression ──
    gzip
    unzip
    zip

    # ── Node.js runtime (shared with containers via nix-profile bind mount) ──
    nodejs_22

    # ── Container runtime ──
    docker
    docker-compose
    # REMOVED 2026-05-06: docker-buildx (~32 MB) — image builds run inside
    # the cloud-builder-x container on oci-apps; host shell never invokes
    # buildx directly.
    # REMOVED 2026-05-06: youki (~30 MB) — alternate OCI runtime never
    # configured to replace runc; dead weight on every VM.
    # REMOVED 2026-05-06: podman (~50 MB) — we use docker daemon
    # exclusively; podman never invoked from any module.

    # ── Database clients ──
    sqlite             # journal-ntfy + small agents
    # REMOVED 2026-05-06: postgresql_16 (~28 MB) — clients ship inside
    # services that need them (cypht-postgres, etc.).
    # REMOVED 2026-05-06: mariadb (~247 MB) — services bundle their own.

    # ── Backup ──
    rustic-rs

    # ── WireGuard ──
    wireguard-tools

    # ── Security scanning (YARA rules engine) ──
    yara
  ];

  # Static busybox for Docker healthcheck probes in distroless containers.
  # Bind-mount ~/bin/busybox-static into containers that lack wget/nc.
  home.file."bin/busybox-static" = {
    source = "${pkgs.pkgsStatic.busybox}/bin/busybox";
  };

  # HM always wins — remove imperative nix profile packages that conflict
  home.activation.removeImperativePackages = lib.hm.dag.entryBefore ["installPackages"] ''
    if command -v nix >/dev/null 2>&1 && nix profile list >/dev/null 2>&1; then
      for pkg in $(nix profile list 2>/dev/null | grep "^Name:" | sed 's/.*Name:[[:space:]]*//' | sed 's/\x1b\[[0-9;]*m//g'); do
        echo "[hm] Removing imperative nix profile package: $pkg"
        nix profile remove "$pkg" 2>/dev/null || true
      done
    fi
  '';

  # Auto-update git submodules in all repos on activation.
  # Ensures cloud-data submodule is always fresh.
  home.activation.gitSubmoduleUpdate = lib.hm.dag.entryAfter ["linkGeneration"] ''
    for repo in "$HOME/git/cloud-t-infra" "$HOME/git/front-diegonmarcos" "$HOME/git/cloud-infra-desktop"; do
      [ -d "$repo/.git" ] || continue
      [ -f "$repo/.gitmodules" ] || continue
      printf "[git-submodules] Updating submodules in %s\n" "$repo"
      ${pkgs.git}/bin/git -C "$repo" submodule update --remote --init 2>/dev/null || true
    done
  '';
}
