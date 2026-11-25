# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/pilot/network/firewall.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Fully declarative iptables + nftables — owns ALL chains
#
# This firewall is THE SINGLE OWNER of all packet filtering rules.
# Docker runs with iptables:false (daemon.json) — it creates NO rules.
# All containers use network_mode: host — no DNAT, no bridge isolation.
#
# On every run: flush ALL tables → rebuild from scratch. Zero stale rules.
#
# Docker subnet range: 172.16.0.0/12 (covers 172.16-31.x.x)
# WG subnet: 10.0.0.0/24
#
# Usage in VM config:
#   (import ./modules/firewall.nix {
#     vmName = "oci-apps";
#     publicPorts = [
#       { port = 8081; proto = "tcp"; desc = "C3 API"; }
#     ];
#   })
#
{ vmName, publicPorts ? [] }:

{ config, lib, pkgs, ... }:

let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[.native.docker + .native.wireguard]
  # 2026-04-27 migrated: cloud-data-firewall-rules.json → _cloud-data-consolidated.json[.firewalls.os.<vm>]
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    docker = consolidated.native.docker or {};
    wireguard = consolidated.native.wireguard or {};
    wireguardPublic = consolidated.native.wireguard_public or {};
    hmVm = consolidated._home_manager.vms.${vmName} or {};
  };
  dockerSubnet = cloudData.docker.subnet;
  wgSubnet = cloudData.wireguard.subnet;

  # Detect WG role for this VM from consolidated peers list. The hub gets
  # a NAT redirect for the WG fallback port (443/udp → 51820/udp), so
  # peers on networks that block 51820/udp (airports, hotels) can reach
  # WG by switching their endpoint to gcp-proxy:443.
  wgPeers = cloudData.wireguard.peers or [];
  thisPeer = lib.findFirst (p: p.name == vmName) null wgPeers;
  isWgHub = (thisPeer != null) && ((thisPeer.role or null) == "hub");
  wgFallbackPort = "443";  # UDP
  wgPort = toString (cloudData.wireguard.port or 51820);

  # ── Phase 6/7: wg-public mesh membership + DOCKER-USER chain ───────────
  # Data-driven from consolidated.native.wireguard_public.{subnet,port,hub,peers}.
  # If this VM peers in wg-public, the wg-public interface is trusted (wg-public
  # INPUT ACCEPT + wg-public subnet ACCEPT) and the hub additionally opens
  # the wg-public listen port. Members run wg-quick@wg-public alongside wg0.
  wgPublicSubnet = cloudData.wireguardPublic.subnet or null;
  wgPublicPort   = cloudData.wireguardPublic.port or null;
  # IPv6 ULA subnets — mirror of the v4 subnets for the ip6tables design.
  wgSubnetV6       = cloudData.wireguard.subnet_v6 or null;
  wgPublicSubnetV6 = cloudData.wireguardPublic.subnet_v6 or null;
  wgPublicHub    = cloudData.wireguardPublic.hub or null;
  wgPublicPeers  = cloudData.wireguardPublic.peers or [];
  isWgPublicPeer = lib.any (p: p.name == vmName) wgPublicPeers;
  # Hub is named by wg-public peer name (e.g. "oci-analytics"); map to the
  # vmName form (some VMs use "oci-analytics" as their vmName). The hub field
  # holds the cloud-name (e.g. "oci-E2-f_1") on some snapshots — accept either.
  thisWgPublicPeer = lib.findFirst (p: p.name == vmName) null wgPublicPeers;
  isWgPublicHub    = (thisWgPublicPeer != null) && ((thisWgPublicPeer.role or null) == "hub");
  # Phase 7: explicit ingress flag drives DOCKER-USER drop. Public ingress VMs
  # need the drop (Docker port-mapping bypass of INPUT chain). Internal-only
  # VMs (wg0-only spokes) still get the drop for defence-in-depth — wg0 + lo
  # + ESTABLISHED are always whitelisted, so legitimate flows never break.
  isPublicIngress = cloudData.hmVm.is_public_ingress or false;

  mkPortRule = r:
    let
      port = toString r.port;
      proto = r.proto or "tcp";
      comment = r.desc or "port-${port}";
      # Source CIDR is data-driven from b_infra/nixhm-sudo-<vm>/build.json
      # firewall.public_ports[].source. Default to 0.0.0.0/0 only when
      # the data omits source (back-compat). Setting source to a WG mesh
      # (10.0.0.0/24 wg0 or 10.1.0.0/24 wg-public) is how operators close
      # a listener to public reach while keeping it open to the meshes —
      # the listener itself stays bound on the same socket; only the
      # firewall scope changes.
      source = r.source or "0.0.0.0/0";
      srcFlag = if source == "0.0.0.0/0" then "" else "-s ${source} ";
    in
      "iptables -A INPUT ${srcFlag}-p ${proto} --dport ${port} -m comment --comment \"${comment}\" -j ACCEPT";

  portRules = builtins.concatStringsSep "\n    " (map mkPortRule publicPorts);

  fwScript = ''
    #!/bin/bash
    # Managed by home-manager (firewall.nix) — do not edit
    # VM: ${vmName} — fully declarative iptables + nftables
    # THIS SCRIPT OWNS ALL PACKET FILTERING. Docker creates nothing.
    set -euo pipefail
    # Default $HOME for systemd-boot-path execution: this script runs both
    # via home-manager activation (HOME=/home/diego, set) AND via systemd
    # firewall.service at boot (root, HOME UNSET). Without this default,
    # `set -u` aborts the script on first $HOME reference, leaving the VM
    # with a stale 4-rule INPUT chain (lo, ESTABLISHED, 10.0.0.0/24,
    # udp/51820) and no public-port ACCEPT rules. Fix: default to root's
    # home so the FW_JSON path search keeps working even at boot.
    : "''${HOME:=/root}"
    export PATH="${pkgs.iptables}/bin:$PATH"

    # ══════════════════════════════════════════════════════════════
    # PHASE 0: FLUSH EVERYTHING — clean slate
    # ══════════════════════════════════════════════════════════════

    # Filter table
    iptables -F INPUT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true

    # NAT table — ALL chains (kills any zombie Docker DNAT/SNAT rules)
    iptables -t nat -F 2>/dev/null || true

    # Mangle table
    iptables -t mangle -F 2>/dev/null || true

    # nftables raw table — flush Docker's container isolation rules
    if command -v nft >/dev/null 2>&1 && nft list table ip raw >/dev/null 2>&1; then
      nft flush chain ip raw PREROUTING 2>/dev/null || true
      nft flush chain ip raw OUTPUT 2>/dev/null || true
      echo "[firewall] nft raw: flushed all rules"
    fi

    # iptables-LEGACY — Fedora 42 ships both nft (default `iptables`) AND legacy
    # tables. Docker (moby-engine) inserts FORWARD rules into LEGACY when its
    # iptables-detector picks up legacy first. With FORWARD policy DROP in
    # legacy, transit traffic (e.g. desktop → hub → spoke) is silently dropped.
    # Mirror the same FORWARD-permits as the nft side so legacy doesn't block.
    if command -v iptables-legacy >/dev/null 2>&1; then
      iptables-legacy -F FORWARD 2>/dev/null || true
      iptables-legacy -P FORWARD ACCEPT 2>/dev/null || true
      iptables-legacy -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
      iptables-legacy -A FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
      iptables-legacy -A FORWARD -s ${dockerSubnet} -j ACCEPT 2>/dev/null || true
      iptables-legacy -A FORWARD -d ${dockerSubnet} -j ACCEPT 2>/dev/null || true
      echo "[firewall] iptables-legacy: FORWARD ACCEPT + wg0/docker rules"
    fi

    # ══════════════════════════════════════════════════════════════
    # PHASE 1: FILTER TABLE — INPUT
    # ══════════════════════════════════════════════════════════════

    iptables -P INPUT DROP

    # Loopback
    iptables -A INPUT -i lo -j ACCEPT
    # Established/related
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # ICMP
    iptables -A INPUT -p icmp -j ACCEPT
    # WireGuard interface (all VPN traffic trusted)
    iptables -A INPUT -i wg0 -j ACCEPT
    # SSH
    iptables -A INPUT -p tcp --dport 22 -m comment --comment "SSH" -j ACCEPT
    # WireGuard port
    iptables -A INPUT -p udp --dport ${toString cloudData.wireguard.port} -m comment --comment "WireGuard" -j ACCEPT
