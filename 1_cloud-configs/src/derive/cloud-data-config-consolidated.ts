// cloud-data-config-consolidated.ts — Consolidated generator: ONE file → ONE output
//
// Replaces: gen-topology.ts, gen-configs.ts, gen-deps.ts, gen-home-manager.ts, gen-gha-config.ts
//
// Input sources (NO self-referential read, NO ~/.ssh/config):
//   1. config.json (repo root)                          → owner, vms overlay, native, vpss, deps
//   2. c_vps/vps_*/src/main.tf                           → terraform VM specs/IPs/firewall/storage
//   3. a_solutions/*/build.json                         → services + containers (scanBuildJsons)
//   4. a_solutions/*/dist/docker-compose.yml            → compose reconciliation (parseCompose)
//   5. a_solutions/*/src/package.json                   → npm deps per service
//   6. bb-sec_caddy/dist/Caddyfile                      → Caddy routes (parseCaddyfile)
//   7. bb-sec_authelia/dist/config/configuration.yml.tpl → Authelia ACL (parseAuthelia)
//   8. ba-clo_hickory-dns/dist/zones/                   → DNS zones (parseDNSZones)
//   9. vault/A0_keys/providers/wireguard/*/publickey    → WG public keys (source of truth)
//
// Output:
//   cloud-data/_cloud-data-consolidated.json
//
// Run: tsx cloud-data-config-consolidated.ts

import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync, lstatSync } from "fs";
import { resolve, join } from "path";

import { scanBuildJsons, normalizeToContainers, CATEGORY_PREFIX, type BuildJsonEntry, type ContainerSpec } from "./parsers/build-json.js";
import { parseCompose } from "./parsers/compose.js";
import { parseCaddyfile } from "./parsers/caddyfile.js";
import { parseAuthelia } from "./parsers/authelia.js";
import { parseDNSZones } from "./parsers/dns.js";
import { parseWireGuard, parseOSFirewalls, parseOSFirewallGlobal } from "./parsers/wireguard.js";
import { parseTerraform } from "./parsers/terraform.js";
import { parseCloudflareRecords } from "./parsers/cloudflare.js";
import { parseNtfy } from "./parsers/ntfy.js";
import { parseMailu } from "./parsers/mailu.js";

// ═══════════════════════════════════════════════════════════════════════════
// Paths
// ═══════════════════════════════════════════════════════════════════════════

const ENGINE_DIR = import.meta.dirname!;
// Script lives at: cloud/1_cloud-configs/src/derive — 2 levels up = cloud/9_others
const CONFIGS_DIR = resolve(ENGINE_DIR, "../..");
const CLOUD_ROOT = resolve(CONFIGS_DIR, "..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT, "..");
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const INFRA_DIR = join(CLOUD_ROOT, "c_vps");
const CONFIG_JSON = join(CLOUD_ROOT, "config.json");

const CLOUD_DATA_DIR = join(CONFIGS_DIR, "dist");             // sole write target (cloud/1_cloud-configs/dist)
const OUTPUT_JSON = join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json");
const VAULT_WG_DIR = join(GIT_BASE, "vault", "A0_keys", "providers", "wireguard");

// ═══════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════

interface SystemDep {
  nix: string | null;
  apt: string | null;
  desc?: string;
  npm?: string;
}

interface ServiceDeps {
  service: string;
  folder: string;
  category: string;
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf-8"));
}

/** Stable empty string for `_generated` / `generated_at` — see derive's `now()`. */
function reproducibleNow(): string {
  return "";
}

function takeHigher(existing: string | undefined, candidate: string): string {
  if (!existing) return candidate;
  return candidate > existing ? candidate : existing;
}

function sortObj(obj: Record<string, string>): Record<string, string> {
  return Object.fromEntries(Object.entries(obj).sort(([a], [b]) => a.localeCompare(b)));
}

/** Build alias → vmId map from config.json vms */
function buildAliasMap(configVms: Record<string, any>): Record<string, string> {
  const map: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(configVms)) {
    if (vm.ssh_alias) map[vm.ssh_alias] = vmId;
  }
  return map;
}

/** Resolve an ssh alias (or "local"/"all") to a VM ID */
function resolveVmId(host: string, aliasMap: Record<string, string>, vms: Record<string, any>): string {
  if (host === "local" || host === "all") return host;
  if (aliasMap[host]) return aliasMap[host];
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias === host) return vmId;
  }
  return host;
}

// public_ports source-of-truth = b_infra/nixhm-sudo-<alias>/build.json.firewall.public_ports
// Per loyal-firewalling-marmot.md the home-manager sudo deploy that owns wg0+iptables also owns the port catalog.
// Fallback signature kept for safety; in practice config.json no longer holds public_ports (deleted in Phase 2).
//
// 2026-05-09 (Phase 7) bugfix: previously read from b_infra/home-manager/nixhm-sudo-<alias>/
// which doesn't exist — the actual layout is b_infra/nixhm-sudo-<alias>/. Without the fix every
// VM's public_ports silently fell back to []. Now declared ports actually reach the firewall.
function loadVmHmBuild(alias: string | undefined, cloudRoot: string): any | null {
  if (!alias) return null;
  const hmBuildPath = join(cloudRoot, "b_infra", `nixhm-sudo-${alias}`, "build.json");
  if (!existsSync(hmBuildPath)) return null;
  try {
    return JSON.parse(readFileSync(hmBuildPath, "utf-8"));
  } catch {
    return null;
  }
}

function loadVmPublicPorts(alias: string | undefined, cloudRoot: string, fallback: any[]): any[] {
  const bj = loadVmHmBuild(alias, cloudRoot);
  if (!bj) return fallback;
  const ports = bj.firewall?.public_ports;
  return Array.isArray(ports) ? ports : fallback;
}

