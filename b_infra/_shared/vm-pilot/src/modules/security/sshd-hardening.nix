# SSH daemon hardening + boot-time SSH firewall.
#
# Phase 3 of loyal-firewalling-marmot.md: the public-port list embedded in the
# generated ssh-firewall.sh is now derived from _cloud-data-consolidated.json[._home_manager.vms]
# (sourced from b_infra/nixhm-sudo-<vmName>/build.json.firewall.public_ports).
# 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms]
# Replaces the previous hardcoded hub-mode block (per-host hostname check + fixed port list).
#
# The companion vm-pilot/network/firewall.nix runs earlier in boot (before
# network.target) from the SAME source data — both firewalls now produce
# identical INPUT chains. ssh-firewall.service runs second and re-applies
# (re-flush + same rules) as defence-in-depth.
{ vmName }:
{ config, pkgs, lib, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
  };
  vmData = cloudData.vms.${vmName} or null;
  publicPorts = if vmData == null then [] else (vmData.public_ports or []);

  # Emit one `iptables -A INPUT [-s <src>] -p <proto> --dport <port> ACCEPT`
  # per port. The `source` field on each entry MUST be honored — without it
  # ssh-firewall.sh re-flushes INPUT and adds public-source ACCEPTs that
  # silently undo firewall.nix's WG-only rules (firewall.service runs first,
  # ssh-firewall.service runs ~5s later). Two separate mkPortRule
  # implementations — both must stay aligned with the same source-honoring
  # semantics. Default 0.0.0.0/0 (no -s flag) for back-compat with entries
  # that omit `source`.
  mkPortRule = p:
    let
      proto = p.proto or "tcp";
      desc  = p.desc or "port-${toString p.port}";
      source = p.source or "0.0.0.0/0";
      srcFlag = if source == "0.0.0.0/0" then "" else "-s ${source} ";
    in
      ''iptables -A INPUT ${srcFlag}-p ${proto} --dport ${toString p.port} -m comment --comment "${desc}" -j ACCEPT'';

  portRulesScript =
    if publicPorts == []
    then ''  # no declared public ports for ${vmName} — WG mesh + lo only''
    else builtins.concatStringsSep "\n  " (map mkPortRule publicPorts);

  portCount = toString (builtins.length publicPorts);

  # ── wg-public mesh (2026-08-11) ────────────────────────────────────────
  # BUG this fixes: ssh-firewall.sh does `iptables -F INPUT` and rebuilds the
  # chain from scratch ~5s AFTER firewall.nix ran, but it only knew about the
  # wg0 mesh — so every wg-public rule firewall.nix had emitted was silently
  # wiped. IPv6 survived only because this script never touches ip6tables,
  # which is why services-server answered on fd0c:1d01::1 but dropped every
  # IPv4 packet from 10.1.0.0/24. Mirrors firewall.nix's bindings/rules so the
  # "both firewalls produce identical INPUT chains" claim above is true again.
  # The hub's 51821/udp listener is NOT re-emitted here: it is already declared
  # in nixhm-sudo-<vm>/build.json firewall.public_ports, so portRulesScript
  # covers it. Only the mesh-trust rules were missing.
  wgPublic       = consolidated.native.wireguard_public or {};
  wgPublicSubnet = wgPublic.subnet or null;
  wgPublicPeers  = wgPublic.peers or [];
  isWgPublicPeer = lib.any (p: p.name == vmName) wgPublicPeers;

  wgPublicRules = builtins.concatStringsSep "\n" (
    lib.optionals (isWgPublicPeer && wgPublicSubnet != null) [
      "iptables -A INPUT -i wg-public -j ACCEPT"
      "iptables -A INPUT -s ${wgPublicSubnet} -j ACCEPT"
    ]
  );
