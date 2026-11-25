# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/container/daemon.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Container Control Daemon — orchestrator for Docker daemon.json configuration
#
# Defines a custom HM option (docker.daemon.settings) that sub-modules
# contribute to. The merged attrset is serialized to daemon.json and
# deployed to /etc/docker/daemon.json via activation script.
#
# Sub-modules:
#   container-control-daemon-security.nix   — process isolation
#   container-control-daemon-firewall.nix   — iptables policy
#   container-control-daemon-network.nix    — DNS, topology
#   container-control-daemon-resources.nix  — pointer to system-protection
{ config, pkgs, lib, ... }:

{
  imports = [
    ./daemon-security.nix
    ./daemon-firewall.nix
    ./daemon-network.nix
    ./daemon-resources.nix
  ];

  # ── Custom option: sub-modules merge into this ─────────────────
  options.docker.daemon.settings = lib.mkOption {
    type = lib.types.attrs;
    default = {};
    description = "Docker daemon.json settings — merged from sub-modules";
  };

  # ── Generate daemon.json from merged settings ──────────────────
  config = {
    home.file.".local/share/container-init/daemon.json".text =
      builtins.toJSON config.docker.daemon.settings;

    # ── Activation: deploy daemon.json to /etc/docker/ ───────────
    home.activation.installDaemonJson = lib.hm.dag.entryAfter ["linkGeneration"] ''
      (
      trap 'echo "[docker-daemon] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
      SUDO=""
      for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
        [ -x "$p" ] && SUDO="$p" && break
      done
      if [ -z "$SUDO" ]; then
        echo "[docker-daemon] WARNING: sudo not found — skipping"
        exit 0
      fi

      DAEMON_SRC="$HOME/.local/share/container-init/daemon.json"
      DAEMON_DEST="/etc/docker/daemon.json"
      $SUDO mkdir -p /etc/docker

      # GUARD: refuse to deploy malformed JSON. builtins.toJSON emits ONE
      # object on ONE line; >1 '{'-lines means two modules both declared the
      # home.file (types.lines silently CONCATENATES) — deploying that config
      # kept dockerd crash-looping on oci-mail 2026-07-03. Keep last good
      # config, fail LOUD.
      if [ "$(grep -c '^{' "$DAEMON_SRC")" -gt 1 ]; then
        echo "[docker-daemon] ✗✗✗ REFUSING deploy: daemon.json is CONCATENATED (duplicate home.file writers) — dockerd would crash-loop ✗✗✗" >&2
        logger -p daemon.err -t docker-daemon "daemon.json malformed (concatenated writers) — deploy refused, keeping last good config" 2>/dev/null || true
        exit 1
      fi

      DJNEW=$(cat "$DAEMON_SRC")
      DJOLD=$($SUDO cat "$DAEMON_DEST" 2>/dev/null || true)
      if [ "$DJNEW" != "$DJOLD" ]; then
        # Atomic install (tmp + mv) — a half-written daemon.json bricks dockerd.
        echo "$DJNEW" | $SUDO tee "$DAEMON_DEST.tmp" > /dev/null
        $SUDO mv -f "$DAEMON_DEST.tmp" "$DAEMON_DEST"
        echo "[docker-daemon] daemon.json deployed"

        # A changed daemon.json is INERT until dockerd re-reads it, and SIGHUP
        # (systemctl reload) re-reads only the SHORT documented subset below —
        # dockerd "Configuration reload behavior". Every other key (userland-proxy,
        # bridge/MTU/DNS, iptables, storage-driver, default-address-pools,
        # log-driver…) keeps the value the daemon BOOTED with, indefinitely.
        # That is how 33d5abccc (userland-proxy: true) was silently ineffective
        # fleet-wide: the file was right, drift checks passed, and oci-apps was
        # still broken on all 10 published ports while oci-analytics ran an
        # 11-day-old daemon against a daemon.json rewritten 2026-09-05 20:42.
        # So diff the KEYS and pick reload vs restart accordingly.
        #
        # default-runtime/runtimes appear in Docker's documented reload list but
        # are deliberately EXCLUDED here: the 2026-07-03 oci-mail youki incident
        # showed a SIGHUP does not actually change the runtime in use. Anything
        # not proven reloadable belongs on the restart side.
        RELOADABLE='["allow-nondistributable-artifacts","authorization-plugins","debug","features","insecure-registries","labels","live-restore","max-concurrent-downloads","max-concurrent-uploads","max-download-attempts","registry-mirrors","shutdown-timeout"]'
        if printf '%s' "$DJOLD" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
          DIRTY=$(printf '%s\n%s\n' "$DJOLD" "$DJNEW" | ${pkgs.jq}/bin/jq -s -r --argjson ok "$RELOADABLE" '
            .[0] as $o | .[1] as $n
            | [ (($o|keys) + ($n|keys) | unique)[]
                | select(($o[.] // null) != ($n[.] // null))
                | select(([.] - $ok) | length > 0) ]
            | join(" ")')
        else
          # No parseable previous config = assume the daemon is running something
          # else entirely.
          DIRTY="(no parseable previous daemon.json)"
        fi

        if $SUDO systemctl is-active --quiet docker; then
          if [ -z "$DIRTY" ]; then
            $SUDO systemctl reload docker 2>/dev/null \
              && echo "[docker-daemon] docker reloaded (only live-reloadable keys changed)" \
              || echo "[docker-daemon] docker reload failed"
          else
            # live-restore is the ONLY reason a restart is non-disruptive:
            # containerd-shims survive and containers keep running (proven
            # 2026-09-05). Query the RUNNING daemon — the file on disk is
            # precisely the thing that has not been applied yet.
            LIVE_RESTORE=$($SUDO timeout 15 ${pkgs.docker}/bin/docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || echo unknown)
            if [ "$LIVE_RESTORE" = "true" ]; then
              echo "[docker-daemon] non-reloadable keys changed ($DIRTY) — restarting docker (live-restore on, containers survive)"
              $SUDO systemctl restart docker \
                && echo "[docker-daemon] docker restarted — daemon.json fully applied" \
                || { echo "[docker-daemon] ✗ docker restart FAILED ($DIRTY still not applied) — journalctl -u docker" >&2
                     logger -p daemon.err -t docker-daemon "docker restart failed; daemon.json not applied" 2>/dev/null || true; }
            else
              echo "[docker-daemon] ✗ REFUSING docker restart: live-restore is '$LIVE_RESTORE' on the running daemon — a restart would KILL every container. NOT applied: $DIRTY" >&2
              logger -p daemon.err -t docker-daemon "daemon.json changed ($DIRTY) but live-restore is not enabled — restart refused, config NOT applied" 2>/dev/null || true
            fi
          fi
        fi
      fi
      ) || echo "[docker-daemon] FAILED — see errors above, activation continues"
    '';
  };
}
