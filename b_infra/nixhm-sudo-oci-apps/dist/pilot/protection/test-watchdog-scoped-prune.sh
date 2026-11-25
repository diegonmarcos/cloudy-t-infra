#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/protection/test-watchdog-scoped-prune.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test #393: the disk-watchdog's docker prunes must be SCOPED, so that automatic
# disk pressure can never delete a declared container, a tagged fleet image, or
# any volume.
#
# WHY this test exists
# ────────────────────
# infra/prune-maintenance.nix carries the scoped filter and the comment explaining
# it. watchdog.nix — its sibling, running every 5 minutes as root — never received
# it. On 2026-09-16 that gap deleted matomo off oci-apps: healthy at
# 2026-09-15T22:39:58Z, then `container prune` took the container at 05:24:46 and
# the CRIT branch untagged matomo-binaries:latest and matomo-configs:latest at
# 06:30:21. It freed 22.44MB against a ~19GB shortfall.
#
# protection/guardrails.nix already BLOCKS these operations — but only as a PATH
# wrapper in ~/.local/bin, which a root systemd unit never traverses. So the ban
# has to be asserted against this source file directly. That is this test.
#
# Run:  sh test-watchdog-scoped-prune.sh
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/watchdog.nix"
SIB="$(cd "$(dirname "$0")" && pwd)/../infra/prune-maintenance.nix"
PET="$(cd "$(dirname "$0")" && pwd)/watchdog-petter.sh"
fail=0
ok()   { printf "  [ok] %s\n"   "$1"; }
nope() { printf "  [FAIL] %s\n" "$1"; fail=1; }

echo "test-watchdog-scoped-prune: $SRC"

# Only the actual prune command lines matter. Every rationale comment in this
# module quotes the banned flags by name, and matching those would make the test
# pass or fail on prose. Strip comments first, then assert against code only.
CODE=$(sed 's/[[:space:]]*#.*$//' "$SRC")

# Checks 1-4 and 7 apply to EVERY automatic prune path, not just this module:
# #447 fixed the flag here and left infra/prune-maintenance.nix on the
# deprecated one, because this tester only ever read watchdog.nix. A rule
# asserted against one of its three call sites is a rule for that site only.
cli_checks() {  # cli_checks <label> <code>
    _l=$1; CODE=$2
    # ── 1. No unscoped `container prune` ──────────────────────────────────
    # A bare `docker container prune -f` takes every stopped container, declared or not.
    if printf '%s\n' "$CODE" | grep -q 'docker container prune' \
       && ! printf '%s\n' "$CODE" | grep 'docker container prune' \
            | grep -q 'label!=com.docker.compose.project'; then
        nope "[$_l] container prune is present but NOT filtered on label!=com.docker.compose.project"
    else
        ok "[$_l] container prune is absent or label-scoped"
    fi

    # ── 2. No volume pruning anywhere on the automatic path ───────────────
    # Volumes are the databases. There is no safe automatic form of this.
    if printf '%s\n' "$CODE" | grep -qE 'docker[[:space:]]+volume[[:space:]]+(prune|rm)'; then
        nope "[$_l] watchdog still prunes/removes docker volumes — databases live there"
    else
        ok "[$_l] no docker volume prune/rm on the automatic path"
    fi

    # ── 3. No `image prune -a` — `-a` drops TAGGED images ─────────────────
    # Matches -a, -af, -fa and --all. Dangling-only pruning (no -a) is fine.
    if printf '%s\n' "$CODE" | grep 'docker image prune' \
         | grep -qE '(^|[[:space:]])-(-all|[a-z]*a[a-z]*)([[:space:]]|$)'; then
        nope "[$_l] image prune uses -a/--all — that deletes TAGGED fleet deploy artifacts"
    else
        ok "[$_l] image prune is dangling-only (no -a/--all)"
    fi

    # ── 4. No `docker system prune` ───────────────────────────────────────
    # Its container sweep cannot be scoped as tightly as the label filter, so it
    # silently re-opens the hole check 1 closes.
    if printf '%s\n' "$CODE" | grep -q 'docker system prune'; then
        nope "[$_l] docker system prune is back — it re-opens the unscoped container sweep"
    else
        ok "[$_l] no docker system prune"
    fi

    # ── 7. No stale docker flag — --keep-storage is deprecated, --max-storage is rejected ──
    # Verified against the live oci-apps docker (27.5.1) on 2026-09-17:
    #   --keep-storage    still parses but warns "Flag --keep-storage has been
    #                     deprecated ... changed to max-storage"
    #   --max-storage     "unknown flag" — rejected outright
    #   --max-used-space  current flag ("Maximum amount of disk space allowed to
    #                     keep for cache") — the same 1G-keeper as --keep-storage=1G
    if printf '%s\n' "$CODE" | grep -qE '\-\-keep-storage|\-\-max-storage'; then
        nope "[$_l] builder prune passes a stale flag (--keep-storage or --max-storage) — the current one is --max-used-space"
    else
        ok "[$_l] no stale builder-prune flag (--keep-storage/--max-storage)"
    fi
    if printf '%s\n' "$CODE" | grep -q '\-\-max-used-space'; then
        ok "[$_l] builder prune uses the current --max-used-space"
    else
        nope "[$_l] builder prune does not pass --max-used-space — the 1G build-cache cap is gone"
    fi
}

