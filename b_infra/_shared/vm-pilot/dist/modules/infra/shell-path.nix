# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/infra/shell-path.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Ensure nix-profile binaries are in PATH for ALL contexts:
# - home.sessionPath → ~/.profile (login shells, SSH sessions)
# - home.sessionVariables → ~/.profile (env vars)
# - /etc/environment → PAM-level, covers non-login non-interactive SSH (GHA, cron, scripts)
# - /etc/systemd/system.conf.d/ → DefaultEnvironment for ALL root systemd services
{ lib, pkgs, config, ... }:
{
  home.sessionPath = [
    "$HOME/.nix-profile/bin"
    "$HOME/.local/bin"
    "/nix/var/nix/profiles/default/bin"
  ];

  home.sessionVariables = {
    SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt";
  };

  # /etc/environment is read by PAM before any shell — covers ALL session types
  # including non-login non-interactive SSH (where bash skips all dotfiles).
  home.activation.nixPathEtcEnvironment = lib.hm.dag.entryAfter ["writeBoundary"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[shell-path] WARNING: sudo not found — skipping /etc/environment"
      exit 0
    fi

    NIX_PATHS="/home/${config.home.username}/.nix-profile/bin:/nix/var/nix/profiles/default/bin"

    # Ensure /etc/environment exists
    $SUDO touch /etc/environment

    if $SUDO grep -qF '.nix-profile/bin' /etc/environment 2>/dev/null; then
      echo "[shell-path] /etc/environment already has nix PATH"
    else
      # Prepend nix paths to existing PATH or add new PATH line
      if $SUDO grep -q '^PATH=' /etc/environment 2>/dev/null; then
        $SUDO sed -i "s|^PATH=|PATH=$NIX_PATHS:|" /etc/environment
      else
        echo "PATH=$NIX_PATHS:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" | $SUDO tee -a /etc/environment >/dev/null
      fi
      echo "[shell-path] Added nix paths to /etc/environment"
    fi
    # systemd DefaultEnvironment — root services (watchdog, container-init, etc.)
    # /etc/environment only covers PAM sessions, not systemd-spawned services.
    SYSTEMD_CONF_DIR="/etc/systemd/system.conf.d"
    SYSTEMD_CONF="$SYSTEMD_CONF_DIR/nix-path.conf"
    WANT="[Manager]
DefaultEnvironment=PATH=$NIX_PATHS:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    $SUDO mkdir -p "$SYSTEMD_CONF_DIR"
    CURRENT=$($SUDO cat "$SYSTEMD_CONF" 2>/dev/null || true)
    if [ "$CURRENT" != "$WANT" ]; then
      echo "$WANT" | $SUDO tee "$SYSTEMD_CONF" > /dev/null
      $SUDO systemctl daemon-reexec 2>/dev/null || true
      echo "[shell-path] systemd DefaultEnvironment deployed (daemon-reexec)"
    fi

    # sudoers — add nix paths to secure_path so `sudo docker` works
    # without `sudo env PATH="$PATH"` workaround
    SUDOERS_NIX="/etc/sudoers.d/nix-path"
    SUDOERS_WANT="Defaults secure_path=\"$NIX_PATHS:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\""
    SUDOERS_CURRENT=$($SUDO cat "$SUDOERS_NIX" 2>/dev/null || true)
    if [ "$SUDOERS_CURRENT" != "$SUDOERS_WANT" ]; then
      echo "$SUDOERS_WANT" | $SUDO tee "$SUDOERS_NIX" > /dev/null
      $SUDO chmod 440 "$SUDOERS_NIX"
      $SUDO visudo -cf "$SUDOERS_NIX" >/dev/null 2>&1 || { $SUDO rm -f "$SUDOERS_NIX"; echo "[shell-path] WARN: sudoers syntax error, removed"; }
      echo "[shell-path] sudoers secure_path updated with nix paths"
    fi

    # Ensure nix multi-call symlinks exist (HM activate needs nix-build etc.)
    NIX_BIN="/nix/var/nix/profiles/default/bin"
    if [ -x "$NIX_BIN/nix" ]; then
      # if/then, not `[ ! -e ] && ln`: when every link already exists that
      # list returns 1, it was the subshell's last command, and every
      # converged activation printed "[shell-path] FAILED" with no error
      # above it (2026-11-18, oci-analytics run 44419144605).
      for cmd in nix-build nix-instantiate nix-env nix-store nix-channel; do
        if [ ! -e "$NIX_BIN/$cmd" ]; then
          $SUDO ln -sf nix "$NIX_BIN/$cmd" && echo "[shell-path] created $NIX_BIN/$cmd -> nix"
        fi
      done
    fi

    ) || echo "[shell-path] FAILED — see errors above, activation continues"
  '';
}
