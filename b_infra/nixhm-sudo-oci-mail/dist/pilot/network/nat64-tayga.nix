# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/network/nat64-tayga.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# NAT64 via Tayga — translates IPv6-only clients to IPv4
#
# Enables IPv6-only clients (e.g. on IPv6-only WiFi links) to reach IPv4
# internet via stateless NAT64, using the Well-Known Prefix or a ULA /96.
#
# ENABLED ONLY ON: oci-analytics (wg-public hub, x86_64 Ubuntu).
# No-op on all other VMs.
#
# NAT64 prefix:
#   2603:c026:c104:8f00:ff9b::/96  (OCI Oracle /96 carved from the oci-analytics /64)
#
# Tayga xlate pool: 192.168.255.0/24
# Tun device:       nat64
# Tun IPv4 address: 192.168.255.1 (Tayga's own address on the tun)
#
# Usage in VM config (oci-analytics home.nix):
#   (import ./modules/network/nat64-tayga.nix { vmName = "oci-analytics"; })
#
{ vmName }:

{ config, lib, pkgs, ... }:

let
  # Gate: this module is a no-op on every VM except oci-analytics
  enabled = vmName == "oci-analytics";

  # ── Shared constants ──────────────────────────────────────────────────────
  # Real Oracle /96 carved from oci-analytics' /64 (2603:c026:c104:8f00::/64).
  # Search token: NAT64_PREFIX
  nat64Prefix = "2603:c026:c104:8f00:ff9b::/96";

  # Tayga's own IPv6 node address on the nat64 tun device.
  # Must be inside the /64 but OUTSIDE the /96 translation prefix.
  nat64Ipv6Addr = "2603:c026:c104:8f00::2";

  xlatePool  = "192.168.255.0/24";
  tunDevice  = "nat64";
  tunIpv4    = "192.168.255.1";

  # Tun MTU. NOT the default 1500 — and getting it wrong produces the most
  # deceptive failure in this stack: TCP connects, small replies arrive, every
  # large response vanishes. That reads as "no internet" while every check you
  # would think to run reports healthy.
  #
  # NAT64 clients arrive over wg-public, MTU 1380. Translating IPv4 -> IPv6
  # GROWS the header by 20 bytes (20 -> 40), so a 1380-byte IPv4 reply becomes a
  # 1400-byte IPv6 packet that cannot leave a 1380 interface. 1380 - 20 = 1360.
  # At 1360, tayga tells IPv4 senders "Frag Needed, MTU 1360" and everything it
  # emits fits inside wg-public.
  #
  # INVARIANT: nat64Mtu = wg-public MTU - 20. Re-derive if wg-public changes.
  nat64Mtu = "1360";

  taygaConf = ''
    # Managed by home-manager (nat64-tayga.nix) — do not edit
    tun-device    ${tunDevice}
    ipv4-addr     ${tunIpv4}
    prefix        ${nat64Prefix}
    # ipv6-addr: Tayga's node addr on the tun — inside /64, outside /96.
    ipv6-addr     ${nat64Ipv6Addr}
    dynamic-pool  ${xlatePool}
    data-dir      /var/db/tayga
  '';

  # PERSISTENT v6 forwarding. firewall.nix enables it with a bare `sysctl -w`,
  # deliberately, so that IPv6-disabled hosts (GCP e2-micro) don't fail
  # activation — but `sysctl -w` is runtime-only. After a reboot v6 forwarding
  # is OFF until the next home-manager activation happens to run, and NAT64
  # silently stops forwarding until then. Writing it as a file is safe HERE in a
  # way it is not globally: this module is gated to oci-analytics, which
  # demonstrably has working IPv6.
  sysctlConf = ''
    # Managed by home-manager (nat64-tayga.nix) — do not edit
    net.ipv6.conf.all.forwarding = 1
    net.ipv4.ip_forward = 1
  '';

  taygaUnit = ''
    [Unit]
    Description=Tayga NAT64 translator
    Documentation=man:tayga(8)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    # -d = don't daemonize (foreground). tayga reads /etc/tayga.conf by default.
    ExecStart=${pkgs.tayga}/bin/tayga -d --config /etc/tayga.conf
    # Bring up the tun, add routes, install MASQUERADE after Tayga creates the
    # tun device. $(ip …) probes which outbound iface is default-routed.
    ExecStartPost=${pkgs.iproute2}/bin/ip link set ${tunDevice} mtu ${nat64Mtu}
    ExecStartPost=${pkgs.iproute2}/bin/ip link set ${tunDevice} up
    ExecStartPost=${pkgs.iproute2}/bin/ip route add ${nat64Prefix} dev ${tunDevice} 2>/dev/null || true
    ExecStartPost=${pkgs.iproute2}/bin/ip route add ${xlatePool} dev ${tunDevice} 2>/dev/null || true
    ExecStartPost=/bin/sh -c ' \
      OIFACE=$(${pkgs.iproute2}/bin/ip route show default | awk "/default/ {print \$$5; exit}"); \
      OIFACE=''${OIFACE:-eth0}; \
      ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING \
        -s ${xlatePool} -o "$$OIFACE" -j MASQUERADE 2>/dev/null || \
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING \
        -s ${xlatePool} -o "$$OIFACE" -j MASQUERADE'
    # FORWARD accepts for the tun. NOT OPTIONAL — this module shipped without
    # them and NAT64 was dead on arrival. oci-analytics runs -P FORWARD DROP
    # with per-interface accepts (wg0, wg-public), so a client packet reaches
    # the tun via "-i wg-public" and then the TRANSLATED packet leaving the tun
    # matches no rule and is silently dropped. End state: tayga running, routes
    # correct, MASQUERADE present, and zero connectivity — nothing looks broken.
    # Verified 2026-08-12: adding these turned a 15s timeout into HTTP 200.
    ExecStartPost=/bin/sh -c 'for t in ${pkgs.iptables}/bin/iptables ${pkgs.iptables}/bin/ip6tables; do \
      for d in -i -o; do \
        $$t -C FORWARD $$d ${tunDevice} -j ACCEPT 2>/dev/null || \
        $$t -A FORWARD $$d ${tunDevice} -j ACCEPT; \
      done; \
    done'
    Restart=on-failure
    RestartSec=10
    # Tayga needs to create/open the tun device and write state to /var/db/tayga
    CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
    AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
    User=root

    [Install]
    WantedBy=multi-user.target
  '';

