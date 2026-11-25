# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/agents/my-stack.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# vm-pilot as the HUB for the two products that used to live inside it.
#
# WHAT CHANGED AND WHY
# vm-pilot implemented "a web server and a watchdog" itself: busybox httpd on
# 7680 serving symlinked directories, and a data-publisher timer writing
# containers.json every five minutes. Both jobs now belong to products of their
# own in cloud-u-linux — my-webserver and my-watchdog — for the same reason the
# sampler left my-konsole: the coupling was never more than a file path, and
# owning a second implementation of somebody else's job is how the two drift.
#
# So this module deploys them and gets out of the way. vm-pilot keeps what is
# genuinely its own — the protection layers, the alerting, the identity and
# rescue paths — and stops carrying a metrics stack alongside them.
#
# WHAT THIS GIVES THE FLEET
#   * my-watchdog samples this machine every 2s and publishes one snapshot,
#     the same shape the desktop publishes, so the hub's panel describes a VM
#     exactly as it describes the laptop.
#   * my-webserver answers /__api__/watchdog with that file, so the hub reads
#     it over HTTP instead of opening an ssh session and running a collector
#     script on the far end — which is both slower and a portability problem
#     on every box with BusyBox df or mawk.
#
# NO BUILDING HERE. Both are fetched as prebuilt binaries, statically linked
# against musl so one artifact per architecture runs on the Ubuntu, Fedora and
# NixOS boxes alike. Compiling Rust on these VMs is what no-build-guard.nix
# exists to prevent.
{ vmName, ramMB ? 0 }:
{ config, pkgs, lib, ... }:

let
  # On a 1 GB / 1-OCPU burstable VM the sampler's 2 s loop alone was ~13% of
  # the CPU (oci-mail, 2026-11-19, steal 44-74%, mail timing out). Cap it
  # there: a slower snapshot costs nothing, a starved mail stack costs mail.
  # ramMB = 0 (unknown) and bigger boxes get no cap.
  cpuQuotaLine = if ramMB > 0 && ramMB <= 1536 then "CPUQuota=8%" else "";
  # 2026-08-27: my-webserver and my-watchdog moved to cloud-u-linux in the d*
  # split, so their rolling releases are published there now.
  repo = "diegonmarcos/cloudy-u-linux";
  webPort = 8000;

  # Bind to the MESH address only, resolved at start.
  #
  # Not 0.0.0.0. Several of these VMs have public addresses, and this serves a
  # file listing of $HOME — on 0.0.0.0 that is a directory browser on the
  # internet, firewalled or not, and "there is a firewall" is not a reason to
  # open a socket that has no business being open. The hub reaches these over
  # WireGuard and nothing else needs to.
  #
  # No wg0, no server: refusing to start is the correct outcome when the only
  # address it is allowed to bind does not exist.
  serveScript = pkgs.writeShellScript "my-webserver-mesh.sh" ''
    set -euo pipefail
    ip=""
    for dev in wg0 wg-public; do
      ip="$(ip -o -4 addr show "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
      [ -n "$ip" ] && break
    done
    if [ -z "$ip" ]; then
      echo "[my-webserver] no mesh address on wg0/wg-public — refusing to bind anywhere else" >&2
      exit 1
    fi
    exec "$HOME/.local/bin/my-webserver" --port ${toString webPort} --host "$ip" --root "$HOME"
  '';

  # The hub can also push these over scp (`da_watchdog/build.sh deploy`), and
  # on a VM without a working `gh` credential that is the path that works. This
  # script is the pull half: it makes a VM able to update itself, and it is
  # deliberately quiet about failing, because a metrics binary that could not
  # be refreshed must never take a deploy down with it.
  fetchScript = pkgs.writeShellScript "my-stack-fetch.sh" ''
    set -uo pipefail
    BIN="$HOME/.local/bin"
    mkdir -p "$BIN"

    arch="$(uname -m)"
    case "$arch" in
      aarch64|arm64) suffix=aarch64 ;;
      x86_64)        suffix=x86_64 ;;
      *) echo "[my-stack] no build for $arch — nothing to fetch"; exit 0 ;;
    esac

    have_gh=0
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && have_gh=1
    if [ "$have_gh" -eq 0 ]; then
      echo "[my-stack] gh not authenticated here — the hub pushes these instead (build.sh deploy)"
      exit 0
    fi

    get() { # tag asset dest
      tmp="$(mktemp "$BIN/.fetch.XXXXXX")" || return 0
      if gh release download "$1" --repo "${repo}" --pattern "$2" --output "$tmp" --clobber 2>/dev/null; then
        chmod +x "$tmp"
        # rename(2), never write-in-place: overwriting a running binary is
        # ETXTBSY, and this runs on a timer while both are running.
        mv -f "$tmp" "$BIN/$3"
        echo "[my-stack] $3 updated"
      else
        rm -f "$tmp"
        echo "[my-stack] $2 not available — keeping the copy already here"
      fi
    }

    # The watchdog is published as c3-watchdog since the rename; the
    # my-watchdog-latest release froze on 2026-09-03 and never got another
    # build, so fetching it kept every VM on an old sampler (no small-box
    # docker cadence, 2026-11-19). The binary keeps its installed name
    # (my-watchdog), its --no-tray flag and its /run/my-watchdog output.
    get c3-watchdog-latest  "c3-watchdog-$suffix"  my-watchdog
    get my-webserver-latest "my-webserver-$suffix" my-webserver
  '';
