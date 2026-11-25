# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/security/authorized-keys.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Declarative authorized_keys management for Home Manager
# Reads extra SSH public keys from .secrets (sops-decrypted) and ensures
# they are present in ~/.ssh/authorized_keys without removing existing keys
{ config, lib, ... }:

{
  home.activation.authorizedKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[authorized-keys] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    AK_LOG="[authorized-keys]"
    AK_FILE="$HOME/.ssh/authorized_keys"
    SECRETS="$HOME/.config/home-manager/.secrets"

    if [ ! -f "$SECRETS" ]; then
      echo "$AK_LOG No .secrets file — skipping"
      exit 0
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$AK_FILE"
    chmod 600 "$AK_FILE"

    CHANGED=0

    # Read all *_PUB keys from .secrets (KEY=VALUE format)
    while IFS='=' read -r key value; do
      case "$key" in
        *_PUB)
          # Strip surrounding quotes if present
          value=$(echo "$value" | sed 's/^"//;s/"$//')
          if [ -n "$value" ] && ! grep -qF "$value" "$AK_FILE" 2>/dev/null; then
            echo "$value" >> "$AK_FILE"
            echo "$AK_LOG Added key from $key"
            CHANGED=1
          fi
          ;;
      esac
    done < "$SECRETS"

    if [ "$CHANGED" = "0" ]; then
      echo "$AK_LOG All keys already present — no changes"
    fi
    ) || echo "[authorized-keys] FAILED — see errors above, activation continues"
  '';
}