cli_checks "watchdog.nix" "$CODE"
cli_checks "prune-maintenance.nix" "$(sed 's/[[:space:]]*#.*$//' "$SIB")"
CODE=$(sed 's/[[:space:]]*#.*$//' "$SRC")

# ── 1b. watchdog-petter.sh — the same rules in docker-API form ────────
# It prunes through the socket (curl POST), not the CLI, so the CLI greps
# above cannot see it. #353 measured its unfiltered /containers/prune as the
# September umami/matomo killer on oci-analytics. Its unit is disabled by this
# module's activation, but the script still ships to /opt/scripts.
PCODE=$(sed 's/^[[:space:]]*#.*$//' "$PET")
_cp=$(printf '%s\n' "$PCODE" | grep -c '/containers/prune' || true)
_cps=$(printf '%s\n' "$PCODE" | grep '/containers/prune' | grep -c '%22label%21%22%3A%7B%22com.docker.compose.project%22' || true)
if [ "$_cp" -gt 0 ] && [ "$_cp" -eq "$_cps" ]; then
    ok "[watchdog-petter.sh] all $_cp /containers/prune calls are label!=com.docker.compose.project scoped"
else
    nope "[watchdog-petter.sh] $_cps of $_cp /containers/prune calls are label-scoped — an unscoped one deletes stopped declared services"
fi
if printf '%s\n' "$PCODE" | grep -q '/volumes/prune'; then
    nope "[watchdog-petter.sh] POSTs /volumes/prune — databases live there"
else
    ok "[watchdog-petter.sh] no /volumes/prune"
fi
if printf '%s\n' "$PCODE" | grep '/images/prune' | grep -qE 'dangling%22%3A%7B%22false|dangling=false'; then
    nope "[watchdog-petter.sh] /images/prune with dangling=false — that deletes TAGGED images"
else
    ok "[watchdog-petter.sh] /images/prune is dangling-only"
fi

# ── 5. CRIT must still be able to free something ──────────────────────
# A watchdog that can no longer reclaim anything is also a failure. Builder
# cache is pure derived data and is the safe aggressive lever.
if printf '%s\n' "$CODE" | grep -q 'docker builder prune -af'; then
    ok "CRIT retains an aggressive but safe lever (builder prune -af)"
else
    nope "CRIT has no aggressive reclaim left — builder prune -af is missing"
fi

# ── 6. The sibling this was copied from must still carry the pattern ──
# If prune-maintenance.nix ever loses the filter, this module's comments point
# at a pattern that no longer exists and the next agent re-invents a second one.
if grep -q 'label!=com.docker.compose.project' "$SIB"; then
    ok "sibling infra/prune-maintenance.nix still carries the reference pattern"
else
    nope "sibling infra/prune-maintenance.nix lost the label filter"
fi

# ── 8. The watchdog keeps a durable action log OUTSIDE the journal ──
# journalctl --vacuum erases the journal, which was the only record of what the
# watchdog deleted and why (on oci-apps 2026-09-16 it ate 16 days, including
# the run that had just reclaimed 12.13GB). #447: every deletion appends to
# WATCHDOG_LOG, which the vacuum cannot reach.
if printf '%s\n' "$CODE" | grep -q 'WATCHDOG_LOG='; then
    ok "durable action log defined (WATCHDOG_LOG)"
else
    nope "no WATCHDOG_LOG — the journal vacuum would erase the watchdog's own action record"
fi
# The directive must be Nix-escaped in this source file (''$ before the brace):
# a bare ${ would be parsed as Nix interpolation and would break the entire
# watchdog module at eval time — a latent build error, not a runtime one.
if printf '%s\n' "$CODE" | grep -q "WATCHDOG_LOG=''\${"; then
    ok "WATCHDOG_LOG is Nix-escaped (double single-quote before the brace) — the module still evaluates"
else
    nope "WATCHDOG_LOG uses a bare dollar-brace in nix source — Nix interpolation breaks the module eval"
fi

# ── 9. Every journal vacuum is paired with a record call ──
# The vacuum is the one deletion that erases its own evidence; each must be
# mirrored by a record line so the audit survives the vacuum.
_vac_n=$(printf '%s\n' "$CODE" | grep -c 'journalctl --vacuum' || true)
_rec_n=$(printf '%s\n' "$CODE" | grep -c 'record "journal"' || true)
if [ "$_vac_n" -gt 0 ] && [ "$_vac_n" -eq "$_rec_n" ]; then
    ok "all $_vac_n journal vacuums are paired with a record call"
