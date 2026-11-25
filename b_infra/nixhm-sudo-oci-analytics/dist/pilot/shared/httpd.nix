# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/shared/httpd.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Lightweight static HTTP server module for Home Manager
# Uses busybox httpd — ~100KB RAM per site
# Pattern: shared module, per-VM config via `sites` parameter
#
# Usage in VM's .nix:
#   (import ./httpd.nix {
#     sites = {
#       cloud-spec = { root = "/opt/containers/cloud-spec"; port = 8099; };
#     };
#   })
{ sites ? {} }:

{ config, lib, pkgs, ... }:

let
  # Generate httpd.conf for a site
  mkHttpdConf = name: site: ''
    # ${name} — busybox httpd config (auto-generated)
    *.html:text/html
    *.css:text/css
    *.js:application/javascript
    *.json:application/json
    *.png:image/png
    *.jpg:image/jpeg
    *.svg:image/svg+xml
    *.woff2:font/woff2
    *.woff:font/woff
    *.ttf:font/ttf
    *.ico:image/x-icon
    *.txt:text/plain
    *.xml:application/xml
  '';

  # Generate systemd unit for a site
  mkSystemdUnit = name: site: {
    name = "httpd-${name}.service";
    value = ''
      [Unit]
      Description=Static HTTP server for ${name}
      After=network.target

      [Service]
      Type=simple
      ExecStart=${pkgs.busybox}/bin/busybox httpd -f -p ${toString site.port} -c /etc/httpd/${name}.conf -h ${site.root}
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    '';
  };

  sitesList = lib.attrsets.mapAttrsToList (name: site: { inherit name site; }) sites;

in lib.mkIf (sites != {}) {
  home.packages = [ pkgs.busybox ];

  home.activation.httpd = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[httpd] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    HTTPD_LOG_PREFIX="[httpd]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$HTTPD_LOG_PREFIX ERROR: sudo not found"
      exit 1
    fi

    $SUDO mkdir -p /etc/httpd

    ${lib.concatMapStrings ({ name, site }: ''
      # ── ${name} (port ${toString site.port}) ──
      NEW_CONF=$(cat <<'HTTPDCONF'
${mkHttpdConf name site}
HTTPDCONF
      )

      CONF_FILE="/etc/httpd/${name}.conf"
      CURRENT=""
      if [ -f "$CONF_FILE" ]; then
        CURRENT=$(cat "$CONF_FILE" 2>/dev/null || true)
      fi

      if [ "$NEW_CONF" = "$CURRENT" ]; then
        echo "$HTTPD_LOG_PREFIX ${name}: config unchanged"
      else
        echo "$HTTPD_LOG_PREFIX ${name}: deploying config"
        echo "$NEW_CONF" | $SUDO tee "$CONF_FILE" > /dev/null
      fi

      # Systemd unit
      UNIT_FILE="/etc/systemd/system/httpd-${name}.service"
      NEW_UNIT=$(cat <<'UNITEOF'
[Unit]
Description=Static HTTP server for ${name}
After=network.target

[Service]
Type=simple
ExecStart=${pkgs.busybox}/bin/busybox httpd -f -p ${toString site.port} -c /etc/httpd/${name}.conf -h ${site.root}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
      )

      CURRENT_UNIT=""
      if [ -f "$UNIT_FILE" ]; then
        CURRENT_UNIT=$($SUDO cat "$UNIT_FILE" 2>/dev/null || true)
      fi

      if [ "$NEW_UNIT" = "$CURRENT_UNIT" ]; then
        echo "$HTTPD_LOG_PREFIX ${name}: unit unchanged"
      else
        echo "$HTTPD_LOG_PREFIX ${name}: deploying unit"
        echo "$NEW_UNIT" | $SUDO tee "$UNIT_FILE" > /dev/null
        $SUDO systemctl daemon-reload
      fi

      # Ensure running
      if ! $SUDO systemctl is-active "httpd-${name}" >/dev/null 2>&1; then
        echo "$HTTPD_LOG_PREFIX ${name}: starting"
        $SUDO systemctl enable --now "httpd-${name}"
      else
        if [ "$NEW_UNIT" != "$CURRENT_UNIT" ] || [ "$NEW_CONF" != "$CURRENT" ]; then
          echo "$HTTPD_LOG_PREFIX ${name}: restarting (config changed)"
          $SUDO systemctl restart "httpd-${name}"
        fi
      fi
    '') sitesList}
    ) || echo "[httpd] FAILED — see errors above, activation continues"
  '';
}
