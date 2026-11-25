# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/network/wireguard.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# WireGuard mesh configuration module for Home Manager
# Private keys owned by vault, deployed via sops secrets pipeline
#
# Parameterized to support multiple meshes (wg0 + wg-public) per VM.
#
# Usage:
#   wg0       (default — backward compatible):
#     (import ./network/wireguard.nix { inherit vmName; })
#   wg-public:
#     (import ./network/wireguard.nix {
#       inherit vmName;
#       interfaceName = "wg-public";
#       meshKey       = "wireguard_public";
#       secretEnvName = "WG_PUBLIC_PRIVATE_KEY";
#     })
{
  vmName,
  interfaceName ? "wg0",
  meshKey       ? "wireguard",
  secretEnvName ? "WG_PRIVATE_KEY",
}:

{ config, lib, pkgs, ... }:

let
  # ── Mesh topology from _cloud-data-consolidated.json[.native.<meshKey>] ────
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json
  # 2026-05-09 parameterized: meshKey selects wg0 (.native.wireguard) or
  #            wg-public (.native.wireguard_public). Same hub-and-spoke logic.
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    mesh = consolidated.native.${meshKey} or {};
  };

  # Endpoint in consolidated is "host:port" — split if public_ip/wg_port not present
  splitEndpoint = ep:
    let
      epStr = if ep == null then "" else ep;
      parts = lib.splitString ":" epStr;
    in {
      host = if (builtins.length parts) >= 1 then builtins.elemAt parts 0 else "";
      port = if (builtins.length parts) >= 2 then lib.toInt (builtins.elemAt parts 1) else (cloudData.mesh.port or 51820);
    };

  toTopoEntry = p:
    let ep = splitEndpoint (p.endpoint or null);
    in {
      address   = p.wg_ip;
      addressV6 = p.wg_ipv6 or null;
      endpoint  = p.public_ip or (if ep.host == "" then null else ep.host);
      port      = p.wg_port or ep.port;
      publicKey = p.wg_public_key;
      role      = p.role;
    };
  toClientEntry = name: c: {
    address   = c.wg_ip;
    addressV6 = c.wg_ipv6 or null;
    endpoint  = null;
    port      = null;
    publicKey = c.wg_public_key;
    role      = c.role;
    # Extra source addresses the hub accepts from this client (declared as
    # clients.<name>.extra_allowed_ips in the mesh owner's build.json).
    extraAllowedIps = c.extra_allowed_ips or [];
  };
  # Mesh ULA v6 subnet (null on IPv4-only meshes / wg-public until added)
  subnetV6 = cloudData.mesh.subnet_v6 or null;

  # Build topology from JSON peers (VMs) + clients (surface, termux)
  # Keep all peers (even with null keys) so every VM can find itself in the map.
  # Peers with null keys are excluded later when generating [Peer] blocks.
  allPeerEntries = builtins.listToAttrs (
    map (p: { name = p.name; value = toTopoEntry p; }) (cloudData.mesh.peers or [])
  );
  clientEntries = lib.mapAttrs toClientEntry (cloudData.mesh.clients or {});
  topology = allPeerEntries // clientEntries;

  thisVm =
    if topology ? ${vmName} then topology.${vmName}
    else throw ''
      wireguard.nix: VM "${vmName}" not found in _cloud-data-consolidated.json native.${meshKey}.peers.
      Interface: ${interfaceName}
      Available peers: ${builtins.concatStringsSep ", " (builtins.attrNames topology)}
      Fix: ensure cloud-data submodule is up to date (git submodule update --remote)
    '';

  # ── Config generators ────────────────────────────────────────────────

  # Hub [Interface] with iptables forwarding + masquerade
  mkHubInterface = vm: ''
    [Interface]
    Address = ${vm.address}/24${lib.optionalString (vm.addressV6 or null != null) ", ${vm.addressV6}/64"}
    ListenPort = ${toString vm.port}
    PrivateKey = __PRIVKEY__
    MTU = 1380
    PostUp = iptables -I FORWARD -i ${interfaceName} -j ACCEPT; iptables -I FORWARD -o ${interfaceName} -j ACCEPT; iptables -t nat -A POSTROUTING -s ${cloudData.mesh.subnet} -o ${interfaceName} -j MASQUERADE${lib.optionalString (subnetV6 != null) "; ip6tables -t nat -A POSTROUTING -s ${subnetV6} -o ${interfaceName} -j MASQUERADE || true"}
    PostDown = iptables -D FORWARD -i ${interfaceName} -j ACCEPT; iptables -D FORWARD -o ${interfaceName} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${cloudData.mesh.subnet} -o ${interfaceName} -j MASQUERADE${lib.optionalString (subnetV6 != null) "; ip6tables -t nat -D POSTROUTING -s ${subnetV6} -o ${interfaceName} -j MASQUERADE || true"}
  '';

  # Spoke [Interface] — allow WireGuard traffic to reach Docker port mappings
  mkSpokeInterface = vm: ''
    [Interface]
    Address = ${vm.address}/24${lib.optionalString (vm.addressV6 or null != null) ", ${vm.addressV6}/64"}
    ListenPort = ${toString vm.port}
    PrivateKey = __PRIVKEY__
    MTU = 1380
    PostUp = iptables -I FORWARD -i ${interfaceName} -j ACCEPT; iptables -I FORWARD -o ${interfaceName} -j ACCEPT
    PostDown = iptables -D FORWARD -i ${interfaceName} -j ACCEPT; iptables -D FORWARD -o ${interfaceName} -j ACCEPT
  '';

  # [Peer] block for a given peer VM
  mkPeer = name: peer: ''

    [Peer]
    # ${name}
    PublicKey = ${peer.publicKey}
  '' + (if peer.endpoint != null then
    "Endpoint = ${peer.endpoint}:${toString peer.port}\n"
  else "") +
  (if peer.role == "client" then
    "AllowedIPs = ${peer.address}/32${lib.optionalString (peer.addressV6 or null != null) ", ${peer.addressV6}/128"}${lib.concatMapStrings (ip: ", ${ip}") (peer.extraAllowedIps or [])}\n"
  else if peer.role == "hub" then
    "AllowedIPs = ${cloudData.mesh.subnet}${lib.optionalString (subnetV6 != null) ", ${subnetV6}"}\n"
  else
    "AllowedIPs = ${peer.address}/32${lib.optionalString (peer.addressV6 or null != null) ", ${peer.addressV6}/128"}\n"
  ) + (if peer.endpoint != null
       then "PersistentKeepalive = 25\n"
       else "");
  # ^^ Emit PersistentKeepalive ONLY when an Endpoint is also set.
  # WireGuard's keepalive timer requires an endpoint to send to; setting
  # the keepalive without an endpoint puts the peer into a permanent
  # `(einval)` retry loop (every 5s the kernel tries to send and fails),
  # which silently blocks inbound handshakes from that peer's pubkey
  # from being credited. Symptom: phone WG client tx>0 / rx=0,
  # `wg show <iface> latest-handshakes` stays at 0, and dyndbg shows
  # "Sending handshake initiation to peer N ((einval))" looping
  # without any "Receiving handshake initiation from peer N".
  # Roaming clients (termux, surface) have no endpoint in the SoT —
  # the hub must NOT push keepalives at them; they push at the hub.

  # Derive hub name from topology (the peer with role == "hub")
  hubName = (lib.findFirst (p: p.role == "hub") { name = "gcp-proxy"; } (cloudData.mesh.peers or [])).name;

  # Hub config: interface + ALL other peers (skip peers with null publicKey)
  mkHubConfig =
    let
      hub = topology.${hubName};
      peers = lib.filterAttrs (n: v: n != hubName && v.publicKey != null) topology;
    in mkHubInterface hub
       + lib.concatStrings (lib.mapAttrsToList mkPeer peers);

  # Spoke config: interface + hub peer only
  mkSpokeConfig = name:
    let
      spoke = topology.${name};
      hub = topology.${hubName};
    in mkSpokeInterface spoke
       + mkPeer hubName hub;

  # Select the right config for this VM
  # Assert this VM's own public key is present (null means stale cloud-data)
  wgTemplate =
    if thisVm.publicKey == null then
      throw ''
        wireguard.nix: VM "${vmName}" has null wg_public_key in _cloud-data-consolidated.json (mesh ${meshKey}).
        Interface: ${interfaceName}
        This usually means the cloud-data submodule is stale. Fix:
          1. Regenerate cloud-data (push to cloud-data repo, or run derive-cloud-data)
          2. Update submodule: git submodule update --remote
      ''
    else if thisVm.role == "hub" then mkHubConfig
    else mkSpokeConfig vmName;

  # Activation slot uses the interface name so wg0 + wg-public coexist as
  # distinct activation entries (home.activation attrs must be unique).
  activationSlot = "wireguard_" + lib.replaceStrings ["-"] ["_"] interfaceName;

