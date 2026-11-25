# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/pilot/scripts/log-shipper.conf.tpl
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# log-shipper.conf — Fluent Bit config (template)
#
# Placeholders are substituted by vm-pilot/agents/log-shipper.nix at activation:
#   {HOSTNAME}        → output of `hostname -s`
#   {ZO_INGEST_TOKEN} → value from $HOME/.config/home-manager/.secrets
#                       (decrypted from _shared/secrets.yaml by build.sh secrets)
#
# Output target is the central OpenObserve at WG IP 10.0.0.6:5080 — no public
# DNS / Caddy dependency. Two streams keep host journals separate from
# container stdout/stderr.

[SERVICE]
    flush         5
    daemon        off
    # error, not info: with OpenObserve down every flush logs a retry line, and
    # the parser warnings below logged one per record -- ~170M/day into syslog
    # (2026-10-14). Only real errors are worth a log line.
    log_level     error
    parsers_file  {PARSERS_FILE}
    parsers_file  /opt/fluent-bit/parsers-local.conf
    # retry backoff: wait 10s..60s between attempts instead of hammering
    scheduler.base 10
    scheduler.cap  60
    storage.path  /var/lib/fluent-bit/storage
    storage.sync  normal
    storage.backlog.mem_limit 4M

[INPUT]
    Name             systemd
    # journald input had NO cap while tail did. Unbounded here is the leak path
    # measured 2026-09-02 (450 MB swapped). Pause instead of eating the host.
    Mem_Buf_Limit    8MB
    Tag              host.{HOSTNAME}
    DB               /var/lib/fluent-bit/journald.db
    Read_From_Tail   On
    Strip_Underscores On

[INPUT]
    Name             tail
    Tag              docker.{HOSTNAME}.*
    Path             /var/lib/docker/containers/*/*-json.log
    DB               /var/lib/fluent-bit/docker.db
    Path_Key         _docker_log_path
    Buffer_Max_Size  64KB
    Mem_Buf_Limit    8MB
    Skip_Long_Lines  On
    Refresh_Interval 5
    Rotate_Wait      30
    Parser           docker

[FILTER]
    Name   parser
    Match  docker.*
    Key_Name log
    # json_notime (parsers-local.conf): the bundled `json` parser has a Time_Format
    # that rejects docker's RFC3339 stamps and warned on every single record.
    Parser   json_notime
    Reserve_Data On
    Preserve_Key On

[OUTPUT]
    Name             http
    Match            host.*
    Host             10.0.0.6
    Port             5080
    URI              /api/default/host_journald/_json
    Format           json
    Json_Date_Key    _timestamp
    Json_Date_Format iso8601
    http_User        {ZO_USER}
    http_Passwd      {ZO_PASS}
    Retry_Limit      3
    # Buffer cap per output: with filesystem storage this bounds the on-disk
    # backlog; with the default memory storage it is the same ceiling in RAM.
    storage.total_limit_size 64M
    net.connect_timeout 5
    net.keepalive    on
    net.keepalive_idle_timeout 15
    net.keepalive_max_recycle  100

[OUTPUT]
    Name             http
    Match            docker.*
    Host             10.0.0.6
    Port             5080
    URI              /api/default/container_logs/_json
    Format           json
    Json_Date_Key    _timestamp
    Json_Date_Format iso8601
    http_User        {ZO_USER}
    http_Passwd      {ZO_PASS}
    Retry_Limit      3
    # Buffer cap per output: with filesystem storage this bounds the on-disk
    # backlog; with the default memory storage it is the same ceiling in RAM.
    storage.total_limit_size 64M
    net.connect_timeout 5
    net.keepalive    on
    net.keepalive_idle_timeout 15
    net.keepalive_max_recycle  100

# Built-in parsers `docker` and `json` are loaded from Fluent Bit's
# bundled parsers.conf — referenced via parsers_file in [SERVICE]
# below. Custom [PARSER] sections are not valid in the main config.
