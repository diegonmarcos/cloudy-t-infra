# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/security/secrets-subst.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# secrets-subst.nix — Generic secret substitution for home-manager configs
#
# Mimics Docker's env_file + container init.sh pattern, but for HM activation.
# Processes .tpl template files, replacing ${VAR} placeholders with values
# from .secrets (KEY=VALUE), using awk index() (literal, no regex).
#
# Flow:
#   1. Nix generates config.tpl with ${SECRET_NAME} placeholders (committed to git)
#   2. build.sh secrets → decrypts secrets.yaml → .secrets (KEY=VALUE)
#   3. This activation script reads .secrets → awk-substitutes into final config
#
# Template registration:
#   Import this module with a list of { template, output, mode } entries.
#   Templates are paths relative to ~/.config/home-manager/
#
# Usage:
#   imports = [
#     (import ./secrets-subst.nix {
#       templates = [
#         { template = "templates/mcp.json.tpl"; output = ".mcp.json"; mode = "600"; }
#         { template = "templates/foo.conf.tpl"; output = ".config/foo/config"; mode = "644"; }
#       ];
#     })
#   ];
#
{ templates ? [] }:

{ lib, ... }:

let
  # Build the template list as a space-separated string for shell iteration
  # Format: template:output:mode (colon-separated triple)
  templateList = lib.concatStringsSep " " (map (t:
    "${t.template}:${t.output}:${t.mode or "600"}"
  ) templates);
in
{
  home.activation.secretsSubst = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    (
    trap 'echo "[secrets-subst] FAILED at line $LINENO (''${FUNCNAME[0]:-main}): $BASH_COMMAND" >&2' ERR
    SS_LOG="[secrets-subst]"
    HM_DIR="$HOME/.config/home-manager"
    SECRETS="$HM_DIR/.secrets"

    if [ ! -f "$SECRETS" ]; then
      echo "$SS_LOG No .secrets file — skipping substitution"
      exit 0
    fi

    TEMPLATES="${templateList}"
    if [ -z "$TEMPLATES" ]; then
      echo "$SS_LOG No templates registered — skipping"
      exit 0
    fi

    # ── awk index() substitution (literal string, no regex) ──
    # Same proven pattern as Authelia's init.sh
    # Usage: subst <file> VAR1 VAR2 ...
    subst() {
      _file="$1"; shift
      for _var in "$@"; do
        _val=$(grep "^''${_var}=" "$SECRETS" | head -1 | cut -d= -f2-)
        if [ -z "$_val" ]; then
          echo "$SS_LOG WARNING: $''${_var} not found in .secrets — leaving placeholder"
          continue
        fi
        awk -v pat="\''${''${_var}}" -v rep="$_val" '{
          while (i = index($0, pat)) {
            $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
          }
          print
        }' "$_file" > "$_file.tmp"
        mv "$_file.tmp" "$_file"
      done
    }

    # ── Process each registered template ──
    for entry in $TEMPLATES; do
      TPL="''${entry%%:*}"
      rest="''${entry#*:}"
      OUTPUT="''${rest%%:*}"
      MODE="''${rest#*:}"

      TPL_PATH="$HM_DIR/$TPL"
      OUTPUT_PATH="$HOME/$OUTPUT"

      if [ ! -f "$TPL_PATH" ]; then
        echo "$SS_LOG WARNING: Template $TPL not found — skipping"
        continue
      fi

      # Create output directory if needed
      OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
      mkdir -p "$OUTPUT_DIR"

      # Copy template to output location
      cp "$TPL_PATH" "$OUTPUT_PATH"

      # Extract ${VAR} placeholders from template
      VARS=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$OUTPUT_PATH" 2>/dev/null \
        | sed 's/\${\(.*\)}/\1/' | sort -u || true)

      if [ -z "$VARS" ]; then
        echo "$SS_LOG $TPL → $OUTPUT (no placeholders)"
      else
        subst "$OUTPUT_PATH" $VARS
        echo "$SS_LOG $TPL → $OUTPUT ($(echo "$VARS" | wc -w) vars substituted)"
      fi

      chmod "$MODE" "$OUTPUT_PATH"
    done

    echo "$SS_LOG Done"
    )
  '';
}
