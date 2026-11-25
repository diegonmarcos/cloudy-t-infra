# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/protection/layer2-identity.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# System Protection — Layer 2: Identity & System Slice Hierarchy
#
# LOCAL (system.slice) — daemons started by systemd:
#   ├── kernel.slice        → NO CAP   — bare minimum for Linux to function
#   ├── os-essentials.slice → 95% cap  — protection + connectivity daemons
#   └── workload.slice      → 75% cap  — everything else (catch-all)
#
# REMOTE (user.slice) — login sessions via OpenSSH:
#   ├── user-0.slice        → 90% cap  — root SSH (emergency maintenance)
#   └── user-1000.slice     → 75% cap  — diego SSH (normal operations)
#
# Dropbear (rescue-ssh) sessions stay in os-essentials.slice (95%)
# because dropbear doesn't use PAM/logind — rescue access by design.
#
# CPU guarantees (1 vCPU):
#   kernel:        ≥5%  (uncapped, gets what's left)
#   os-essentials: ≥20% (95% - 75%)
#   workload:      ≤75% (hard cap, shared)
#   user-0:        ≤90% (root emergency)
#   user-1000:     ≤75% (normal ops)
#
# Classification: enumerate active services, match against lists.
# Anything not in kernel or os-essentials → workload (catch-all, capped).
# Re-runs on every HM activation.
#
# Imported by: system-protection.nix (orchestrator)
#
# ┌─────────────────────────┬────────────────┬──────────┬──────────────┐
# │ Slice                   │ CPU (×cores)   │ MemHigh  │ MemMax       │
# ├─────────────────────────┼────────────────┼──────────┼──────────────┤
# │ kernel.slice            │ uncapped       │ —        │ —            │
# │ os-essentials.slice     │ 95% of total   │ —        │ —            │
# │ workload.slice          │ 75% of total   │ —        │ —            │
# ├─────────────────────────┼────────────────┼──────────┼──────────────┤
# │ user-{uid} (diego)      │ 75% of total   │ 75% RAM │ 85% RAM      │
# │ user-0 (root)           │ 90% of total   │ 85% RAM │ 95% RAM      │
# ├─────────────────────────┼────────────────┼──────────┼──────────────┤
# │ sshd                    │ FIFO p1        │ —        │ os-essentials│
# │ wg-quick@*              │ FIFO p1        │ —        │ os-essentials│
# │ rescue-ssh (dropbear)   │ FIFO p1        │ —        │ os-essentials│
# │ earlyoom                │ RR p1          │ —        │ os-essentials│
# │ watchdog-petter         │ RR p1          │ —        │ os-essentials│
# │ docker, container-init  │ CFS            │ —        │ workload     │
# │ (catch-all)             │ CFS            │ —        │ workload     │
# └─────────────────────────┴────────────────┴──────────┴──────────────┘
#
{ config, pkgs, lib, ramMB, cpus ? 1, userName ? "diego", userId ? 1000, ... }:

