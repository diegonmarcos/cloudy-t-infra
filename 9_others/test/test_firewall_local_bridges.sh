#!/usr/bin/env bash
# #1821: the generated ssh-firewall.sh (the live INPUT chain on every VM)
# accepts local Docker bridge interfaces, so bridge-network containers can
# reach host-network services and the host resolver on the VM's own wg IPs.
#   F1 docker0 and br+ ACCEPT rules are present
#   F2 they sit before the final `iptables -P INPUT DROP`
#   F3 no source-range wildcard was added (interface-scoped only)
set -euo pipefail
cd "$(dirname "$0")/../.."
f=b_infra/_shared/vm-pilot/src/modules/security/sshd-hardening.nix
fail=0
ln_d=$(grep -n 'iptables -A INPUT -i docker0 -j ACCEPT' "$f" | head -1 | cut -d: -f1 || true)
ln_b=$(grep -n 'iptables -A INPUT -i br+ -j ACCEPT' "$f" | head -1 | cut -d: -f1 || true)
ln_p=$(grep -n 'iptables -P INPUT DROP' "$f" | head -1 | cut -d: -f1 || true)
if [ -n "$ln_d" ] && [ -n "$ln_b" ]; then echo "PASS F1 bridge ACCEPT rules present"; else echo "FAIL F1 missing docker0/br+ ACCEPT"; fail=1; fi
if [ -n "$ln_d" ] && [ -n "$ln_b" ] && [ -n "$ln_p" ] && [ "$ln_d" -lt "$ln_p" ] && [ "$ln_b" -lt "$ln_p" ]; then echo "PASS F2 before INPUT DROP"; else echo "FAIL F2 order"; fail=1; fi
if grep -qE 'iptables -A INPUT -s (172\.16\.0\.0/12|192\.168\.0\.0/16|0\.0\.0\.0/0) ' "$f"; then echo "FAIL F3 source-range wildcard added"; fail=1; else echo "PASS F3 interface-scoped only"; fi
exit $fail
