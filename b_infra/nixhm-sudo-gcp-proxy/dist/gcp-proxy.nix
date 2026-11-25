# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/gcp-proxy.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ config, pkgs, lib, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager + .home_manager]
  consolidated = builtins.fromJSON (builtins.readFile ./pilot/_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    home_manager = consolidated.home_manager or { state_version = "24.11"; };
  };
  vmData = cloudData.vms."gcp-proxy";

  # #1872 Go port of gcp-idtoken-bridge (stdlib only, so no vendored modules). buildGoModule
  # runs its go test in the check phase; the Python-vs-Go shadow harness is behind -tags shadow.
  gcpIdtokenBridgeGo = pkgs.buildGoModule {
    pname = "gcp-idtoken-bridge";
    version = "1872";
    src = ./gcp-idtoken-bridge/go;
    vendorHash = null;
    CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" ];
  };
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
  home.file.".local/share/gcp-idtoken-bridge/ports.json".source = ./gcp-idtoken-bridge/ports.json;
  home.file.".local/share/gcp-idtoken-bridge/gcp-idtoken-bridge.service".text = ''
    [Unit]
    Description=GCP ID-token bridge for Cloud Run (metadata server, WG-only)
    After=network-online.target wg-quick@wg0.service
    Wants=network-online.target

    [Service]
    Type=simple
    Environment=BRIDGE_ROUTES=/opt/gcp-idtoken-bridge/routes.json
    Environment=BRIDGE_PORTS=/opt/gcp-idtoken-bridge/ports.json
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

  # #1872 canary: the Go port runs NEXT TO bridge.py, router mode only, on 10.0.0.1:9121 (same
  # routes file). bridge.py keeps 9120 and every per-service listener (ports.json) until the
  # canary is proven; nothing points at 9121 yet. Activation probes the canary and compares its
  # /_health and unknown-service answers with bridge.py's, and logs the verdict.
  home.file.".local/share/gcp-idtoken-bridge/gcp-idtoken-bridge-go" = { executable = true; source = "${gcpIdtokenBridgeGo}/bin/gcp-idtoken-bridge"; };
  home.file.".local/share/gcp-idtoken-bridge/gcp-idtoken-bridge-go.service".text = ''
    [Unit]
    Description=GCP ID-token bridge for Cloud Run, Go port canary (metadata server, WG-only, #1872)
    After=network-online.target wg-quick@wg0.service
    Wants=network-online.target

    [Service]
    Type=simple
    Environment=BRIDGE_ROUTES=/opt/gcp-idtoken-bridge/routes.json
    Environment=BRIDGE_LISTEN=10.0.0.1
    Environment=BRIDGE_PORT=9121
    ExecStart=/opt/gcp-idtoken-bridge/gcp-idtoken-bridge-go
    Restart=always
    RestartSec=5
    MemoryMax=32M
    CPUQuota=20%
    DynamicUser=yes
    NoNewPrivileges=yes
    ProtectSystem=strict

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installGcpIdtokenBridgeGo = lib.hm.dag.entryAfter ["installGcpIdtokenBridge"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0
    SRC="$HOME/.local/share/gcp-idtoken-bridge"
    $SUDO mkdir -p /opt/gcp-idtoken-bridge
    $SUDO install -m 0755 "$SRC/gcp-idtoken-bridge-go" /opt/gcp-idtoken-bridge/gcp-idtoken-bridge-go
    $SUDO cp -f "$SRC/gcp-idtoken-bridge-go.service" /etc/systemd/system/gcp-idtoken-bridge-go.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable gcp-idtoken-bridge-go.service 2>/dev/null || true
    $SUDO systemctl restart gcp-idtoken-bridge-go.service 2>/dev/null || true
    sleep 2
    B=/opt/gcp-idtoken-bridge/gcp-idtoken-bridge-go
    if $B -healthcheck http://10.0.0.1:9121/_health; then
      echo "[gcp-idtoken-bridge-go] canary up on 10.0.0.1:9121"
    else
      echo "[gcp-idtoken-bridge-go] canary NOT healthy on 10.0.0.1:9121"
    fi
    if command -v curl >/dev/null 2>&1; then
      ok=1
      for path in /_health /no-such-service/x; do
        a=$(curl -s -m 5 -w ' %{http_code}' "http://10.0.0.1:9120$path" || true)
        b=$(curl -s -m 5 -w ' %{http_code}' "http://10.0.0.1:9121$path" || true)
        [ "$a" = "$b" ] || { ok=0; echo "[gcp-idtoken-bridge-go] canary differs on $path: python='$a' go='$b'"; }
      done
      [ "$ok" = 1 ] && echo "[gcp-idtoken-bridge-go] canary-compare PASS (health, unknown service)"
    fi
    ) || echo "[gcp-idtoken-bridge-go] FAILED — activation continues"
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
    $SUDO cp -f "$SRC/bridge.py" "$SRC/routes.json" "$SRC/ports.json" /opt/gcp-idtoken-bridge/
    $SUDO cp -f "$SRC/gcp-idtoken-bridge.service" /etc/systemd/system/gcp-idtoken-bridge.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable gcp-idtoken-bridge.service 2>/dev/null || true
    $SUDO systemctl restart gcp-idtoken-bridge.service 2>/dev/null || true
    echo "[gcp-idtoken-bridge] deployed"
    ) || echo "[gcp-idtoken-bridge] FAILED — activation continues"
  '';
}
