# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/pilot/container/init.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Container Control Init — owns Docker lifecycle + data-driven sequential startup
#
# Docker is DISABLED from systemd auto-start (system-protection-systemd-control).
# This service is the ONLY way Docker and containers start.
#
# Data-driven: container-init.json provides VM identity + config.
# At boot: clones/pulls cloud-data, detects drift, pulls images, starts containers.
#
# Deploys:
#   - /opt/scripts/container-init.sh (the script)
#   - /opt/scripts/container-init.json (VM identity + config)
#   - /etc/systemd/system/docker.service (nix dockerd path)
#   - /etc/systemd/system/container-init.service
#   - ~/container-init.sh (symlink for easy access)
{ vmName ? "unknown" }:
{ config, pkgs, lib, ... }:

let
  dockerdBin = "${pkgs.docker}/bin/dockerd";
  youkiBin = "${pkgs.youki}/bin/youki";
  # 2026-04-27 migrated: cloud-data-home-manager.json → _cloud-data-consolidated.json[._home_manager.vms + .native.monitoring]
  consolidated = builtins.fromJSON (builtins.readFile ../_cloud-data-consolidated.json);
  cloudData = {
    vms = consolidated._home_manager.vms or {};
    monitoring = consolidated.native.monitoring or {};
  };
  vmData = cloudData.vms.${vmName} or {};
  # Read HM build.json for this VM (delivery method, image, etc.)
  # HM configs live at b_infra/nixhm-sudo-<vmName>/build.json
  # From here (vm-pilot/src/modules/container/), that's ../../../../nixhm-sudo-<vmName>/
  hmBuildJsonPath = ../../../../. + "/nixhm-sudo-${vmName}/build.json";
  hmBuildJson = if builtins.pathExists hmBuildJsonPath
    then builtins.fromJSON (builtins.readFile hmBuildJsonPath)
    else {};
  hmConfig = hmBuildJson.hm or {};

  # ── Boot autostart gate — data-driven, never hand-flipped ────────────
  # Docker is disabled from systemd auto-start and every compose service is
  # generated with restart:"no" (a_solutions/_shared/docker.nix), on the stated
  # premise that container-init owns the lifecycle. But container-init was
  # script-only, so in practice NOTHING owned it: a reboot left the VM with
  # zero containers until a human ran the script or CI happened to re-ship.
  # oci-apps rebooted 2026-08-30 22:11 and vaultwarden stayed down 4 days.
  #
  # The original "no boot unit" call was about boot OOM on the 1GB E2 Micros,
  # which is a real constraint — cmd_boot pulls images and starts services
  # sequentially, and three of the four VMs have 1GB of RAM. So gate on the
  # declared spec rather than blanket-enabling: >=2GB gets the boot unit,
  # micros keep the manual-start behaviour they were tuned for. Today that is
  # oci-apps (24GB) only; a resized VM picks it up from cloud-data with no
  # edit here.
  # isInt guard: ram_gb is null for VMs cloud-data has not fully described
  # (vast-ollama today), and `null >= 2` is an eval ERROR, not false — which
  # would fail the whole home-manager generation for that VM rather than just
  # this option. Unknown size ⇒ 0 ⇒ manual start, the conservative branch.
  ramGbRaw = vmData.specs.ram_gb or 0;
  ramGb = if builtins.isInt ramGbRaw then ramGbRaw else 0;
  bootAutostart = ramGb >= 2;

  containerInitJson = builtins.toJSON {
    vm_alias = vmName;
    vm_id = vmData.instance_id or "";
    cloud_data_repo = "https://github.com/diegonmarcos/cloud-data.git";
    cloud_data_dir = "${vmData.home or "/home/diego"}/git/cloud-data";
    containers_dir = "/opt/containers";
    ntfy_base = cloudData.monitoring.ntfy_base or "https://rss.diegonmarcos.com";
    ntfy_topic = "container-init";
    docker_timeout = 60;
    start_delay = 5;
    pull_nice = 19;
    pull_ionice = 3;
    git_user = vmData.user or "diego";
    # HM self-update config
    hm_delivery = hmConfig.delivery or "nix-copy";
    hm_image = hmConfig.image or "";
    hm_user = hmConfig.user or vmData.user or "diego";
    hm_config = hmConfig.config or "";
  };