in
{
  # ── my-watchdog ────────────────────────────────────────────────────
  # Headless: there is no tray on a VM and the fleet build has none compiled
  # in, so --no-tray is belt and braces for a desktop artifact deployed here
  # by hand.
  home.file.".local/share/vm-pilot/my-watchdog.service".text = ''
    [Unit]
    Description=my-watchdog — machine sampler (${vmName})
    After=network.target

    [Service]
    Type=simple
    ExecStart=%h/.local/bin/my-watchdog --no-tray
    Restart=always
    RestartSec=5
    # A monitor that competes with what it is monitoring is the problem it
    # exists to report, and this fleet has already had one freeze caused by a
    # watchdog that computed before its early exit and became the load.
    Nice=10
    IOSchedulingClass=idle
    MemoryMax=96M
    ${cpuQuotaLine}

    [Install]
    WantedBy=default.target
  '';

  # ── my-webserver ───────────────────────────────────────────────────
  # Bound to the mesh address, not 0.0.0.0: this serves a file listing and a
  # metrics route, and neither belongs on a public interface. The mesh is the
  # only network the hub reaches it on anyway.
  home.file.".local/share/vm-pilot/my-webserver.service".text = ''
    [Unit]
    Description=my-webserver — file server and /__api__/watchdog (${vmName})
    After=network.target

    [Service]
    Type=simple
    ExecStart=${serveScript}
    Restart=always
    RestartSec=5
    Nice=10
    MemoryMax=192M

    [Install]
    WantedBy=default.target
  '';

  # Refresh on a slow timer. Daily, because these change when something is
  # pushed to main and never on their own — a tighter loop is a GitHub API
  # call per VM per interval for no benefit.
  home.file.".local/share/vm-pilot/my-stack-update.service".text = ''
    [Unit]
    Description=my-stack — refresh my-watchdog and my-webserver

    [Service]
    Type=oneshot
    ExecStart=${fetchScript}
  '';

  home.file.".local/share/vm-pilot/my-stack-update.timer".text = ''
    [Unit]
    Description=my-stack — daily refresh

    [Timer]
    OnBootSec=10min
    OnUnitActiveSec=1d
    Persistent=true

    [Install]
    WantedBy=timers.target
  '';

  home.activation.installMyStack = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[my-stack] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

    SRC="$HOME/.local/share/vm-pilot"
    UNITS="$HOME/.config/systemd/user"
    mkdir -p "$UNITS" "$HOME/.local/bin"

    for u in my-watchdog.service my-webserver.service my-stack-update.service my-stack-update.timer; do
      install -m644 "$SRC/$u" "$UNITS/$u"
    done

    # THE BINARIES COME DOWN FIRST, for the same reason.
    #
    # The fetch also sat after that `exit 0`, so a server with no user session
    # never pulled a new build: gcp-proxy was still running an 08-29 sampler
    # today. It is idempotent and a no-op when the hub already pushed them.
    ${fetchScript} || true

    # THE ROOT SAMPLER GOES IN FIRST — it is a SYSTEM unit and needs no
    # user session. It used to sit after the `exit 0` below, which every
    # server with no user D-Bus session takes, so the deploy went green on
    # four VMs and installed nothing at all.
    # ── my-watchdog AS ROOT ────────────────────────────────────────────
    # /proc/<pid>/io is readable only for your own processes, so a sampler
    # running as the user shows a dash in every per-process IO column for
    # root's daemons and the kernel's threads — which, on a box whose disk
    # is pinned at 100%, is exactly the set doing the IO. Root reads all of
    # it. The unit is a SYSTEM unit installed with sudo; it publishes under
    # /run/my-watchdog (RuntimeDirectory), which my-watchdog-tui and
    # my-webserver look at first, and the directory is root:<user's group>
    # 0770 with UMask=0007 so the user can still append kill requests to the
    # mailbox while nobody else on the box can. The user unit is retired.
    #
    # The unit text is written to a TEMP file, not into $SRC: that directory
    # is home-manager's own symlink tree. And the heredoc ends at column
    # zero — an indented terminator does not close it, which silently ate
    # the rest of this block on the first attempt and installed nothing.
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    if [ -n "$SUDO" ] && $SUDO -n true 2>/dev/null; then
      UNIT_TMP="$(mktemp)"
      cat > "$UNIT_TMP" <<'WATCHDOG_UNIT'
[Unit]
Description=my-watchdog — machine sampler as root
After=network.target

[Service]
Type=simple
User=root
ExecStart=@HOME@/.local/bin/my-watchdog --no-tray
Environment=XDG_RUNTIME_DIR=/run/my-watchdog
RuntimeDirectory=my-watchdog
RuntimeDirectoryMode=0770
RuntimeDirectoryPreserve=yes
UMask=0007
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle
MemoryMax=96M
${cpuQuotaLine}

[Install]
WantedBy=multi-user.target
WATCHDOG_UNIT
      # Group and path are this user's, so the panel and my-webserver — which
      # run as the user — can read what root publishes.
      sed -i "s|@HOME@|$HOME|; s|^User=root$|User=root\nGroup=$(id -gn)|" "$UNIT_TMP"
      $SUDO install -m644 "$UNIT_TMP" /etc/systemd/system/my-watchdog.service
      rm -f "$UNIT_TMP"
      $SUDO systemctl daemon-reload
      # RETIRE THE USER COPY — host systemctl by path, user bus by path.
      # HM activation runs on a strict PATH with no systemctl in it (`$SUDO
      # systemctl` only works because sudo's secure_path adds /usr/bin), so
      # the bare `systemctl --user disable --now` this used to be died with
      # "command not found" on every ship — read off the oci-analytics
      # activation log 2026-10-02 — and its `2>/dev/null || true` hid it.
      # The ship also runs this as `sudo -u <user>`, which strips
      # XDG_RUNTIME_DIR, so the bus is addressed by its well-known path too.
      # oci-analytics (the 1/8-OCPU public edge) ran BOTH samplers for a
      # month: measured 2026-10-01 the user copy at ~8.6% of a vCPU and the
      # root copy at ~16%, together the whole burst baseline before a single
      # container ran. No bus socket = no user manager = nothing to retire.
      SYSTEMCTL=""
      for p in /usr/bin/systemctl /bin/systemctl /run/current-system/sw/bin/systemctl; do
        [ -x "$p" ] && SYSTEMCTL="$p" && break
      done
      _ubus="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if [ -n "$SYSTEMCTL" ] && [ -S "$_ubus/bus" ]; then
        XDG_RUNTIME_DIR="$_ubus" "$SYSTEMCTL" --user disable --now my-watchdog.service \
          || echo "[my-stack] WARN: could not retire the user my-watchdog — two samplers may be running" >&2
      fi
      if [ -x "$HOME/.local/bin/my-watchdog" ]; then
        if $SUDO systemctl enable --now my-watchdog.service 2>/dev/null; then
          echo "[my-stack] my-watchdog running as root"
        else
          echo "[my-stack] could not start system my-watchdog"
        fi
      else
        $SUDO systemctl enable my-watchdog.service 2>/dev/null || true
        echo "[my-stack] my-watchdog binary not present yet — system unit enabled, not started"
      fi
    fi

    # A VM with no user D-Bus session has no `systemctl --user` to talk to, and
    # that is a normal state on a box nobody has logged into. Installing the
    # units and stopping there is the right outcome: they start on the next
    # login, or when lingering is enabled.
    if ! systemctl --user show-environment >/dev/null 2>&1; then
      echo "[my-stack] units installed; no user session to start them in yet"
      exit 0
    fi

    systemctl --user daemon-reload

    for u in my-watchdog.service my-webserver.service; do
      # The sampler is a system unit now where sudo allows; skip the user copy there.
      [ "$u" = my-watchdog.service ] && [ -f /etc/systemd/system/my-watchdog.service ] && continue
      bin="$HOME/.local/bin/''${u%.service}"
      if [ -x "$bin" ]; then
        systemctl --user enable --now "$u" 2>/dev/null || \
          echo "[my-stack] could not start $u"
      else
        # Enabled but not started: the unit is in place for whenever the
        # binary arrives, and saying so beats a start that fails every boot.
        systemctl --user enable "$u" 2>/dev/null || true
        echo "[my-stack] $bin not present yet — unit enabled, not started"
      fi
    done
    systemctl --user enable --now my-stack-update.timer 2>/dev/null || true

    echo "[my-stack] my-watchdog + my-webserver deployed (port ${toString webPort})"
    )
  '';
}
