# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-apps/src/pilot/packages/packages-from-json.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Data-driven package installation + slice classification
#
# Reads system-packages.json → installs packages for the given scope
# → generates service classification lists for system-protection modules.
#
# Every package has a group. Every group has a slice. No orphans.
#
# Source of truth: system-packages.json
{ pkgs, lib, scope ? "cloud", ... }:

let
  data = builtins.fromJSON (builtins.readFile ./system-packages.json);

  # Resolve groups for this scope
  scopeData = data.scopes.${scope};
  activeGroupNames = scopeData.groups;
  activeGroups = map (name: data.groups.${name} // { _name = name; }) activeGroupNames;

  # Collect nix packages from all active groups
  resolvePackage = name:
    if builtins.hasAttr name pkgs
    then pkgs.${name}
    else builtins.trace "[system-packages] WARNING: package '${name}' not in nixpkgs" null;

  groupPackages = lib.concatMap (g:
    let resolved = map resolvePackage (g.packages or []);
    in lib.filter (p: p != null) resolved
  ) activeGroups;

  allPackages = groupPackages;

  # Build service → slice classification from groups
  collectServices = sliceName:
    lib.concatMap (g:
      if g.slice == sliceName then (g.services or []) else []
    ) activeGroups;

  # Merge: static slice patterns + group-derived service patterns
  kernelServices = (data.slices.kernel.service_patterns or []) ++ (collectServices "kernel");
  osEssentialsServices = (data.slices.os-essentials.service_patterns or []) ++ (collectServices "os-essentials");
  # workload = catch-all (everything not in kernel or os-essentials)

in {
  home.packages = allPackages;

  # Classification lists — Phase 1: write to -json suffix for diffing against hardcoded lists
  # Phase 2: remove suffix, replace hardcoded lists in layer2-identity.nix
  home.file.".local/share/system-protection/kernel-services-json.list".text =
    lib.concatStringsSep "\n" kernelServices;
  home.file.".local/share/system-protection/os-essentials-services-json.list".text =
    lib.concatStringsSep "\n" osEssentialsServices;
}