// Phase 7: VM is a public ingress IF it declares any public_ports. Implicit/derived
// from the same source of truth — operators add a port to firewall.public_ports and
// the VM automatically becomes "public ingress" (drives DOCKER-USER drop / accept logic).
function loadVmIsPublicIngress(alias: string | undefined, cloudRoot: string): boolean {
  const bj = loadVmHmBuild(alias, cloudRoot);
  if (!bj) return false;
  // Explicit override wins (lets operators force `false` to lock down).
  if (typeof bj.firewall?.is_public_ingress === "boolean") return bj.firewall.is_public_ingress;
  return Array.isArray(bj.firewall?.public_ports) && bj.firewall.public_ports.length > 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

function main() {
  console.log("cloud-data-config-consolidated: scanning all sources...\n");

  // ── 1. Load config.json (overlay source) ───────────────────────────────
  if (!existsSync(CONFIG_JSON)) {
    console.error(`FATAL: config.json not found at ${CONFIG_JSON}`);
    process.exit(1);
  }
  const config = readJson(CONFIG_JSON) as any;

  // ── 1a. Fetched GitHub inventory — SoT for which repos exist ────────────
  // Refreshed by .github/workflows/fetch-github-repos.yml, committed as data
  // so the build stays offline and deterministic. Absent file degrades to an
  // empty inventory rather than failing: a fresh clone that has never run the
  // fetch should still build.
  // Repo NAMES are not sensitive and live in this public repo by design. The
  // TOKEN used to fetch them is — it stays in the vault / GH secrets and is
  // never written here. Refreshed by .github/workflows/fetch-github-repos.yml.
  const GITHUB_REPOS_JSON = join(CONFIGS_DIR, "src", "inputs", "github-repos.json");
  const githubInventory: any = existsSync(GITHUB_REPOS_JSON)
    ? readJson(GITHUB_REPOS_JSON)
    : { repos: [] };
  if (!existsSync(GITHUB_REPOS_JSON)) {
    console.warn("  WARN: src/inputs/github-repos.json missing — git registry will be empty");
  } else {
    const _n = githubInventory.repos?.length ?? 0;
    const _priv = (githubInventory.repos ?? []).filter((r: any) => r?.visibility === "private").length;
    console.log(`  github-repos.json: ${_n} repos (${_priv} private), fetched ${githubInventory.fetched_at ?? "?"}`);
  }
  const configVms: Record<string, any> = config.vms ?? {};
  const aliasMap = buildAliasMap(configVms);
  console.log(`  config.json: ${Object.keys(configVms).length} VMs, owner=${config.owner?.name}`);

  // ── 1b. Load WG public keys from vault (source of truth) ──────────────
  const vaultWgKeys: Record<string, string> = {};
  if (existsSync(VAULT_WG_DIR)) {
    for (const entry of readdirSync(VAULT_WG_DIR, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const pubFile = join(VAULT_WG_DIR, entry.name, "publickey");
      if (existsSync(pubFile)) {
        vaultWgKeys[entry.name] = readFileSync(pubFile, "utf8").trim();
      }
    }
    console.log(`  vault/wireguard: ${Object.keys(vaultWgKeys).length} public keys`);
  } else {
    console.log("  vault/wireguard: NOT FOUND — falling back to previously derived keys");
  }

  // Carry forward the keys already in the last derived output when the vault is
  // absent. The vault lives in a SEPARATE repo (~/git/cloud-vault) that GHA runners
  // never check out, so every CI derive re-emitted `wg_public_key: null` and
  // committed those nulls over good values. Downstream that is fatal, not
  // cosmetic: vm-pilot's wireguard.nix throws `VM "<x>" has null wg_public_key`
  // and the whole home-manager deploy dies (2026-08-11, all 4 VMs).
  //
  // A public key is not a secret and never rotates silently, so the last known
  // value is always a better answer than null. The vault still wins whenever it
  // is present, so a real rotation propagates on the next local derive.
  if (existsSync(OUTPUT_JSON)) {
    try {
      const prev = JSON.parse(readFileSync(OUTPUT_JSON, "utf8"));
      let carried = 0;
      const harvest = (name?: string | null, key?: string | null) => {
        if (!name || !key) return;
        if (vaultWgKeys[name]) return;   // vault wins
        vaultWgKeys[name] = key;
        carried++;
      };
      for (const p of prev?.native?.wireguard?.peers ?? []) harvest(p?.name, p?.wg_public_key);
      for (const p of prev?.native?.wireguard_public?.peers ?? []) {
        harvest(p?.name ? `${p.name}-public` : null, p?.wg_public_key);
      }
      for (const [name, vm] of Object.entries<any>(prev?.vms ?? {})) harvest(name, vm?.wg_public_key);
      // CLIENTS TOO — they were missing here, and it broke the mesh silently.
      //
      // `clients` (surface, termux, gha-runner, health-runner) is a DICT, not a
      // list, so it was skipped when the carry-forward above was written for
      // the 2026-08-11 VM incident. The consequence is worse for clients than
      // for VMs: wireguard.nix's hub config does
      //     peers = lib.filterAttrs (n: v: ... && v.publicKey != null) topology
      // so a null key does not throw like it does for a VM — the peer is
      // silently DROPPED from the hub's wg0 config. No error, no warning, the
      // deploy goes green, and the client simply can never handshake again.
      //
      // That is what took the fleet out on 2026-08-12. gha-runner (10.0.0.200)
      // is the identity CI uses to reach every VM, so with its key nulled the
      // runner could not join the mesh at all and EVERY home-manager deploy
      // failed with "ssh: connect to host 10.0.0.1 port 22: Connection timed
      // out". That looked like a dead hub — it was a missing peer. The Surface
      // (10.0.0.5) went the same way and lost mesh access on the hub's next
      // reboot, which is when the runtime-only peer entry disappeared.
      //
      // Public keys are not secrets and do not rotate silently, so the last
      // known value always beats null; the vault still wins when present.
      for (const [name, c] of Object.entries<any>(prev?.native?.wireguard?.clients ?? {})) {
        harvest(name, c?.wg_public_key ?? c?.public_key);
      }
      for (const [name, c] of Object.entries<any>(prev?.native?.wireguard_public?.clients ?? {})) {
        harvest(name ? `${name}-public` : null, c?.wg_public_key ?? c?.public_key);
      }
      if (carried > 0) console.log(`  carried forward ${carried} WG public keys from previous output`);
    } catch (e) {
      console.log(`  WARN: could not read previous output for WG key carry-forward: ${e}`);
    }
  }

  // THE PREVIOUS OUTPUT IS NOT ALWAYS A GOOD SOURCE.
  //
  // Carry-forward above reads the last derived file — which is exactly the
  // file a bad derive already filled with nulls. Once nulls land there they
  // are self-sustaining: every later derive carries nothing, re-emits null,
  // and every home-manager deploy dies on `null wg_public_key` (2026-09-02,
  // all 4 VMs, twice). So the SHIPPED per-VM copies are read too. They are
  // committed alongside each VM's pilot bundle, they are what actually
  // deployed the last time the mesh worked, and a public key is not a secret.
  {
    let carried = 0;
    const harvest = (name?: string | null, key?: string | null) => {
      if (!name || !key || vaultWgKeys[name]) return;
      vaultWgKeys[name] = key;
      carried++;
    };
    const pilots = join(CLOUD_ROOT, "b_infra");
    for (const dir of existsSync(pilots) ? readdirSync(pilots) : []) {
      const f = join(pilots, dir, "dist", "pilot", "_cloud-data-consolidated.json");
      if (!existsSync(f)) continue;
      try {
        const prev = JSON.parse(readFileSync(f, "utf8"));
        for (const p of prev?.native?.wireguard?.peers ?? []) harvest(p?.name, p?.wg_public_key);
        for (const p of prev?.native?.wireguard_public?.peers ?? []) {
          harvest(p?.name ? `${p.name}-public` : null, p?.wg_public_key);
        }
        for (const [name, vm] of Object.entries<any>(prev?.vms ?? {})) harvest(name, vm?.wg_public_key);
        for (const [name, c] of Object.entries<any>(prev?.native?.wireguard?.clients ?? {})) {
          harvest(name, c?.wg_public_key ?? c?.public_key);
        }
      } catch { /* a bundle that will not parse is simply not a source */ }
    }
    if (carried > 0) console.log(`  carried forward ${carried} WG public keys from shipped pilot bundles`);
  }

  // ── 2. Parse Terraform for VM specs, storage, firewalls ────────────────
  const tfData = parseTerraform(INFRA_DIR);
  const totalFwRules = tfData.firewalls.reduce((sum, fw) => sum + fw.rules.length, 0);
  console.log(`  Terraform: ${Object.keys(tfData.vm_specs).length} VM specs, ${tfData.storage.length} storage, ${totalFwRules} firewall rules`);

  // Build terraform instance name → VM ID mapping
  // OCI: display_name matches VM ID directly (e.g. "oci-E2-f_0")
  // GCP: instance name (e.g. "arch-1") needs gcloud_instance mapping
  const tfNameToVmId: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(configVms)) {
    if (vm.gcloud_instance) tfNameToVmId[vm.gcloud_instance] = vmId;
  }

  // ── 3. Merge VMs: terraform specs + config.json overlay ────────────────
  const vms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(configVms)) {
    // Find matching terraform specs by display_name or gcloud_instance
    let tfSpecs = tfData.vm_specs[vmId]; // OCI: direct match
    if (!tfSpecs && vm.gcloud_instance) {
      tfSpecs = tfData.vm_specs[vm.gcloud_instance]; // GCP: via gcloud_instance
    }

    // Merge specs: config.json base, terraform overlay, machine_type lookup fallback
    const mergedSpecs = { ...(vm.specs ?? {}), ...(tfSpecs ?? {}) };
    // If cpu/ram still 0 (HCL parser can't handle for_each), resolve from machine_type lookup
    const machineType = mergedSpecs.machine_type || mergedSpecs.shape || "";
    if ((!mergedSpecs.cpu || mergedSpecs.cpu === 0 || !mergedSpecs.ram_gb || mergedSpecs.ram_gb === 0) && machineType) {
      const MACHINE_SPECS: Record<string, { cpu: number; ram_gb: number }> = {
        // GCP
        "e2-micro":       { cpu: 2, ram_gb: 1 },
        "e2-small":       { cpu: 2, ram_gb: 2 },
        "e2-medium":      { cpu: 2, ram_gb: 4 },
        "n1-standard-1":  { cpu: 1, ram_gb: 3.75 },
        "n1-standard-2":  { cpu: 2, ram_gb: 7.5 },
        "n1-standard-4":  { cpu: 4, ram_gb: 15 },
        "n1-standard-8":  { cpu: 8, ram_gb: 30 },
        "g2-standard-4":  { cpu: 4, ram_gb: 16 },   // 1x NVIDIA L4 built in (gcp-gpu-embed)
        // OCI
        "VM.Standard.E2.1.Micro": { cpu: 1, ram_gb: 1 },
        "VM.Standard.A1.Flex":    { cpu: 4, ram_gb: 24 },
      };
      const known = MACHINE_SPECS[machineType];
      if (known) {
        if (!mergedSpecs.cpu || mergedSpecs.cpu === 0) mergedSpecs.cpu = known.cpu;
        if (!mergedSpecs.ram_gb || mergedSpecs.ram_gb === 0) mergedSpecs.ram_gb = known.ram_gb;
      }
    }

    vms[vmId] = {
      // Terraform owns: ip (fallback to config), specs
      ip: vm.ip,
      specs: mergedSpecs,
      description: vm.description ?? "",
      // Config.json owns: wg, ssh, user, home, method, rescue, gha
      // public_ports MOVED to b_infra/nixhm-sudo-<alias>/build.json.firewall.public_ports
      // (loyal-firewalling-marmot.md Phase 1 — the home-manager sudo deploy that owns wg0+iptables also owns the port catalog)
      wg_ip: vm.wg_ip,
      wg_ipv6: vm.wg_ipv6 ?? null,  // mesh ULA (fd0c:1d00::x), null on non-mesh VMs
      wg_public_key: vaultWgKeys[vm.ssh_alias] ?? null,  // vault is source of truth
      wg_port: vm.wg_port ?? 51820,
      wg_role: vm.wg_role ?? "spoke",
      user: vm.user,
      home: vm.home ?? (vm.user === "root" ? "/root" : `/home/${vm.user}`),
      method: vm.method ?? "key",
      ssh_alias: vm.ssh_alias,
      rescue_port: vm.rescue_port ?? 2200,
      public_ports: loadVmPublicPorts(vm.ssh_alias, CLOUD_ROOT, vm.public_ports ?? []),
      is_public_ingress: loadVmIsPublicIngress(vm.ssh_alias, CLOUD_ROOT),
      gha: vm.gha ?? null,
      // Optional provider/provisioning fields
      ...(vm.provider ? { provider: vm.provider } : {}),
      ...(vm.provisioning ? { provisioning: vm.provisioning } : {}),
      ...(vm.gcloud_instance ? { gcloud_instance: vm.gcloud_instance } : {}),
      ...(vm.gcloud_zone ? { gcloud_zone: vm.gcloud_zone } : {}),
      ...(vm.idle_shutdown ? { idle_shutdown: vm.idle_shutdown } : {}),
      ...(vm.notes ? { notes: vm.notes } : {}),
      // PLAN-ghcr-artifacts.md item 4: optional self-hosted GHA runner label
      // for this VM (config.json vms.<host>.runner_label). Root-caused
      // 2026-08-25: the ghaVms block below reads vm.runner_label off THIS
      // projected object, not off raw config.json directly — without this
      // line the field was silently dropped here and every deploy fell back
      // to ubuntu-latest+mesh regardless of what config.json declared.
      ...(vm.runner_label ? { runner_label: vm.runner_label } : {}),
      // Cloud provider instance ID (from terraform.json) — used by devops.vm.reset etc.
      ...(mergedSpecs.instance_id ? { instance_id: mergedSpecs.instance_id } : {}),
      // Derived (populated below)
      services: [] as string[],
      container_count: 0,
    };
  }

  // ── 4. Scan build.json → services ──────────────────────────────────────
  const buildEntries = scanBuildJsons(SOLUTIONS_DIR);
  console.log(`  build.json: ${buildEntries.length} services`);

  // ── 5. Build services map with compose reconciliation ──────────────────
  const services: Record<string, any> = {};

  for (const entry of buildEntries) {
    const compose = parseCompose(SOLUTIONS_DIR, entry.folder, entry.name);
    const vmId = resolveVmId(entry.vm, aliasMap, vms);

    // Normalize to containers (new schema or synthesized from flat)
    const containers = normalizeToContainers(entry);

    // Compute upstream IP — prefer the primary container's bind_host (e.g. wg-public
    // hub IP 10.1.0.1) over the VM's wg0 IP. This is how services like cf-worker-bridge
    // declare "I bind on the wg-public mesh, not wg0" — without it, the catalog points
    // probes/Caddy at the wrong interface.
    const vmWgIp = vmId ? vms[vmId]?.wg_ip : undefined;
    const primaryContainer = Object.values(containers).find(c => c.port === entry.port) ?? Object.values(containers)[0];
    // #1686: a container served from Cloud Run declares cloud_run_bridge.host (the gcp-idtoken-bridge
    // listener, same port as before): Caddy and probes then dial the bridge instead of the oci-apps box.
    const upstreamIp = primaryContainer?.cloud_run_bridge?.host ?? primaryContainer?.bind_host ?? vmWgIp;
    const computedUpstream = upstreamIp && entry.port ? `${upstreamIp}:${entry.port}` : undefined;

    // Derive container names from containers spec
    const containerNames = Object.values(containers).map(c => c.container_name);

    // Derive all ports from containers
    const allPorts: string[] = [];
    for (const c of Object.values(containers)) {
      if (c.port) allPorts.push(String(c.port));
    }
    // Merge compose ports
    for (const p of compose.ports) {
      if (!allPorts.includes(p)) allPorts.push(p);
    }

    // Derive all dns entries from containers
    const allDns: string[] = [];
    for (const c of Object.values(containers)) {
      if (c.dns) allDns.push(c.dns);
    }

    const svc: any = {
      category: entry.category,
      vm: vmId,
      folder: entry.folder,
      description: entry.description,
      enabled: entry.enabled ?? true,
      // Domain + routing
      ...(entry.domain ? { domain: entry.domain } : {}),
      ...(entry.flake ? { flake: entry.flake } : {}),
      ...(entry.port != null ? { port: entry.port } : {}),
      ...(entry.dns ? { dns: entry.dns } : {}),
      ...(computedUpstream ? { upstream: computedUpstream } : {}),
      // Containers (new schema)
      containers,
      container_names: containerNames.length > 0 ? containerNames : compose.containers,
      all_ports: allPorts,
      all_dns: allDns,
      // Compose reconciliation
      compose: {
        containers: compose.containers,
        ports: compose.ports,
        networks: compose.networks,
      },
      // Declarative infrastructure fields (pass through from build.json)
      ...(entry.proxy ? { proxy: entry.proxy } : {}),
      ...(entry.ports ? { declared_ports: entry.ports } : {}),
      ...(entry.health ? { health: entry.health } : {}),
      ...(entry.monitoring ? { monitoring: entry.monitoring } : {}),
      ...(entry.backup ? { backup: entry.backup } : {}),
      ...(entry.notifications ? { notifications: entry.notifications } : {}),
      // Cross-service declarative SoTs — each service's own build.json owns
      // these. The derive engine joins them into peer build-{name}.json files
      // (deriveServiceConnections + deriveMailAccounts).
      ...(entry.users ? { users: entry.users } : {}),
      ...(entry.mail_clients ? { mail_clients: entry.mail_clients } : {}),
      // Deploy overrides
      ...(entry.fallback_vm ? { fallback_vm: resolveVmId(entry.fallback_vm, aliasMap, vms) } : {}),
      // Extra service-specific fields
      ...(entry.extra ?? {}),
    };

    // ── API + MCP + Web UI classification (declarative) ────────────────────
    // Sourced from entry.api and entry.mcp (declared per service in its build.json,
    // schema in a_solutions/build.schema.json). Replaces the previous KNOWN_API_PATHS
    // hardcoded map, the name-based hasApi heuristic, and the healthcheck-regex
    // api-path extraction. Adding a new API now requires zero engine edits.
    // healthcheck per build.schema can be a path string ("/health"), a
    // shell-cmd string ("curl ..."), an object ({test, interval, ...}),
    // or null. Only path strings are useful here — coerce non-strings to
    // "" so the downstream `.startsWith("/")` filter is type-safe.
    const healthchecks: string[] = Object.values(containers)
      .map((c: any) => (typeof c.healthcheck === "string" ? c.healthcheck : ""))
      .filter(Boolean);

    const apiDecl = (entry.api ?? null) as Record<string, unknown> | null;
    const mcpDecl = (entry.mcp ?? null) as Record<string, unknown> | null;

    const hasApi = !!apiDecl && apiDecl.type !== "no-api";
    // For OpenAPI: spec_path is the canonical entry; for custom-rest: base_path.
    const apiPath = (apiDecl?.spec_path as string | undefined)
      ?? (apiDecl?.base_path as string | undefined)
      ?? null;
    const apiUrl = (apiDecl?.spec_url as string | undefined)
      ?? (apiPath && entry.domain ? `https://${entry.domain}${apiPath}` : null);

    const mcpPath = (mcpDecl?.endpoint_path as string | undefined) ?? null;
    const mcpUrl = mcpPath && entry.domain ? `https://${entry.domain}${mcpPath}` : null;

    // Web UI = has a domain AND not an MCP-only service.
    // "MCP-only" is now derived from declarations, not name-regex.
    const WEB_UI_EXCLUSIONS = new Set(["introspect-proxy", "http-to-smtp-proxy-api", "hickory-dns"]);
    const isMcpOnly = !!mcpDecl && !apiDecl;
    const hasWebUi = !!(entry.domain && !isMcpOnly && !WEB_UI_EXCLUSIONS.has(entry.name));

    svc.api = {
      // Stable contract preserved for existing consumers (health, monitoring, dashboard):
      has_api: hasApi,
      has_web_ui: hasWebUi,
      api_path: apiPath,
      api_url: apiUrl,
      healthcheck_paths: healthchecks.filter((h: string) => h.startsWith("/")),
      // Pass-through of the declared block (added fields, no removals):
      ...(apiDecl ?? {}),
    };

    if (mcpDecl) {
      svc.mcp = {
        has_mcp: mcpDecl.transport !== "stdio",
        mcp_url: mcpUrl,
        ...mcpDecl,
      };
    }

    // Extract secret env var names from src/secrets.yaml (keys are plaintext in sops)
    const secretsPath = join(SOLUTIONS_DIR, entry.folder, "src", "secrets.yaml");
    if (existsSync(secretsPath)) {
      const lines = readFileSync(secretsPath, "utf-8").split("\n");
      const envVars = lines
        .map(l => l.match(/^([A-Z][A-Z0-9_]+):\s/))
        .filter(Boolean)
        .map(m => m![1]);
      if (envVars.length > 0) svc.secret_env_vars = envVars;
    }

    services[entry.name] = svc;
  }

  // ── 6. Aggregate services → VMs (skip disabled services) ──────────────
  for (const [svcName, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm) continue;
    vm.services.push(svcName);
    if (svc.enabled !== false) {
      vm.container_count += (svc.container_names?.length ?? 0);
    }
  }

  // ── 7. Firewalls (terraform + OS-level) ────────────────────────────────
  const osFirewalls = parseOSFirewalls(GIT_BASE);
  const osFirewallGlobal = parseOSFirewallGlobal(GIT_BASE);
  console.log(`  OS Firewalls: ${osFirewalls.length} VMs, docker_iptables=${osFirewallGlobal.docker_iptables}`);

  // Restructure firewalls into the consolidated shape
  const firewalls: any = {
    terraform: {} as Record<string, any>,
    os: {} as Record<string, any>,
    global: {
      docker_iptables: osFirewallGlobal.docker_iptables,
      forward_policy: osFirewallGlobal.forward_policy,
      docker_subnet: osFirewallGlobal.docker_subnet,
      wg_subnet: osFirewallGlobal.wg_subnet,
      forward_rules: osFirewallGlobal.forward_rules,
      nat_rules: osFirewallGlobal.nat_rules,
    },
  };

  // Group terraform firewalls by provider
  for (const fw of tfData.firewalls) {
    if (!firewalls.terraform[fw.provider]) {
      firewalls.terraform[fw.provider] = [];
    }
    firewalls.terraform[fw.provider].push({ scope: fw.scope, rules: fw.rules });
  }

  // OS firewalls: per-vm public_ports — sourced via loadVmPublicPorts (per-VM home-manager build.json)
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.public_ports?.length > 0) {
      firewalls.os[vm.ssh_alias || vmId] = vm.public_ports;
    }
  }

  // ── 8. Storage ─────────────────────────────────────────────────────────
  const storage = tfData.storage;

  // ── 9. DNS (internal zones + cloudflare) ───────────────────────────────
  const internalZones = parseDNSZones(SOLUTIONS_DIR);
  const cfRecords = parseCloudflareRecords(SOLUTIONS_DIR);
  console.log(`  DNS: ${internalZones.length} internal zones, ${cfRecords.length} Cloudflare records`);

  // Derive internal zone entries from service containers dns + vm wg_ip
  const derivedDnsEntries: Array<{ name: string; type: string; value: string; service: string }> = [];
  for (const [svcName, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip) continue;
    for (const dnsName of (svc.all_dns ?? [])) {
      if (dnsName) {
        derivedDnsEntries.push({
          name: dnsName,
          type: "A",
          value: vm.wg_ip,
          service: svcName,
        });
      }
    }
  }

  const dns = {
    internal_zones: internalZones,
    derived_entries: derivedDnsEntries,
    cloudflare: cfRecords,
  };

  // ── 10. Configs (Caddy, Authelia, ntfy, mailu) ─────────────────────────
  const caddyRoutes = parseCaddyfile(SOLUTIONS_DIR);
  const autheliaAcl = parseAuthelia(SOLUTIONS_DIR);
  const ntfyConfig = parseNtfy(SOLUTIONS_DIR);
  const mailuConfig = parseMailu(SOLUTIONS_DIR);
  console.log(`  Configs: ${caddyRoutes.length} Caddy routes, ${autheliaAcl.length} Authelia ACL rules`);

  const configs: any = {
    caddy: { routes: caddyRoutes },
    authelia: { acl: autheliaAcl },
  };
  if (ntfyConfig) configs.ntfy = ntfyConfig;
  if (mailuConfig) configs.mailu = mailuConfig;

  // ── 11. Deps (system + node per-service) ───────────────────────────────
  const { mergedDeps, mergedDevDeps, perServiceDeps } = scanNodeDeps(buildEntries);
  const systemDeps = readSystemDeps(config);
  console.log(`  Deps: ${perServiceDeps.length} services with package.json, ${Object.keys(mergedDeps).length + Object.keys(mergedDevDeps).length} merged packages`);

  const deps = {
    system: systemDeps.system,
    build: systemDeps.build,
    optional: systemDeps.optional,
    node: {
      required: config.deps?.node?.required ?? [],
      merged: {
        dependencies: sortObj(mergedDeps),
        devDependencies: sortObj(mergedDevDeps),
      },
      per_service: perServiceDeps.sort((a, b) => a.folder.localeCompare(b.folder)),
    },
    install: config.deps?.install ?? {},
    gha: config.deps?.gha ?? {},
  };

  // ── 12. VPSs ──────────────────────────────────────────────────────────
  const vpss: Record<string, any> = config.vpss ?? {};
  // Enrich with terraform provider info
  for (const prov of tfData.providers) {
    const existing = vpss[prov.name] ?? {};
    vpss[prov.name] = {
      ...existing,
      has_terraform: prov.has_terraform,
      folder: `c_vps/${prov.folder}`,
    };
  }

  // ── 13. WireGuard ─────────────────────────────────────────────────────
  const wgPeers = parseWireGuard(GIT_BASE);
  // Fallback: derive peers from VMs if parser found nothing
  if (wgPeers.length === 0) {
    for (const vm of Object.values(vms)) {
      if (vm.wg_ip) {
        wgPeers.push({
          name: vm.ssh_alias,
          wg_ip: vm.wg_ip,
          wg_public_key: vaultWgKeys[vm.ssh_alias] ?? null,
          endpoint: vm.ip ? `${vm.ip}:51820` : "dynamic",
          role: vm.wg_role || "spoke",
        });
      }
    }
  }
  // Enrich peers with wg_public_key from vault (source of truth)
  for (const peer of wgPeers) {
    peer.wg_public_key = vaultWgKeys[peer.name] ?? null;
  }

  // ── 14. Native section from config.json ────────────────────────────────
  const native = config.native ?? {};

  // ── 15. Home-manager data (previously gen-home-manager.ts) ─────────────
  const homeManagerVms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    if (!vm.ssh_alias) continue;
    homeManagerVms[vm.ssh_alias] = {
      vm_id: vmId,
      ip: vm.ip,
      wg_ip: vm.wg_ip,
      wg_public_key: vm.wg_public_key,
      wg_port: vm.wg_port,
      wg_role: vm.wg_role,
      user: vm.user,
      home: vm.home,
      rescue_port: vm.rescue_port,
      specs: vm.specs,
      public_ports: vm.public_ports,
      is_public_ingress: vm.is_public_ingress ?? false,
      idle_shutdown: vm.idle_shutdown ?? null,
      containers: vm.services,
      method: vm.method,
      gha: vm.gha,
      // Per-VM protection-stack overrides (load-shedder / tier1-apps / health-agent /
      // watchdog thresholds). Source of truth: b_infra/nixhm-sudo-<alias>/build.json
      // .protection. Merged over native.protection defaults by the Nix consumers.
      // Read via the SAME helper as public_ports/dashboard (correct b_infra path);
      // absent → {} (VM inherits defaults).
      protection: (loadVmHmBuild(vm.ssh_alias, CLOUD_ROOT)?.protection) ?? {},
    };
  }

  // Enrich homeManagerVms with dashboard config from HM build.json files
  const HM_DIR = join(CLOUD_ROOT, "b_infra", "home-manager");
  for (const alias of Object.keys(homeManagerVms)) {
    try {
      const bjPath = join(HM_DIR, `nixhm-sudo-${alias}`, "build.json");
      if (existsSync(bjPath)) {
        const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
        if (bj.dashboard) {
          homeManagerVms[alias].dashboard = bj.dashboard;
        }
      }
    } catch { /* skip if unreadable */ }
  }

  const sshEntries = Object.entries(homeManagerVms).flatMap(([alias, v]: [string, any]) => {
    const idFile = v.method === "gcloud" ? "~/.ssh/google_compute_engine" : "~/.ssh/vault_id_rsa";
    const hostname = v.wg_ip ?? v.ip;
    const entries = [{
      host: alias,
      hostname,
      user: v.user,
      identity_file: idFile,
      port: 22,
    }];
    // Dropbear rescue SSH alias (same host, port 2200)
    if (v.rescue_port) {
      entries.push({
        host: `${alias}-dropbear`,
        hostname,
        user: v.user,
        identity_file: idFile,
        port: v.rescue_port,
      });
    }
    return entries;
  });

  // Enrich mesh peers with wg_ipv6 (ULA) from config.json vms + clients (by name).
  const wgIpv6ByName: Record<string, string> = {};
  for (const vm of Object.values(vms) as any[]) {
    if (vm.ssh_alias && vm.wg_ipv6) wgIpv6ByName[vm.ssh_alias] = vm.wg_ipv6;
  }
  for (const [cname, c] of Object.entries(native.wireguard?.clients ?? {}) as [string, any][]) {
    if (c.wg_ipv6) wgIpv6ByName[cname] = c.wg_ipv6;
  }
  for (const peer of wgPeers) {
    if (wgIpv6ByName[peer.name]) (peer as any).wg_ipv6 = wgIpv6ByName[peer.name];
  }

  const wireguardSection = {
    subnet: native.wireguard?.subnet ?? "10.0.0.0/24",
    subnet_v6: native.wireguard?.subnet_v6 ?? null,
    port: native.wireguard?.port ?? 51820,
    // Fallback port: hub-side NAT redirect on gcp-proxy (Phase 4: udp/<port_fallback> -> udp/<port>)
    // Clients on networks blocking udp/51820 (airport/hotel WiFi) switch to this port.
    port_fallback: native.wireguard?.port_fallback ?? null,
    port_fallback_proto: native.wireguard?.port_fallback_proto ?? "udp",
    hub: native.wireguard?.wg_hub ?? null,
    peers: wgPeers,
    clients: Object.fromEntries(
      Object.entries(native.wireguard?.clients ?? {}).map(([name, client]: [string, any]) => [
        name,
        { ...client, wg_public_key: vaultWgKeys[name] ?? client.wg_public_key ?? null },
      ])
    ),
  };

  // ── 13b. WireGuard PUBLIC mesh ────────────────────────────────────────
  // Second WG interface ("wg-public") between the public-facing VM
  // (oci-analytics hub) and the 3 service VMs (gcp-proxy, oci-mail,
  // oci-apps), plus client peers (operator devices). Distinct subnet
  // (10.1.0.0/24) and port (51821) from wg0.
  //
  // SINGLE source of truth — no fallback:
  //   a_solutions/infra-net_wireguard-public/build.json::wireguard_public
  //
  // Read via the SAME pipeline as every other service: scanBuildJsons()
  // picks the field up into entry.extra.wireguard_public (the generic
  // catch-all for non-typed top-level keys), then this engine finds the
  // single entry that owns it. No special-case file read here.
  //
  // Public keys live at vault/A0_keys/providers/wireguard/<name>-public/publickey.
  //
  // If no scanned entry carries the field this engine FAILS LOUDLY rather
  // than silently degrading — wg-public is critical infra; a stale or
  // missing topology would lock peers out. Recovery is to restore the
  // owning build.json from git, never to add a fallback here.
  const wgPublicEntries = buildEntries.filter(
    (e: any) => e.extra && e.extra.wireguard_public
  );
  if (wgPublicEntries.length === 0) {
    throw new Error(
      `wg-public SoT not found: no a_solutions/*/build.json carries a ` +
      `top-level 'wireguard_public' field. Expected owner: ` +
      `a_solutions/infra-net_wireguard-public/build.json. Restore from git ` +
      `and retry.`
    );
  }
  if (wgPublicEntries.length > 1) {
    throw new Error(
      `wg-public SoT collision: ${wgPublicEntries.length} build.json files ` +
      `declare 'wireguard_public': ${wgPublicEntries.map((e: any) => e.folder).join(", ")}. ` +
      `Exactly one entry must own this field.`
    );
  }
  const wgPublicOwner = wgPublicEntries[0] as any;
  const wgPublicCfg = wgPublicOwner.extra.wireguard_public;
  if (!wgPublicCfg || typeof wgPublicCfg !== "object") {
    throw new Error(
      `wg-public SoT malformed: ${wgPublicOwner.folder}/build.json has 'wireguard_public' ` +
      `but it is not an object. Expected { subnet, port, hub, peers[], clients{} }.`
    );
  }
  const wireguardPublicSection = wgPublicCfg ? {
    subnet: wgPublicCfg.subnet ?? "10.1.0.0/24",
    subnet_v6: wgPublicCfg.subnet_v6 ?? null,
    port: wgPublicCfg.port ?? 51821,
    hub: wgPublicCfg.hub ?? null,
    _doc: wgPublicCfg._doc ?? null,
    peers: (wgPublicCfg.peers ?? []).map((p: any) => {
      // Resolve endpoint from VM IP (hub peer needs publicly reachable endpoint)
      const vmEntry = Object.values(vms).find((v: any) => v.ssh_alias === p.name) as any;
      const endpoint = vmEntry?.ip ? `${vmEntry.ip}:${wgPublicCfg.port ?? 51821}` : "dynamic";
      return {
        name: p.name,
        wg_ip: p.wg_ip,
        wg_ipv6: p.wg_ipv6 ?? null,
        role: p.role ?? "spoke",
        endpoint,
        wg_public_key: vaultWgKeys[`${p.name}-public`] ?? null,
      };
    }),
    // Mirrors wireguard.clients shape — non-VM client peers (Surface laptop,
    // Termux phone). Vault key dir is `<name>-public` (parallel to the VM
    // peer naming convention above).
    clients: Object.fromEntries(
      Object.entries(wgPublicCfg.clients ?? {}).map(([name, client]: [string, any]) => [
        name,
        { ...client, wg_public_key: vaultWgKeys[`${name}-public`] ?? client.wg_public_key ?? null },
      ])
    ),
  } : null;

  // ── 16. GHA config (previously gen-gha-config.ts) ──────────────────────
  const ghaVms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    if (!vm.ssh_alias || !vm.gha) continue;
    ghaVms[vm.ssh_alias] = {
      ssh_secret: vm.gha.ssh_secret,
      user: vm.user,
      ...(vm.gha.host_literal ? { host: vm.ip } : {}),
      ...(vm.gha.host_secret ? { host_secret: vm.gha.host_secret, user_secret: vm.gha.user_secret } : {}),
      // PLAN-ghcr-artifacts.md item 4: optional self-hosted runner label for
      // this VM's deploy job (vms.<host>.runner_label in config.json — a
      // top-level field on the vm, NOT under .gha, since it names a GHA
      // runner that happens to live on the VM, not a GHA-credential
      // concern). Present -> ship.yml's deploy job runs directly on that
      // label (docker socket, no ssh/rsync/WG — the runner IS the VM).
      // Absent -> omitted entirely, same as today; ship.yml's own fallback
      // (`matrix.runner_label || 'ubuntu-latest'`) is what makes "no label
      // set" behaviour-neutral, not a value written here.
      ...(vm.runner_label ? { runner_label: vm.runner_label } : {}),
      // Per-VM deploy disk floor (vms.<host>.gha.min_free_gb in config.json): a ship refuses to
      // start on this VM with less free space on / than this, after pruning dangling images.
      // Absent -> the engine default (5 GB). See cloud-ship-disk-headroom.sh.
      ...(typeof vm.gha.min_free_gb === "number" ? { min_free_gb: vm.gha.min_free_gb } : {}),
    };
  }

  const ghaServices: Record<string, any> = {};
  for (const [name, svc] of Object.entries(services) as [string, any][]) {
    const folder = svc.folder;
    if (!folder) continue;
    const bjPath = join(SOLUTIONS_DIR, folder, "build.json");
    if (!existsSync(bjPath)) continue;
    try {
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      const host = bj.deploy?.host;
      if (!host || host === "local" || host === "all") continue;
      if (bj.frozen) continue;
      ghaServices[name] = { dir: folder, vm: host, has_docker: !!bj.docker };
    } catch { continue; }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Expand gitea mirror policy against the real inventory
  // ═══════════════════════════════════════════════════════════════════════
  // Hand-listed mirrors drift from reality in both directions, and both had
  // already happened: `front` named a repo that has never existed (so that
  // mirror could only ever fail), and `cloud-data` — private on GitHub — was
  // mirrored WITHOUT private:true, meaning gitea republished a private repo.
  // Deriving the list from the fetched inventory makes both impossible:
  // every repo is covered, and visibility is copied from the real repo rather
  // than remembered by hand.
  expandGiteaMirrors(services, githubInventory);

  // ═══════════════════════════════════════════════════════════════════════
  // Assemble consolidated output
  // ═══════════════════════════════════════════════════════════════════════

  const consolidated = {
    _warning: "DO NOT EDIT — AUTO-GENERATED FILE. Source of truth lives in a_solutions/*/build.json + config.json + b_infra/*/build.json. Edits here are overwritten on every `bash 9_others/build.sh all`.",
    _meta: {
      version: 2,
      generated_at: reproducibleNow(),
      generated_by: "1_cloud-configs/src/derive/cloud-data-config-consolidated.ts",
      pipeline: {
        description: "Two-stage build: consolidator merges all build.json + config.json sources into the master file; derive emits per-container + archived split files from the master.",
        source_inputs: [
          "a_solutions/*/build.json (per-service declarations)",
          "config.json (global topology + vms + dns + wireguard)",
          "b_infra/*/build.json (per-VM HM config)",
          "vault/secrets.yaml (sops-encrypted secrets per service, key names extracted)",
        ],
        engines: {
          consolidator: "1_cloud-configs/src/derive/cloud-data-config-consolidated.ts",
          derive: "1_cloud-configs/src/derive/cloud-data-config-derive.ts",
        },
        outputs: {
          master: "1_cloud-configs/dist/_cloud-data-consolidated.json (this file)",
          per_container: "1_cloud-configs/dist/build-{container_or_service_name}.json (one per container in topology, plus one for each container-less service)",
          archived: "1_cloud-configs/dist/z_archive/cloud-data-{slice}.json (deprecated split files — kept for soft-transition fallbacks; consumers should read consolidated instead)",
        },
        rebuild_command: "bash 9_others/build.sh all",
      },
    },
    owner: config.owner ?? {},
    home_manager: config.home_manager ?? { state_version: "24.11" },
    ssh_key: config.ssh_key ?? "/home/diego/git/cloud-vault/A0_keys/ssh/id_rsa",
    remote_base: config.remote_base ?? "/opt/containers",
    engine_folder: config.engine_folder ?? "bc-obs_c3-infra-mcp",
    vms,
    vpss,
    native: {
      wireguard: wireguardSection,
      ...(wireguardPublicSection ? { wireguard_public: wireguardPublicSection } : {}),
      dns: native.dns ?? { primary: "10.0.0.1", fallback: "1.1.1.1" },
      docker: native.docker ?? { subnet: "172.16.0.0/12", iptables: false },
      monitoring: native.monitoring ?? { ntfy_base: "https://rss.diegonmarcos.com" },
      // Cross-VM protection-stack defaults. Consumed by vm-pilot protection modules
      // (load-shedder / tier1-apps / health-agent / watchdog); per-VM overrides live
      // under _home_manager.vms.<alias>.protection and win over these defaults.
      protection: native.protection ?? {},
    },
    // Top-level convenience alias (also lives under native.wireguard_public).
    // Phase 1 of the wg-public mesh plan — consumers can read either path.
    ...(wireguardPublicSection ? { wireguard_public: wireguardPublicSection } : {}),
    deps,
    services,
    firewalls,
    storage,
    databases: buildDatabases(services, storage, config.owner ?? {}, githubInventory),
    dns,
    configs,
    // Embedded sub-outputs (previously separate generators)
    _home_manager: {
      vms: homeManagerVms,
      ssh_config: sshEntries,
    },
    _gha: {
      vms: ghaVms,
      services: ghaServices,
    },
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Inject enabled + ssh fields from build.json (read directly to avoid tsx cache)
  // ═══════════════════════════════════════════════════════════════════════
  let disabledCount = 0;
  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    const bjPath = join(SOLUTIONS_DIR, svc.folder, "build.json");
    if (existsSync(bjPath)) {
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      svc.enabled = bj.enabled ?? true;
      if (!svc.enabled) disabledCount++;
      // ssh: per-service container SSH-key requirement
      // Shape: { uid: int, ssh_dir: string, keys: string[] }
      // Consumed by: vm-pilot/src/modules/security/ssh-keys.nix (via per-VM
      // homeManagerVms[alias].ssh_containers, derived below).
      if (bj.ssh) svc.ssh = bj.ssh;
    } else {
      svc.enabled = true;
    }
  }
  if (disabledCount > 0) {
    console.log(`  Disabled: ${disabledCount} services (enabled: false)`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Derive per-VM ssh_containers from enriched services[*].ssh
  // ═══════════════════════════════════════════════════════════════════════
  // For each VM, look up its services that declared a top-level `ssh` field
  // in their build.json, and emit them as a `ssh_containers` array on the
  // VM's homeManagerVms entry. This is what ssh-keys.nix consumes.
  // build.json `ssh.extra_hosts`: ssh aliases a container needs beyond the
  // fleet VMs (e.g. cloud-superapp-mcp -> the phone). Each entry names a mesh
  // client instead of an IP, so the address has ONE source:
  //   { host, wg_client, family: "v4"|"v6", user, port, identity_file? }
  // hostname := native.wireguard.clients[wg_client].wg_ip | wg_ipv6.
  // An unresolvable entry FAILS the derive: a silently missing Host block is
  // exactly how SUPERAPP_HOSTS ended up naming aliases no config defined.
  const resolveExtraHosts = (svcName: string, raw: any): any[] => {
    if (raw == null) return [];
    if (!Array.isArray(raw)) throw new Error(`${svcName}: ssh.extra_hosts must be an array`);
    const clients = native.wireguard?.clients ?? {};
    return raw.map((e: any) => {
      const c = clients[e.wg_client];
      if (!e.host || !c) throw new Error(`${svcName}: ssh.extra_hosts entry ${JSON.stringify(e.host)} names unknown wg_client ${JSON.stringify(e.wg_client)}`);
      const hostname = (e.family ?? "v4") === "v6" ? c.wg_ipv6 : c.wg_ip;
      if (!hostname) throw new Error(`${svcName}: wg_client ${e.wg_client} has no ${e.family ?? "v4"} address`);
      if (!e.user || !Number.isInteger(e.port)) throw new Error(`${svcName}: ssh.extra_hosts ${e.host} needs user and integer port`);
      return { host: e.host, hostname, user: e.user, port: e.port, identity_file: e.identity_file ?? "~/.ssh/vault_id_rsa" };
    });
  };
  // build.json `ssh.phones` x `ssh.doors` (cloud-superapp-mcp, #1106): the phones are declared ONCE
  // ({alias, wg_client}) and the doors once ({suffix, user, port}); every ssh alias the MCP dials is
  // their product, so a Host block can no longer be missing for a declared phone. Names follow the
  // MCP's own rule: <alias><suffix> (v4) and <alias><suffix>-v6. Explicit extra_hosts still merge in
  // (an explicit host of the same name wins), so nothing already declared changes meaning.
  const mergeExtraHosts = (svcName: string, ssh: any): any[] => {
    const explicit: any[] = Array.isArray(ssh.extra_hosts) ? ssh.extra_hosts : [];
    if (ssh.phones == null && ssh.doors == null) return explicit;
    if (!Array.isArray(ssh.phones) || !Array.isArray(ssh.doors)) throw new Error(`${svcName}: ssh.phones and ssh.doors must both be arrays`);
    const byHost = new Map<string, any>();
    for (const p of ssh.phones) {
      if (!p.alias || !p.wg_client) throw new Error(`${svcName}: ssh.phones entry needs alias and wg_client (${JSON.stringify(p)})`);
      for (const d of ssh.doors) {
        for (const family of ["v4", "v6"]) {
          const host = `${p.alias}${d.suffix ?? ""}${family === "v6" ? "-v6" : ""}`;
          byHost.set(host, { host, wg_client: p.wg_client, family, user: d.user, port: d.port });
        }
      }
    }
    for (const e of explicit) byHost.set(e.host, e);
    return [...byHost.values()];
  };
  for (const [alias, hmVm] of Object.entries(homeManagerVms) as [string, any][]) {
    const containerSshTargets: any[] = [];
    for (const svcName of (hmVm.containers ?? []) as string[]) {
      const svc = (services as any)[svcName];
      if (svc?.ssh) {
        // Apply the SSH target to each container_name of the service
        // (most services = 1 container with same name; multi-container
        // services would need to opt in per container, not handled yet).
        const cnames = svc.container_names && svc.container_names.length > 0
          ? svc.container_names
          : [svcName];
        for (const cname of cnames as string[]) {
          containerSshTargets.push({
            name: cname,
            uid: svc.ssh.uid ?? 0,
            ssh_dir: svc.ssh.ssh_dir ?? "/root/.ssh",
            keys: svc.ssh.keys ?? [],
            extra_hosts: resolveExtraHosts(svcName, mergeExtraHosts(svcName, svc.ssh)),
          });
        }
      }
    }
    if (containerSshTargets.length > 0) {
      hmVm.ssh_containers = containerSshTargets;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Write output
  // ═══════════════════════════════════════════════════════════════════════

  if (!existsSync(CLOUD_DATA_DIR)) {
    mkdirSync(CLOUD_DATA_DIR, { recursive: true });
  }

  const jsonStr = JSON.stringify(consolidated, null, 2) + "\n";
  // NO NULL KEYS LEAVE THIS FUNCTION.
  //
  // wireguard.nix throws on a null VM key and — worse — SILENTLY DROPS a
  // client with one, so a bad derive either breaks every deploy or removes a
  // peer from the hub with a green build. Both have happened. Failing here
  // costs one derive; the alternative costs the fleet.
  {
    const parsed = JSON.parse(jsonStr);
    const missing = [
      ...(parsed?.native?.wireguard?.peers ?? []).filter((p: any) => !p?.wg_public_key).map((p: any) => `peer ${p?.name}`),
      ...Object.entries<any>(parsed?.native?.wireguard?.clients ?? {})
        .filter(([, c]) => !(c?.wg_public_key ?? c?.public_key)).map(([n]) => `client ${n}`),
    ];
    if (missing.length) {
      throw new Error(
        `refusing to write ${OUTPUT_JSON} with null wg_public_key: ${missing.join(", ")}.\n` +
        `  The vault (~/git/cloud-vault) was absent AND no previous output or shipped pilot\n` +
        `  bundle carried these keys. Derive on a machine with the vault, or restore the\n` +
        `  last good dist — do not commit nulls: wireguard.nix throws on a null VM key and\n` +
        `  silently drops a client with one.`,
      );
    }
  }
  // SERVICE-COUNT FLOOR. A partial or missing a_solutions checkout does not
  // fail anything upstream of here — it just yields fewer services, and every
  // build-*.json derived from this file silently loses them. The count may
  // only drop by services whose removal is DECLARED, i.e. whose build.json was
  // moved to a_solutions/z_archive/ (cloud-u-containers' retirement idiom).
  // A plain deletion or an absent checkout has no such declaration and fails.
  if (existsSync(OUTPUT_JSON)) {
    const prev = Object.keys(JSON.parse(readFileSync(OUTPUT_JSON, "utf-8"))?.services ?? {});
    const next = Object.keys(consolidated.services ?? {});
    const archived = new Set(scanBuildJsons(join(SOLUTIONS_DIR, "z_archive")).map((e) => e.name));
    const declaredRemovals = prev.filter((n) => !next.includes(n) && archived.has(n));
    if (next.length + declaredRemovals.length < prev.length) {
      const undeclared = prev.filter((n) => !next.includes(n) && !archived.has(n));
      throw new Error(
        `refusing to write ${OUTPUT_JSON}: service count would collapse ${prev.length} -> ${next.length} ` +
        `with ${declaredRemovals.length} declared removal(s). Undeclared: ${undeclared.join(", ")}.\n` +
        `  Retire a service by moving it to a_solutions/z_archive/; a missing or partial ` +
        `a_solutions checkout is not a removal.`,
      );
    }
  }
  writeFileSync(OUTPUT_JSON, jsonStr);

  // Refresh MATERIALIZED service copies. Most consumers symlink
  // a_solutions/<svc>/src/_cloud-data-consolidated.json → 1_cloud-configs/dist/, but
  // services whose docker build context is src/ carry a real-file copy (a symlink
  // escaping the context would break `docker build`). Nothing else refreshed those
  // copies, so they silently went stale (observed: cloud-cgc-mcp serving a June
  // topology in July). Discover-and-rewrite keeps 9_others the sole emitter —
  // no hardcoded service list; symlinked consumers are untouched (lstat).
  for (const dir of readdirSync(SOLUTIONS_DIR)) {
    const copy = join(SOLUTIONS_DIR, dir, "src", "_cloud-data-consolidated.json");
    try {
      if (lstatSync(copy).isFile()) {
        writeFileSync(copy, jsonStr);
        console.log(`cloud-data-config-consolidated: refreshed materialized copy ${dir}/src/`);
      }
    } catch { /* absent — nothing to refresh */ }
  }

  console.log(`cloud-data-config-consolidated: written to ${CLOUD_DATA_DIR}`);

  const svcCount = Object.keys(services).length;
  const vmCount = Object.keys(vms).length;
  const depCount = perServiceDeps.length;
  console.log(`\ncloud-data-config-consolidated: written _cloud-data-consolidated.json`);
  console.log(`  ${vmCount} VMs, ${svcCount} services, ${depCount} service deps, ${caddyRoutes.length} Caddy routes`);
  console.log("cloud-data-config-consolidated: done.");
}

// ═══════════════════════════════════════════════════════════════════════════
// Deps scanning (from gen-deps.ts)
// ═══════════════════════════════════════════════════════════════════════════

function scanNodeDeps(buildEntries: BuildJsonEntry[]): {
  mergedDeps: Record<string, string>;
  mergedDevDeps: Record<string, string>;
  perServiceDeps: ServiceDeps[];
} {
  const mergedDeps: Record<string, string> = {};
  const mergedDevDeps: Record<string, string> = {};
  const perServiceDeps: ServiceDeps[] = [];

  const folders = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();

  for (const folder of folders) {
    const pkgPath = join(SOLUTIONS_DIR, folder, "src", "package.json");
    if (!existsSync(pkgPath)) continue;

    // Find matching build entry for metadata
    const buildJsonPath = join(SOLUTIONS_DIR, folder, "build.json");
    let category = "unknown";
    let serviceName = folder;
    if (existsSync(buildJsonPath)) {
      try {
        const bj = readJson(buildJsonPath) as { name?: string; category?: string };
        serviceName = bj.name ?? folder;
        category = bj.category ?? "unknown";
      } catch { /* use defaults */ }
    }

    try {
      const pkg = readJson(pkgPath) as {
        dependencies?: Record<string, string>;
        devDependencies?: Record<string, string>;
      };
      const deps = pkg.dependencies ?? {};
      const devDeps = pkg.devDependencies ?? {};

      for (const [k, v] of Object.entries(deps)) {
        mergedDeps[k] = takeHigher(mergedDeps[k], v);
      }
      for (const [k, v] of Object.entries(devDeps)) {
        mergedDevDeps[k] = takeHigher(mergedDevDeps[k], v);
      }

      perServiceDeps.push({
        service: serviceName,
        folder,
        category,
        dependencies: deps,
        devDependencies: devDeps,
      });
    } catch (e) {
      console.warn(`  WARN: failed to parse ${pkgPath}: ${e}`);
    }
  }

  // Include repo-level config.json deps.node.required
  if (existsSync(CONFIG_JSON)) {
    try {
      const config = readJson(CONFIG_JSON) as { deps?: { node?: { required?: string[] } } };
      const required = config.deps?.node?.required ?? [];
      for (const pkg of required) {
        if (!mergedDeps[pkg] && !mergedDevDeps[pkg]) {
          mergedDeps[pkg] = "latest";
        }
      }
    } catch { /* skip */ }
  }

  return { mergedDeps, mergedDevDeps, perServiceDeps };
}

function readSystemDeps(config: any): {
  system: Record<string, SystemDep>;
  build: Record<string, SystemDep>;
  optional: Record<string, SystemDep>;
} {
  return {
    system: config.deps?.system ?? {},
    build: config.deps?.build ?? {},
    optional: config.deps?.optional ?? {},
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// buildDatabases — one canonical registry of every datastore we own
//
// Before this existed the answer to "what databases do we have" was spread
// across three places that disagreed: containers carrying `db_engine`, the
// `embedded_dbs` declarations (14 of them — stalwart's rocksdb, every sqlite
// file, radicale's flat files — which no fleet category listed at all), and
// the S3 bucket list. Git repos were nowhere, despite being the store behind
// gitea and the octocode index.
//
// Two orthogonal axes are kept deliberately separate, because conflating them
// is what made the old `db-hd` category mean two different things in two
// files:
//
//   kind        WHAT it is        container | embedded | object-store | git-remote
//   persistence WHERE it survives docker-volume | docker-bind | s3 | git | unknown
//
// A postgres container is kind=container persistence=docker-volume; stalwart's
// rocksdb is kind=embedded persistence=docker-volume; a bucket is
// kind=object-store persistence=s3. Fleet groups are then a pure projection of
// one axis or the other, never a hand-maintained third list.
// ═══════════════════════════════════════════════════════════════════════════

/** "src:dst[:mode]" → {type, ref, mount}. A leading / means a host bind. */
function classifyVolume(spec: string): { type: string; ref: string; mount: string | null } {
  const [src, dst] = String(spec).split(":");
  return {
    type:  src.startsWith("/") ? "docker-bind" : "docker-volume",
    ref:   src,
    mount: dst ?? null,
  };
}

/** Pick the volume whose mountpoint contains `path` — that is what actually
 *  persists an embedded store. Falls back to the container's first volume. */
function volumeForPath(volumes: string[], path: string | undefined) {
  const parsed = (volumes ?? []).map(classifyVolume);
  if (path) {
    const hit = parsed
      .filter(v => v.mount && path.startsWith(v.mount))
      .sort((a, b) => (b.mount!.length - a.mount!.length))[0];   // longest match wins
    if (hit) return hit;
  }
  return parsed[0] ?? { type: "unknown", ref: null as any, mount: null };
}

function buildDatabases(services: Record<string, any>, storage: any[], owner: any, githubInventory: any): any {
  const entries: any[] = [];
  // From the owner block in the SoT — never a literal.
  const ownerGithub: string = owner?.github ?? "";
  // Derived from the same place the mirrors point at, so the forge host is not
  // asserted here either; falls back to github.com only if nothing declares it.
  const githubBase: string = (() => {
    for (const svc of Object.values<any>(services ?? {})) {
      for (const m of Object.values<any>(svc?.gitea?.mirrors ?? {})) {
        const u = String(m?.upstream ?? "");
        const hit = u.match(/^(https?:\/\/[^/]+)\//);
        if (hit) return hit[1];
      }
    }
    return "https://github.com";
  })();

  for (const [svcId, svc] of Object.entries(services ?? {})) {
    if (!svc || typeof svc !== "object") continue;
    const vm = (svc as any).vm ?? null;
    const backup = (svc as any).backup ?? {};
    for (const [ctName, ct] of Object.entries<any>((svc as any).containers ?? {})) {
      const vols: string[] = ct.volumes ?? [];

      // A container whose whole job is being a database.
      if (ct.db_engine) {
        const p = volumeForPath(vols, undefined);
        entries.push({
          id: `${svcId}/${ctName}`, service: svcId, container: ctName,
          engine: ct.db_engine, kind: "container",
          persistence: { type: p.type, ref: p.ref, mount: p.mount },
          port: ct.port ?? null, vm,
          backup: { enabled: backup.enabled ?? false, strategy: backup.strategy ?? null },
        });
      }

      // Datastores living *inside* an application container.
      for (const edb of (ct.embedded_dbs ?? []) as any[]) {
        if (!edb?.engine) continue;
        const p = volumeForPath(vols, edb.path);
        entries.push({
          id: `${svcId}/${ctName}#${edb.engine}`, service: svcId, container: ctName,
          engine: edb.engine, kind: "embedded", path: edb.path ?? null,
          persistence: { type: p.type, ref: p.ref, mount: p.mount },
          port: edb.port ?? null, vm,
          backup: { enabled: backup.enabled ?? false, strategy: backup.strategy ?? null },
        });
      }
    }
  }

  // Object storage.
  for (const s of storage ?? []) {
    entries.push({
      id: s.name, service: null, container: null,
      engine: "s3", kind: "object-store",
      persistence: { type: "s3", ref: s.name, mount: null },
      provider: s.provider ?? null, region: s.region ?? null,
      tier: s.tier ?? null, endpoint: s.s3_endpoint ?? null, dns: s.dns ?? null,
      vm: null, backup: { enabled: false, strategy: null },
    });
  }

  // ── Git remotes ──────────────────────────────────────────────────────────
  // WHICH REPOS EXIST is answered by the fetched GitHub inventory, never by
  // our own declarations. gitea.mirrors and octocode.repo_map answer a
  // different question — which repos we mirror and index — and are applied
  // here as FLAGS on top of the real inventory. Deriving existence from the
  // declarations is what let a gitea mirror point at diegonmarcos/front, a
  // repo that has never existed, and silently never sync.
  //
  // Both providers are still discovered by shape (any service declaring
  // runtime.octocode.repo_map / gitea.mirrors), so no service id is named.
  const declaredIndex = new Map<string, { indexedBy?: string; localDir?: string }>();
  const declaredMirror = new Map<string, { by: string; upstream: string | null; vm: any; backup: any }>();
  const danglingDeclarations: any[] = [];

  for (const [svcId, svc] of Object.entries<any>(services ?? {})) {
    if (!svc || typeof svc !== "object") continue;
    const oc = svc.runtime?.octocode;
    if (oc?.repo_map) {
      const idx: string[] = oc.index_repos ?? [];
      for (const [localDir, repo] of Object.entries<any>(oc.repo_map)) {
        if (idx.includes(localDir)) declaredIndex.set(String(repo), { indexedBy: svcId, localDir });
      }
    }
    for (const [name, m] of Object.entries<any>(svc.gitea?.mirrors ?? {})) {
      const upstream: string | null = m?.upstream ?? null;
      const repoName = upstream
        ? upstream.replace(/\.git$/, "").split("/").pop()!
        : name;
      declaredMirror.set(repoName, {
        by: svcId, upstream, vm: svc.vm ?? null, backup: svc.backup ?? {},
      });
    }
  }

  const inventory: any[] = githubInventory?.repos ?? [];
  const known = new Set(inventory.map(r => r.name));

  for (const r of inventory) {
    const idx = declaredIndex.get(r.name);
    const mir = declaredMirror.get(r.name);
    entries.push({
      id: `git#gh/${r.name}`, service: idx?.indexedBy ?? mir?.by ?? null, container: null,
      engine: "git", kind: "git-remote", host: "github",
      repo: `${ownerGithub}/${r.name}`,
      visibility: r.visibility ?? null, fork: r.fork ?? false, pushed_at: r.pushed_at ?? null,
      indexed: Boolean(idx), local_dir: idx?.localDir ?? null,
      mirrored: Boolean(mir),
      persistence: { type: "git", ref: `${githubBase}/${ownerGithub}/${r.name}.git`, mount: null },
      vm: null, backup: { enabled: false, strategy: null },
    });
    if (mir) {
      entries.push({
        id: `git#gitea/${r.name}`, service: mir.by, container: null,
        engine: "git", kind: "git-remote", host: "gitea",
        repo: r.name, upstream: mir.upstream,
        persistence: { type: "git", ref: mir.upstream, mount: null },
        vm: mir.vm,
        backup: { enabled: mir.backup?.enabled ?? false, strategy: mir.backup?.strategy ?? null },
      });
    }
  }

  // A declaration naming a repo that does not exist is a live defect: the
  // mirror or index job for it can only ever fail. Surfaced in the output
  // rather than thrown, so one stale entry does not block every build.
  for (const [repo, mir] of declaredMirror) {
    if (!known.has(repo)) danglingDeclarations.push({ kind: "gitea-mirror", repo, upstream: mir.upstream, declared_by: mir.by });
  }
  for (const [repo, idx] of declaredIndex) {
    if (!known.has(repo)) danglingDeclarations.push({ kind: "octocode-index", repo, declared_by: idx.indexedBy });
  }

  const tally = (key: string) =>
    entries.reduce<Record<string, number>>((a, e) => {
      const k = key === "kind" ? e.kind : e.persistence?.type ?? "unknown";
      a[k] = (a[k] ?? 0) + 1; return a;
    }, {});

  return {
    _doc: "Canonical registry of every datastore. `kind` is what it is; `persistence.type` is where it survives. Fleet groups project one axis — never hand-maintain a parallel list. Git existence comes from the fetched GitHub inventory (src/inputs/github-repos.json); mirrored/indexed are declaration-driven flags on top.",
    _counts: {
      total: entries.length,
      by_kind: tally("kind"),
      by_persistence: tally("persistence"),
      github_repos: (githubInventory?.repos ?? []).length,
      github_indexed: entries.filter(e => e.host === "github" && e.indexed).length,
      github_mirrored: entries.filter(e => e.host === "github" && e.mirrored).length,
    },
    // Non-empty means a declaration points at a repo that does not exist —
    // its mirror/index job cannot ever succeed.
    _dangling_declarations: danglingDeclarations,
    entries,
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Run
// ═══════════════════════════════════════════════════════════════════════════

main();

// ═══════════════════════════════════════════════════════════════════════════
// expandGiteaMirrors — mirror_policy + inventory → concrete gitea.mirrors
//
// Discovered by shape: any service declaring gitea.mirror_policy gets its
// mirrors expanded, so no service id is named here. A service that still
// hand-lists gitea.mirrors is left untouched, which keeps this backwards
// compatible and makes the migration opt-in per service.
// ═══════════════════════════════════════════════════════════════════════════
function expandGiteaMirrors(services: Record<string, any>, githubInventory: any): void {
  const repos: any[] = githubInventory?.repos ?? [];
  const owner: string = githubInventory?.owner ?? "";
  if (!repos.length) return;

  for (const [svcId, svc] of Object.entries<any>(services ?? {})) {
    const policy = svc?.gitea?.mirror_policy;
    if (!policy) continue;

    const exclude = new Set<string>(policy.exclude ?? []);
    const includeForks: boolean = policy.include_forks === true;

    const mirrors: Record<string, any> = {};
    for (const r of repos) {
      if (exclude.has(r.name)) continue;
      if (r.fork && !includeForks) continue;
      mirrors[r.name] = {
        upstream: `https://github.com/${owner}/${r.name}.git`,
        // Copied from the repo's REAL visibility — a private upstream must
        // never land in gitea as a public mirror.
        ...(r.visibility === "private" ? { private: true } : {}),
      };
    }
    svc.gitea.mirrors = mirrors;
    const priv = Object.values(mirrors).filter((m: any) => m.private).length;
    console.log(`  gitea mirrors (${svcId}): ${Object.keys(mirrors).length} repos (${priv} private)${includeForks ? "" : ", forks excluded"}`);
  }
}
