# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/network/ipv6-guest.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ipv6-guest.nix — bring the OCI-assigned IPv6 UP INSIDE THE GUEST.
#
# ENABLED ONLY ON: oci-analytics (wg-public hub). No-op on every other VM.
#
# WHY THIS EXISTS (2026-08-12)
# ───────────────────────────
# OCI assigns an IPv6 to the VNIC in its CONTROL PLANE. terraform does that
# (c_vps/vps_oci, oci_core_ipv6.analytics_v6 → 2603:c026:c104:8f00:0:c704:63b:6eee)
# and it is genuinely allocated — the terraform apply refreshes it from a real
# OCID. But the GUEST OS never configures it, so nothing on the instance ever
# listens on that address.
#
# Proven, not assumed. Pointing the laptop's wg-public peer at
# [2603:c026:c104:8f00:0:c704:63b:6eee]:51821 and waiting 65s:
#   sent     16.02 KiB -> 16.08 KiB   (packets leaving)
#   received  4.40 KiB ->  4.40 KiB   (nothing coming back)
#   handshake aged out to 1m35s
# Reverted to the IPv4 endpoint and the handshake recovered immediately.
#
# The same missing guest-side IPv6 is why nat64-tayga.nix does not translate:
# its prefix 2603:c026:c104:8f00:ff9b::/96 is carved from a /64 the OS has never
# brought up, so nothing routes to it either. One fix, both features.
#
# CONFIRMED ON THE INSTANCE 2026-08-12 — both halves of this module's premise
# were checked directly on oci-analytics rather than inferred from a failing
# handshake:
#   ip -6 addr show dev ens3 scope global
#     -> fd0c:1d00::4/64, fd0c:1d01::1/64        (the two ULA mesh addresses)
#     -> NO 2603:… address. The OCI-assigned IPv6 was genuinely absent.
#   ip -6 route show default
#     -> default via fe80::200:17ff:fe89:a0df dev ens3 proto ra
# So the ROUTE was already there and correct, arriving by Router Advertisement,
# while the ADDRESS was the only missing piece. That is exactly the split this
# module assumes, and it settles the open question below: OCI *does* send RAs on
# this subnet, so accept-ra genuinely supplies the default route and the gateway
# never has to be hardcoded.
#
# Adding the address by hand (ip -6 addr add …/128 dev ens3) and repointing the
# laptop's wg-public peer at [2603:…:6eee]:51821 made the tunnel work on the
# first attempt: handshake 22s and refreshing, `received` moving for the first
# time ever on IPv6 (6.74 -> 6.83 KiB), and 3/3 ping replies to 10.1.0.1 through
# the tunnel. That hand-added address is session-only and disappears on reboot —
# this module is what makes it survive.
#
# WHY RA/DHCPv6 AND NOT A STATIC ADDRESS
# ──────────────────────────────────────
# A static address needs a gateway, and getting an OCI IPv6 gateway wrong
# installs a bad default route on the VM that hosts the wg-public hub — i.e. it
# can cut the fleet off from the machine that fixes it. accept-ra + dhcp6 asks
# the network instead of asserting: if OCI answers, the address and route come
# from the authority that assigned them; if it does not, NOTHING CHANGES and
# IPv4 is untouched. Non-destructive by construction, which matters on a host
# reachable only over the network being edited.
#
# Deployed as a netplan DROP-IN (99-ipv6.yaml), never by editing OCI's own
# 50-cloud-init.yaml: cloud-init rewrites that file on boot and the change would
# silently vanish. Higher-numbered drop-ins merge over lower ones.
{ vmName }:

{ config, lib, pkgs, ... }:

let
  enabled = vmName == "oci-analytics";

  # The address OCI assigned to this VNIC. Source of truth is terraform:
  # c_vps/vps_oci, output analytics_ipv6 (oci_core_ipv6.analytics_v6).
  # Search token: ANALYTICS_IPV6 — must match wireguard-public-endpoints.json
  # hub.host_v6 in the unix repo, or the laptop dials an address the VM does
  # not hold. Same hardcode-with-a-token convention nat64-tayga.nix uses for
  # NAT64_PREFIX.
  analyticsIpv6 = "2603:c026:c104:8f00:0:c704:63b:6eee";

  # /128, not /64. OCI routes the assigned address to the VNIC as a host route;
  # claiming the whole /64 on the interface would make the guest believe every
  # neighbour in the subnet is link-local and blackhole them.
  analyticsIpv6Cidr = "${analyticsIpv6}/128";

  # Primary NIC. OCI Ubuntu images name it ens3 (virtio) — resolved at RUNTIME
  # from the default route rather than hardcoded, because a wrong interface name
  # yields a netplan file that applies cleanly and does nothing at all.
  #
  # STATIC ADDRESS + RA FOR THE ROUTE. The address is deterministic (terraform
  # assigned it) so it is asserted directly, which removes the dependency on OCI
  # actually serving DHCPv6 — the open question that made the first attempt a
  # coin flip.
  #
  # The GATEWAY is deliberately NOT hardcoded. OCI publishes no static IPv6
  # gateway: its documented method takes the default route from Router
  # Advertisement, and the virtual router's link-local address varies per subnet
  # and is not derivable from anything in this repo. Guessing it would install a
  # bogus default route ON THE VM THAT HOSTS THE wg-public HUB — i.e. it could
  # cut the fleet off from the machine needed to undo it. accept-ra takes the
  # route from the authority that owns it; dhcp6 stays on as a belt-and-braces
  # second path to the same answer. Neither can install a wrong route.
  netplanDropIn = ''
    # Managed by home-manager (ipv6-guest.nix) — do not edit.
    # Drop-in over OCI's cloud-init config; cloud-init rewrites
    # 50-cloud-init.yaml on boot, so IPv6 must live in its own file.
    network:
      version: 2
      ethernets:
        @IFACE@:
          dhcp6: true
          accept-ra: true
          addresses:
            - ${analyticsIpv6Cidr}
  '';
