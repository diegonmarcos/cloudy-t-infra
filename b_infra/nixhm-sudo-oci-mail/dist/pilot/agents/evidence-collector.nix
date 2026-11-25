# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/agents/evidence-collector.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Evidence Collector — LIGHTWEIGHT daily metadata capture + OO push.
#
# Produces /var/backups/evidence/<date>/ containing ONLY the files
# cloud-sec-data-report consumes (runtime sec-scan output → evidence_files; not in _cloud-data-consolidated.json):
#
#   manifest.json           — hostname + per-container image_id / ports / labels
#   diff.json               — vs. yesterday (new / modified / removed containers)
#   docker-inspect.json     — full docker inspect output for running containers
#   processes.txt           — ps aux snapshot
#   connections.txt         — ss -tnp snapshot
#
# 2026-04-20: dropped heavy `docker export | gzip` + /etc /tmp /var /root /home tar.
# 2026-05-05: dropped journal-24h.json.gz — log-shipper streams every journal line
#             to OpenObserve `host_journald` in real-time (full overlap).
# 2026-05-05: now ALSO POSTs the small JSONs to OO `vm_evidence` stream so reports
#             can query the central store instead of fanning out via SSH+ssh_run.
#             Local copy retained (≈10 KB/day) for cloud-sec-data fallback.
#
# Imported by: default.nix
#
{ config, pkgs, lib, ... }:
{
  home.file.".local/share/system-protection/evidence-collector.sh" = {
    executable = true;
    text = ''
      #!/bin/bash
      set -uo pipefail
      DATE=$(date +%Y-%m-%d)
      EVIDENCE_DIR="/var/backups/evidence/$DATE"
      PREV_DIR="/var/backups/evidence/$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo 'none')"
      HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")

      echo "[evidence-collector] Starting lightweight capture for $HOSTNAME ($DATE)"
      sudo mkdir -p "$EVIDENCE_DIR"
      sudo chown "$(id -u):$(id -g)" "$EVIDENCE_DIR"

      # ── Phase 1: Container metadata manifest ───────────────────────────
      # No docker export. Only image_id + ports + labels — tens of KB total.
      CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
      MANIFEST="$EVIDENCE_DIR/manifest.json"
      {
        echo "{"
        echo "  \"vm\": \"$HOSTNAME\","
        echo "  \"date\": \"$DATE\","
        echo "  \"schema\": \"lightweight-v1\","
        echo "  \"containers\": {"
        FIRST_CTR=true
        for ctr in $CONTAINERS; do
          IMAGE_ID=$(docker inspect --format '{{.Image}}' "$ctr" 2>/dev/null || echo "unknown")
          IMAGE_NAME=$(docker inspect --format '{{.Config.Image}}' "$ctr" 2>/dev/null || echo "unknown")
          PORTS=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' "$ctr" 2>/dev/null | tr -d '\n' || true)
          STATUS=$(docker inspect --format '{{.State.Status}}' "$ctr" 2>/dev/null || echo "unknown")
          [ "$FIRST_CTR" = true ] && FIRST_CTR=false || echo ","
          echo "    \"$ctr\": {"
          echo "      \"image_id\": \"$IMAGE_ID\","
          echo "      \"image_name\": \"$IMAGE_NAME\","
          echo "      \"status\": \"$STATUS\","
          echo "      \"ports\": \"$PORTS\""
          echo -n "    }"
        done
        echo ""
        echo "  }"
        echo "}"
      } > "$MANIFEST"
      echo "[evidence-collector] manifest.json ($(wc -l < "$MANIFEST") lines)"

      # ── Phase 2: docker inspect (full, for runtime/drift analysis) ─────
      RUNNING_IDS=$(docker ps -q 2>/dev/null)
      if [ -n "$RUNNING_IDS" ]; then
        docker inspect $RUNNING_IDS > "$EVIDENCE_DIR/docker-inspect.json" 2>/dev/null || echo "[]" > "$EVIDENCE_DIR/docker-inspect.json"
      else
        echo "[]" > "$EVIDENCE_DIR/docker-inspect.json"
      fi

      # ── Phase 3: REMOVED (2026-05-05) ─────────────────────────────────
      # journal-24h.json.gz fully overlaps with log-shipper's host_journald
      # stream in OpenObserve (Fluent Bit INPUT systemd ships every line live).
      # Querying OO is faster + smaller + retains beyond 24h.

      # ── Phase 4: Runtime state (cheap, all local commands) ─────────────
      ps auxww --no-headers 2>/dev/null | awk '{print $1,$2,$3,$4,$11}' > "$EVIDENCE_DIR/processes.txt" || true
      ss -tnp 2>/dev/null > "$EVIDENCE_DIR/connections.txt" || true

      # ── Phase 5: Diff vs yesterday ─────────────────────────────────────
      # Pure-jq implementation: handles empty container sets, missing fields,
      # and never emits malformed JSON. Replaces the prior shell-loop logic
      # that emitted a leading `,` when the new manifest had zero containers.
      DIFF_FILE="$EVIDENCE_DIR/diff.json"
      if [ -f "$PREV_DIR/manifest.json" ]; then
        jq -n \
          --arg baseline "$(basename "$PREV_DIR")" \
          --arg current  "$DATE" \
          --slurpfile cur  "$EVIDENCE_DIR/manifest.json" \
          --slurpfile prev "$PREV_DIR/manifest.json" \
          '
          ($cur[0].containers  // {}) as $c |
          ($prev[0].containers // {}) as $p |
          {
            baseline: $baseline,
            current: $current,
            containers: (
              ([ $c | keys[] | { (.): (
                  if   ($p[.] // null) == null              then "new"
                  elif ($p[.].image_id != $c[.].image_id)   then "modified"
                  else "unchanged" end
                ) } ] + [ $p | keys[] | select(. as $k | ($c[$k] // null) == null) | { (.): "deleted" } ])
                | add // {}
            )
          }
          ' > "$DIFF_FILE" 2>/dev/null \
          || echo "{\"baseline\":\"$(basename "$PREV_DIR")\",\"current\":\"$DATE\",\"containers\":{}}" > "$DIFF_FILE"
      else
        echo "{\"baseline\":null,\"current\":\"$DATE\",\"containers\":{}}" > "$DIFF_FILE"
      fi

      # ── Phase 6: Push evidence to OpenObserve `vm_evidence` stream ─────
      # Single payload combining all small JSONs + text dumps. Reports can
      # query the central OO store instead of SSH-fanout to N VMs.
      # Creds substituted at activation time (mode 0700 root:root).
      ZO_USER="{ZO_USER}"
      ZO_PASS="{ZO_PASS}"
      OO_HOST="10.0.0.6"
      OO_PORT="5080"
      # Activation awk-substitutes both placeholders with values from .secrets.
      # If creds were absent the values become empty strings — skip the push.
      if [ -n "$ZO_USER" ] && [ -n "$ZO_PASS" ]; then
        # docker-inspect.json on hub VMs runs to several MB — passing JSON via
        # `-d "$VAR"` overflows ARG_MAX. Pipe through stdin via `--data @-`.
        # Use --rawfile + fromjson? // {} so a malformed input file (legacy
        # diff.json bug, partial write) still produces a valid envelope
        # instead of empty output that triggers HTTP 400.
        jq -n \
          --arg vm "$HOSTNAME" \
          --arg date "$DATE" \
          --rawfile manifest_raw "$EVIDENCE_DIR/manifest.json" \
          --rawfile diff_raw "$EVIDENCE_DIR/diff.json" \
          --rawfile inspect_raw "$EVIDENCE_DIR/docker-inspect.json" \
          --rawfile processes "$EVIDENCE_DIR/processes.txt" \
          --rawfile connections "$EVIDENCE_DIR/connections.txt" \
          '[{
            vm:$vm,
            date:$date,
            manifest: ($manifest_raw | (fromjson? // {})),
            diff: ($diff_raw | (fromjson? // {})),
            docker_inspect: ($inspect_raw | (fromjson? // [])),
            processes:$processes,
            connections:$connections,
            schema:"vm_evidence-v1"
          }]' 2>/dev/null \
          | curl -fsS --max-time 30 -u "$ZO_USER:$ZO_PASS" \
              -H 'Content-Type: application/json' \
              -X POST "http://$OO_HOST:$OO_PORT/api/default/vm_evidence/_json" \
              --data-binary @- >/dev/null \
              && echo "[evidence-collector] pushed to OO vm_evidence ($HOSTNAME/$DATE)" \
              || echo "[evidence-collector] OO push failed (non-fatal)"
      else
        echo "[evidence-collector] OO creds missing — skipping push"
      fi

      # ── Phase 7: Upload to S3 via rustic (optional, tiny payload) ──────
      if command -v rustic >/dev/null 2>&1 && [ -n "''${RUSTIC_REPO:-}" ]; then
        export AWS_ACCESS_KEY_ID="''${AWS_ACCESS_KEY_ID:-}"
        export AWS_SECRET_ACCESS_KEY="''${AWS_SECRET_ACCESS_KEY:-}"
        export RUSTIC_PASSWORD="''${RUSTIC_PASSWORD:-}"
        rustic init 2>/dev/null || true
        rustic backup "$EVIDENCE_DIR" --tag evidence --tag "$HOSTNAME" --tag "$DATE" \
          && echo "[evidence-collector] Uploaded to S3" \
          || echo "[evidence-collector] S3 upload failed (non-fatal)"
      fi

      # Keep 7 days locally (tiny footprint now — KB per day)
      find /var/backups/evidence -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

      TOTAL_SIZE=$(du -sh "$EVIDENCE_DIR" 2>/dev/null | awk '{print $1}' || echo "?")
      echo "[evidence-collector] Done: $EVIDENCE_DIR ($TOTAL_SIZE)"
    '';
  };

  home.file.".local/share/system-protection/evidence-collector.service".text = ''
    [Unit]
    Description=Evidence Collector — lightweight daily metadata capture
    After=network.target docker.service
    [Service]
    Type=oneshot
    ExecStart=/opt/scripts/evidence-collector.sh
    User=root
    TimeoutStartSec=180
    Slice=workload.slice
    Nice=10
    OOMScoreAdjust=200
    [Install]
    WantedBy=multi-user.target
  '';

  home.file.".local/share/system-protection/evidence-collector.timer".text = ''
    [Unit]
    Description=Evidence Collector timer (daily 2:30 AM)
    [Timer]
    OnCalendar=*-*-* 02:30:00
    RandomizedDelaySec=5min
    Persistent=true
    [Install]
    WantedBy=timers.target
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installEvidenceCollector = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[evidence-collector] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    AWK=${pkgs.gawk}/bin/awk
    MKTEMP=${pkgs.coreutils}/bin/mktemp
    TEE=${pkgs.coreutils}/bin/tee
    MV=${pkgs.coreutils}/bin/mv
    CHMOD=${pkgs.coreutils}/bin/chmod
    CHOWN=${pkgs.coreutils}/bin/chown
    CP=${pkgs.coreutils}/bin/cp
    MKDIR=${pkgs.coreutils}/bin/mkdir
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[evidence-collector] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"
    SECRETS="$HOME/.config/home-manager/.secrets"

    # Read OO admin creds from sops-decrypted .secrets — same pattern as log-shipper.
    ZO_USER=""
    ZO_PASS=""
    if [ -r "$SECRETS" ]; then
      ZO_USER="$($AWK -F= '/^ZO_ROOT_USER_EMAIL=/ {sub(/^ZO_ROOT_USER_EMAIL=/,""); gsub(/^"|"$/,""); print; exit}' "$SECRETS")"
      ZO_PASS="$($AWK -F= '/^ZO_ROOT_USER_PASSWORD=/ {sub(/^ZO_ROOT_USER_PASSWORD=/,""); gsub(/^"|"$/,""); print; exit}' "$SECRETS")"
    fi
    if [ -z "$ZO_USER" ] || [ -z "$ZO_PASS" ]; then
      echo "[evidence-collector] ZO creds missing — script installed without OO push"
    fi

    $SUDO $MKDIR -p /opt/scripts /var/backups/evidence

    # Render script with creds inline (mode 0700 root:root). Literal
    # substitution via awk index() — same pattern as log-shipper.
    SH_OUT_TMP="$($SUDO $MKTEMP /tmp/evidence-collector.sh.XXXXXX)"
    "$AWK" -v zu="$ZO_USER" -v zp="$ZO_PASS" '
      {
        line = $0
        while ((i = index(line, "{ZO_USER}")) > 0)
          line = substr(line,1,i-1) zu substr(line,i+length("{ZO_USER}"))
        while ((i = index(line, "{ZO_PASS}")) > 0)
          line = substr(line,1,i-1) zp substr(line,i+length("{ZO_PASS}"))
        print line
      }
    ' "$SRC/evidence-collector.sh" | $SUDO $TEE "$SH_OUT_TMP" >/dev/null
    $SUDO $MV "$SH_OUT_TMP" /opt/scripts/evidence-collector.sh
    $SUDO $CHOWN root:root /opt/scripts/evidence-collector.sh
    $SUDO $CHMOD 0700 /opt/scripts/evidence-collector.sh

    # One-shot cleanup of deprecated heavy artifacts left by previous script
    # versions (vm-system.tar.gz pre-2026-04-20, journal-24h.json.gz pre-2026-05-05).
    # Idempotent — find -delete is a no-op on subsequent activations.
    $SUDO find /var/backups/evidence -maxdepth 2 -type f \
      \( -name 'vm-system.tar.gz' -o -name 'journal-24h.json.gz' \) -delete 2>/dev/null || true

    $SUDO $CP -f "$SRC/evidence-collector.service" /etc/systemd/system/evidence-collector.service
    $SUDO $CP -f "$SRC/evidence-collector.timer" /etc/systemd/system/evidence-collector.timer

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable evidence-collector.timer 2>/dev/null || true
    $SUDO systemctl start evidence-collector.timer 2>/dev/null || true

    echo "[evidence-collector] deployed: timer=daily@02:30 (lightweight + OO push)"
    ) || echo "[evidence-collector] FAILED — activation continues"
  '';
}
