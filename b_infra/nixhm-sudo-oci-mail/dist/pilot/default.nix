# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/default.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# vm-pilot: Single entry point for all shared VM modules
# Usage: (import ./modules/default.nix { vmName = "oci-apps"; })
#
# Consolidates 37+ modules into a single import.
# Per-VM differences are driven by cloud-data JSON, parameterized by vmName.
#
{ vmName }:
{ config, pkgs, lib, ... }:
let
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
  consolidated = builtins.fromJSON (builtins.readFile ./_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
  };
  vmData = cloudData.vms.${vmName};
  # Pass through `source` (and other optional fields) so firewall.nix mkPortRule
  # can emit per-port -s CIDR. Previously this map only kept port/proto/desc —
  # stripping `source` silently — so the WG-only restriction on gcp-proxy's
  # 25/443 listeners didn't actually fire (deployed firewall.sh had no -s flag).
  publicPorts = map (p: {
    port = p.port;
    proto = p.proto;
    desc = p.desc;
    source = p.source or "0.0.0.0/0";
  }) vmData.public_ports
    # Rescue SSH (Dropbear) — WG-only. Only WG handshake (51820/udp) and WG
    # fallback (443/udp) are reachable from public; everything else, including
    # rescue SSH, must be inside the mesh. Break-glass: WG-tunneled access from
    # admin termux+WG.
    ++ [{ port = vmData.rescue_port; proto = "tcp"; desc = "Rescue SSH (Dropbear)"; source = "10.0.0.0/24"; }];

  # ── wg-public mesh membership (Phase 2 of zero-public-TCP plan) ─────
  # Data-driven: a VM participates in wg-public iff it appears in
  # consolidated.native.wireguard_public.peers[].name. No hardcoded VM lists.
  wgPublicPeers = consolidated.native.wireguard_public.peers or [];
  isWgPublicMember = lib.any (p: p.name == vmName) wgPublicPeers;

  # Low-memory class (ram_gb <= 1, same cut as the zram sizing): the Fedora package-manager
  # timers and PackageKit are memory competitors with no function on a declaratively managed
  # box (packages come from nix). 2026-11-25 20:30Z a dnf5 metadata refresh ran on the 944 MB
  # hub while containers were starting (#1898). Quiesced = disabled + stopped + masked.
  lowMemVm = (vmData.specs.ram_gb or 99) <= 1;
  packageManagerQuiesce = [
    "dnf-makecache.timer" "dnf-makecache.service"
    "dnf5-makecache.timer" "dnf5-makecache.service"
    "dnf-automatic.timer" "dnf-automatic-download.timer"
    "dnf-automatic-install.timer" "dnf-automatic-notifyonly.timer"
    "dnf5-automatic.timer"
    "packagekit.service" "packagekit-offline-update.service"
  ];
in {
  imports = [
    # ── Protection (system-protection orchestrator imports: resource-bouncer,
    #    watchdog, rescue-ssh, scheduler, layer2-identity, dashboard, health-agent)
    (import ./protection/system-protection.nix { inherit config pkgs lib; inherit vmName; })
    (import ./protection/systemd-control.nix { quiesce = lib.optionals lowMemVm packageManagerQuiesce; })
    # Cleanup stranded systemd units from migrations (data:
    # nixhm-sudo-<vm>/build.json .obsolete_systemd_units[]). No-op when
    # the array is empty or absent — safe on every VM.
    (import ./protection/obsolete-cleanup.nix { inherit vmName; })
  ] ++ lib.optionals (vmName != "oci-apps") [
    ./protection/no-build-guard.nix        # WARNING: small VM — remind operators not to build
    ./container/no-build-guardrails.nix    # WARNING: docker wrapper — warns on build/--build
  ] ++ [
    # ── Container (container orchestrator imports: daemon, tools)
    (import ./container/init.nix { inherit vmName; })
    ./container/container.nix

    # ── Network
    # wg0 — private internal mesh (always present on every VM)
    (import ./network/wireguard.nix { inherit vmName; interfaceName = "wg0"; meshKey = "wireguard"; secretEnvName = "WG_PRIVATE_KEY"; })
    (import ./network/firewall.nix { inherit vmName; inherit publicPorts; })
    # MUST come before nat64-tayga: tayga's prefix is carved from the /64 that
    # this module brings up in the guest. Without it tayga has nothing to route.
    (import ./network/ipv6-guest.nix { inherit vmName; })
    (import ./network/nat64-tayga.nix { inherit vmName; })
    ./network/dns-hickory.nix
    ./network/etc-hosts-clean.nix    # strips *.diegonmarcos.com hijacks (Caddy = sole route owner)

    # ── Security
    (import ./security/ssh-keys.nix { inherit vmName; })
    ./security/authorized-keys.nix
    (import ./security/sshd-hardening.nix { inherit vmName; })
    ./security/serial-console.nix

    # ── Infra
    ./infra/shell-path.nix
    ./infra/system-cleanup.nix
    (import ./infra/prune-maintenance.nix { inherit vmName; })

    # ── Packages
    ./packages/node-npm-deps.nix
    ./packages/docker-pull-up.nix
    ./packages/ghcr-hygiene.nix

    # ── Agents (new in vm-pilot)
    ./agents/journal-ntfy.nix
    # Go host daemon, SHADOW stage (#1876): records decisions next to the shell units, acts on nothing
    (import ./agents/vm-pilotd.nix { inherit vmName; })
    ./agents/data-publisher.nix
    ./agents/evidence-collector.nix
    ./agents/log-shipper.nix

    # ── Shared user config
    (import ./shared/bash-config.nix { inherit vmName; })
    ./shared/git-config.nix
  ] ++ lib.optionals isWgPublicMember [
    # ── wg-public — public-trust mesh (Phase 2 of zero-public-TCP plan)
    # Conditionally imported for VMs listed in
    # consolidated.native.wireguard_public.peers[].name. Currently:
    # oci-analytics (hub), gcp-proxy, oci-mail, oci-apps (spokes).
    (import ./network/wireguard.nix {
      inherit vmName;
      interfaceName = "wg-public";
      meshKey       = "wireguard_public";
      secretEnvName = "WG_PUBLIC_PRIVATE_KEY";
    })
  ];
}