in {
  # ── Script: standalone .sh file (no nix interpolation) ──────────────
  home.file.".local/share/container-init/container-init.sh".source = ./container-control-init.sh;

  # ── Config JSON: VM identity + settings (auto-generated from cloud-data) ──
  home.file.".local/share/container-init/container-init.json".text = containerInitJson;

  # ── build-vm.json (NEW canonical per-VM manifest) ────────────────────
  # Source-of-truth migration: replaces the legacy cloud-data-containers-{vm}.json
  # that vm-pilot used to pull at runtime from the cloud-data git clone.
  # The canonical file lives at 1_cloud-configs/dist/build-vm-{vmName}.json (emitted
  # by the 9_others derive pipeline; cloud-data emits NOTHING). The
  # nixhm-sudo-{vm}/src/build-vm-{vm}.json symlink resolves to that file, and
  # the home-manager staging engine copies it into the dist flake root —
  # i.e. dist/build-vm-{vm}.json, parallel to dist/pilot/. From this file
  # (dist/pilot/container/init.nix), that's two `../` away. Falls back to {}
  # if the file isn't staged (e.g. VM not yet wired into the new pattern).
  home.file.".local/share/container-init/build-vm.json".text = let
    p = ../.. + "/build-vm-${vmName}.json";
  in if builtins.pathExists p
     then builtins.readFile p
     else "{}";

  # ── Symlinks in ~/ for easy access ───────────────────────────────────
  home.file."container-init.sh".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts/container-init.sh";
  home.file."container-init.json".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts/container-init.json";
  home.file."build-vm.json".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts/build-vm.json";
  home.file."container-init-drift.json".source = config.lib.file.mkOutOfStoreSymlink "/var/log/container-init-drift.json";
  home.file."container-init-boot.json".source = config.lib.file.mkOutOfStoreSymlink "/var/log/container-init-boot.json";
  home.file."containers".source = config.lib.file.mkOutOfStoreSymlink "/opt/containers";
  home.file."scripts".source = config.lib.file.mkOutOfStoreSymlink "/opt/scripts";

  # ── Docker daemon.json — youki (Rust) replaces runc (Go) as default runtime ──
  # Contributed via the daemon.nix orchestrator's merge option, NEVER as a
  # second home.file.".../daemon.json".text: `text` is type `lines`, so two
  # declarations CONCATENATE into `{...}\n{...}` — invalid JSON that dockerd
  # rejects on its next (re)start. That exact bomb kept docker down on oci-mail
  # after the 2026-07-03 reboot (crash-loop restart #234) while the other VMs
  # carried the same corrupt file latently (only bites on daemon restart).
  # (log-driver/log-opts are owned by daemon-security.nix — one owner per key.)
  # youki registered but NOT default (2026-07-03): the whole fleet runs runc in
  # production; youki 0.4.1 + systemd cgroup driver fails `create` on Ubuntu
  # (verified on oci-mail). Opt in per-container until youki is proven.
  #
  # max-concurrent-downloads: dockerd pulls 3 layers in parallel by default.
  # On the 1 GB VMs that is enough memory pressure to kill dockerd mid-pull
  # (2026-11-18 oci-analytics, ship run 44315729287: "Cannot connect to the
  # Docker daemon" on pull attempt 2, SSH unresponsive ~30 min). VMs with a
  # declared ram_gb <= 1 pull one layer at a time. Unknown size (ramGb = 0)
  # keeps the dockerd default. Live-reloadable key (daemon.nix reloads).
  docker.daemon.settings = {
    runtimes = {
      youki = { path = youkiBin; };
    };
  } // lib.optionalAttrs (ramGb > 0 && ramGb <= 1) {
    "max-concurrent-downloads" = 1;
  };

  # ── Docker unit file — NO [Install], container-init starts it ───────
  home.file.".local/share/container-init/docker.service".text = ''
    [Unit]
    Description=Docker Application Container Engine (nix)
    After=network-online.target

    [Service]
    Type=notify
    # PATH: nix profile FIRST so dockerd resolves containerd-shim-runc-v2
    # from the same nix package as dockerd. Without this, dockerd (nix) calls
    # /usr/bin/containerd-shim-runc-v2 (Fedora moby-engine) which speaks a
    # different shim API — breaks all `docker run` with
    # "unsupported shim version (3): not implemented".
    Environment=PATH=${pkgs.docker}/libexec/docker:${pkgs.docker}/bin:${pkgs.containerd}/bin:${pkgs.runc}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    ExecStartPre=/bin/bash -c '[ -d /var/run/docker.sock ] && rm -rf /var/run/docker.sock || true'
    ExecStart=${dockerdBin}
    ExecReload=/bin/kill -s HUP $MAINPID
    Restart=always
    RestartSec=5
    # systemd's 45s default is TOO SHORT on the 944MB E2 Micros: containerd alone
    # needs ~16s there, and every timed-out attempt ORPHANS a containerd that
    # slows the next one — gcp-proxy hit an 11-restart loop on 2026-09-05 and was
    # only rescued by a hand-written /run/systemd/system/docker.service.d/ drop-in,
    # which lives in tmpfs and dies at reboot. Declared here so it is durable.
    TimeoutStartSec=600
    # Bounded (was infinity) — 2026-06-19 fd-leak incident hardening. infinity
    # lets dockerd + every container consume up to fs.nr_open, i.e. the whole
    # system fd table; a single container fd leak could then freeze the host the
    # same way fluent-bit did. 1048576 = half of fs.nr_open (2097152, set in
    # resource-bouncer.nix) → docker is still astronomically generous yet can
    # never starve sshd / wg-quick / dropbear of file descriptors.
    LimitNOFILE=1048576
    LimitNPROC=infinity
    LimitCORE=infinity
    CPUQuota=80%
    Delegate=yes
    KillMode=process
  '';

  # ── container-init.service — boot sequence, installed only on VMs with RAM ──
  # Always staged; the activation block below installs + enables it only when
  # bootAutostart (see the gate above). ExecStart is the `boot` verb, i.e. the
  # sequence the script already defines (dockerd-up → hm-update → cloud-data
  # sync → containers-up → health → report) — not a second, parallel notion of
  # what "start this VM" means. Docker has no [Install] of its own by design,
  # so this unit is what transitively brings the daemon up too.
  # TimeoutStartSec=30min: observed full runs on oci-apps take ~335s, and it
  # starts ~49 services sequentially with a START_DELAY between each.
  home.file.".local/share/container-init/container-init.service".text = ''
    [Unit]
    Description=Container Init — Docker daemon + declared containers (boot sequence)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/opt/scripts/container-init.sh boot
    TimeoutStartSec=30min
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
  '';

  # ── Activation: deploy to system locations ──────────────────────────
  home.activation.installContainerInit = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[container-init] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -z "$SUDO" ]; then
      echo "[container-init] WARNING: sudo not found — skipping"
      exit 0
    fi

    SRC="$HOME/.local/share/container-init"

    # Deploy script + config JSON
    $SUDO mkdir -p /opt/scripts
    $SUDO cp -f "$SRC/container-init.sh" /opt/scripts/container-init.sh
    $SUDO cp -f "$SRC/container-init.json" /opt/scripts/container-init.json
    # NEW canonical per-VM manifest (replaces legacy cloud-data-containers-{vm}.json)
    [ -f "$SRC/build-vm.json" ] && $SUDO cp -f "$SRC/build-vm.json" /opt/scripts/build-vm.json
    $SUDO chmod +x /opt/scripts/container-init.sh

    # daemon.json deploy moved to daemon.nix (installDaemonJson) — single writer.

    # Deploy docker.service (only if changed)
    DOCKER_UNIT="$SRC/docker.service"
    DOCKER_DEST="/etc/systemd/system/docker.service"
    DNEW=$(cat "$DOCKER_UNIT")
    DOLD=$($SUDO cat "$DOCKER_DEST" 2>/dev/null || true)
    if [ "$DNEW" != "$DOLD" ]; then
      echo "$DNEW" | $SUDO tee "$DOCKER_DEST" > /dev/null
      # Reload HERE, not only at the end of this block: daemon.nix may restart
      # docker during the same activation, and it must get the new
      # TimeoutStartSec rather than systemd's 45s default.
      $SUDO systemctl daemon-reload
      echo "[container-init] docker.service deployed"
    fi

    ${if bootAutostart then ''
    # Boot autostart ON (declared RAM ${toString ramGb}GB >= 2) — install + enable.
    INIT_UNIT="$SRC/container-init.service"
    INIT_DEST="/etc/systemd/system/container-init.service"
    INEW=$(cat "$INIT_UNIT")
    IOLD=$($SUDO cat "$INIT_DEST" 2>/dev/null || true)
    if [ "$INEW" != "$IOLD" ]; then
      echo "$INEW" | $SUDO tee "$INIT_DEST" > /dev/null
      echo "[container-init] container-init.service deployed"
    fi
    $SUDO systemctl daemon-reload
    # enable only — never `start`: ExecStart is the full boot sequence and
    # starting it mid-activation would recreate every running container.
    $SUDO systemctl enable container-init.service 2>/dev/null || true
    '' else ''
    # Boot autostart OFF (declared RAM ${toString ramGb}GB < 2) — E2 Micros
    # cannot afford the boot sequence; keep manual start via dtk/cron.
    if [ -f /etc/systemd/system/container-init.service ]; then
      $SUDO systemctl disable container-init.service 2>/dev/null || true
      $SUDO rm -f /etc/systemd/system/container-init.service
      echo "[container-init] removed stale systemd service"
    fi
    $SUDO systemctl daemon-reload
    ''}

    # Docker itself stays disabled from systemd auto-start either way —
    # container-init.sh (dockerd-up) is the only thing that starts it.
    $SUDO systemctl disable docker.service 2>/dev/null || true

    echo "[container-init] deployed: boot-autostart=${if bootAutostart then "on" else "off"} (ram=${toString ramGb}GB)"
    ) || echo "[container-init] FAILED — see errors above, activation continues"
  '';
}