${lib.optionalString (isWgPublicPeer && wgPublicSubnet != null) ''
    # ── wg-public mesh (Phase 6) ──────────────────────────────────────
    # Trust the wg-public interface AND its subnet (defence-in-depth: if
    # the iface is renamed by wg-quick, the source-address rule still wins).
    iptables -A INPUT -i wg-public -j ACCEPT
    iptables -A INPUT -s ${wgPublicSubnet} -j ACCEPT
''}${lib.optionalString (isWgPublicHub && wgPublicPort != null) ''
    # wg-public hub: open the wg-public listen port to the world
    iptables -A INPUT -p udp --dport ${toString wgPublicPort} -m comment --comment "wg-public hub" -j ACCEPT
''}
    # VM-specific public ports (static from nix)
    ${portRules}

    # Dynamic ports from _cloud-data-consolidated.json[.firewalls.os.<vm>]
    # Path-priority chain: in-image bundle > runtime deploy dir > legacy clone
    FW_JSON=""
    for _p in \
      /app/_cloud-data-consolidated.json \
      /opt/containers/cloud-data/_cloud-data-consolidated.json \
      "$HOME/git/cloud-t-infra/1_cloud-configs/dist/_cloud-data-consolidated.json" \
      "$HOME/git/cloud-t-infra/cloud-data/_cloud-data-consolidated.json"; do
      [ -f "$_p" ] && FW_JSON="$_p" && break
    done
    if [ -n "$FW_JSON" ] && [ -f "$FW_JSON" ] && command -v jq >/dev/null 2>&1; then
      DYNAMIC_PORTS=$(jq -r --arg vm "${vmName}" '.firewalls.os[$vm][]? | "\(.port):\(.proto // "tcp"):\(.owned_by // .desc // "dynamic")"' "$FW_JSON" 2>/dev/null || true)
      for entry in $DYNAMIC_PORTS; do
        PORT=''${entry%%:*}
        REST=''${entry#*:}
        PROTO=''${REST%%:*}
        SVC=''${REST#*:}
        iptables -C INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT 2>/dev/null || \
          iptables -A INPUT -p "$PROTO" --dport "$PORT" -m comment --comment "$SVC (dynamic)" -j ACCEPT
      done
      echo "[firewall] Applied dynamic ports from $FW_JSON"
    fi

    # ══════════════════════════════════════════════════════════════
    # PHASE 2: FILTER TABLE — FORWARD
    # ══════════════════════════════════════════════════════════════

    iptables -P FORWARD DROP

    # Established/related
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Docker containers → internet (outbound)
    iptables -A FORWARD -s ${dockerSubnet} ! -d ${dockerSubnet} -j ACCEPT
    # Inter-container traffic
    iptables -A FORWARD -s ${dockerSubnet} -d ${dockerSubnet} -j ACCEPT
    # WireGuard forwarding
    iptables -A FORWARD -i wg0 -j ACCEPT
    iptables -A FORWARD -o wg0 -j ACCEPT
${lib.optionalString isWgPublicPeer ''
    # wg-public mesh forwarding (Phase 6) — required for hub to relay between
    # spokes and for any wg-public participant to forward returning packets.
    iptables -A FORWARD -i wg-public -j ACCEPT
    iptables -A FORWARD -o wg-public -j ACCEPT
''}

    # ══════════════════════════════════════════════════════════════
    # PHASE 3: NAT TABLE — MASQUERADE only, zero DNAT
    # ══════════════════════════════════════════════════════════════
    # With network_mode: host, services bind directly on 0.0.0.0.
    # No DNAT needed. No docker-proxy. No port mapping.
    # Only MASQUERADE for outbound from Docker bridges and WG.

    # Egress NIC, resolved at RUNTIME from the default route. It is NOT eth0:
    # GCP names it ens4, OCI names it ens3. The old code tried
    # `-o eth0 … || -o ens4 … || <fallback>`, but iptables does NOT validate
    # interface names at insert time — it accepts `-o eth0` on a host with no
    # eth0, returns 0, and the `||` fallbacks never run. Result: a MASQUERADE
    # rule that is present in the chain, looks correct in `iptables -S`, and
    # matches zero packets. Every hub has been silently unable to NAT mesh
    # traffic to the internet (found 2026-08-11 while checking whether a
    # full-tunnel client would actually get egress — it would not have).
    EGRESS_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')

    iptables -t nat -A POSTROUTING -s ${dockerSubnet} ! -d ${dockerSubnet} -j MASQUERADE
    if [ -n "''${EGRESS_IF:-}" ]; then
      iptables -t nat -A POSTROUTING -s ${wgSubnet} -o "$EGRESS_IF" -j MASQUERADE
    else
      iptables -t nat -A POSTROUTING -s ${wgSubnet} ! -d ${wgSubnet} -j MASQUERADE
    fi
${lib.optionalString (isWgPublicPeer && wgPublicSubnet != null) ''
    # wg-public subnet MASQUERADE (Phase 6) — outbound from wg-public peers
    if [ -n "''${EGRESS_IF:-}" ]; then
      iptables -t nat -A POSTROUTING -s ${wgPublicSubnet} -o "$EGRESS_IF" -j MASQUERADE
    else
      iptables -t nat -A POSTROUTING -s ${wgPublicSubnet} ! -d ${wgPublicSubnet} -j MASQUERADE
    fi
''}

    # ══════════════════════════════════════════════════════════════
    # PHASE 3c: DOCKER-USER CHAIN — Tier-2 fleet-wide drop (Phase 7)
    # ══════════════════════════════════════════════════════════════
    # Closes the Docker-port-mapping bypass of the INPUT chain. Any container
    # with a published port (-p host:cont, or moby's iptables=true side) bolts
    # rules into DOCKER-USER ahead of FORWARD. Without an explicit drop here
    # the public-facing iface can reach those containers even though INPUT is
    # locked down. We:
    #   1) Ensure DOCKER-USER exists (Docker creates it lazily; pre-create so
    #      flush is safe even when no Docker container has run yet).
    #   2) Flush any prior rules — own this chain entirely, declarative.
    #   3) Whitelist trusted ifaces (lo, wg0, optionally wg-public) +
    #      RELATED,ESTABLISHED + the docker subnet itself.
    #   4) Final DROP: untrusted public iface → docker = denied.
    iptables -N DOCKER-USER 2>/dev/null || true
    iptables -F DOCKER-USER 2>/dev/null || true
    iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A DOCKER-USER -i lo  -j ACCEPT
    iptables -A DOCKER-USER -i wg0 -j ACCEPT
    ${lib.optionalString isWgPublicPeer ''iptables -A DOCKER-USER -i wg-public -j ACCEPT''}
    iptables -A DOCKER-USER -s ${dockerSubnet} -j ACCEPT
    iptables -A DOCKER-USER -j DROP
    echo "[firewall] DOCKER-USER: declarative drop installed (wg-public peer=${if isWgPublicPeer then "yes" else "no"}, public-ingress=${if isPublicIngress then "yes" else "no"})"

    # ══════════════════════════════════════════════════════════════
    # PHASE 6: IPv6 — mirror the IPv4 filter/forward/NAT design
    # ══════════════════════════════════════════════════════════════
    # Same posture as the iptables rules above, for IPv6. Without this, v6
    # mesh / wg-public traffic has NO forwarding or MASQUERADE, so a v6 full
    # tunnel via this hub blackholes (the whole point of the ULA meshes).
    # ICMPv6 + WG ports + ESTABLISHED are allowed BEFORE the DROP policy so the
    # public v6 WG endpoint, neighbour-discovery and PMTU keep working.
    if command -v ip6tables >/dev/null 2>&1 && [ -d /proc/sys/net/ipv6 ]; then
      # Enable v6 forwarding here (tolerant) rather than as a declarative sysctl,
      # so IPv6-disabled hosts (e.g. GCP e2-micro) don't fail activation.
      sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
      ip6tables -F INPUT   2>/dev/null || true
      ip6tables -F FORWARD 2>/dev/null || true
      ip6tables -t nat -F  2>/dev/null || true
      # ── INPUT ──
      ip6tables -A INPUT -i lo -j ACCEPT
      ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
      ip6tables -A INPUT -i wg0 -j ACCEPT
      ip6tables -A INPUT -p tcp --dport 22  -j ACCEPT
      ip6tables -A INPUT -p tcp --dport 80  -j ACCEPT
      ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
      ip6tables -A INPUT -p udp --dport ${toString cloudData.wireguard.port} -j ACCEPT
${lib.optionalString isWgPublicPeer ''      ip6tables -A INPUT -i wg-public -j ACCEPT
''}${lib.optionalString (isWgPublicPeer && wgPublicSubnetV6 != null) ''      ip6tables -A INPUT -s ${wgPublicSubnetV6} -j ACCEPT
''}${lib.optionalString (wgSubnetV6 != null) ''      ip6tables -A INPUT -s ${wgSubnetV6} -j ACCEPT
''}${lib.optionalString (isWgPublicHub && wgPublicPort != null) ''      ip6tables -A INPUT -p udp --dport ${toString wgPublicPort} -j ACCEPT
''}      ip6tables -P INPUT DROP 2>/dev/null || true
      # ── FORWARD ──
      ip6tables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
      ip6tables -A FORWARD -i wg0 -j ACCEPT
      ip6tables -A FORWARD -o wg0 -j ACCEPT
${lib.optionalString isWgPublicPeer ''      ip6tables -A FORWARD -i wg-public -j ACCEPT
      ip6tables -A FORWARD -o wg-public -j ACCEPT
''}      ip6tables -P FORWARD DROP 2>/dev/null || true
      # ── NAT: MASQUERADE v6 egress to the internet (mirror of the v4 rules) ──
      # Same runtime-resolved egress NIC as the v4 block — see the long comment
      # there for why `-o eth0 || -o ens4` was dead code.
      # NOTE: this only produces working v6 egress on a host that HAS a global
      # IPv6 address. gcp-proxy currently has none (ens4 is v4-only, no v6
      # default route), so v6 NAT66 there is a no-op by physics, not by config.
${lib.optionalString (wgSubnetV6 != null) ''      if [ -n "''${EGRESS_IF:-}" ]; then ip6tables -t nat -A POSTROUTING -s ${wgSubnetV6} -o "$EGRESS_IF" -j MASQUERADE 2>/dev/null || true; else ip6tables -t nat -A POSTROUTING -s ${wgSubnetV6} ! -d ${wgSubnetV6} -j MASQUERADE 2>/dev/null || true; fi
''}${lib.optionalString (isWgPublicPeer && wgPublicSubnetV6 != null) ''      if [ -n "''${EGRESS_IF:-}" ]; then ip6tables -t nat -A POSTROUTING -s ${wgPublicSubnetV6} -o "$EGRESS_IF" -j MASQUERADE 2>/dev/null || true; else ip6tables -t nat -A POSTROUTING -s ${wgPublicSubnetV6} ! -d ${wgPublicSubnetV6} -j MASQUERADE 2>/dev/null || true; fi
''}      echo "[firewall] IPv6 mirror applied: INPUT/FORWARD DROP + wg trust + v6 MASQUERADE (egress=''${EGRESS_IF:-none})"
    else
      echo "[firewall] ip6tables unavailable — IPv6 mirror skipped"
    fi
${if isWgHub then ''

    # ══════════════════════════════════════════════════════════════
    # WG0 FALLBACK — redirect UDP/${wgFallbackPort} → UDP/${wgPort}
    # ══════════════════════════════════════════════════════════════
    # Hub-only. Peers behind networks that block ${wgPort}/udp (airports,
    # hotels, restrictive corp WiFi) can switch their wg-quick endpoint
    # to gcp-proxy:${wgFallbackPort} and still reach the mesh. Caddy must
    # NOT bind UDP/${wgFallbackPort} (drop QUIC/HTTP/3) for this to work.
    iptables -t nat -A PREROUTING -p udp --dport ${wgFallbackPort} -j REDIRECT --to-port ${wgPort}
    echo "[firewall] wg0 fallback NAT: udp/${wgFallbackPort} → udp/${wgPort}"
'' else ""}
${let
  # wg-public's own UDP-fallback REDIRECT on its hub (oci-analytics).
  # Coexists with wg0's UDP/443 redirect because the hubs live on
  # different public IPs — each REDIRECT is local to its own host.
  # Data: wireguard_public.{port_fallback, port_fallback_proto, port}.
  wgpPortFallback  = cloudData.wireguardPublic.port_fallback or null;
  wgpFallbackProto = cloudData.wireguardPublic.port_fallback_proto or "udp";
  wgpPort          = toString (cloudData.wireguardPublic.port or 51821);
in if isWgPublicHub && wgpPortFallback != null then ''

    # ══════════════════════════════════════════════════════════════
    # WG-PUBLIC FALLBACK — redirect ${wgpFallbackProto}/${toString wgpPortFallback} → ${wgpFallbackProto}/${wgpPort}
    # ══════════════════════════════════════════════════════════════
    # Same mechanism as wg0's fallback above, but for the wg-public hub.
    # The two coexist because each runs on a different VM (different
    # public IP). Caddy on this VM is TCP-only on :443, so UDP/443 is
    # available for the redirect.
    iptables -t nat -A PREROUTING -p ${wgpFallbackProto} --dport ${toString wgpPortFallback} -j REDIRECT --to-port ${wgpPort}
    echo "[firewall] wg-public fallback NAT: ${wgpFallbackProto}/${toString wgpPortFallback} → ${wgpFallbackProto}/${wgpPort}"
'' else ""}

    echo "[firewall] Applied: fully declarative iptables + nft for ${vmName} (${toString (builtins.length publicPorts)} static ports)"
  '';

in {
  home.packages = [ pkgs.iptables ];

  home.file.".local/share/firewall/firewall.sh" = {
    executable = true;
    # fwScript's '' indented-string common-indent strip fails because the
    # ${lib.optionalString ...} conditional blocks sit at column 0 in the
    # nix source — that pulls the common-indent down to 0 and nix strips
    # nothing, so every body line retains its 4-space prefix (including
    # #!/bin/bash). bash invocation tolerates it, but systemd exec(2) does
    # not — status=203/EXEC at boot, firewall.service stays failed, rules
    # are never re-applied across reboots. Post-process: drop a uniform
    # 4-space prefix from every line so the shebang lands at column 0.
    text = lib.replaceStrings [ "\n    " ] [ "\n" ] (lib.removePrefix "    " fwScript);
  };

  home.file.".local/share/firewall/firewall.service".text = ''
    [Unit]
    Description=OS-level firewall (${vmName})
    After=network-pre.target
    Before=network.target docker.service wg-quick@wg0.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/firewall.sh

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installFirewall = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    trap 'echo "[firewall] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[firewall] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/firewall"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/firewall.sh" /opt/scripts/firewall.sh
    $SUDO chmod +x /opt/scripts/firewall.sh
    $SUDO cp -f "$SRC/firewall.service" /etc/systemd/system/firewall.service

    # Diff check — only restart if changed
    CURRENT=""
    if $SUDO test -f /opt/scripts/.firewall.sh.prev; then
      CURRENT=$($SUDO cat /opt/scripts/.firewall.sh.prev 2>/dev/null || true)
    fi
    NEW=$($SUDO cat /opt/scripts/firewall.sh)

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable firewall.service 2>/dev/null || true

    if [ "$NEW" = "$CURRENT" ]; then
      echo "[firewall] rules unchanged — skipping"
    else
      # Run the script directly (works even when systemd unit is in a stale
      # failed state) AND `reset-failed` + `try-restart` the unit so its
      # systemd state reflects current reality. Without try-restart the
      # unit can sit `failed` from a prior bad script across reboots even
      # though the on-disk script is now correct.
      $SUDO /opt/scripts/firewall.sh
      echo "$NEW" | $SUDO tee /opt/scripts/.firewall.sh.prev > /dev/null
      $SUDO systemctl reset-failed firewall.service 2>/dev/null || true
      $SUDO systemctl try-restart firewall.service 2>/dev/null || true
      echo "[firewall] rules applied for ${vmName}"
    fi
    ) || echo "[firewall] FAILED — see errors above, activation continues"
  '';
}