else
    nope "journal vacuums ($_vac_n) vs journal record calls ($_rec_n) are out of balance"
fi

# ── 10. #413: no journal vacuum may go below the declared retention floor ──
# --vacuum-size / --vacuum-files delete the OLDEST archives until a volume cap
# is met, whatever their age: on oci-apps 2026-09-16 that erased 16 days. Only
# --vacuum-time can honour a floor, and its value must be the declared one
# (config.json native.protection.journal_retention_floor_days), never a literal.
# Applies to all three automatic vacuum sites, for the same reason as 1-4/7.
floor_checks() {  # floor_checks <label> <code> <required-arg>
    _l=$1; _c=$2; _want=$3
    _vl=$(printf '%s\n' "$_c" | grep 'journalctl --vacuum' || true)
    _n=$(printf '%s\n' "$_vl" | grep -c 'journalctl --vacuum' || true)
    if [ "$_n" -eq 0 ]; then
        nope "[$_l] no journal vacuum found — this check would pass on nothing"
        return
    fi
    if printf '%s\n' "$_c" | grep -qE -- '--vacuum-(size|files)'; then
        nope "[$_l] journal vacuum by size/files — deletes by volume regardless of age, below any retention floor"
    else
        ok "[$_l] no --vacuum-size/--vacuum-files"
    fi
    _good=$(printf '%s\n' "$_vl" | grep -cF -- "--vacuum-time=$_want" || true)
    if [ "$_good" -eq "$_n" ]; then
        ok "[$_l] all $_n journal vacuums are --vacuum-time=$_want (the declared floor)"
    else
        nope "[$_l] $_good of $_n journal vacuums use --vacuum-time=$_want — the rest bypass the declared floor"
    fi
}
PM_CODE=$(sed 's/[[:space:]]*#.*$//' "$SIB")
floor_checks "watchdog.nix" "$CODE" '${toString journalFloorDays}d'
floor_checks "prune-maintenance.nix" "$PM_CODE" '${toString journalFloorDays}d'
floor_checks "watchdog-petter.sh" "$PCODE" '"${JOURNAL_FLOOR_DAYS}d"'
# journalFloorDays must be bound to the declared key in both Nix modules, and
# the petter must receive it from its unit — else the checks above are names only.
for _pair in "watchdog.nix:$CODE" "prune-maintenance.nix:$PM_CODE"; do
    _l=${_pair%%:*}; _c=${_pair#*:}
    # Same line, not -A1: the next line carries the key name in a throw message /
    # fallback, which made a rebind to another key pass (mutation-caught).
    if printf '%s\n' "$_c" | grep -qE 'journalFloorDays = [^;]*journal_retention_floor_days'; then
        ok "[$_l] journalFloorDays is read from journal_retention_floor_days"
    else
        nope "[$_l] journalFloorDays is not bound to journal_retention_floor_days"
    fi
done
if printf '%s\n' "$CODE" | grep -qF 'Environment=JOURNAL_FLOOR_DAYS=${toString journalFloorDays}'; then
    ok "[watchdog-petter.sh] its unit is given JOURNAL_FLOOR_DAYS from the declared floor"
else
    nope "[watchdog-petter.sh] unit does not pass JOURNAL_FLOOR_DAYS — the petter's vacuum would be skipped or unbounded"
fi
# The DERIVED value every VM actually gets (consolidated snapshot the modules
# read: per-VM override over native default) must be a positive whole number of
# days. 0 or a missing key would make --vacuum-time=0d / eval-throw.
CONS="$(cd "$(dirname "$0")/.." && pwd)/_cloud-data-consolidated.json"
if command -v jq >/dev/null 2>&1; then
    _bad=$(jq -r '(.native.protection.journal_retention_floor_days) as $d
        | (._home_manager.vms // {}) | to_entries[]
        | ((.value.protection // {}).journal_retention_floor_days // $d) as $f
        | select(($f|type) != "number" or $f < 1 or ($f|floor) != $f) | "\(.key)=\($f)"' "$CONS" 2>&1)
    _vms=$(jq -r '(._home_manager.vms // {}) | length' "$CONS" 2>/dev/null || echo 0)
    if [ -z "$_bad" ] && [ "${_vms:-0}" -gt 0 ]; then
        ok "every one of $_vms VMs resolves a positive whole-day journal floor in the consolidated data"
    else
        nope "journal floor missing/invalid in consolidated data (vms=$_vms): $_bad"
    fi
else
    nope "jq missing — cannot read the derived journal floor"
fi

echo
[ "$fail" -eq 0 ] && echo "test-watchdog-scoped-prune: PASS" && exit 0
echo "test-watchdog-scoped-prune: FAIL"
exit 1