in
lib.mkIf enabled {
  home.packages = with pkgs; [ iproute2 ];

  home.file.".local/share/ipv6-guest/99-ipv6.yaml.tpl".text = netplanDropIn;

  home.activation.installGuestIpv6 = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    trap 'echo "[ipv6-guest] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[ipv6-guest] WARNING: sudo not found — skipping"
      exit 0
    fi

    if [ ! -d /etc/netplan ]; then
      echo "[ipv6-guest] no /etc/netplan — not an Ubuntu/netplan host, skipping"
      exit 0
    fi

    # Interface carrying the default route. Guessing wrong produces a netplan
    # file that applies without error and changes nothing, so resolve it.
    IFACE=$(${pkgs.iproute2}/bin/ip route show default 2>/dev/null | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')
    IFACE=''${IFACE:-ens3}
    echo "[ipv6-guest] primary interface: $IFACE"

    NEW=$(${pkgs.gnused}/bin/sed "s|@IFACE@|$IFACE|" "$HOME/.local/share/ipv6-guest/99-ipv6.yaml.tpl")
    DST=/etc/netplan/99-ipv6.yaml

    CURRENT=""
    $SUDO test -f "$DST" && CURRENT=$($SUDO cat "$DST" 2>/dev/null || true)
    if [ "$NEW" = "$CURRENT" ]; then
      echo "[ipv6-guest] netplan drop-in unchanged — skipping apply"
    else
      printf '%s\n' "$NEW" | $SUDO tee "$DST" > /dev/null
      # netplan refuses world-readable configs (warns and may ignore them).
      $SUDO chmod 600 "$DST"
      # `netplan apply` re-applies ALL configs including OCI's cloud-init one,
      # so a broken drop-in takes IPv4 with it.
      #
      # RUN IT DETACHED — DO NOT run it in the foreground of this activation.
      # netplan apply restarts networking on a host that is reachable ONLY over
      # the network being restarted, so it can hang the very SSH session this
      # deploy is running through. An earlier revision of this file carried a
      # comment claiming "--no-block so a hung apply can never wedge the deploy"
      # while the command had no such flag — and netplan apply has no
      # --no-block option at all; that is a systemctl flag. The protection was
      # described but never implemented. On 2026-08-12 the oci-analytics deploy
      # hung for exactly its 45-minute timeout and was cancelled; that
      # particular hang happened earlier in the Ship step (the drop-in was never
      # written, so this line was not the cause), but it is precisely the
      # failure this line would produce once activation does reach it, on the
      # one VM that hosts the wg-public hub.
      #
      # systemd-run detaches it from this session so activation returns
      # immediately, and RuntimeMaxSec bounds it so a wedged apply cannot linger.
      # The address also comes up on next boot from the file alone, so a killed
      # apply costs nothing permanent.
      $SUDO systemd-run --unit=ipv6-guest-netplan --collect \
        --property=RuntimeMaxSec=120 \
        netplan apply 2>&1 | ${pkgs.gnugrep}/bin/grep -v '^$' || true
      echo "[ipv6-guest] applied netplan drop-in for $IFACE"
    fi

    # Report the result so the deploy log says whether it actually worked,
    # rather than leaving it to be discovered by a failing handshake later.
    ${pkgs.coreutils}/bin/sleep 3
    V6=$(${pkgs.iproute2}/bin/ip -6 addr show dev "$IFACE" scope global 2>/dev/null \
         | ${pkgs.gawk}/bin/awk '/inet6/ {print $2; exit}')
    V6ROUTE=$(${pkgs.iproute2}/bin/ip -6 route show default 2>/dev/null | ${pkgs.coreutils}/bin/head -1)

    # ADDRESS AND ROUTE ARE REPORTED SEPARATELY ON PURPOSE. The address is now
    # asserted statically, so it comes up whether or not the network cooperates
    # — meaning "has an address" no longer proves anything works. Only the
    # default route, which must come from RA, tells you the VM can actually
    # answer off-subnet traffic like a WireGuard handshake from a v6-only WiFi.
    # Reporting them together would let a half-working state read as success.
    if [ -n "$V6" ]; then
      echo "[ipv6-guest] address OK — $IFACE has global IPv6 $V6"
    else
      echo "[ipv6-guest] WARNING: $IFACE has NO global IPv6 despite a static address in netplan." >&2
      echo "[ipv6-guest] Check that netplan applied: netplan get; journalctl -u systemd-networkd" >&2
    fi
    if [ -n "$V6ROUTE" ]; then
      echo "[ipv6-guest] route OK — default via: $V6ROUTE"
    else
      echo "[ipv6-guest] WARNING: NO IPv6 default route. The address is configured but OFF-SUBNET TRAFFIC CANNOT WORK —" >&2
      echo "[ipv6-guest] a WireGuard handshake from an IPv6-only network will still fail. OCI is not sending RAs on this" >&2
      echo "[ipv6-guest] subnet; the gateway must then be obtained from OCI (it is NOT derivable) and set explicitly." >&2
    fi
    ) || echo "[ipv6-guest] activation failed; deploy continues"
  '';
}