let
  # ── Clamp helper: compute from %, then enforce absolute min/max ─────────
  # Formulas calculate proportional values, clamp enforces sane bounds.
  # This prevents crazy values from bad cloud-data (0 cpu, 0 ram).
  clamp = min: max: v: if v < min then min else if v > max then max else v;

  # ── Slice budgets (scaled by core count) ───────────────────────────────
  # CPUQuota is relative to ONE core (100% = 1 core, 400% = 4 cores)
  #   75% of total = cpus * 75          min=50%     max=800%
  #   95% of total = cpus * 95          min=75%     max=800%
  workloadCpuQuota     = clamp 50  800 (cpus * 75);
  osEssentialsCpuQuota = clamp 75  800 (cpus * 95);
  # kernel.slice = no cap (implicit)

  # ── User slice limits ─────────────────────────────────────────────────
  # user-1000 (diego): normal operations
  #   CPU:  75% of total                min=50%     max=800%
  #   MemHigh: 75% of RAM              min=256MB   max=36864MB (192GB)
  #   MemMax:  85% of RAM              min=384MB   max=36864MB
  userCpuQuota  = clamp 50   800    (cpus * 75);
  userMemHighMB = clamp 256  36864 (ramMB * 75 / 100);
  userMemMaxMB  = clamp 384  36864 (ramMB * 85 / 100);

  userSliceConf = ''
    [Slice]
    Description=User ${userName} (UID ${toString userId}) resource limits
    CPUQuota=${toString userCpuQuota}%
    MemoryHigh=${toString userMemHighMB}M
    MemoryMax=${toString userMemMaxMB}M
    IOWeight=100
  '';

  # user-0 (root): emergency maintenance, generous but bounded
  #   CPU:  90% of total                min=75%     max=800%
  #   MemHigh: 85% of RAM              min=384MB   max=36864MB
  #   MemMax:  95% of RAM              min=448MB   max=36864MB
  rootCpuQuota  = clamp 75   800    (cpus * 90);
  rootMemHighMB = clamp 384  36864 (ramMB * 85 / 100);
  rootMemMaxMB  = clamp 448  36864 (ramMB * 95 / 100);

  rootSliceConf = ''
    [Slice]
    Description=Root (UID 0) resource limits — emergency SSH maintenance
    CPUQuota=${toString rootCpuQuota}%
    MemoryHigh=${toString rootMemHighMB}M
    MemoryMax=${toString rootMemMaxMB}M
    IOWeight=200
  '';

  # ── Slice definitions ─────────────────────────────────────────────────
  kernelSliceConf = ''
    [Slice]
    Description=Kernel-essential services — no cap, Linux cannot function without these
  '';

  osEssentialsSliceConf = ''
    [Slice]
    Description=OS-essential services — protection, connectivity, monitoring
    CPUQuota=${toString osEssentialsCpuQuota}%
  '';

  workloadSliceConf = ''
    [Slice]
    Description=Workload services — docker, containers, application services
    CPUQuota=${toString workloadCpuQuota}%
  '';

  # ── Service classification ────────────────────────────────────────────
  # kernel.slice: bare minimum for Linux to boot and stay alive
  # Patterns: exact name or prefix (ending in - or @)
  kernelServices = [
    # systemd core
    "systemd-"              # prefix: journald, udevd, logind, resolved, networkd, timesyncd, etc.
    "dbus"
    "dbus-broker"
    "init.scope"
    # filesystem
    "mount"
    "swap"
    "fsck"
    "lvm2"
    "dm-event"
    "blk-availability"
    # login/session
    "getty@"                 # prefix: TTY logins
    "serial-getty@"          # prefix: serial consoles
    "user@"                  # prefix: user manager instances
    "user-runtime-dir@"      # prefix: user runtime dirs
    # network fundamentals
    "NetworkManager"
    "dhclient"
    "chrony"
    "ntp"
  ];

  # os-essentials.slice: our protection + connectivity daemons
  # These are services WE installed that must stay responsive
  osEssentialsServices = [
    # CONNECTIVITY (FIFO-protected — SSH, VPN, rescue)
    "sshd"
    "ssh"
    "wg-quick@"             # prefix: all WG interfaces
    "rescue-ssh"
    # PROTECTION (RR-protected — must never be throttled when system is stressed)
    "earlyoom"
    "watchdog-petter"
    # SWAP/MEMORY (our setup, critical for system stability)
    "zram-setup"
    # DASHBOARD (web terminal for monitoring — must stay responsive under load)
    "dashboard-ttyd"
  ];

  # Everything else → workload.slice (capped at 75%)

  # Generate classification files (one pattern per line)
  kernelListText = lib.concatStringsSep "\n" kernelServices;
  osEssentialsListText = lib.concatStringsSep "\n" osEssentialsServices;

