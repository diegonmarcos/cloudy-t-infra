# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/infra/managed-header.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# managed-header.nix — Injects a "DO NOT EDIT" header into generated files.
# Single source of truth for the declarative environment banner.
#
# Usage:
#   let managed = import ./managed-header.nix { inherit lib; repo = "unix/bb_flakes_termux"; };
#   in {
#     # For home.file with inline text:
#     home.file.".local/bin/foo" = managed.wrap {
#       source = "modules/my-module.nix";
#       text = "#!/bin/sh\necho hello";
#       executable = true;  # passed through to home.file
#     };
#
#     # For raw text injection (e.g. inside mkWrapper):
#     text = managed.inject {
#       source = "modules/guardrails.nix";
#       text = "#!/bin/sh\n...";
#     };
#   }
#
{ lib, repo }:

let
  # Detect comment style from file path extension
  commentStyle = path: let
    ext = lib.last (lib.splitString "." path);
  in
    if builtins.elem ext [ "html" "xml" "svg" ] then "html"
    else if builtins.elem ext [ "js" "ts" "mjs" "cjs" "jsx" "tsx" "css" "scss" ] then "slash"
    else "hash";

  # Build the header block for a given comment style
  mkHeader = { style, source, rebuild }: let
    line1 = "DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY";
    line2 = "AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!";
    line3 = "Source: ~/git/${repo}/${source}";
    line4 = "Rebuild: ~/git/${repo}/${rebuild}";
  in
    if style == "html" then ''
      <!-- ╔══════════════════════════════════════════════════════════════════╗
           ║ ${line1}  ║
           ║ ${line2}               ║
           ╠══════════════════════════════════════════════════════════════════╣
           ║ ${line3}
           ║ ${line4}
           ╚══════════════════════════════════════════════════════════════════╝ -->
    ''
    else if style == "slash" then ''
      // ╔══════════════════════════════════════════════════════════════════╗
      // ║ ${line1}  ║
      // ║ ${line2}               ║
      // ╠══════════════════════════════════════════════════════════════════╣
      // ║ ${line3}
      // ║ ${line4}
      // ╚══════════════════════════════════════════════════════════════════╝
    ''
    else ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ ${line1}  ║
      # ║ ${line2}               ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ ${line3}
      # ║ ${line4}
      # ╚══════════════════════════════════════════════════════════════════╝
    '';

  # Insert header after shebang (if present), otherwise at top
  injectHeader = { path ? "default.sh", source, rebuild ? "build.sh switch", text }: let
    style = commentStyle path;
    header = mkHeader { inherit style source rebuild; };
    lines = lib.splitString "\n" text;
    firstLine = builtins.head lines;
    hasShebang = lib.hasPrefix "#!" firstLine;
    rest = builtins.concatStringsSep "\n" (builtins.tail lines);
  in
    if hasShebang then
      firstLine + "\n" + header + rest
    else
      header + text;

in {
  # inject: returns modified text string with header inserted
  # Use this when you build text yourself (e.g. guardrails mkWrapper)
  inject = injectHeader;

  # wrap: returns a home.file attrset with header injected into .text
  # Use this for home.file."path" = managed.wrap { ... };
  wrap = { source, text, rebuild ? "build.sh switch", path ? "default.sh", ... }@args:
    let passthrough = builtins.removeAttrs args [ "source" "rebuild" "path" ];
    in passthrough // {
      text = injectHeader { inherit path source rebuild text; };
    };
}
