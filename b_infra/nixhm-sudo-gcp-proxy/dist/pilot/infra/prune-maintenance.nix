# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/pilot/infra/prune-maintenance.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Infra Prune Maintenance — daily proactive cleanup of docker + nix + journald
#
# WHY this exists
# ───────────────
# protection/watchdog-petter-dropbear-health-agent.nix has a disk-watchdog
# that ONLY fires above 85% / 90% / 95% thresholds. Below those, prunables
# accumulate freely (build cache, untagged images, stopped containers, old
# nix generations, journald logs). On VMs that stay comfortably under the
# WARN line for months, that's many GB of dead weight.
#
# This module mirrors the desktop's storage-maintenance.service pattern
# (unix/aa_nixos-surface_host/src/modules/configuration_system-protection-storage.nix):
# scheduled, low-priority, conservative defaults.
#
# WHAT IT RUNS (all safe — no data-loss ops)
#   docker container prune -f --filter              drop stopped containers that
#     'label!=com.docker.compose.project'           are NOT a declared service
#   docker image prune -f --filter until=72h        drop dangling images >72h
#   docker builder prune -f --max-used-space=1G     cap build cache at 1G
#   journalctl --vacuum-time=<floor>d               age out journals older than
#                                                   native.protection.journal_retention_floor_days
#                                                   (#413 — never --vacuum-size, it ignores age)
#   nix-env --delete-generations +3 (every profile) keep the 3 newest generations
#   nix-collect-garbage                             then collect what they freed
#   nix-store --optimise                            retroactive hardlink dedup
#   apt-get autoclean + clean                       drop the apt package cache
#   logrotate (hourly, own timer)                   syslog: daily + maxsize 100M + gzip
# (journald is capped in protection/resource-bouncer.nix: SystemMaxUse=500M.
#  fluent-bit noise is cut at the source in agents/log-shipper.nix + its conf.)
#
# WHAT IT DOES NOT RUN (intentionally — guardrail-banned in protection/guardrails.nix)
#   docker volume prune              — may contain databases
#   docker system prune -a --volumes — same
#   docker image prune -af           — drops images currently unused but
#                                      possibly needed for next deploy
#
# Schedule: daily 03:30 (staggered 30min before disk-swap-maintenance at
# 04:00 to avoid IO contention on E2 Micros).
#
# Imported by: ./default.nix with vmName (every VM gets it).
{ vmName }:
{ config, pkgs, lib, ... }:

let
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  protVm = (consolidated._home_manager.vms.${vmName} or {}).protection or {};
  journalFloorDays = protVm.journal_retention_floor_days
    or consolidated.native.protection.journal_retention_floor_days
    or (throw "prune-maintenance.nix: native.protection.journal_retention_floor_days is not declared in config.json");
