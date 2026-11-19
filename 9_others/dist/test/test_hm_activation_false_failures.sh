#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_hm_activation_false_failures.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: two home-manager activation steps no longer report failures that did
# not happen (2026-11-18, oci-analytics run 44419144605, both with no error
# printed above them):
#   [shell-path] FAILED — the subshell's last command was
#     `[ ! -e link ] && ln ...`, which returns 1 once every link exists.
#   [tier1-watchdog] WARNING: failed to start — a single is-active check 2 s
#     after `restart --no-block` raced the unit (it was active 5 s later).
# Extracts each activation snippet from the REAL .nix module and runs it
# against a fake root with fake sudo / systemctl / journalctl / sleep.
set -u
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
M="$REPO_ROOT/b_infra/_shared/vm-pilot/src/modules"
SP="$M/infra/shell-path.nix"; T1="$M/protection/tier1-apps.nix"
for f in "$SP" "$T1"; do [ -f "$f" ] || { echo "::error::$f not found"; exit 1; }; done

W="$(mktemp -d "${TMPDIR:-/tmp}/hm-false-fail.XXXXXX")"; trap 'rm -rf "$W"' EXIT
FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -12 | sed 's/^/       | /'; FAIL=1; }

# snippet <file> <activation-name>: the '' … '' body, every absolute system
# path moved under $R, sudo discovery pointed at the fake.
snippet() {
    awk -v n="home.activation.$2 " 'index($0, n) {f=1; next} f && /^  '"''"';$/ {exit} f' "$1" \
    | sed -e 's|for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do|for p in "$FAKESUDO"; do|' \
          -e 's|/etc/|$R/etc/|g; s|/nix/var/|$R/nix/var/|g; s|/opt/scripts|$R/opt/scripts|g' \
          -e 's|\${config.home.username}|ubuntu|g; s|\${tier1List}|caddy-public|g; s|\${toString tier1ReserveMB}|64|g'
}

mkdir -p "$W/bin"
cat > "$W/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
# systemctl: `show -p ActiveState --value` walks $W/states (one per call,
# last repeats); every other verb succeeds.
cat > "$W/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"show -p ActiveState --value"*)
    n=$(( $(cat "$W/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$W/n"
    s=$(sed -n "${n}p" "$W/states"); [ -n "$s" ] || s=$(tail -1 "$W/states"); echo "$s" ;;
  *"is-active"*) s=$(sed -n "1p" "$W/states"); [ "$s" = active ] ;;
  *) exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "unit log line: ExecStart failed"\n' > "$W/bin/journalctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/sleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/visudo"
chmod +x "$W/bin/"*

run() {  # <script-file> → OUT, RC
    local _s="$1"
    OUT=$(cd "$W" && PATH="$W/bin:$PATH" W="$W" R="$W/root" HOME="$W/home" FAKESUDO="$W/bin/sudo" \
          bash -c 'set -eu -o pipefail; . "$1"' _ "$_s" 2>&1); RC=$?
}

# ── shell-path ─────────────────────────────────────────────────────────
snippet "$SP" nixPathEtcEnvironment > "$W/sp.sh"
grep -q 'nix-channel' "$W/sp.sh" || bad "could not extract nixPathEtcEnvironment"
rm -rf "$W/root"; mkdir -p "$W/root/etc" "$W/root/nix/var/nix/profiles/default/bin"
: > "$W/root/nix/var/nix/profiles/default/bin/nix"; chmod +x "$W/root/nix/var/nix/profiles/default/bin/nix"
run "$W/sp.sh"
[ -L "$W/root/nix/var/nix/profiles/default/bin/nix-build" ] && grep -q 'nix-profile/bin' "$W/root/etc/environment" \
  && ! printf '%s\n' "$OUT" | grep -q FAILED \
  && ok "shell-path first run: links + /etc/environment created, no FAILED" || bad "shell-path first run" "$OUT"
run "$W/sp.sh"
printf '%s\n' "$OUT" | grep -q 'already has nix PATH' && ! printf '%s\n' "$OUT" | grep -q FAILED \
  && ok "shell-path converged re-run (all links exist): no false FAILED" || bad "shell-path converged re-run says FAILED" "$OUT"
rm -rf "$W/root/etc"; : > "$W/root/etc"   # /etc is a file → real errors
run "$W/sp.sh"
# Inside `( … ) || echo FAILED` bash ignores errexit, so a mid-script error
# never reaches the FAILED line (pre-existing, true of every module using the
# pattern); what must hold is that the error itself is still printed.
printf '%s\n' "$OUT" | grep -q 'Not a directory' \
  && ok "shell-path real error is still printed to the log" || bad "shell-path hid a real error" "$OUT"

# ── tier1-watchdog ─────────────────────────────────────────────────────
snippet "$T1" installTier1Watchdog > "$W/t1.sh"
grep -q 'ActiveState' "$W/t1.sh" || bad "could not extract installTier1Watchdog (or it has no state poll)"
t1_case() {  # <states...>
    rm -rf "$W/root" "$W/home" "$W/n"; mkdir -p "$W/root/etc/systemd/system" "$W/home/.local/share/system-protection"
    for f in tier1-watchdog.sh tier1-watchdog.service tier1.slice; do : > "$W/home/.local/share/system-protection/$f"; done
    printf '%s\n' "$@" > "$W/states"; run "$W/t1.sh"
}
t1_case activating activating activating active
printf '%s\n' "$OUT" | grep -q 'ARMED' && ! printf '%s\n' "$OUT" | grep -q WARNING \
  && ok "tier1: unit active on the 4th poll (≈6 s) → ARMED, no false WARNING" || bad "tier1 slow start" "$OUT"
t1_case activating failed
printf '%s\n' "$OUT" | grep -q 'WARNING: failed to start (state: failed)' && printf '%s\n' "$OUT" | grep -q 'ExecStart failed' \
  && [ "$(cat "$W/n")" -eq 2 ] \
  && ok "tier1: unit failed → WARNING with state + journal, stops polling at once" || bad "tier1 failed unit" "$OUT"
t1_case activating
printf '%s\n' "$OUT" | grep -q 'WARNING: failed to start (state: activating)' && [ "$(cat "$W/n")" -eq 15 ] \
  && ok "tier1: never active → WARNING after the 15-poll window" || bad "tier1 never active" "$OUT"

[ "$FAIL" -eq 0 ] && echo "PASS: hm activation false failures" || echo "FAIL: hm activation false failures"
exit "$FAIL"