in {
  home.file = {
    # Slice definitions
    ".local/share/system-protection/kernel.slice".text = kernelSliceConf;
    ".local/share/system-protection/os-essentials.slice".text = osEssentialsSliceConf;
    ".local/share/system-protection/workload.slice".text = workloadSliceConf;
    # User slices
    ".local/share/system-protection/user-${toString userId}-slice-limits.conf".text = userSliceConf;
    ".local/share/system-protection/user-0-slice-limits.conf".text = rootSliceConf;
    # Classification lists
    ".local/share/system-protection/kernel-services.list".text = kernelListText;
    ".local/share/system-protection/os-essentials-services.list".text = osEssentialsListText;
  };

  home.activation.installLayer2Identity = lib.hm.dag.entryAfter ["installScheduler"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # ── Remove imperative cpu-watchdog (replaced by cgroup slices) ──────
    if $SUDO systemctl is-active cpu-watchdog.service >/dev/null 2>&1; then
      $SUDO systemctl stop cpu-watchdog.service 2>/dev/null || true
      echo "[layer2-identity] stopped imperative cpu-watchdog"
    fi
    if [ -f /etc/systemd/system/cpu-watchdog.service ]; then
      $SUDO systemctl disable cpu-watchdog.service 2>/dev/null || true
      $SUDO rm -f /etc/systemd/system/cpu-watchdog.service
      $SUDO rm -f /usr/local/bin/cpu-watchdog.sh
      $SUDO systemctl daemon-reload
      echo "[layer2-identity] removed imperative cpu-watchdog (replaced by cgroup slices)"
    fi

    # ── Deploy slice definitions ─────────────────────────────────────────
    $SUDO cp -f "$SRC/kernel.slice" /etc/systemd/system/kernel.slice
    $SUDO cp -f "$SRC/os-essentials.slice" /etc/systemd/system/os-essentials.slice
    $SUDO cp -f "$SRC/workload.slice" /etc/systemd/system/workload.slice

    # ── Deploy user slice caps ───────────────────────────────────────────
    # user-1000 (diego) — normal operations
    $SUDO mkdir -p "/etc/systemd/system/user-${toString userId}.slice.d"
    $SUDO cp -f "$SRC/user-${toString userId}-slice-limits.conf" \
      "/etc/systemd/system/user-${toString userId}.slice.d/limits.conf"

    # user-0 (root) — emergency maintenance
    $SUDO mkdir -p "/etc/systemd/system/user-0.slice.d"
    $SUDO cp -f "$SRC/user-0-slice-limits.conf" \
      "/etc/systemd/system/user-0.slice.d/limits.conf"

    # ── Classify services into slices ────────────────────────────────────
    # Helper: check if service matches any pattern in a list file
    matches_list() {
      _svc="$1"; _list="$2"
      while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        case "$pattern" in
          *@|*-)
            case "$_svc" in "$pattern"*) return 0 ;; esac
            ;;
          *)
            [ "$_svc" = "$pattern" ] && return 0
            ;;
        esac
      done < "$_list"
      return 1
    }

    KERNEL_COUNT=0
    ESSENTIAL_COUNT=0
    WORKLOAD_COUNT=0
    SELFSLICE_COUNT=0

    # awk MUST be an absolute store path: HM activation runs with a stripped PATH
    # that excludes /usr/bin (gawk is not in HM's default activation PATH set,
    # only coreutils/gnused/gnugrep are). Bare `awk` here would die with
    # "awk: command not found" and abort the entire installLayer2Identity step.
    for svc in $($SUDO systemctl list-units --type=service --state=active,running \
                  --no-legend --no-pager --plain 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}'); do

      svc_base="''${svc%.service}"

      # ── A unit that declares its OWN Slice= is authoritative ───────────
      # This loop used to classify EVERY active service, so a unit that had
      # deliberately placed itself in connectivity.slice got silently demoted
      # to workload.slice by our own drop-in. That put the LOAD SHEDDER — the
      # daemon whose unit comments read "never starved, OOM-immune" — inside
      # the very capped slice it exists to police, and did the same to
      # rescue-ssh, the emergency way back in. It also overrode systemd's
      # native Slice=user-%i.slice on user@/user-runtime-dir@.
      # Only 4 of 66 active units on oci-analytics declare a Slice, so this
      # exemption is narrow: honour it, and delete any stale drop-in we wrote
      # on an earlier activation so the fix is self-healing.
      _frag=$($SUDO systemctl show -p FragmentPath --value "$svc" 2>/dev/null)
      if [ -n "$_frag" ] && [ -f "$_frag" ] && \
         ${pkgs.gnugrep}/bin/grep -qE '^[[:space:]]*Slice=' "$_frag"; then
        $SUDO rm -f "/etc/systemd/system/''${svc}.d/slice-assignment.conf"
        $SUDO rmdir "/etc/systemd/system/''${svc}.d" 2>/dev/null || true
        SELFSLICE_COUNT=$((SELFSLICE_COUNT + 1))
        continue
      fi

      # Determine target slice
      if matches_list "$svc_base" "$SRC/kernel-services.list"; then
        TARGET_SLICE="kernel.slice"
        KERNEL_COUNT=$((KERNEL_COUNT + 1))
      elif matches_list "$svc_base" "$SRC/os-essentials-services.list"; then
        TARGET_SLICE="os-essentials.slice"
        ESSENTIAL_COUNT=$((ESSENTIAL_COUNT + 1))
      else
        TARGET_SLICE="workload.slice"
        WORKLOAD_COUNT=$((WORKLOAD_COUNT + 1))
      fi

      # Deploy slice assignment drop-in
      $SUDO mkdir -p "/etc/systemd/system/''${svc}.d"
      printf '[Service]\nSlice=%s\n' "$TARGET_SLICE" | \
        $SUDO tee "/etc/systemd/system/''${svc}.d/slice-assignment.conf" > /dev/null
    done

    $SUDO systemctl daemon-reload

    echo "[layer2-identity] user-${toString userId}.slice CPU=${toString userCpuQuota}% MemHigh=${toString userMemHighMB}M MemMax=${toString userMemMaxMB}M"
    echo "[layer2-identity] user-0.slice CPU=${toString rootCpuQuota}% MemHigh=${toString rootMemHighMB}M MemMax=${toString rootMemMaxMB}M"
    echo "[layer2-identity] system slices: kernel=$KERNEL_COUNT (no cap) | os-essentials=$ESSENTIAL_COUNT (${toString osEssentialsCpuQuota}%) | workload=$WORKLOAD_COUNT (${toString workloadCpuQuota}%) | self-declared=$SELFSLICE_COUNT (left alone)"
    ) || echo "[layer2-identity] FAILED — activation continues"
  '';
}