in
{
  home.file.".local/share/system-protection/infra-prune-maintenance.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Don't `set -e` — every prune op is independent; a single failure
      # (e.g. docker daemon down, nix-collect-garbage missing) must not
      # abort the rest of the run.
      set -u

      LOG_PREFIX="[prune-maint]"

      echo "$LOG_PREFIX === $(date '+%Y-%m-%d %H:%M:%S') ==="

      # ── Disk before ──────────────────────────────────────────────────
      USAGE_BEFORE=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
      AVAIL_BEFORE_KB=$(df -P / | awk 'NR==2 { print $4 }')
      echo "$LOG_PREFIX Disk before: ''${USAGE_BEFORE}% used, $((AVAIL_BEFORE_KB/1024))MB free"

      # ── Docker pruning (skip cleanly if daemon down) ─────────────────
      if command -v docker >/dev/null 2>&1 && \
         docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then

        DOCKER_BEFORE=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null \
          | awk '{print $0}' | tr '\n' '|' || echo "?")
        echo "$LOG_PREFIX Docker before: $DOCKER_BEFORE"

        # label!=com.docker.compose.project — NEVER prune a declared service.
        # An unfiltered `container prune` deletes every stopped container, and
        # after a reboot that is the entire fleet: restart is "no" by policy
        # (container-init owns lifecycle), so the 03:30 run would delete the
        # containers the boot sequence had not yet recreated. That is exactly
        # how vaultwarden vanished — rebooted 2026-08-30 22:11, pruned 03:30,
        # gone for 4 days with vault.diegonmarcos.com serving 502, because
        # nothing re-shipped it. Every declared service is deployed through
        # docker compose and therefore carries this label; what is left to
        # collect is stray `docker run` debris, which is all this should ever
        # have been reclaiming.
        # NOT `--filter until=<age>`: that matches on CREATION time, so it
        # protects only containers created in the last N hours — precisely
        # backwards, since the long-lived ones are the ones worth keeping.
        docker container prune -f --filter "label!=com.docker.compose.project" 2>&1 | sed "s/^/$LOG_PREFIX docker-container: /"
        docker image prune -f --filter "until=72h" 2>&1 | sed "s/^/$LOG_PREFIX docker-image: /"
        # --max-used-space, not --keep-storage: docker 27.5.1 (all four VMs,
        # measured 2026-09-24) prints a deprecation warning for the old name,
        # and its first rename --max-storage is rejected as an unknown flag.
        docker builder prune -f --max-used-space=1G 2>&1 | sed "s/^/$LOG_PREFIX docker-builder: /"

        DOCKER_AFTER=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null \
          | awk '{print $0}' | tr '\n' '|' || echo "?")
        echo "$LOG_PREFIX Docker after : $DOCKER_AFTER"
      else
        echo "$LOG_PREFIX Docker: not running, skipping"
      fi

      # ── Journald rotation ────────────────────────────────────────────
      if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=${toString journalFloorDays}d 2>&1 | sed "s/^/$LOG_PREFIX journal-time: /" | tail -3
      fi

      # ── Nix: keep 3 generations, then collect ────────────────────────
      # systemd gives this unit a bare PATH; nix lives in the default profile.
      export PATH="/nix/var/nix/profiles/default/bin:$PATH"
      if command -v nix-collect-garbage >/dev/null 2>&1; then
        # Every profile that accumulates generations: HM + profile of each user,
        # root's, and the default one. `+3` = keep the newest three, drop the rest.
        for prof in /nix/var/nix/profiles/default \
                    /nix/var/nix/profiles/per-user/*/profile \
                    /nix/var/nix/profiles/per-user/*/home-manager \
                    /home/*/.local/state/nix/profiles/home-manager \
                    /home/*/.local/state/nix/profiles/profile \
                    /root/.local/state/nix/profiles/home-manager \
                    /root/.local/state/nix/profiles/profile; do
          [ -e "$prof" ] || continue
          nix-env --profile "$prof" --delete-generations +3 2>&1 \
            | sed "s|^|$LOG_PREFIX nix-gens $prof: |" | tail -2 || true
        done
        nix-collect-garbage 2>&1 | sed "s/^/$LOG_PREFIX nix-gc: /" | tail -5
      fi
      if command -v nix-store >/dev/null 2>&1; then
        # Retroactive hardlink dedup. Cheap if auto-optimise-store=true,
        # but VMs are Ubuntu+HM (no NixOS module) so this is the only
        # full-pass optimise that ever runs.
        nix-store --optimise 2>&1 \
          | sed "s/^/$LOG_PREFIX nix-optimise: /" | tail -3 || true
      fi

      # ── apt cache ────────────────────────────────────────────────────
      if command -v apt-get >/dev/null 2>&1; then
        apt-get -y autoclean 2>&1 | sed "s/^/$LOG_PREFIX apt-autoclean: /" | tail -2 || true
        apt-get -y clean 2>&1 | sed "s/^/$LOG_PREFIX apt-clean: /" | tail -2 || true
      fi

      # ── Disk after ───────────────────────────────────────────────────
      USAGE_AFTER=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
      AVAIL_AFTER_KB=$(df -P / | awk 'NR==2 { print $4 }')
      FREED_MB=$(( (AVAIL_AFTER_KB - AVAIL_BEFORE_KB) / 1024 ))
      echo "$LOG_PREFIX Disk after : ''${USAGE_AFTER}% used, $((AVAIL_AFTER_KB/1024))MB free (freed ''${FREED_MB}MB)"
      echo "$LOG_PREFIX === done ==="
    '';
  };

  home.file.".local/share/system-protection/infra-prune-maintenance.service".text = ''
    [Unit]
    Description=Infra prune maintenance — docker + nix + journald (daily, conservative)
    After=docker.service network.target
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/infra-prune-maintenance.sh
    User=root
    Nice=19
    IOSchedulingClass=idle
    OOMScoreAdjust=500
    TimeoutStartSec=30min
    StandardOutput=journal
    StandardError=journal
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/infra-prune-maintenance.timer".text = ''
    [Unit]
    Description=Daily infra prune maintenance (03:30)
    [Timer]
    OnCalendar=*-*-* 03:30:00
    RandomizedDelaySec=10min
    Persistent=true
    [Install]
    WantedBy=timers.target
  '';


  # ── syslog: daily + maxsize + gzip ────────────────────────────────────
  # Ubuntu's stock /etc/logrotate.d/rsyslog rotates WEEKLY with no size cap, so a
  # chatty shipper turned /var/log/syslog into 500M+ (fluent-bit retry spam,
  # ~170M/day, 2026-10-14). Daily + maxsize 100M + gzip bounds a file at roughly
  # 100M live + 7 x gz. The hourly timer below makes maxsize bite within the
  # hour instead of waiting for logrotate.timer's once-a-day run.
  home.file.".local/share/system-protection/logrotate-rsyslog".text = ''
    /var/log/syslog
    /var/log/mail.log
    /var/log/kern.log
    /var/log/auth.log
    /var/log/user.log
    /var/log/cron.log
    {
    	rotate 7
    	daily
    	maxsize 100M
    	maxage 14
    	missingok
    	notifempty
    	compress
    	sharedscripts
    	postrotate
    		/usr/lib/rsyslog/rsyslog-rotate
    	endscript
    }
  '';

  # fluent-bit already lands in the journal; copying its retry/parse chatter into
  # /var/log/syslog as well is what filled the disk. Errors stay in the journal.
  home.file.".local/share/system-protection/rsyslog-no-fluent-bit.conf".text = ''
    :programname, isequal, "fluent-bit" stop
  '';

  home.file.".local/share/system-protection/logrotate-hourly.service".text = ''
    [Unit]
    Description=Hourly logrotate pass for syslog (daily + maxsize)
    [Service]
    Type=oneshot
    ExecStart=/usr/sbin/logrotate /etc/logrotate.d/rsyslog
    Nice=19
    IOSchedulingClass=idle
  '';

  home.file.".local/share/system-protection/logrotate-hourly.timer".text = ''
    [Unit]
    Description=Hourly logrotate pass for syslog
    [Timer]
    OnCalendar=hourly
    RandomizedDelaySec=5min
    Persistent=true
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation: copy to /opt + /etc/systemd/system, enable, start ───
  home.activation.installPruneMaintenance = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[prune-maint-install] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[prune-maint-install] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/infra-prune-maintenance.sh"      /opt/scripts/infra-prune-maintenance.sh
    $SUDO chmod +x                                     /opt/scripts/infra-prune-maintenance.sh
    $SUDO cp -f "$SRC/infra-prune-maintenance.service" /etc/systemd/system/infra-prune-maintenance.service
    $SUDO cp -f "$SRC/infra-prune-maintenance.timer"   /etc/systemd/system/infra-prune-maintenance.timer

    if [ -d /etc/logrotate.d ] && [ -x /usr/sbin/logrotate ]; then
      $SUDO cp -f "$SRC/logrotate-rsyslog"             /etc/logrotate.d/rsyslog
      $SUDO cp -f "$SRC/logrotate-hourly.service"      /etc/systemd/system/logrotate-hourly.service
      $SUDO cp -f "$SRC/logrotate-hourly.timer"        /etc/systemd/system/logrotate-hourly.timer
    fi
    if [ -d /etc/rsyslog.d ]; then
      if ! $SUDO cmp -s "$SRC/rsyslog-no-fluent-bit.conf" /etc/rsyslog.d/05-no-fluent-bit.conf 2>/dev/null; then
        $SUDO cp -f "$SRC/rsyslog-no-fluent-bit.conf" /etc/rsyslog.d/05-no-fluent-bit.conf
        $SUDO systemctl restart rsyslog 2>/dev/null || true
      fi
    fi

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable  infra-prune-maintenance.timer 2>/dev/null || true
    $SUDO systemctl restart infra-prune-maintenance.timer 2>/dev/null || true
    $SUDO systemctl enable  logrotate-hourly.timer 2>/dev/null || true
    $SUDO systemctl restart logrotate-hourly.timer 2>/dev/null || true

    echo "[prune-maint-install] deployed: daily 03:30 prune (docker, nix keep-3, apt, journal) + hourly syslog logrotate"
    ) || echo "[prune-maint-install] FAILED — activation continues"
  '';
}