in
{
  home.activation.sshdHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[sshd-hardening] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SSHD_DROP="/etc/ssh/sshd_config.d/10-hardening.conf"
    SSHD_OLD="/etc/ssh/sshd_config.d/90-hardening.conf"
    SSHD_LOG_PREFIX="[sshd-hardening]"

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "$SSHD_LOG_PREFIX WARN: sudo not found — skipping sshd hardening"
      exit 0
    fi

    # Clean up old filename
    if $SUDO test -f "$SSHD_OLD"; then
      echo "$SSHD_LOG_PREFIX removing old $SSHD_OLD"
      $SUDO rm -f "$SSHD_OLD"
    fi

    # Allowed SSH source IPs (VM mesh + admin + GHA)
    ALLOWED_IPS="10.0.0.0/24 130.110.251.193 129.151.228.66 82.70.229.129 35.226.147.64 34.173.227.250"

    NEW_CONF="# Managed by home-manager (sshd-hardening.nix) — do not edit
# Anti brute-force
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxStartups 3:50:10
LoginGraceTime 20
# Performance
UseDNS no
GSSAPIAuthentication no
# Key-only auth
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
"

    # Deploy iptables: WG mesh always allowed; per-port ACCEPTs derived from
    # nixhm-sudo-${vmName}/build.json.firewall.public_ports (loyal-firewalling-marmot.md Phase 3).
    IPTABLES_SCRIPT="/opt/scripts/ssh-firewall.sh"
    $SUDO tee "$IPTABLES_SCRIPT" > /dev/null << 'FWEOF'
#!/bin/bash
# Generated by home-manager (sshd-hardening.nix) for vm=${vmName}
# Source-of-truth: b_infra/nixhm-sudo-${vmName}/build.json.firewall.public_ports
# Public ports declared: ${portCount}
set -euo pipefail
VM=$(hostname -s 2>/dev/null || echo unknown)

# SAFETY: abort if WG is not up — applying DROP without WG = total lockout
# Rescue: gcloud serial console → iptables -F INPUT && iptables -P INPUT ACCEPT
if ! ip link show wg0 >/dev/null 2>&1; then
  echo "[firewall] ABORT — wg0 not up, skipping firewall (would lock out VM)"
  exit 0
fi

iptables -F INPUT 2>/dev/null || true
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -s 10.0.0.0/24 -j ACCEPT
iptables -A INPUT -p udp --dport 51820 -j ACCEPT
# Local container -> host (#1821, owner-approved 2026-11-19). Bridge-network
# containers reach the host's own wg0/wg-public addresses (host-network
# services, the host resolver) via docker0 / br-*; only this VM's containers
# send on those interfaces. Without it Stalwart on oci-apps could not reach its
# event webhook (10.0.0.6:3103) or the host DNS, so SPF/DMARC lookups timed out.
iptables -A INPUT -i docker0 -j ACCEPT
iptables -A INPUT -i br+ -j ACCEPT

# wg-public mesh (data-driven from consolidated.native.wireguard_public)
${wgPublicRules}

# Per-VM public ports (data-driven from nixhm-sudo-${vmName}/build.json.firewall.public_ports)
${portRulesScript}

iptables -P INPUT DROP
echo "[firewall] $VM locked — WG mesh + ${portCount} declared public port(s)"
FWEOF
    $SUDO chmod +x "$IPTABLES_SCRIPT"

    # Also create systemd service to apply on boot (iptables are non-persistent)
    $SUDO tee /etc/systemd/system/ssh-firewall.service > /dev/null << 'SVCEOF'
[Unit]
Description=SSH firewall — WG mesh + per-VM declared ports
After=network-online.target wg-quick@wg0.service
Wants=wg-quick@wg0.service
Before=sshd.service ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/opt/scripts/ssh-firewall.sh

[Install]
WantedBy=multi-user.target
SVCEOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable ssh-firewall.service 2>/dev/null || true
    $SUDO "$IPTABLES_SCRIPT" 2>/dev/null || echo "$SSHD_LOG_PREFIX iptables firewall failed (non-fatal)"

    CURRENT=""
    if $SUDO test -f "$SSHD_DROP"; then
      CURRENT=$($SUDO cat "$SSHD_DROP" 2>/dev/null || true)
    fi

    if [ "$NEW_CONF" = "$CURRENT" ]; then
      echo "$SSHD_LOG_PREFIX $SSHD_DROP unchanged — skipping"
    else
      echo "$SSHD_LOG_PREFIX deploying $SSHD_DROP"
      $SUDO mkdir -p /etc/ssh/sshd_config.d
      echo "$NEW_CONF" | $SUDO tee "$SSHD_DROP" > /dev/null
      $SUDO chmod 644 "$SSHD_DROP"
      if $SUDO systemctl is-active sshd >/dev/null 2>&1 || $SUDO systemctl is-active ssh >/dev/null 2>&1; then
        $SUDO systemctl reload sshd 2>/dev/null || $SUDO systemctl reload ssh 2>/dev/null || true
        echo "$SSHD_LOG_PREFIX sshd reloaded"
      fi
    fi
    ) || echo "[sshd-hardening] FAILED — see errors above, activation continues"
  '';
}
