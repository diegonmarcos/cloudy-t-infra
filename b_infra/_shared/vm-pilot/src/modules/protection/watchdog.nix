# System Protection — Disk Swap + Disk Watchdog + Kernel Watchdog Petter
# Disk swap (+ 24h defrag maintenance), disk watchdog (escalating cleanup
# with swap+docker budget awareness), kernel watchdog petter.
#
# Disk watchdog tiers:
#   85% WARN  — tmp/journals (never below the retention floor)/docker prune (incl. images >72h)
#   90% CRIT  — aggressive prune (swap untouched)
#   95% EMERG — remove swapfile entirely + truncate logs + nix GC
#
# Split from: system-protection-watchdog-petter-dropbear-health-agent.nix
# Imported by: default.nix (via system-protection.nix orchestrator)
#
{ config, pkgs, lib, ramMB, vmName, ... }:

let
  diskSwapMB = if ramMB < 2048 then 2048 else ramMB;

  # P4: data-driven watchdog-petter thresholds (disk tiers, docker-fail, low-mem
  # prune) + ntfy base/topic. Single SoT: config.json native.protection (defaults)
  # + b_infra/nixhm-sudo-<alias>/build.json .protection (per-VM overrides), emitted
  # by 9_others into native.protection and _home_manager.vms.<vmName>.protection.
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  protDefaults = consolidated.native.protection or {};
  protVm       = (consolidated._home_manager.vms.${vmName} or {}).protection or {};
  prot         = key: fallback: protVm.${key} or (protDefaults.${key} or fallback);

  diskWarn      = prot "disk_warn_pct"        80;
  diskHigh      = prot "disk_high_pct"        85;
  diskEmerg     = prot "disk_emerg_pct"       90;
  dockerFail    = prot "docker_fail_threshold" 120;
  lowMemPrune   = prot "low_mem_prune_mb"     50;
  ntfyBase      = consolidated.native.monitoring.ntfy_base or "https://rss.diegonmarcos.com";
  ntfyTopic     = prot "ntfy_topic"           "watchdog-dropbear";
  # #413: no fallback literal on purpose — a floor nobody declared is not a floor.
  journalFloorDays = prot "journal_retention_floor_days"
    (throw "watchdog.nix: native.protection.journal_retention_floor_days is not declared in config.json");
