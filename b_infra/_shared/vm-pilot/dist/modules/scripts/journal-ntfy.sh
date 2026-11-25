#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/scripts/journal-ntfy.sh
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# journal-ntfy — Phase 3: severity-routed ntfy publisher.
# Routes journal events to the correct ntfy topic by unit pattern + severity.
# Dedup: 1 msg per (unit, topic) per RATE_SECONDS window to prevent flooding.
# Topics match infra-obs_ntfy/build.json taxonomy (data-driven SoT).
set -eu

NTFY_BASE="${NTFY_BASE:-https://rss.diegonmarcos.com}"
NTFY_WG_BASE="${NTFY_WG_BASE:-http://10.0.0.6:8090}"
VM=$(hostname -s 2>/dev/null || echo "unknown")
RATE_DIR="/tmp/journal-ntfy-rate"
RATE_SECONDS="${RATE_SECONDS:-300}"

mkdir -p "$RATE_DIR"

# ntfy_post <priority 1-5> <topic> <title> <body>
ntfy_post() {
  _p="$1"; _t="$2"; _title="$3"; _body="$4"
  # Try WG-direct first (lower latency), fall back to public edge
  for _base in "$NTFY_WG_BASE" "$NTFY_BASE"; do
    curl -sf --max-time 5 -X POST "$_base/$_t" \
      -H "Title: [$VM] $_title" \
      -H "Priority: $_p" \
      -H "Tags: journal,$VM" \
      -d "$_body" >/dev/null 2>&1 && return 0 || true
  done
  return 1
}

# Route to the right topic + priority based on unit name pattern and severity.
# Returns: "<priority> <topic>"
route() {
  _unit="$1"; _sev="$2"
  case "$_unit" in
    load-shedder|tier1-watchdog)    echo "5 health_resources" ;;
    wg-quick*|wireguard*)           echo "5 health_mesh" ;;
    docker*|containerd*)            echo "4 health_containers" ;;
    sshd|dropbear|ssh*)             echo "4 health_mesh" ;;
    maddy|stalwart|mail-puller*)    echo "4 health_endpoints" ;;
    caddy|introspect-proxy|authelia) echo "4 health_endpoints" ;;
    crowdsec|fail2ban)              echo "4 sec_audit" ;;
    fluent-bit|log-shipper)         echo "3 health_resources" ;;
    health-agent|evidence-collect*) echo "2 health_resources" ;;
    dagu*)                          echo "3 deploy_ship" ;;
    *)
      # Severity-based fallback for unrecognised units
      case "$_sev" in
        emerg|alert|crit) echo "5 health_resources" ;;
        err)              echo "4 health_resources" ;;
        *)                echo "3 health_resources" ;;
      esac
      ;;
  esac
}

# Tail warnings AND errors (previously errors-only missed WG reconnect attempts
# and disk pressure signals that show as warnings before becoming critical).
journalctl -p warning -f --no-hostname -o short-precise 2>/dev/null | \
while IFS= read -r line; do
  # Extract unit name from journalctl short-precise format (field ending .service)
  unit=$(printf '%s' "$line" | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /[a-z].*\.service$/) {
      gsub(/\.service$/,"",$i); print $i; exit
    }}')
  [ -z "$unit" ] && unit="unknown"

  # Extract severity keyword from line prefix
  sev="err"
  case "$line" in
    *emerg*|*"<0>"*) sev="emerg" ;;
    *alert*|*"<1>"*) sev="alert" ;;
    *crit*|*"<2>"*)  sev="crit"  ;;
    *" err"*|*"<3>"*) sev="err"  ;;
    *warning*|*"<4>"*) sev="warning" ;;
  esac

  routing=$(route "$unit" "$sev")
  prio=$(printf '%s' "$routing" | cut -d' ' -f1)
  topic=$(printf '%s' "$routing" | cut -d' ' -f2)

  # Rate limit: per (unit, topic) pair — prevents flooding on repeat errors
  rate_key=$(printf '%s_%s' "$unit" "$topic" | tr '/' '_')
  rate_file="$RATE_DIR/$rate_key"
  if [ -f "$rate_file" ]; then
    last=$(cat "$rate_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$((now - last))
    [ "$elapsed" -lt "$RATE_SECONDS" ] && continue
  fi

  date +%s > "$rate_file"
  ntfy_post "$prio" "$topic" "$unit ($sev)" "$line" || true
done
