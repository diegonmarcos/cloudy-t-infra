# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-gcp-proxy/src/pilot/network/etc-hosts-clean.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# vm-pilot/network/etc-hosts-clean.nix
#
# Asserts /etc/hosts contains NO loopback/internal hijacks for canonical service
# domains. Caddy on gcp-proxy is THE sole route owner — every hostname resolution
# from any VM must go through real DNS → Caddy → backend.
#
# Past hand-edits added entries like `127.0.0.1 mail.diegonmarcos.com` to oci-mail's
# /etc/hosts to "force local delivery" or shortcut Maddy hairpins. Those bypass
# Caddy and create silent inconsistencies (e.g. cypht trying mail.diegonmarcos.com
# for JMAP gets local Maddy with no JMAP listener — Fire Rule #1 violation).
#
# This module runs on every HM activation and idempotently strips any line in
# /etc/hosts that maps a "*.diegonmarcos.com" hostname (other than what /etc/hosts
# legitimately needs — localhost, the VM's own hostname). Real DNS resolution
# applies to everything else.
#
# Source-of-truth contract: routes are owned by Caddy (build-caddy.json derived
# from each service's build.json#proxy.primary). /etc/hosts has no business
# overriding those.
{ config, lib, pkgs, ... }:

let
  # Hostnames that are LEGITIMATELY allowed in /etc/hosts (won't be stripped).
  # localhost handled by libc; the VM's own hostname is set by cloud-init.
  # Add new exceptions here as data, never as code paths.
  allowedHosts = [
    # (none — all *.diegonmarcos.com lookups must go through DNS → Caddy)
  ];
in
{
  home.activation.etcHostsCleanCaddySoT = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # Subshell isolates `exit` so the not-writable early-return doesn't kill
    # the whole HM activation script (which would silently skip every later
    # activation entry — `home.activation.installLogShipper`,
    # `installJournalNtfy`, `installDataPublisher`, `installEvidenceCollector`,
    # ...). Surfaced 2026-05-05: log-shipper deployment failed to land
    # because etcHostsCleanCaddySoT's `exit 0` terminated `activate` early.
    (
      set -eu
      HOSTS=/etc/hosts
      [ -w "$HOSTS" ] || { echo "[etc-hosts-clean] /etc/hosts not writable, skipping"; exit 0; }

      # Match any line where the second token (or later) ends in diegonmarcos.com
      # and is not in the allow-list. Strip those lines in-place.
      TMP=$(${pkgs.coreutils}/bin/mktemp)
      ${pkgs.gawk}/bin/awk '
        {
          keep = 1
          for (i = 2; i <= NF; i++) {
            if ($i ~ /\.diegonmarcos\.com$/) {
              ${lib.concatMapStringsSep "\n              "
                (h: "if ($i == \"${h}\") continue;")
                allowedHosts}
              keep = 0
              break
            }
          }
          if (keep) print
        }
      ' "$HOSTS" > "$TMP"

      if ! ${pkgs.diffutils}/bin/cmp -s "$TMP" "$HOSTS"; then
        ${pkgs.coreutils}/bin/cat "$TMP" | ${pkgs.coreutils}/bin/install -m 644 /dev/stdin "$HOSTS"
        echo "[etc-hosts-clean] stripped *.diegonmarcos.com hijacks from /etc/hosts (Caddy is sole route owner)"
      fi
      ${pkgs.coreutils}/bin/rm -f "$TMP"
    ) || echo "[etc-hosts-clean] failed — activation continues"
  '';
}
