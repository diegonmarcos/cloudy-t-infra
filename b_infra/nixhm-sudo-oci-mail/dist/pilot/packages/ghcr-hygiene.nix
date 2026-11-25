# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-mail/src/pilot/packages/ghcr-hygiene.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# GHCR credential hygiene — clears stale short-lived workflow tokens.
#
# A ghs_ token is an ephemeral GitHub Actions GITHUB_TOKEN. When one is left
# behind in ~/.docker/config.json (e.g. by a prior `docker login` during a
# workflow), it EXPIRES but docker keeps sending it — so pulls of PUBLIC ghcr
# images fail with `denied: denied` instead of falling back to an anonymous
# token. This blocked hermes-agent's first deploy (public GHCR mirror).
#
# This activation removes the ghcr.io entry ONLY when its stored token is a
# short-lived ghs_ token, so anonymous pulls of public images work again. A
# real long-lived cred (ghp_/PAT) is left untouched.
{ config, lib, ... }:

{
  home.activation.ghcrHygiene = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    for CFG in "$HOME/.docker/config.json" /root/.docker/config.json; do
      SUDO=""
      case "$CFG" in /root/*)
        for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
          [ -x "$p" ] && SUDO="$p" && break
        done
        [ -z "$SUDO" ] && continue ;;
      esac
      $SUDO test -f "$CFG" || continue
      # Decode the ghcr.io auth blob; if the credential is a ghs_ workflow token, drop it.
      AUTH=$($SUDO grep -A2 '"ghcr.io"' "$CFG" 2>/dev/null | grep '"auth"' | head -1 | sed 's/.*"auth"[^"]*"\([^"]*\)".*/\1/')
      [ -z "$AUTH" ] && continue
      DECODED=$(printf '%s' "$AUTH" | base64 -d 2>/dev/null || true)
      case "$DECODED" in
        *:ghs_*)
          echo "[ghcr-hygiene] stale ghs_ token in $CFG — logging out ghcr.io"
          $SUDO docker logout ghcr.io >/dev/null 2>&1 || true ;;
        *)
          echo "[ghcr-hygiene] $CFG ghcr.io cred OK (not a ghs_ token)" ;;
      esac
    done
    ) || echo "[ghcr-hygiene] FAILED — activation continues"
  '';
}
