# System Protection — Resource Bouncer
# Memory: zram, earlyoom, sysctl, cgroup caps, Docker MemoryMax
# SSH/WG OOM immunity, ext4 reserved blocks
#
# Desktop equivalent: unix/aa_nixos-surface_host/src/modules/configuration_system-protection.nix
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, ... }:

let
  # Clamp helper: compute then enforce absolute min/max
  clamp = min: max: v: if v < min then min else if v > max then max else v;

  # Sane RAM range: 1GB–36GB (cloud-data may return 0 if terraform parsing fails)
  safeRamMB = clamp 1024 36864 (if ramMB > 0 then ramMB else 1024);

  # Above 100 says "swap is cheaper than the filesystem, prefer it". That is
  # only true while zram still has room to compress into; once zram is full the
  # marginal anon page goes to the DISK swapfile, and preferring it over
  # dropping a clean file page is strictly backwards. Measured 2026-08-28:
  # oci-analytics sat with its 512MB zram 94% full, 105MB already spilled to
  # the disk swapfile, and 309MB of file cache held with Dirty=0 - i.e. free to
  # drop. A 1GB box lives in that state permanently, so it gets the balanced
  # kernel default; bigger boxes keep real zram headroom and get the neutral
  # in-memory-swap value. Neither is above 100.
  swappiness = if safeRamMB <= 2048 then 60 else 100;

  # vfs_cache_pressure was a flat 200 ("drop dentry/inode slab twice as
  # readily") on the theory that a clean file page is free to drop. That
  # theory holds only when re-reading it is cheap. On these free-tier VMs the
  # boot disk is slow NETWORK storage (GCP PD-standard is HDD-backed: measured
  # r_await 262ms/op on gcp-proxy 2026-09-02, %util 96% at just 81 reads/s), so
  # a dropped CODE page refaults at a quarter-second and io-PSI pins at 92%
  # "full" — the whole box stalls on the disk. On a small box that behaviour is
  # a death spiral (caddy took 1412 major-faults/s re-reading its own binary).
  # So small boxes now RETAIN cache (50); big boxes with faster/ample setups
  # keep the aggressive reclaim. This is the surgical knob for file-refault
  # thrash and does not touch the swappiness/zram tiering above.
  vfsCachePressure = if safeRamMB <= 2048 then 50 else 200;

  minFreeKB = if safeRamMB <= 1024 then 65536
              else if safeRamMB <= 8192 then 131072
              else 262144;

  # zram: 50% of RAM, min 256MB, max 16GB
  zramSizeMB = clamp 256 16384 (safeRamMB / 2);
  zramSizeBytes = toString (zramSizeMB * 1024 * 1024);

  # Docker memory cap: RAM minus OS overhead, min 256MB, max 32GB
  dockerMaxMB = clamp 256 32768 (
    if safeRamMB <= 1024 then safeRamMB - 350
    else if safeRamMB <= 8192 then safeRamMB - 512
    else safeRamMB - 1024
  );

