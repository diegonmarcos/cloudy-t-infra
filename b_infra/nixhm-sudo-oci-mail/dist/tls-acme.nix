# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/tls-acme.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:
# Automated wildcard TLS cert for *.diegonmarcos.com via acme.sh + Cloudflare DNS-01.
# Writes cert to /opt/containers/maddy/tls/ (shared mount for maddy + stalwart).
# Monthly renewal via /etc/cron.monthly/tls-acme-renew.
# Reads CF_API_TOKEN from sops .secrets.d/ (HM secrets pipeline).
let
  tlsDir = "/opt/containers/maddy/tls";
  domain = "*.diegonmarcos.com";
  acmeEmail = "me@diegonmarcos.com";
  # acme.sh installed standalone at runtime (no Nix package) to avoid adding a
  # new package to home.packages which would invalidate the 2GB Nix store layer
  # and cause oci-mail (1GB E2-micro, 270s pull timeout) to fail the docker pull.
in {
  # Combined issue+renew script — handles both first-time issuance (no cert on disk)
  # and periodic renewal (--days 30). Installed to /etc/cron.monthly/ by activation.
  # Also called detached from activation to avoid blocking the SSH/HM session.
  home.file.".local/share/tls-acme/renew.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      HOME=/home/ubuntu
      # HM activation nohup inherits a minimal PATH — set explicitly
      export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin"
      SECRETS_D="$HOME/.config/home-manager/.secrets.d"
      CF_TOKEN_FILE="$SECRETS_D/CF_API_TOKEN"
      [ -f "$CF_TOKEN_FILE" ] || { echo "[tls-acme] No CF_API_TOKEN — skipping"; exit 0; }
      export CF_Token="$(cat "$CF_TOKEN_FILE")"
      TLS_DIR="${tlsDir}"
      ACME="$HOME/.acme.sh/acme.sh"

      # Bootstrap acme.sh standalone if not installed
      if [ ! -x "$ACME" ]; then
        echo "[tls-acme] Installing acme.sh standalone..."
        curl -fsSL https://get.acme.sh | sh -s email="${acmeEmail}" || { echo "[tls-acme] acme.sh install failed"; exit 1; }
      fi

      # First-time issuance if cert not present yet
      if [ ! -f "$TLS_DIR/fullchain.pem" ]; then
        echo "[tls-acme] No cert found — issuing for ${domain}..."
        "$ACME" --home "$HOME/.acme.sh" \
          --issue --dns dns_cf -d "${domain}" \
          --accountemail "${acmeEmail}" \
          --server letsencrypt \
          || { echo "[tls-acme] --issue failed"; exit 1; }
      fi

      # Renew if due (no-op otherwise)
      "$ACME" --home "$HOME/.acme.sh" --renew-all --days 30 || true

      # Deploy cert to shared TLS dir
      "$ACME" --home "$HOME/.acme.sh" --install-cert -d "${domain}" \
        --fullchain-file "$TLS_DIR/fullchain.pem" \
        --key-file "$TLS_DIR/privkey.pem" || true

      docker ps -q --filter 'name=stalwart' | xargs -r docker restart
      docker ps -q --filter 'name=maddy'    | xargs -r docker restart
      echo "[tls-acme] Done"
    '';
  };

  home.activation.tlsAcme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    SECRETS_D="$HOME/.config/home-manager/.secrets.d"
    CF_TOKEN_FILE="$SECRETS_D/CF_API_TOKEN"
    if [ ! -f "$CF_TOKEN_FILE" ]; then
      echo "[tls-acme] CF_API_TOKEN not found in secrets — skipping" >&2
      exit 0
    fi

    _SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && _SUDO="$p" && break
    done
    [ -z "$_SUDO" ] && echo "[tls-acme] sudo not found — skipping" >&2 && exit 0

    # Ensure TLS dir exists and is writable
    $_SUDO mkdir -p "${tlsDir}"
    $_SUDO chown "$(id -u):$(id -g)" "${tlsDir}"

    # Install monthly renewal cron
    $_SUDO install -m 755 \
      "$HOME/.local/share/tls-acme/renew.sh" \
      /etc/cron.monthly/tls-acme-renew

    # Launch cert issuance detached — DNS-01 challenge sleeps 20s+ which
    # would time out the SSH/HM activation session if run synchronously.
    nohup "$HOME/.local/share/tls-acme/renew.sh" > /tmp/tls-acme-init.log 2>&1 &

    echo "[tls-acme] Cert issuance running in background (log: /tmp/tls-acme-init.log)"
    echo "[tls-acme] Done"
    )
  '';
}
