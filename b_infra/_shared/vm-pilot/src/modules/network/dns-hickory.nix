# Configure DNS resolvers for all VMs — reads from _cloud-data-consolidated.json
# 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[.native.dns]
# Three methods, picked per host (all idempotent):
#   A. systemd-resolved active → drop-in /etc/systemd/resolved.conf.d/hickory.conf
#      (DNS=primary, FallbackDNS=fallback), resolved restarted only on change.
#      On these hosts `resolvconf` is resolvectl's shim and `-a <name>` needs a
#      real interface: `resolvconf -a hickory` failed with "No such device"
#      and left /etc/resolv.conf untouched (gcp-proxy Ship run 44259524045).
#   B. real resolvconf (openresolv) → `resolvconf -a hickory|hickory-fallback`
#   C. neither → direct write of an immutable /etc/resolv.conf
# DNS hierarchy:
#   Tier 1: Hickory (10.0.0.1) — .app private domains + forwarding
#   Tier 2: Cloudflare (1.1.1.1, 1.0.0.1) — fallback
#   Tier 3: Google (8.8.8.8) — last resort
# Docker daemon.json DNS is owned by container-init.nix
{ config, lib, pkgs, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    dns = consolidated.native.dns or {};
  };
  primaryDns = cloudData.dns.primary;
  fallbackDns = cloudData.dns.fallback;
in {
  home.activation.configureHickoryDns = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[hickory-dns] no sudo — skipping" && exit 0

    # systemctl, to tell whether systemd-resolved owns the stub resolver
    SYSTEMCTL=""
    for p in /run/current-system/sw/bin/systemctl /usr/bin/systemctl /bin/systemctl; do
      [ -x "$p" ] && SYSTEMCTL="$p" && break
    done
    RESOLVED_ACTIVE=0
    if [ -n "$SYSTEMCTL" ] && $SYSTEMCTL is-active --quiet systemd-resolved 2>/dev/null; then
      RESOLVED_ACTIVE=1
    fi

    # Use resolvconf if available (NixOS, Arch with openresolv) — but not
    # resolvectl's compatibility shim, whose `-a` wants a real interface.
    RESOLVCONF=""
    for p in /run/current-system/sw/bin/resolvconf /usr/bin/resolvconf /usr/sbin/resolvconf /sbin/resolvconf; do
      [ -x "$p" ] && RESOLVCONF="$p" && break
    done
    if [ -n "$RESOLVCONF" ] && [ "$(basename "$(readlink -f "$RESOLVCONF")")" = "resolvectl" ]; then
      RESOLVCONF=""
    fi

    if [ "$RESOLVED_ACTIVE" = 1 ]; then
      # systemd-resolved method — global DNS via a drop-in, restart on change only
      HICKORY_DROPIN=/etc/systemd/resolved.conf.d/hickory.conf
      WANT="# Managed by home-manager (vm-pilot dns-hickory.nix) — do not edit
[Resolve]
DNS=${primaryDns}
FallbackDNS=${fallbackDns} 8.8.8.8
"
      if [ -f "$HICKORY_DROPIN" ] && [ "$(cat "$HICKORY_DROPIN")" = "$(printf '%s' "$WANT")" ]; then
        echo "[hickory-dns] systemd-resolved drop-in already current → ${primaryDns} (tier 1)"
      else
        $SUDO mkdir -p /etc/systemd/resolved.conf.d
        printf '%s' "$WANT" | $SUDO tee "$HICKORY_DROPIN" > /dev/null
        $SUDO "$SYSTEMCTL" restart systemd-resolved
        echo "[hickory-dns] systemd-resolved drop-in → ${primaryDns} (tier 1), resolved restarted"
      fi
      case "$(readlink -f /etc/resolv.conf 2>/dev/null)" in
        /run/systemd/resolve/*) ;;
        *) echo "[hickory-dns] note: /etc/resolv.conf is not resolved's stub — libc may bypass resolved" ;;
      esac
    elif [ -n "$RESOLVCONF" ]; then
      # resolvconf method — proper DNS hierarchy
      echo "nameserver ${primaryDns}" | $SUDO $RESOLVCONF -a hickory
      echo "nameserver ${fallbackDns}" | $SUDO $RESOLVCONF -a hickory-fallback
      echo "[hickory-dns] resolvconf → ${primaryDns} (tier 1)"
    else
      # Fallback: direct write (Arch VMs without resolvconf)
      $SUDO chattr -i /etc/resolv.conf 2>/dev/null || true
      [ -L /etc/resolv.conf ] && $SUDO rm /etc/resolv.conf
      $SUDO tee /etc/resolv.conf > /dev/null <<DNSEOF
nameserver ${primaryDns}
nameserver ${fallbackDns}
nameserver 8.8.8.8
DNSEOF
      $SUDO chattr +i /etc/resolv.conf 2>/dev/null || true
      echo "[hickory-dns] resolv.conf → ${primaryDns} (direct write, immutable)"
    fi

    # A stale resolved drop-in is only removed where resolved does not own DNS
    if [ "$RESOLVED_ACTIVE" != 1 ]; then
      $SUDO rm -f /etc/systemd/resolved.conf.d/hickory.conf
    fi
    ) || echo "[hickory-dns] FAILED — see errors above"
  '';
}
