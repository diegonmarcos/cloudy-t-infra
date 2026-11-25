# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : src/modules/packages/node-npm-deps-cloud.nix
# ║   Engine : b_infra/_shared/vm-pilot/build.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Cloud npm dependencies — merged from _cloud-data-consolidated.json[.deps] at activation time.
# 2026-04-27 migrated: cloud-data-deps.json → _cloud-data-consolidated.json[.deps]
{ config, lib, pkgs, ... }:

let
  nodejs = pkgs.nodejs_22;
in {
  options.nodeNpmDeps.cloud = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Cloud service npm dependencies (auto-merged from _cloud-data-consolidated.json[.deps])";
  };

  # Activation: read _cloud-data-consolidated.json[.deps] → populate nodeNpmDeps.cloud
  # Path-priority chain: in-image bundle > runtime deploy dir > legacy clone
  config.home.activation.mergeCloudDeps = lib.hm.dag.entryBefore ["sharedNodeModules"] ''
    CLOUD_DEPS=""
    for _p in \
      /app/_cloud-data-consolidated.json \
      /opt/containers/cloud-data/_cloud-data-consolidated.json \
      "$HOME/git/cloud-t-infra/1_cloud-configs/dist/_cloud-data-consolidated.json" \
      "$HOME/git/cloud-t-infra/cloud-data/_cloud-data-consolidated.json"; do
      [ -f "$_p" ] && CLOUD_DEPS="$_p" && break
    done
    CLOUD_OUT="$HOME/.node_modules/.cloud-deps-merged.json"

    if [ -n "$CLOUD_DEPS" ] && [ -f "$CLOUD_DEPS" ]; then
      PATH="${nodejs}/bin:$PATH" ${nodejs}/bin/node -e "
        const fs = require('fs');
        const deps = {};
        try {
          const root = JSON.parse(fs.readFileSync('$CLOUD_DEPS', 'utf8'));
          const d = root.deps || root;
          const take = (obj) => {
            for (const [k, v] of Object.entries(obj || {})) {
              if (!deps[k] || v > deps[k]) deps[k] = v;
            }
          };
          take(d.node?.merged?.dependencies);
          take(d.node?.merged?.devDependencies);
        } catch (e) { console.error('WARN: cloud-deps: ' + e.message); }
        fs.writeFileSync('$CLOUD_OUT', JSON.stringify(deps, null, 2) + '\n');
        console.log('[node-npm-deps-cloud] ' + Object.keys(deps).length + ' cloud deps extracted');
      " || printf "[node-npm-deps-cloud] WARN: merge failed\n"
    else
      printf "[node-npm-deps-cloud] No _cloud-data-consolidated.json found\n"
      echo '{}' > "$CLOUD_OUT" 2>/dev/null || true
    fi
  '';
}
