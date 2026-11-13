{ config, pkgs, lib, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager + .home_manager]
  consolidated = builtins.fromJSON (builtins.readFile ./pilot/_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    home_manager = consolidated.home_manager or { state_version = "24.11"; };
  };
  vmData = cloudData.vms."gcp-proxy";
in {
  imports = [
    (import ./pilot/default.nix { vmName = "gcp-proxy"; })
  ];

  home.username = vmData.user;
  home.homeDirectory = vmData.home;
  home.stateVersion = cloudData.home_manager.state_version;
  programs.home-manager.enable = true;

  # ── VM-specific: GCP Guest Agent ──────────────────────────────────────
  home.packages = [ pkgs.google-guest-agent ];

  home.file.".local/share/gcp-agent/google-guest-agent.service".text = ''
    [Unit]
    Description=Google Guest Agent (nix)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=${pkgs.google-guest-agent}/bin/google_guest_agent
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installGcpAgent = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/gcp-agent"
    $SUDO cp -f "$SRC/google-guest-agent.service" /etc/systemd/system/google-guest-agent.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable google-guest-agent.service 2>/dev/null || true
    $SUDO systemctl restart google-guest-agent.service 2>/dev/null || true
    echo "[gcp-agent] Google Guest Agent deployed — startup scripts + rescue mode enabled"
    ) || echo "[gcp-agent] FAILED — see errors above"
  '';

  # ── #1686 gcp-idtoken-bridge: WG-only forwarder that mints metadata-server ID tokens (no key) for the IAM-only
  # Cloud Run services and sends them as X-Serverless-Authorization. Callers (oci-apps over wg0) use
  # http://10.0.0.1:9120/<service>/<path>. Routes: gcp-idtoken-bridge/routes.json (test-checked against terraform.json).
  home.file.".local/share/gcp-idtoken-bridge/bridge.py" = { executable = true; source = ./gcp-idtoken-bridge/bridge.py; };
  home.file.".local/share/gcp-idtoken-bridge/routes.json".source = ./gcp-idtoken-bridge/routes.json;
  home.file.".local/share/gcp-idtoken-bridge/gcp-idtoken-bridge.service".text = ''
    [Unit]
    Description=GCP ID-token bridge for Cloud Run (metadata server, WG-only)
    After=network-online.target wg-quick@wg0.service
    Wants=network-online.target

    [Service]
    Type=simple
    Environment=BRIDGE_ROUTES=/opt/gcp-idtoken-bridge/routes.json
    Environment=BRIDGE_LISTEN=10.0.0.1
    Environment=BRIDGE_PORT=9120
    ExecStart=/usr/bin/python3 /opt/gcp-idtoken-bridge/bridge.py
    Restart=always
    RestartSec=5
    MemoryMax=64M
    CPUQuota=20%
    DynamicUser=yes
    NoNewPrivileges=yes
    ProtectSystem=strict

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installGcpIdtokenBridge = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0
    SRC="$HOME/.local/share/gcp-idtoken-bridge"
    $SUDO mkdir -p /opt/gcp-idtoken-bridge
    $SUDO cp -f "$SRC/bridge.py" "$SRC/routes.json" /opt/gcp-idtoken-bridge/
    $SUDO cp -f "$SRC/gcp-idtoken-bridge.service" /etc/systemd/system/gcp-idtoken-bridge.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable gcp-idtoken-bridge.service 2>/dev/null || true
    $SUDO systemctl restart gcp-idtoken-bridge.service 2>/dev/null || true
    echo "[gcp-idtoken-bridge] deployed"
    ) || echo "[gcp-idtoken-bridge] FAILED — activation continues"
  '';
}
