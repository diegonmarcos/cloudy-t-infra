# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/scheduler.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# system-protection-slices.nix — cgroup slice isolation (slices only, no FIFO/RR)
#
# Two slices, kernel-enforced:
#   connectivity.slice: SSH, WG, Dropbear — guaranteed memory + high CPU weight
#   docker.slice: Docker daemon + all containers — capped memory + CPU
#
# No FIFO/RR scheduling (caused unkillable zombies on E2 Micros).
# No docker wrappers (caused /usr/bin/docker not-found on nix/Fedora).
# Protection is purely via cgroup resource limits.
{ config, pkgs, lib, ramMB, ... }:

let
  clamp = min: max: v: if v < min then min else if v > max then max else v;
  safeRamMB = clamp 1024 36864 (if ramMB > 0 then ramMB else 1024);

  reservedMB = 150;
  availableMB = safeRamMB - reservedMB;
  containerInitMaxMB = clamp 64  8192  (availableMB / 4);
  dockerMaxMB        = clamp 128 32768 (availableMB * 3 / 4);
  connectivityReserveMB = clamp 80 512 (if safeRamMB <= 1024 then 120 else 200);

  # ── connectivity.slice — kernel-guaranteed memory for SSH/WG/Dropbear ──
  connectivitySlice = ''
    [Slice]
    MemoryMin=${toString connectivityReserveMB}M
    MemoryLow=${toString connectivityReserveMB}M
    CPUWeight=10000
    IOWeight=1000
  '';

  # ── docker.slice — caps ALL docker processes ──
  dockerSlice = ''
    [Slice]
    CPUQuota=${toString (clamp 50 800 (if safeRamMB <= 2048 then 75 else 150))}%
    MemoryMax=${toString dockerMaxMB}M
    MemoryHigh=${toString (dockerMaxMB * 9 / 10)}M
    IOWeight=50
  '';

  # ── Service drop-ins — slice assignment + basic OOM protection ──
  connectivityConf = mem: ''
    [Service]
    Slice=connectivity.slice
    OOMScoreAdjust=-900
    OOMPolicy=continue
    MemoryMin=${toString mem}M
    Nice=-10
  '';

  workloadConf = cpuQuota: nice: oomScore: memMax: ''
    [Service]
    CPUQuota=${toString cpuQuota}%
    Nice=${toString nice}
    OOMScoreAdjust=${toString oomScore}
    IOWeight=50
    MemoryMax=${toString memMax}M
    MemoryHigh=${toString (memMax * 9 / 10)}M
  '';

  assignments = {
    sshd            = { conf = connectivityConf 10; targets = [ "sshd" "ssh" ]; };
    wg              = { conf = connectivityConf 10; targets = [ "wg-quick@wg0" ]; };
    container-init  = { conf = workloadConf 70 10 200 containerInitMaxMB;  targets = [ "container-init" ]; };
    docker          = { conf = workloadConf 80 5  500 dockerMaxMB;          targets = [ "docker" ]; };
  };

  mkDropIn = name: spec:
    lib.nameValuePair
      ".local/share/system-protection/scheduler-${name}.conf"
      { text = spec.conf; };

  dropInFiles = lib.mapAttrs' mkDropIn assignments;

  deployScript = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: spec:
    lib.concatMapStringsSep "\n" (target: ''
      if $SUDO systemctl cat "${target}.service" >/dev/null 2>&1 || \
         $SUDO systemctl cat "${target}" >/dev/null 2>&1; then
        $SUDO mkdir -p "/etc/systemd/system/${target}.service.d"
        $SUDO cp -f "$SRC/scheduler-${name}.conf" "/etc/systemd/system/${target}.service.d/scheduler.conf"
        echo "[scheduler] ${target} → ${name}"
      fi
    '') spec.targets
  ) assignments);

in {
  home.file = dropInFiles // {
    ".local/share/system-protection/connectivity.slice".text = connectivitySlice;
    ".local/share/system-protection/docker.slice".text = dockerSlice;
  };

  home.activation.installScheduler = lib.hm.dag.entryAfter ["installResourceBouncer" "installWatchdogDropbear"] ''
    (
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Deploy slices
    $SUDO cp -f "$SRC/connectivity.slice" /etc/systemd/system/connectivity.slice
    $SUDO cp -f "$SRC/docker.slice" /etc/systemd/system/docker.slice

    # Remove ALL stale docker wrappers (caused /usr/bin/docker not-found on nix/Fedora)
    for _w in /usr/local/bin/docker /usr/local/bin/docker-capped /usr/local/bin/docker-compose-capped /usr/local/bin/docker-buildx-capped /usr/local/bin/docker-real; do
      [ -f "$_w" ] && $SUDO rm -f "$_w" && echo "[scheduler] removed stale wrapper: $_w"
    done

    # Stale docker-real wrapper in the nix profile: DELIBERATELY not removed
    # here. ~/.nix-profile/bin is a symlink into the read-only nix store merged
    # directory, so `rm -f` silently no-ops and printed a misleading "removed"
    # success. The real fix for a stale docker-real wrapper is a fresh
    # `home-manager switch`, which rewrites the profile. The /usr/local/bin
    # loop above is the only writable wrapper location and is the one that
    # matters.

    ${deployScript}

    # Remove ALL stale drop-ins from old FIFO/RR/protection modules
    for svc_dir in /etc/systemd/system/*.service.d; do
      [ -d "$svc_dir" ] || continue
      for stale in "$svc_dir/protection.conf" "$svc_dir/bouncer.conf" "$svc_dir/slice-assignment.conf" "$svc_dir/cpu-cap.conf" "$svc_dir/memory-cap.conf"; do
        [ -f "$stale" ] && $SUDO rm -f "$stale" && echo "[scheduler] removed stale $(basename "$stale") from $(basename "$svc_dir")"
      done
    done

    $SUDO systemctl daemon-reload

    # Defer sshd restart until 20s AFTER activation finishes. A direct
    # `systemctl restart sshd` here can race with — and tear down — the SSH
    # session that is carrying this very activation (the HM-Docker delivery
    # invokes the activation over SSH; if sshd's KillMode is not strictly
    # `process`, the foreground `docker run` that wraps the activation is
    # killed and the ship engine sees exit 255, aborting before later steps
    # like installLayer2Identity / installObsoleteSystemdUnitsCleanup ever
    # run. systemd-run --on-active queues the restart on the host's systemd
    # so it fires once the activation is well past completion.
    $SUDO ${pkgs.systemd}/bin/systemd-run \
      --on-active=20 \
      --unit=sshd-scheduler-restart.service \
      --description="Deferred sshd restart to apply scheduler.conf drop-in" \
      systemctl restart sshd 2>/dev/null \
    || $SUDO ${pkgs.systemd}/bin/systemd-run \
      --on-active=20 \
      --unit=sshd-scheduler-restart.service \
      --description="Deferred sshd restart to apply scheduler.conf drop-in" \
      systemctl restart ssh 2>/dev/null \
    || true

    echo "[scheduler] deployed: connectivity.slice=${toString connectivityReserveMB}MB | docker.slice=${toString dockerMaxMB}MB | slices-only (no FIFO/RR) | sshd-restart deferred 20s"
    ) || echo "[scheduler] FAILED — activation continues"
  '';
}