in {
  # ── Disk swap ─────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/disk-swap.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      # BusyBox from the nix profile shadows util-linux/kmod/coreutils on some
      # VMs (its modprobe cannot load .ko.zst, its dd rejects status=progress),
      # which left oci-apps with no swap at all (#1641). Pin the GNU tools.
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
      SWAPFILE="/swapfile"
      SWAP_MB=${toString diskSwapMB}

      if swapon --show=NAME 2>/dev/null | grep -q "$SWAPFILE"; then
        CURRENT=$(stat -c%s "$SWAPFILE" 2>/dev/null || echo 0)
        WANT=$(($SWAP_MB * 1024 * 1024))
        if [ "$CURRENT" -ge "$WANT" ]; then
          echo "[disk-swap] Already active ($(($CURRENT/1024/1024))MB), skipping"; exit 0
        fi
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
      fi

      # Never let swap fill the root disk: cap the file at free space minus a
      # 4 GiB headroom, and skip below 1 GiB (#1641: oci-apps root was 95% full,
      # a 24 GiB file would have filled it).
      if [ ! -f "$SWAPFILE" ]; then
        AVAIL_MB=$(( $(df -P / | awk 'NR==2 {print $4}') / 1024 ))
        CAP_MB=$(( AVAIL_MB - 4096 ))
        if [ "$CAP_MB" -lt 1024 ]; then
          echo "[disk-swap] Only ''${AVAIL_MB}MB free on / - skipping disk swap"; exit 0
        fi
        if [ "$SWAP_MB" -gt "$CAP_MB" ]; then SWAP_MB=$CAP_MB; fi
      fi

      if [ ! -f "$SWAPFILE" ]; then
        echo "[disk-swap] Creating ''${SWAP_MB}MB swapfile..."
        truncate -s 0 "$SWAPFILE"
        chattr +C "$SWAPFILE" 2>/dev/null || true
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=progress
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"
      fi

      swapon -p 10 "$SWAPFILE"
      echo "[disk-swap] Activated ''${SWAP_MB}MB disk swap"
    '';
  };

  home.file.".local/share/system-protection/disk-swap.service".text = ''
    [Unit]
    Description=Disk-backed swap (${toString diskSwapMB}MB)
    After=local-fs.target
    Before=docker.service
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/disk-swap.sh
    [Install]
    WantedBy=multi-user.target
  '';

  # ── Disk swap maintenance (24h defrag cycle) ──────────────────────────
  home.file.".local/share/system-protection/disk-swap-maintenance.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      # BusyBox from the nix profile shadows util-linux/kmod/coreutils on some
      # VMs (its modprobe cannot load .ko.zst, its dd rejects status=progress),
      # which left oci-apps with no swap at all (#1641). Pin the GNU tools.
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
      SWAPFILE="/swapfile"
      SWAP_MB=${toString diskSwapMB}

      # Check disk has room to recreate (need SWAP_MB + 1GB headroom).
      # df -P (POSIX format) is portable: works on GNU coreutils AND BusyBox
      # (some VMs ship BusyBox df where --output=* is unsupported).
      # POSIX columns: 1=fs 2=1K-blocks 3=Used 4=Available 5=Capacity 6=Mountpoint.
      AVAIL_MB=$(df -P / | awk 'NR==2 {print $4}')
      AVAIL_MB=$((AVAIL_MB / 1024))
      NEED_MB=$((SWAP_MB + 1024))
      if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
        echo "[disk-swap-maint] Not enough space to recreate (''${AVAIL_MB}MB avail, need ''${NEED_MB}MB) — skipping"
        exit 0
      fi

      echo "[disk-swap-maint] Recreating ''${SWAP_MB}MB swapfile (defrag)..."
      swapoff "$SWAPFILE" 2>/dev/null || true
      rm -f "$SWAPFILE"
      truncate -s 0 "$SWAPFILE"
      chattr +C "$SWAPFILE" 2>/dev/null || true
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=progress
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE"
      swapon -p 10 "$SWAPFILE"
      echo "[disk-swap-maint] Done — ''${SWAP_MB}MB swapfile active"
    '';
  };

  home.file.".local/share/system-protection/disk-swap-maintenance.service".text = ''
    [Unit]
    Description=Swap file maintenance — recreate to defrag (${toString diskSwapMB}MB)
    After=disk-swap.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/disk-swap-maintenance.sh
  '';

  home.file.".local/share/system-protection/disk-swap-maintenance.timer".text = ''
    [Unit]
    Description=Recreate swapfile every 24h
    [Timer]
    OnBootSec=6h
    OnUnitActiveSec=24h
    [Install]
    WantedBy=timers.target
  '';

  # ── Disk watchdog ─────────────────────────────────────────────────────
  home.file.".local/share/system-protection/disk-watchdog.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      WARN=85; CRIT=90; EMERG=95

      # Durable action log — the ONE record that survives every journal vacuum.
      # journalctl --vacuum-* below erases the journal that would otherwise be
      # the only trace of what this watchdog deleted and why: on 2026-09-16 the
      # vacuum on oci-apps ate 16 days of history, including the run that had
      # just reclaimed 12.13GB minutes earlier. Every deletion below therefore
      # appends one line here — what + how much it reclaimed — with the freed
      # amount parsed from the tool's own report where it gives one. This file
      # is exempted from this script's own /var/log sweep in the EMERG branch.
      # Env-with-default so a tester can point it at a throwaway file (the same
      # pattern watchdog-petter.sh uses for its thresholds). The double
      # single-quote before the brace is the Nix escape that makes this a
      # literal shell parameter expansion: a bare dollar-brace would be parsed
      # as Nix interpolation and break the whole module at eval time.
      WATCHDOG_LOG=''${WATCHDOG_LOG:-/var/log/disk-watchdog.log}

      record() {  # record <action> <detail> [reclaimed]
        _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
        printf '%s %s %s %s reclaimed=%s\n' "$_ts" "[disk-watchdog]" "$1" "$2" "''${3:-unmeasured}" >> "$WATCHDOG_LOG" 2>/dev/null || true
        sync "$WATCHDOG_LOG" 2>/dev/null || true
      }

      reclaimed() {  # reclaimed <tool-output> — pull the freed figure from known prune reports
        printf '%s\n' "$1" | awk '
          /Total reclaimed space:/{print $4; next}
          /^Total:/{print $2; next}
          {for(v=1;v<=NF;v++){
             if($v=="freed" && v<NF){
               if(v+1<NF && $(v+2) ~ /^(B|KB|MB|GB|TB|KiB|MiB|GiB)$/){print $(v+1) " " $(v+2)} else {print $(v+1)}
               next
             }
             if($v=="MiB" && v>1 && $(v-1) ~ /^[0-9]/){print $(v-1) " MiB"; next}
           }}
        ' | tail -1
      }

      # Budget awareness: report swapfile + docker total
      SWAP_SIZE_MB=0
      if [ -f /swapfile ]; then
        SWAP_SIZE_MB=$(($(stat -c%s /swapfile 2>/dev/null || echo 0) / 1024 / 1024))
      fi
      USAGE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')

      # `docker system df` walks every image layer, container and volume. On an
      # IO-starved box that is minutes of disk work, and it was being paid on
      # EVERY 5-min tick only to be discarded by the healthy-disk exit below.
      # MEASURED 2026-08-24 on oci-mail (swap-thrashing, load 11): a single
      # invocation was still running after 9 minutes, so with OnUnitActiveSec=5min
      # the watchdog was doing that walk essentially continuously — the disk
      # watchdog had become a top consumer of the disk. Only price it once we
      # actually know the disk is in trouble, and never let it hang unbounded.
      if [ "$USAGE" -lt "$WARN" ]; then
        echo "[disk-watchdog] Root: ''${USAGE}% | swap=''${SWAP_SIZE_MB}MB"
        exit 0
      fi

      record "run" "start usage=''${USAGE}% swap=''${SWAP_SIZE_MB}MB"

      # ── >=85%: disk-janitor in aggressive mode + ntfy alert ──────────────
      # The janitor (infra-ops_disk-janitor, a container on oci-apps) owns the
      # policy: dangling images, unused build cache, images beyond in-use + 1
      # previous, idle GitHub runner leftovers, Gradle cache, cgc lance fragments.
      # `--aggressive` drops its age gates; its keep rules and never-list are
      # unchanged, so this cannot reach a volume. Cooldowns (30 min janitor,
      # 60 min alert) keep a stuck-high disk from re-running a docker-wide walk
      # every 5 minutes and from spamming ntfy. VMs without the container skip
      # the janitor and still alert.
      STAMP_DIR=''${STAMP_DIR:-/var/tmp}
      _now=$(date +%s)
      _age() { _m=$(stat -c %Y "$1" 2>/dev/null || echo 0); echo $(( _now - _m )); }
      _used_before=$USAGE
      _free_before=$(df -P / | awk 'NR==2{print $4}')
      _ran_janitor=no
      if command -v docker >/dev/null 2>&1 \
         && timeout 15 docker ps --format '{{.Names}}' 2>/dev/null | grep -qx disk-janitor \
         && [ "$(_age "$STAMP_DIR/disk-watchdog-janitor.stamp")" -gt 1800 ]; then
        touch "$STAMP_DIR/disk-watchdog-janitor.stamp"
        _jout=$(timeout 1200 docker exec -e RUN_ONCE=true disk-janitor /usr/local/bin/entrypoint.sh --aggressive 2>&1 | tail -2 || true)
        _ran_janitor=yes
        _free_now=$(df -P / | awk 'NR==2{print $4}')
        record "janitor" "aggressive pass at ''${USAGE}%" "$(( (_free_now - _free_before) * 1024 ))B"
        USAGE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
      fi
      if [ "$(_age "$STAMP_DIR/disk-watchdog-ntfy.stamp")" -gt 3600 ]; then
        touch "$STAMP_DIR/disk-watchdog-ntfy.stamp"
        _freeGB=$(( $(df -P / | awk 'NR==2{print $4}') / 1048576 ))
        curl -fsS -m 10 -H "Title: $(hostname -s): root disk ''${_used_before}% used" \
          -H "Priority: high" -H "Tags: floppy_disk,warning" \
          -d "root ''${_used_before}% -> ''${USAGE}% after cleanup (''${_freeGB} GB free). janitor aggressive: $_ran_janitor. Tiers: WARN 85, CRIT 90, EMERG 95." \
          "${ntfyBase}/${ntfyTopic}" >/dev/null 2>&1 || record "ntfy" "alert publish failed"
        record "ntfy" "alert sent usage=''${_used_before}%->''${USAGE}%"
      fi

      DOCKER_SIZE="N/A"
      if command -v docker >/dev/null 2>&1 && timeout 15 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
        DOCKER_SIZE=$(timeout 60 docker system df --format '{{.Size}}' 2>/dev/null | paste -sd+ | bc 2>/dev/null || timeout 60 docker system df 2>/dev/null | awk 'NR>1{print $4}' | head -1 || echo "?")
      fi
      echo "[disk-watchdog] Root: ''${USAGE}% | swap=''${SWAP_SIZE_MB}MB | docker=$DOCKER_SIZE"

      # ── WARN (85%) — gentle cleanup ──────────────────────────────────
      echo "[disk-watchdog] WARNING (''${USAGE}%) — cleaning"
      _before=$(df -P / | awk 'NR==2{print $4}')
      find /tmp -type f -atime +2 -delete 2>/dev/null || true
      _after=$(df -P / | awk 'NR==2{print $4}')
      record "rm" "find /tmp -type f -atime +2" "$(( (_after - _before) * 1024 ))B"
      _before=$(df -P / | awk 'NR==2{print $4}')
      find /var/tmp -type f -atime +2 -delete 2>/dev/null || true
      _after=$(df -P / | awk 'NR==2{print $4}')
      record "rm" "find /var/tmp -type f -atime +2" "$(( (_after - _before) * 1024 ))B"
      # #413: --vacuum-time ONLY, at the declared retention floor. --vacuum-size
      # deletes the oldest archives until the cap is met, whatever their age — on
      # 2026-09-16 that erased 16 days of oci-apps journal, including the record
      # of this watchdog's own 12.13GB deletion. Only entries older than the floor
      # (config.json native.protection.journal_retention_floor_days) may go.
      _vac=$(journalctl --vacuum-time=${toString journalFloorDays}d 2>/dev/null || true)
      record "journal" "vacuum-time=${toString journalFloorDays}d" "$(reclaimed "$_vac")"
      if command -v docker >/dev/null 2>&1; then
        # label!=com.docker.compose.project — NEVER prune a declared service.
        # Copied from infra/prune-maintenance.nix, which already learned this: an
        # unfiltered `container prune` deletes every stopped container, and that is
        # how vaultwarden vanished for four days (rebooted 2026-08-30 22:11, pruned
        # 03:30). That sibling got the filter; this module never did, and on
        # 2026-09-16 it deleted matomo off oci-apps exactly the same way — created,
        # started and healthy at 2026-09-15T22:39:58Z, no container and no image
        # nine hours later. Every declared service is deployed through docker
        # compose and therefore carries this label; what is left to collect is
        # stray `docker run` debris, which is all this should ever have reclaimed.
        # NOT `--filter until=<age>`: that matches on CREATION time, so it would
        # protect only containers created in the last N hours — precisely backwards.
        _cont=$(docker container prune -f --filter "label!=com.docker.compose.project" 2>/dev/null || true)
        record "docker" "container-prune label!=com.docker.compose.project" "$(reclaimed "$_cont")"
        # until=72h scopes this to dangling images older than 72h. Unscoped, it
        # untagged matomo-binaries@sha256:9d3a9615 at 05:25:16 — a live deploy
        # artifact, hours before the CRIT branch finished the job.
        # builder prune: --keep-storage was renamed, and its first replacement
        # name --max-storage is itself rejected ("unknown flag") by the docker
        # on the fleet (27.5.1, verified 2026-09-17). --max-used-space is the
        # current flag and means the same thing: keep at most 1G of build cache.
        _img=$(docker image prune -f --filter "until=72h" 2>/dev/null || true)
        record "docker" "image-prune until=72h" "$(reclaimed "$_img")"
        _bld=$(docker builder prune -f --max-used-space=1G 2>/dev/null || true)
        record "docker" "builder-prune max-used-space=1G" "$(reclaimed "$_bld")"
        # NO `docker system prune`: it is a superset of the three scoped calls
        # above, and its container sweep cannot be scoped as tightly, so it
        # silently re-opens the exact hole the label filter closes.
        # prune-maintenance.nix does not run it either — same reason.
      fi

      USAGE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
      if [ "$USAGE" -lt "$CRIT" ]; then
        record "run" "finish usage=''${USAGE}%"
        echo "[disk-watchdog] Resolved ''${USAGE}%"
        exit 0
      fi

      # ── CRIT (90%) — aggressive prune (swap untouched) ──────────────
      # BANNED on the automatic path, deliberately. Both were here until
      # 2026-09-16 and both are listed as forbidden by infra/prune-maintenance.nix
      # ("WHAT IT DOES NOT RUN") and by protection/guardrails.nix, which blocks
      # them for humans — but guardrails.nix implements that ban as a PATH wrapper
      # in ~/.local/bin, and this script runs as a root systemd unit calling docker
      # directly, so it never traversed the wrapper. The ban was real; the watchdog
      # was simply not on the code path it protects. Hence it is restated here:
      #   volume prune    — volumes ARE the databases. A watchdog that deletes a
      #                     database to free space is not protection, it is the
      #                     outage. On 2026-09-16 the ONLY reason matomo's data is
      #                     recoverable is that this branch ran before its volumes
      #                     went unreferenced.
      #   image prune -af — `-a` drops TAGGED images, i.e. the fleet's own deploy
      #                     artifacts. It untagged matomo-binaries:latest and
      #                     matomo-configs:latest at 06:30:21.
      #
      # WHAT CRIT MAY STILL DELETE, and why each set is safe to lose:
      #   builder cache (-af)   pure derived data, rebuildable from source. On a VM
      #                         doing native arm64 builds this is the genuinely
      #                         large reclaimable set, and nothing depends on it.
      #   dangling images       untagged AND unreferenced by any container. The
      #     (until=24h)         only cost of being wrong is a re-pull.
      # NOT the journal: WARN already vacuumed down to the retention floor, and
      # below the floor is exactly what #413 forbids — there is nothing more
      # CRIT may take from it.
      #   nix gens >3d          rollback history, not live system state.
      # That is a real escalation over WARN (which stops at 72h-dangling and a 1G
      # build cache) without putting a single byte of persistent state at risk.
      echo "[disk-watchdog] CRIT (''${USAGE}%) — aggressive cleanup"
      if command -v docker >/dev/null 2>&1; then
        _bld=$(docker builder prune -af 2>/dev/null || true)
        record "docker" "builder-prune -af" "$(reclaimed "$_bld")"
        _img=$(docker image prune -f --filter "until=24h" 2>/dev/null || true)
        record "docker" "image-prune until=24h" "$(reclaimed "$_img")"
      fi
      if command -v nix-collect-garbage >/dev/null 2>&1; then
        _gc=$(nix-collect-garbage --delete-older-than 3d 2>/dev/null || true)
        record "nix" "collect-garbage --delete-older-than 3d" "$(reclaimed "$_gc")"
      fi

      USAGE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
      if [ "$USAGE" -lt "$EMERG" ]; then
        record "run" "finish usage=''${USAGE}%"
        echo "[disk-watchdog] Resolved ''${USAGE}%"
        exit 0
      fi

      # ── EMERG (95%) — remove swapfile entirely + last resort ─────────
      echo "[disk-watchdog] EMERGENCY (''${USAGE}%) — last resort"

      # Remove swapfile entirely to free maximum disk space
      SWAPFILE="/swapfile"
      if [ -f "$SWAPFILE" ]; then
        FREED_MB=$(($(stat -c%s "$SWAPFILE" 2>/dev/null || echo 0) / 1024 / 1024))
        echo "[disk-watchdog] Removing swapfile to free ''${FREED_MB}MB"
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
        record "rm" "swapfile $SWAPFILE" "''${FREED_MB}MB"
      fi

      # The action log is exempt from this sweep — it is the evidence record.
      # Everything else >10M is truncated to 1M and each truncation is logged.
      # `'''` is the Nix escape for a literal two-single-quote pair: a bare pair
      # ENDS this indented string, which is how this module stopped evaluating
      # on 2026-09-17 (#413 — caught the first time the nix tester really ran).
      find /var/log -name "*.log" ! -name "disk-watchdog.log" -size +10M -print0 2>/dev/null \
        | while IFS= read -r -d ''' _f; do
            _sz=$(stat -c%s "$_f" 2>/dev/null || echo 0)
            truncate -s 1M "$_f" 2>/dev/null || true
            record "truncate" "$_f -> 1M" "$(( _sz > 1048576 ? _sz - 1048576 : 0 ))B"
          done
      _before=$(df -P / | awk 'NR==2{print $4}')
      find /var/log -name "*.gz" -delete 2>/dev/null || true
      _after=$(df -P / | awk 'NR==2{print $4}')
      record "rm" "find /var/log -name '*.gz'" "$(( (_after - _before) * 1024 ))B"
      if command -v nix-collect-garbage >/dev/null 2>&1; then
        _gc=$(nix-collect-garbage -d 2>/dev/null || true)
        record "nix" "collect-garbage -d" "$(reclaimed "$_gc")"
      fi

      USAGE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
      record "run" "finish usage=''${USAGE}%"
      echo "[disk-watchdog] Final: ''${USAGE}%"
    '';
  };

  home.file.".local/share/system-protection/disk-watchdog.service".text = ''
    [Unit]
    Description=Disk usage watchdog
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/disk-watchdog.sh
  '';

  home.file.".local/share/system-protection/disk-watchdog.timer".text = ''
    [Unit]
    Description=Run disk watchdog every 5 minutes
    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min
    [Install]
    WantedBy=timers.target
  '';

  # ── Kernel Watchdog Petter ────────────────────────────────────────────
  home.file.".local/share/system-protection/watchdog-petter.sh" = {
    executable = true;
    source = ./watchdog-petter.sh;
  };

  home.file.".local/share/system-protection/watchdog-petter.service".text = ''
    [Unit]
    Description=Kernel Watchdog Petter — feeds /dev/watchdog, auto-heals containers, rich telemetry
    After=multi-user.target
    [Service]
    Type=simple
    ExecStart=/opt/scripts/watchdog-petter.sh
    # P4: thresholds data-driven from consolidated protection block (never hardcoded
    # in the script). watchdog-petter.sh reads each as env-with-default.
    Environment=DISK_WARN=${toString diskWarn}
    Environment=DISK_HIGH=${toString diskHigh}
    Environment=DISK_EMERG=${toString diskEmerg}
    Environment=DOCKER_FAIL_THRESHOLD=${toString dockerFail}
    Environment=LOW_MEM_PRUNE_MB=${toString lowMemPrune}
    Environment=JOURNAL_FLOOR_DAYS=${toString journalFloorDays}
    Environment=NTFY=${ntfyBase}/${ntfyTopic}
    OOMScoreAdjust=-999
    MemoryMax=32M
    MemoryMin=10M
    CPUQuota=10%
    Nice=-20
    Restart=always
    RestartSec=2
    User=root
    [Install]
    WantedBy=multi-user.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installWatchdog = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[watchdog] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[watchdog] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/disk-swap.sh" /opt/scripts/disk-swap.sh
    $SUDO cp -f "$SRC/disk-swap-maintenance.sh" /opt/scripts/disk-swap-maintenance.sh
    $SUDO cp -f "$SRC/disk-watchdog.sh" /opt/scripts/disk-watchdog.sh
    $SUDO cp -f "$SRC/watchdog-petter.sh" /opt/scripts/watchdog-petter.sh
    $SUDO chmod +x /opt/scripts/disk-swap.sh /opt/scripts/disk-swap-maintenance.sh /opt/scripts/disk-watchdog.sh /opt/scripts/watchdog-petter.sh
    $SUDO cp -f "$SRC/disk-swap.service" /etc/systemd/system/disk-swap.service
    $SUDO cp -f "$SRC/disk-swap-maintenance.service" /etc/systemd/system/disk-swap-maintenance.service
    $SUDO cp -f "$SRC/disk-swap-maintenance.timer" /etc/systemd/system/disk-swap-maintenance.timer
    $SUDO cp -f "$SRC/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
    $SUDO cp -f "$SRC/disk-watchdog.timer" /etc/systemd/system/disk-watchdog.timer
    # watchdog-petter disabled — too aggressive, causes reboot loops
    $SUDO systemctl stop watchdog-petter.service 2>/dev/null || true
    $SUDO systemctl disable watchdog-petter.service 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/watchdog-petter.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable disk-swap.service disk-swap-maintenance.timer disk-watchdog.timer 2>/dev/null || true
    # --no-block: dd writes 2GB on first run → saturates I/O → SSH keepalive stalls → exit 255
    $SUDO systemctl start disk-swap.service --no-block 2>/dev/null || true
    $SUDO systemctl start disk-swap-maintenance.timer 2>/dev/null || true
    $SUDO systemctl start disk-watchdog.timer 2>/dev/null || true

    echo "[watchdog] deployed: disk-swap=${toString diskSwapMB}MB(+24h-maint) watchdog-petter=disabled"
    ) || echo "[watchdog] FAILED — activation continues"
  '';
}
