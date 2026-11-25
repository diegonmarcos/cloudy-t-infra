# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/agents/vm-pilotd.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# agents/vm-pilotd.nix — Go host daemon, SHADOW stage (ticket #1876).
#
# One static Go binary (b_infra/_shared/vm-pilot/src/vm-pilotd) that re-implements the decisions
# of journal-ntfy, load-shedder and tier1-watchdog. In shadow mode it ACTS ON NOTHING: every
# decision is written to the journal (tag vm-pilotd, line prefix "SHADOW") next to the shell
# units, which stay installed, enabled and in charge. Switch-over happens only after a soak
# comparison; the shell units remain declared for rollback.
#
# Deliberately an observer: normal slice, OOM-killable (OOMScoreAdjust=500), 32M cap, 5% CPU.
# It must never compete with the connectivity island it will one day replace pieces of.
#
# watchdog-petter is NOT in the components list: the shell unit is disabled on the fleet
# (watchdog.nix activation), so there is no live behaviour to compare against. The Go core for
# it is parity-tested in CI and ships in the binary, ready for the day it is enabled.
#
# Thresholds are the same data-driven values load-shedder.nix / tier1-apps.nix read
# (consolidated native.protection + per-VM overrides).
#
# Binary delivery: a pinned GitHub release asset built by CI (vm-pilotd-test.yml), fetched at
# activation with a sha256 check; any failure leaves the VM exactly as it was.
{ vmName }:
{ config, pkgs, lib, ... }:
let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  defaults     = consolidated.native.protection or {};
  vmConf       = (consolidated._home_manager.vms.${vmName} or {}).protection or {};
  cfg          = key: fallback: vmConf.${key} or (defaults.${key} or fallback);
  ntfyBase     = consolidated.native.monitoring.ntfy_base or "https://rss.diegonmarcos.com";

  # Source-tree id of vm-pilotd the release was built from (git rev-parse HEAD:<dir>).
  releaseTag = "vm-pilotd-2d70aa3333ce";

  tier1 = cfg "tier1_services" [];

  # #1898: per-VM switch. The 944 MB hub (gcp-proxy) sets vm_pilotd_shadow=false: the shadow acts
  # on nothing, but it polls dockerd (inspect per tier-1 service every 30 s, containers/json every
  # 15 s) and holds up to 32 MB while the box thrashes; the shell units stay in charge either way.
  shadowEnabled = cfg "vm_pilotd_shadow" true;

  conf = {
    vm = vmName;
    shadow = true;
    components = [ "journal-ntfy" "shedder" ] ++ lib.optional (tier1 != []) "tier1";
    shedder = {
      warn = cfg "mem_psi_warn" 35;
      crit = cfg "mem_psi_crit" 50;
      page = cfg "mem_psi_page" 65;
      need = cfg "need_breaches" 3;
      interval_secs = cfg "interval_secs" 15;
      docker_grace_secs = cfg "docker_start_grace_secs" 180;
      tier1 = tier1;
    };
    tier1 = {
      services = tier1;
      max_restarts = cfg "tier1_max_restarts" 3;
      reset_window_secs = cfg "tier1_reset_window_secs" 300;
      interval_secs = cfg "tier1_check_interval_secs" 30;
    };
    journal_ntfy = {
      wg_base = "http://10.0.0.6:8090";
      public_base = ntfyBase;
      rate_seconds = 300;
      shell_rate_dir = "/tmp/journal-ntfy-rate";
    };
  };
in
{
  home.file.".local/share/vm-pilotd/vm-pilotd.json".text = builtins.toJSON conf;

  home.file.".local/share/vm-pilotd/vm-pilotd.service".text = ''
    [Unit]
    Description=vm-pilotd (Go, SHADOW stage #1876) - records decisions, acts on nothing
    After=multi-user.target
    [Service]
    Type=notify
    NotifyAccess=main
    ExecStart=/opt/scripts/vm-pilotd -config /etc/vm-pilotd.json
    Restart=always
    RestartSec=30
    WatchdogSec=120
    MemoryMax=32M
    CPUQuota=5%
    Nice=10
    OOMScoreAdjust=500
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/vm-pilotd/fetch-vm-pilotd.sh" = {
    executable = true;
    text = ''
      #!/bin/sh
      # Fetch the pinned vm-pilotd release asset for this architecture and install it atomically.
      # Exit 0 = binary in place (new or already current); exit 1 = nothing changed.
      TAG="$1"
      DEST=/opt/scripts/vm-pilotd
      case "$(uname -m)" in
        x86_64)  A=amd64 ;;
        aarch64) A=arm64 ;;
        *) echo "[vm-pilotd] unsupported arch $(uname -m)"; exit 1 ;;
      esac
      if [ -x "$DEST" ] && [ "$(cat /opt/scripts/vm-pilotd.tag 2>/dev/null)" = "$TAG" ]; then
        echo "[vm-pilotd] binary already at $TAG"; exit 0
      fi
      BASE="https://github.com/diegonmarcos/cloudy-t-infra/releases/download/$TAG"
      T=$(mktemp -d) || exit 1
      trap 'rm -rf "$T"' EXIT
      curl -fsSL --max-time 90 -o "$T/bin" "$BASE/vm-pilotd-linux-$A" || { echo "[vm-pilotd] download failed"; exit 1; }
      curl -fsSL --max-time 30 -o "$T/sum" "$BASE/vm-pilotd-linux-$A.sha256" || { echo "[vm-pilotd] checksum download failed"; exit 1; }
      WANT=$(cut -d' ' -f1 "$T/sum")
      GOT=$(sha256sum "$T/bin" | cut -d' ' -f1)
      [ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || { echo "[vm-pilotd] checksum mismatch"; exit 1; }
      chmod 755 "$T/bin"
      mkdir -p /opt/scripts
      mv -f "$T/bin" "$DEST.new" && mv -f "$DEST.new" "$DEST" && echo "$TAG" > /opt/scripts/vm-pilotd.tag
      echo "[vm-pilotd] installed $TAG ($A)"
    '';
  };

  home.activation.installVmPilotd = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[vm-pilotd] no sudo - skipping" && exit 0

    ${lib.optionalString (!shadowEnabled) ''
    # #1898: disabled on this VM - stop and disable the shadow, never install it.
    timeout 15 $SUDO systemctl disable --now vm-pilotd.service 2>/dev/null || true
    echo "[vm-pilotd] shadow stage disabled for this VM (vm_pilotd_shadow=false)"
    exit 0
    ''}
    SRC="$HOME/.local/share/vm-pilotd"
    if ! timeout 150 $SUDO sh "$SRC/fetch-vm-pilotd.sh" ${releaseTag}; then
      echo "[vm-pilotd] binary not installed - shadow stage skipped (shell units unaffected)"
      exit 0
    fi
    $SUDO cp -f "$SRC/vm-pilotd.json" /etc/vm-pilotd.json
    $SUDO cp -f "$SRC/vm-pilotd.service" /etc/systemd/system/vm-pilotd.service
    # ACTIVATION MUST NEVER BLOCK: every systemctl is timeout-capped, restart is --no-block.
    timeout 15 $SUDO systemctl daemon-reload || true
    timeout 10 $SUDO systemctl enable vm-pilotd.service 2>/dev/null || true
    timeout 10 $SUDO systemctl restart --no-block vm-pilotd.service 2>/dev/null || true
    echo "[vm-pilotd] shadow stage deployed (${releaseTag})"
    ) || echo "[vm-pilotd] FAILED - activation continues"
  '';
}
