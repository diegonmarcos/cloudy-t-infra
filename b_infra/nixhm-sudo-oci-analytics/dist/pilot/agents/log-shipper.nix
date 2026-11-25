# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/agents/log-shipper.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Log shipper — Fluent Bit streaming agent
# Inputs : systemd journald + /var/lib/docker/containers/*/*-json.log
# Output : OpenObserve via WG IP 10.0.0.6:5080 (host_journald + container_logs streams)
#
# Bearer token wiring: ZO_INGEST_TOKEN is read from $HOME/.config/home-manager/.secrets
# (decrypted by build.sh secrets from _shared/secrets.yaml at deploy time) and
# substituted into /opt/fluent-bit/log-shipper.conf at activation time. {HOSTNAME}
# is substituted from `hostname -s` so each VM tags its records with its alias.
#
# Resource caps mirror journal-ntfy.service: MemoryMax=64M CPUQuota=10%. Fits the
# 1 GB E2 Micro VMs (gcp-proxy, oci-mail, oci-analytics).
#
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [ fluent-bit ];

  home.file.".local/share/vm-pilot/log-shipper.conf.tpl" = {
    source = ../scripts/log-shipper.conf.tpl;
  };

  # Parser without Time_Key/Time_Format: docker's own `time` is the RFC3339 stamp the
  # bundled `json` parser cannot read. Loaded via a second parsers_file line.
  home.file.".local/share/vm-pilot/parsers-local.conf".text = ''
    [PARSER]
        Name   json_notime
        Format json
  '';

  home.file.".local/share/vm-pilot/log-shipper.service".text = ''
    [Unit]
    Description=Fluent Bit — stream journald + docker container logs to OpenObserve
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=${pkgs.fluent-bit}/bin/fluent-bit --config=/opt/fluent-bit/log-shipper.conf
    Restart=always
    RestartSec=15
    MemoryMax=64M
    # MemoryMax alone is a trap on a box with swap: when the cgroup hits the
    # cap the kernel SWAPS the process out instead of killing it, so a leak
    # grows unbounded in zram while RSS reads a tidy 12M. Measured 2026-09-02
    # on gcp-proxy: fluent-bit RSS 11M, VmSwap 450M — half the host's RAM
    # gone into its compressed swap, every other daemon refaulting its code
    # pages off a 262ms/op disk (authelia alone: 118 GB of reads). Deny swap
    # so the cap means what it says: leak -> OOM-kill -> Restart=always brings
    # it back clean. Same self-healing blip pattern as the fd cap below.
    MemorySwapMax=0
    CPUQuota=10%
    # Whatever it logs, it may not flood the journal (and so syslog): 20 lines
    # per 30 s, the rest are dropped and counted by journald.
    LogRateLimitIntervalSec=30s
    LogRateLimitBurst=20
    # ── fd / task self-limit (2026-06-19 fd-leak incident) ───────────────
    # The `tail` input opens one fd + inotify watch per matched container log
    # and leaks them on container churn / log rotation (known upstream tail
    # behaviour). Hard-cap fluent-bit's own fds so a leak can NEVER drain the
    # system fd table — if it ever climbs past this it hits EMFILE itself,
    # crashes, and Restart=always (RestartSec=15) brings it back with fresh
    # fds. A self-contained, self-healing blip instead of a host-wide freeze.
    # ~30 containers need <500 fds; 8192 is generous-but-bounded headroom.
    LimitNOFILE=8192
    TasksMax=64
    User=root
    # Fluent Bit needs read access to /var/log/journal + /var/lib/docker
    ProtectSystem=strict
    ReadWritePaths=/var/lib/fluent-bit
    ReadOnlyPaths=/var/lib/docker /var/log/journal /run/log/journal /opt/fluent-bit

    [Install]
    WantedBy=multi-user.target
  '';

  home.activation.installLogShipper = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    # HM activate sets a strict PATH that has bash/coreutils/diffutils/jq/etc
    # but NOT awk or hostname. Use full nix-store paths for everything we
    # invoke directly (cf. etc-hosts-clean.nix which already does this).
    AWK=${pkgs.gawk}/bin/awk
    HOSTNAME_BIN=${pkgs.hostname}/bin/hostname
    MKTEMP=${pkgs.coreutils}/bin/mktemp
    INSTALL=${pkgs.coreutils}/bin/install
    MKDIR=${pkgs.coreutils}/bin/mkdir
    CHMOD=${pkgs.coreutils}/bin/chmod
    CHOWN=${pkgs.coreutils}/bin/chown
    CP=${pkgs.coreutils}/bin/cp
    MV=${pkgs.coreutils}/bin/mv
    TEE=${pkgs.coreutils}/bin/tee

    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && exit 0

    SRC="$HOME/.local/share/vm-pilot"
    SECRETS="$HOME/.config/home-manager/.secrets"

    # Read bearer token from the sops-decrypted .secrets dotenv file. If missing,
    # log loudly and skip — the agent unit will fail-fast on next activation
    # rather than silently shipping with an empty token.
    if [ ! -r "$SECRETS" ]; then
      echo "[log-shipper] FATAL: .secrets not readable at $SECRETS — skipping"
      exit 0
    fi
    # Reads root-user creds from .secrets — OpenObserve admin credentials
    # (bootstrapped from bc-obs_openobserve/src/secrets.yaml at OO install
    # time). HTTP basic-auth is the OO-supported ingest auth dialect; the
    # earlier ZO_INGEST_TOKEN bearer-token path required minting a real
    # org-scoped token via OO admin API which we'll defer to v2.
    ZO_USER="$($AWK -F= '/^ZO_ROOT_USER_EMAIL=/ {sub(/^ZO_ROOT_USER_EMAIL=/,""); gsub(/^"|"$/,""); print; exit}' "$SECRETS")"
    ZO_PASS="$($AWK -F= '/^ZO_ROOT_USER_PASSWORD=/ {sub(/^ZO_ROOT_USER_PASSWORD=/,""); gsub(/^"|"$/,""); print; exit}' "$SECRETS")"
    if [ -z "$ZO_USER" ] || [ -z "$ZO_PASS" ]; then
      echo "[log-shipper] FATAL: ZO_ROOT_USER_EMAIL or ZO_ROOT_USER_PASSWORD missing/empty in $SECRETS — skipping"
      exit 0
    fi
    HOSTNAME_SHORT="$($HOSTNAME_BIN -s 2>/dev/null || echo unknown)"
    PARSERS_FILE=${pkgs.fluent-bit}/etc/fluent-bit/parsers.conf

    # Render the conf — literal substitution via awk index() (no regex, no shell-glob).
    # Same substitution pattern used by secrets-subst.nix.
    CONF_TPL="$SRC/log-shipper.conf.tpl"
    CONF_OUT_TMP="$($SUDO $MKTEMP /tmp/log-shipper.conf.XXXXXX)"
    "$AWK" -v zu="$ZO_USER" -v zp="$ZO_PASS" -v hst="$HOSTNAME_SHORT" -v pf="$PARSERS_FILE" '
      {
        line = $0
        while ((i = index(line, "{ZO_USER}")) > 0)
          line = substr(line,1,i-1) zu substr(line,i+length("{ZO_USER}"))
        while ((i = index(line, "{ZO_PASS}")) > 0)
          line = substr(line,1,i-1) zp substr(line,i+length("{ZO_PASS}"))
        while ((i = index(line, "{HOSTNAME}")) > 0)
          line = substr(line,1,i-1) hst substr(line,i+length("{HOSTNAME}"))
        while ((i = index(line, "{PARSERS_FILE}")) > 0)
          line = substr(line,1,i-1) pf substr(line,i+length("{PARSERS_FILE}"))
        print line
      }
    ' "$CONF_TPL" | $SUDO $TEE "$CONF_OUT_TMP" >/dev/null

    $SUDO $MKDIR -p /opt/fluent-bit /var/lib/fluent-bit
    $SUDO $CP -f "$SRC/parsers-local.conf" /opt/fluent-bit/parsers-local.conf
    $SUDO $MV "$CONF_OUT_TMP" /opt/fluent-bit/log-shipper.conf
    $SUDO $CHMOD 0600 /opt/fluent-bit/log-shipper.conf
    $SUDO $CHOWN root:root /opt/fluent-bit/log-shipper.conf

    $SUDO $CP -f "$SRC/log-shipper.service" /etc/systemd/system/log-shipper.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable log-shipper.service 2>/dev/null || true
    $SUDO systemctl restart log-shipper.service 2>/dev/null || true
    echo "[log-shipper] deployed (host=$HOSTNAME_SHORT, target=10.0.0.6:5080)"
    ) || echo "[log-shipper] FAILED — activation continues"
  '';
}