in {
  # earlyoom package dropped 2026-07-03 with the disabled unit below (ONLY-PSI directive)
  home.packages = [ pkgs.e2fsprogs ];

  # ── Sysctl ────────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/sysctl.conf".text = ''
    # Managed by home-manager (system-protection-resource-bouncer.nix)
    vm.min_free_kbytes = ${toString minFreeKB}
    vm.swappiness = ${toString swappiness}
    # Reclaim before swapping, in that order, and note this used to declare 150
    # on the argument that zram compresses 4.5:1 so anon->zram is cheaper than
    # re-reading a dropped file page. The counters say otherwise once zram is
    # full, which is the steady state on the small boxes, so the value is now
    # tiered and never exceeds 100 (see the `swappiness` let above).
    #
    # The other two knobs are unambiguous. vfs_cache_pressure=200 makes the
    # kernel give up dentry/inode slab twice as readily as default instead of
    # holding it while anon pages go out. page-cluster=0 stops swap readahead
    # pulling 8 pages per fault, which is pure waste when each page is
    # decompressed individually anyway - and those 7 extra pages are part of
    # what fills zram in the first place. Disk swap stays last by priority
    # (zram 100, file 10).
    vm.vfs_cache_pressure = ${toString vfsCachePressure}
    vm.page-cluster = 0
    vm.dirty_ratio = 10
    vm.dirty_background_ratio = 5
    vm.watermark_scale_factor = 500
    net.ipv4.ip_forward = 1
    # ── File-descriptor / inotify / PID exhaustion headroom ──────────────
    # 2026-06-19 incident: a fluent-bit fd leak drained the SYSTEM fd table on
    # gcp-proxy → every daemon (incl. FIFO-priority sshd / wg-quick / dropbear)
    # got EMFILE (errno 24) on accept()/open() → the whole WG hub went
    # unreachable while CPU+memory protection still looked healthy. cgroup
    # CPU/mem slices CANNOT cap file descriptors, inotify watches, or PIDs —
    # those live in global kernel tables. Give those tables massive headroom so
    # a single leaking process can never exhaust them (defence-in-depth with the
    # per-service LimitNOFILE caps on fluent-bit + docker). 8 GB RAM ceiling is
    # irrelevant: each struct file is ~1 KB, 2M fds ≈ worst case the offender
    # never reaches because it is LimitNOFILE-capped first.
    fs.file-max = 2097152
    fs.nr_open = 2097152
    fs.inotify.max_user_watches = 524288
    fs.inotify.max_user_instances = 1024
    kernel.pid_max = 262144
  '';

  # ── Journald → volatile (RAM) ─────────────────────────────────────────
  # journald's persistent store lives on the same slow network disk. Worse,
  # the my-watchdog dashboard runs `journalctl` continuously to render itself,
  # so the panel's own reads re-fetch+decompress archived journals off the HDD
  # (measured ~2MB/s READ from journald on gcp-proxy 2026-09-02) — pure disk
  # churn that competes with everything else at 262ms/op. Storage=volatile
  # keeps the journal in /run (tmpfs/RAM): writes and the panel's reads never
  # touch the disk. RuntimeMaxUse bounds the RAM it may take on these small
  # boxes; Compress=no because compressing an in-RAM ring only burns CPU. The
  # trade is logs do not survive reboot — acceptable on a box whose failure
  # mode is disk-IO starvation, and recent logs stay in RAM for the panel.
  home.file.".local/share/system-protection/journald-volatile.conf".text = ''
    [Journal]
    Storage=volatile
    RuntimeMaxUse=${if safeRamMB <= 2048 then "40M" else "128M"}
    # Hard disk cap, independent of Storage=: if a VM is ever flipped back to
    # persistent (or a stray /var/log/journal reappears) it can never take more
    # than 500M of the root disk.
    SystemMaxUse=500M
    Compress=no
    ForwardToSyslog=no
  '';

  # ── Zram ──────────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/zram-setup.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -euo pipefail
      # BusyBox from the nix profile shadows util-linux/kmod/coreutils on some
      # VMs (its modprobe cannot load .ko.zst, its dd rejects status=progress),
      # which left oci-apps with no swap at all (#1641). Pin the GNU tools.
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
      modprobe zram num_devices=1 2>/dev/null || true
      if swapon --show=NAME,TYPE 2>/dev/null | grep -q zram; then
        echo "[zram] Already active, skipping"; exit 0
      fi
      if [ -e /sys/block/zram0/reset ]; then
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
      fi
      echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || \
        echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
      echo ${zramSizeBytes} > /sys/block/zram0/disksize
      mkswap /dev/zram0
      swapon -p 100 /dev/zram0
      echo "[zram] Activated ${toString zramSizeMB}MB compressed swap"
    '';
  };

  home.file.".local/share/system-protection/zram-setup.service".text = ''
    [Unit]
    Description=Setup zram compressed swap (${toString zramSizeMB}MB)
    After=local-fs.target
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/zram-setup.sh
    [Install]
    WantedBy=multi-user.target
  '';

  # ── Earlyoom ──────────────────────────────────────────────────────────
  # DISABLED 2026-07-03 (user directive: 'remove ALL non-PSI triggers, ONLY
  # PSI'). earlyoom has no PSI awareness at all — it is purely absolute
  # free-mem%/free-swap% (-m 10 -s 10), the same class of bug that made the
  # desktop's earlyoom false-kill plasmashell at PSI≈0. load-shedder.nix
  # (armed, MEMORY-PSI-ONLY, memPsiCrit=50%) is this fleet's real memory-
  # thrash protection — genuinely PSI-gated per its own header contract.
  # Unit definition kept (commented ExecStart removed from activation below)
  # so it can be restored if a non-PSI last-resort backstop is ever wanted.

  # SSH + WG + Docker scheduler configs moved to system-protection-scheduler-fifo-rr-cfs.nix

  # ── Docker memory cap ─────────────────────────────────────────────────
  home.file.".local/share/system-protection/docker-memory-cap.conf".text = ''
    [Service]
    MemoryMax=${toString dockerMaxMB}M
    MemoryHigh=${toString (dockerMaxMB * 9 / 10)}M
    OOMScoreAdjust=500
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installResourceBouncer = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[resource-bouncer] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[resource-bouncer] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Sysctl
    $SUDO mkdir -p /etc/sysctl.d
    $SUDO cp -f "$SRC/sysctl.conf" /etc/sysctl.d/99-system-protection.conf
    $SUDO chmod 644 /etc/sysctl.d/99-system-protection.conf

    # `sysctl --system` reads /etc/sysctl.conf LAST — after every
    # /etc/sysctl.d/*.conf, whatever they are named — so one stray key there
    # beats this module and nothing says so. oci-analytics ran vm.swappiness=10
    # that way for ten weeks (hand-added from a runbook line since corrected),
    # which is exactly why it sat on 326MB of page cache and pushed 71MB out to
    # the DISK swapfile while its zram was 95% full. Comment the keys we manage
    # out of there so the declared value is the one that lands.
    if [ -f /etc/sysctl.conf ]; then
      sed -n "s/^ *\([a-z0-9._-]*\) *=.*/\1/p" "$SRC/sysctl.conf" | while read -r k; do
        $SUDO sed -i "s|^ *$k *=|# superseded by 99-system-protection.conf: &|" /etc/sysctl.conf
      done
    fi

    $SUDO sysctl --system > /dev/null 2>&1 || true

    # Journald → volatile (RAM). Only restart journald if the drop-in actually
    # changed, so re-activation is not a per-generation journal bounce.
    $SUDO mkdir -p /etc/systemd/journald.conf.d
    if ! $SUDO cmp -s "$SRC/journald-volatile.conf" /etc/systemd/journald.conf.d/99-volatile.conf 2>/dev/null; then
      $SUDO cp -f "$SRC/journald-volatile.conf" /etc/systemd/journald.conf.d/99-volatile.conf
      $SUDO chmod 644 /etc/systemd/journald.conf.d/99-volatile.conf
      $SUDO systemctl restart systemd-journald 2>/dev/null || true
      # Reclaim the on-disk journal once it is RAM-backed (idempotent).
      $SUDO rm -rf /var/log/journal 2>/dev/null || true
    fi

    # Read back rather than assume. A single bad key aborts the whole file, and
    # a swappiness that never took is invisible until the box is already
    # swapping to disk — which is the failure this whole module exists to stop.
    sed -n "s/^ *\([a-z0-9._-]*\) *= *\([^ ].*\)/\1 \2/p" "$SRC/sysctl.conf" | while read -r k v; do
      live=$(cat "/proc/sys/$(echo "$k" | tr . /)" 2>/dev/null || echo "?")
      [ "$live" = "$v" ] || echo "[resource-bouncer] WARN $k is $live, declared $v"
    done

    # Ext4 reserved blocks: REMOVED 2026-05-06 — disk-ballast.nix is the
    # single source of truth for disk reservation now (universal across
    # ext4 + btrfs, declarative size, root-deletable on demand by the
    # engine pre-flight). resource-bouncer setting -m 5 here was undoing
    # disk-ballast's `-m 0` and double-reserving disk we already own
    # via the userland ballast file.

    # SSH/WG/Docker scheduler drop-ins handled by system-protection-scheduler-fifo-rr-cfs.nix

    # Docker memory cap (separate from scheduler)
    if $SUDO systemctl cat "docker.service" >/dev/null 2>&1; then
      $SUDO mkdir -p "/etc/systemd/system/docker.service.d"
      $SUDO cp -f "$SRC/docker-memory-cap.conf" "/etc/systemd/system/docker.service.d/memory-cap.conf"
    fi

    # Services
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/zram-setup.sh" /opt/scripts/zram-setup.sh
    $SUDO chmod +x /opt/scripts/zram-setup.sh
    $SUDO cp -f "$SRC/zram-setup.service" /etc/systemd/system/zram-setup.service

    # earlyoom: disabled + torn down 2026-07-03 (ONLY-PSI directive) — it has
    # no PSI awareness (absolute mem/swap% only); load-shedder.service is the
    # real PSI-based memory-thrash protection for this fleet.
    $SUDO systemctl stop earlyoom.service 2>/dev/null || true
    $SUDO systemctl disable earlyoom.service 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/earlyoom.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable zram-setup.service 2>/dev/null || true
    $SUDO systemctl start zram-setup.service 2>/dev/null || true

    echo "[resource-bouncer] deployed: mem=${toString (minFreeKB / 1024)}MB-reserve zram=${toString zramSizeMB}MB docker-cap=${toString dockerMaxMB}MB"
    ) || echo "[resource-bouncer] FAILED — activation continues"
  '';
}
