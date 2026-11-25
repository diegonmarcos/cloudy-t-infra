# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/packages/node-npm-deps-list.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Static list of all known npm dependencies — always installed.
# This is the declarative baseline. Snapshot from 2026-03-24.
# Merged from: _cloud-data-consolidated.json[.deps] + front-deps.json + essential tools (2026-04-27 migrated).
# Dynamic cloud/front modules add NEW packages on top; this list is the baseline.
{ lib, ... }:

{
  options.nodeNpmDeps.static = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Static npm dependencies to always install";
  };

  config.nodeNpmDeps.static = {
    # ── Essential CLI tools ──
    "tsx" = "^4.19.0";
    "typescript" = "^5.7.0";

    # ── MCP SDK ──
    "@modelcontextprotocol/sdk" = "^1.12.0";

    # ── Server frameworks ──
    "fastify" = "^5.2.0";
    "fastify-plugin" = "^5.0.0";
    "@fastify/cors" = "^10.0.0";
    "@fastify/static" = "^8.0.0";
    "@fastify/swagger" = "^9.4.0";
    "@fastify/swagger-ui" = "^5.2.0";

    # ── Schema / validation ──
    "zod" = "^3.25.0";
    "zod-to-json-schema" = "^3.24.0";

    # ── Templating / data ──
    "nunjucks" = "^3.2.4";
    "yaml" = "^2.6.0";
    "gray-matter" = "^4.0.3";

    # ── Database ──
    "better-sqlite3" = "^11.0.0";

    # ── Mail ──
    "imapflow" = "^1.0.0";
    "mailparser" = "^3.7.0";
    "nodemailer" = "^6.9.0";

    # ── HTTP ──
    "axios" = "^1.6.0";

    # ── Vue 3 ecosystem ──
    "vue" = "^3.5.27";
    "pinia" = "^2.1.0";
    "vue-sonner" = "^1.0.0";
    "vue-tsc" = "^3.2.4";
    "@vueuse/core" = "^10.9.0";
    "@tanstack/vue-query" = "^5.28.0";
    "@tanstack/vue-virtual" = "^3.1.0";
    "@floating-ui/vue" = "^1.0.0";
    "radix-vue" = "^1.5.0";
    "shadcn-vue" = "^2.3.3";
    "lucide-vue-next" = "^0.340.0";
    "unplugin-auto-import" = "^0.17.0";
    "unplugin-vue-components" = "^0.26.0";
    "@vitejs/plugin-vue" = "^6.0.3";
    "vite-plugin-vue-devtools" = "^7.0.0";
    "vite-ssg" = "^0.23.0";
    "@vue/eslint-config-typescript" = "^12.0.0";
    "eslint-plugin-vue" = "^9.20.0";

    # ── Svelte 5 ecosystem ──
    "svelte" = "^5.41.0";
    "svelte-check" = "^4.3.3";
    "@sveltejs/kit" = "^2.47.1";
    "@sveltejs/adapter-auto" = "^7.0.0";
    "@sveltejs/adapter-static" = "^3.0.10";
    "@sveltejs/vite-plugin-svelte" = "^6.2.1";
    "prettier-plugin-svelte" = "^3.4.0";
    "eslint-plugin-svelte" = "^3.13.0";

    # ── Vite / build tools ──
    "vite" = "^7.3.1";
    "vite-plugin-compression" = "^0.5.0";
    "vite-plugin-singlefile" = "^2.3.0";
    "esbuild" = "^0.20.2";
    "terser" = "^5.44.1";
    "vitest" = "^1.3.0";

    # ── CSS / Tailwind ──
    "tailwindcss" = "^4.1.18";
    "tailwindcss-animate" = "^1.0.7";
    "tailwind-merge" = "^3.4.0";
    "@tailwindcss/postcss" = "^4.1.18";
    "@tailwindcss/vite" = "^4.1.18";
    "postcss" = "^8.5.6";
    "autoprefixer" = "^10.4.23";
    "sass" = "^1.97.3";
    "class-variance-authority" = "^0.7.1";

    # ── Code quality ──
    "eslint" = "^9.39.1";
    "prettier" = "^3.6.2";
    "prettier-plugin-tailwindcss" = "^0.5.0";
    "@typescript-eslint/eslint-plugin" = "^6.13.0";
    "@typescript-eslint/parser" = "^6.13.0";

    # ── D3 / visualization ──
    "d3" = "^7.9.0";
    "d3-geo" = "^3.1.1";
    "d3-interpolate" = "^3.0.1";
    "d3-timer" = "^3.0.1";
    "chart.js" = "^4.5.1";
    "three" = "^0.182.0";
    "pixi.js" = "^8.6.0";

    # ── Maps ──
    "maplibre-gl" = "^5.17.0";
    "topojson-client" = "^3.1.0";
    "@turf/helpers" = "^7.0.0";
    "@turf/union" = "^7.0.0";
    "@mapbox/togeojson" = "^0.16.2";

    # ── Content / markdown ──
    "marked" = "^15.0.12";
    "shiki" = "^1.0.0";
    "dompurify" = "^3.0.0";

    # ── Utilities ──
    "clsx" = "^2.1.0";
    "date-fns" = "^3.3.0";
    "lodash-es" = "^4.17.21";
    "jszip" = "^3.10.1";
    "blurhash" = "^2.0.0";
    "unlazy" = "^0.11.0";
    "lucide" = "^0.460.0";
    "web-vitals" = "^3.5.0";
    "@formkit/auto-animate" = "^0.8.0";

    # ── Search / CMS ──
    "@orama/orama" = "^2.0.0";
    "@sanity/client" = "^6.12.0";
    "@sanity/image-url" = "^1.0.2";

    # ── Testing ──
    "@testing-library/vue" = "^8.0.0";

    # ── Types ──
    "@types/node" = "^22.0.0";
    "@types/better-sqlite3" = "^7.6.13";
    "@types/nunjucks" = "^3.2.6";
    "@types/nodemailer" = "^6.4.0";
    "@types/d3" = "^7.4.3";
    "@types/d3-geo" = "^3.1.0";
    "@types/dompurify" = "^3.0.0";
    "@types/lodash-es" = "^4.17.12";
    "@types/three" = "^0.182.0";
    "@types/topojson-client" = "^3.1.5";
  };
}