in {
  # Only the wg0 invocation publishes WIREGUARD_IP into the shell env (avoid
  # clobbering — wg0 is the canonical "the WG IP" for tooling).
  home.sessionVariables = lib.optionalAttrs (interfaceName == "wg0") {
    WIREGUARD_IP = thisVm.address;
  };

  programs.bash.bashrcExtra = lib.optionalString (interfaceName == "wg0") ''
    # WireGuard mesh IP (also in home.sessionVariables for login shells)
    export WIREGUARD_IP="${thisVm.address}"
  '';

  home.activation.${activationSlot} = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[wireguard:${interfaceName}] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    WG_CONF="/etc/wireguard/${interfaceName}.conf"
    WG_LOG_PREFIX="[wireguard:${interfaceName}]"

    # Find sudo (not in PATH during home-manager activation)
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$WG_LOG_PREFIX ERROR: sudo not found — cannot manage WireGuard"
      exit 1
    fi

    # 1. Read private key from sops secrets (deployed by build.sh secrets)
    VM_NAME_UPPER=$(echo "${vmName}" | tr '[:lower:]-' '[:upper:]_')
    SECRETS_DIR="$HOME/.config/home-manager/.secrets.d"
    SECRET_FILE="$SECRETS_DIR/${secretEnvName}_$VM_NAME_UPPER"

    # STRICT: key MUST come from sops secrets. No fallback, no generation, no reading existing config.
    if [ ! -f "$SECRET_FILE" ]; then
      echo "$WG_LOG_PREFIX FATAL: WG private key not found at $SECRET_FILE"
      echo "$WG_LOG_PREFIX Fix: ensure sops secrets.yaml has ${secretEnvName}_$VM_NAME_UPPER and redeploy"
      exit 1
    fi
    PRIVKEY=$(cat "$SECRET_FILE" | tr -d '[:space:]')
    echo "$WG_LOG_PREFIX Read private key from secrets ($SECRET_FILE)"

    $SUDO mkdir -p /etc/wireguard

    # 2. Generate new config from template with injected key
    # NOTE: heredoc closer MUST be at column 0 (bash quirk). Use printf via
    # a nix variable so we never depend on heredoc indentation behavior.
    TEMPLATE=${lib.escapeShellArg wgTemplate}
    NEW_CONF=$(echo "$TEMPLATE" | sed "s|__PRIVKEY__|$PRIVKEY|")

    # 3. Compare with current live config (use sudo — /etc/wireguard is 700 root:root)
    CURRENT=""
    if $SUDO test -f "$WG_CONF"; then
      CURRENT=$($SUDO cat "$WG_CONF" 2>/dev/null || true)
    fi

    if [ "$NEW_CONF" = "$CURRENT" ]; then
      echo "$WG_LOG_PREFIX ${interfaceName}.conf unchanged — skipping"
    else
      echo "$WG_LOG_PREFIX ${interfaceName}.conf changed — deploying"
      echo "$NEW_CONF" | $SUDO tee "$WG_CONF" > /dev/null
      $SUDO chmod 600 "$WG_CONF"
      $SUDO chown root:root "$WG_CONF"
      if $SUDO systemctl is-active wg-quick@${interfaceName} >/dev/null 2>&1; then
        # Live-apply WITHOUT downing wg0. A full `systemctl restart` (down+up)
        # drops every mesh connection — including the deploy's own SSH, which
        # rides wg0 — causing exit 255 + a rolled-back generation. Instead:
        # `wg syncconf` updates peers/keys in place and `ip addr add` applies
        # any new address (e.g. the IPv6 ULA). wg0 is NEVER downed, so this
        # cannot brick the mesh — on any failure the interface simply stays up
        # on its prior state.
        WG_CMD="$HOME/.nix-profile/bin/wg"
        WG_QUICK_BIN="$HOME/.nix-profile/bin/wg-quick"
        if STRIPPED=$($SUDO "$WG_QUICK_BIN" strip ${interfaceName} 2>/dev/null) && [ -n "$STRIPPED" ]; then
          echo "$STRIPPED" | $SUDO "$WG_CMD" syncconf ${interfaceName} /dev/stdin 2>/dev/null \
            && echo "$WG_LOG_PREFIX ${interfaceName} peers synced live (no restart)" \
            || echo "$WG_LOG_PREFIX ${interfaceName} syncconf failed — interface left up"
        fi
        # Apply [Interface] Address entries live (add-only; present → ignored).
        echo "$NEW_CONF" | sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' | tr ',' '\n' | while read -r _a; do
          _a=$(echo "$_a" | tr -d '[:space:]'); [ -n "$_a" ] && { $SUDO ip address add "$_a" dev ${interfaceName} 2>/dev/null || true; }
        done
        echo "$WG_LOG_PREFIX ${interfaceName} live-synced (peers + addresses, no SSH-dropping restart)"
      fi
    fi

    # 4. Ensure systemd unit + start wg-quick@${interfaceName} (Fedora/Debian don't ship
    #    wg-quick@.service — install one pointing at HM's nix-profile binary).
    WG_UNIT="/etc/systemd/system/wg-quick@.service"
    WG_BIN="$HOME/.nix-profile/bin/wg-quick"
    WG_BIN_DIR="$HOME/.nix-profile/bin"
    if [ -x "$WG_BIN" ] && ! $SUDO test -f "$WG_UNIT"; then
      echo "$WG_LOG_PREFIX installing $WG_UNIT"
      printf '%s\n' \
        "[Unit]" \
        "Description=WireGuard via wg-quick(8) for %I" \
        "After=network-online.target nss-lookup.target" \
        "Wants=network-online.target nss-lookup.target" \
        "PartOf=wg-quick.target" \
        "Documentation=man:wg-quick(8)" \
        "" \
        "[Service]" \
        "Type=oneshot" \
        "RemainAfterExit=yes" \
        "ExecStart=$WG_BIN up %i" \
        "ExecStop=$WG_BIN down %i" \
        "Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity" \
        "Environment=PATH=$WG_BIN_DIR:/usr/sbin:/usr/bin:/sbin:/bin" \
        "" \
        "[Install]" \
        "WantedBy=multi-user.target" \
        | $SUDO tee "$WG_UNIT" > /dev/null
      $SUDO systemctl daemon-reload
    fi

    # 5. Enable + start wg-quick@${interfaceName} if not already running
    if ! $SUDO systemctl is-enabled wg-quick@${interfaceName} >/dev/null 2>&1; then
      $SUDO systemctl enable wg-quick@${interfaceName} >/dev/null 2>&1 || true
    fi
    if ! $SUDO systemctl is-active wg-quick@${interfaceName} >/dev/null 2>&1; then
      echo "$WG_LOG_PREFIX starting wg-quick@${interfaceName}"
      $SUDO systemctl start wg-quick@${interfaceName} 2>&1 \
        || $SUDO "$WG_BIN" up ${interfaceName} 2>&1 | sed "s/^/$WG_LOG_PREFIX wg-quick: /"
    fi
    ) || echo "[wireguard:${interfaceName}] FAILED — see errors above, activation continues"
  '';
}