in lib.mkIf enabled {
  home.packages = with pkgs; [ tayga iproute2 iptables ];

  home.file.".local/share/nat64-tayga/tayga.conf".text = taygaConf;
  home.file.".local/share/nat64-tayga/nat64-tayga.service".text = taygaUnit;
  home.file.".local/share/nat64-tayga/99-nat64.conf".text = sysctlConf;

  home.activation.installNat64Tayga = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    trap 'echo "[nat64-tayga] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[nat64-tayga] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/nat64-tayga"

    # Ensure tayga data dir exists
    $SUDO mkdir -p /var/db/tayga

    # Persist v6 forwarding BEFORE tayga starts — a translator that cannot
    # forward is worse than one that is absent, because everything reports
    # healthy while packets die.
    $SUDO mkdir -p /etc/sysctl.d
    $SUDO cp -f "$SRC/99-nat64.conf" /etc/sysctl.d/99-nat64.conf
    $SUDO chmod 644 /etc/sysctl.d/99-nat64.conf
    $SUDO sysctl -q -p /etc/sysctl.d/99-nat64.conf 2>/dev/null || true

    # Deploy config + unit
    $SUDO cp -f "$SRC/tayga.conf" /etc/tayga.conf
    $SUDO chmod 644 /etc/tayga.conf
    $SUDO cp -f "$SRC/nat64-tayga.service" /etc/systemd/system/nat64-tayga.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable nat64-tayga.service 2>/dev/null || true

    # Diff check — only restart if changed (activation-must-never-block)
    CURRENT=""
    if $SUDO test -f /etc/tayga.conf.prev; then
      CURRENT=$($SUDO cat /etc/tayga.conf.prev 2>/dev/null || true)
    fi
    NEW=$($SUDO cat /etc/tayga.conf)

    if [ "$NEW" = "$CURRENT" ]; then
      echo "[nat64-tayga] config unchanged — skipping restart"
    else
      $SUDO systemctl reset-failed nat64-tayga.service 2>/dev/null || true
      # start --no-block: activation must never hang the deploy
      $SUDO systemctl start --no-block nat64-tayga.service 2>/dev/null || true
      echo "$NEW" | $SUDO tee /etc/tayga.conf.prev > /dev/null
      echo "[nat64-tayga] deployed on ${vmName}"
    fi
    ) || echo "[nat64-tayga] FAILED — see errors above, activation continues"
  '';
}
