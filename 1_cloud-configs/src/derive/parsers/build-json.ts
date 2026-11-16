import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

export interface ProxyPathOverride {
  upstream?: string;
  auth?: string;
  strip_prefix?: boolean;
}

// New schema: proxy.primary — the custom/vanity route
export interface ProxyPrimaryConfig {
  domain?: string;
  type?: "subdomain" | "path" | "l4";
  parent_domain?: string;
  base_path?: string;
  auth?: string;
  paths?: Record<string, ProxyPathOverride>;
  github_pages?: string;
  landing_page?: string;
  tls_skip_verify?: boolean;
  max_upload?: string;
  streaming?: boolean;
  timeout?: string;
}

// New schema: proxy.app_hub — standardized app.diegonmarcos.com/{name} route
export interface AppHubConfig {
  enabled?: boolean;   // default: true (false for infra/backend services)
  auth?: string;       // inherits from primary.auth if not set
}

// Combined proxy config — supports both old flat format and new primary/app_hub format
export interface ProxyConfig {
  // New schema fields
  primary?: ProxyPrimaryConfig;
  app_hub?: AppHubConfig | false;

  // Legacy flat fields (backward compat during migration)
  upstream?: string;
  auth?: string;
  paths?: Record<string, ProxyPathOverride>;
  github_pages?: string;
  landing_page?: string;
  tls_skip_verify?: boolean;
  max_upload?: string;
  streaming?: boolean;
  timeout?: string;
  type?: "subdomain" | "path" | "l4";
  parent_domain?: string;
  base_path?: string;
  additional_routes?: unknown[];
}

export interface PortConfig {
  container: number;
  host?: number;
  proto?: "tcp" | "udp";
  public?: boolean;
}

export interface HealthConfig {
  path?: string;
  interval?: string;
  timeout?: string;
  expected_status?: number;
}

export interface MonitoringConfig {
  tls_check?: boolean;
  dns_check?: boolean;
  endpoint_check?: boolean;
}

export interface BackupConfig {
  enabled?: boolean;
  volumes?: string[];
  schedule?: string;
  retention?: string;
}

export interface NotificationsConfig {
  topic?: string;
  on_failure?: boolean;
  on_recovery?: boolean;
}

// ── Container spec — per-container declaration in build.json ───────────
export type PortProtocol = "http" | "https" | "tls" | "starttls" | "tcp" | "udp";

export interface PortSpec {
  port: number;
  protocol: PortProtocol;
}

// Embedded DB engines that live INSIDE an application container (no network port).
// Declared per-container so the .db zone can surface them alongside real DB containers.
export type EmbeddedDbEngine =
  | "sqlite" | "rocksdb" | "leveldb" | "boltdb"
  | "mariadb" | "mysql" | "postgres"   // sometimes bundled inside an "all-in-one" image
  | "tsdb" | "wal" | "files";

export interface EmbeddedDbSpec {
  engine: EmbeddedDbEngine;
  path?: string;  // file/dir inside the container for backup tools
  port?: number;  // optional — set when a bundled DB is also network-exposed (e.g. matomo-hybrid mariadb:3306)
}

export interface ContainerSpec {
  container_name: string;
  image: string;
  port?: number | null;
  protocol?: PortProtocol;       // required when `port` is non-null
  port_env?: string | null;
  extra_ports?: PortSpec[];      // array of {port, protocol} — additional ports on the same container
  embedded_dbs?: EmbeddedDbSpec[];  // DBs living inside this container, no network port exposed
  db_engine?: EmbeddedDbEngine;     // declared when the container IS a DB (used by .db zone)
  dns?: string | null;
  bind_host?: string;            // interface this container is actually reachable on — overrides the VM wg0 IP when computing the Caddy/probe upstream
  cloud_run_bridge?: { host: string };  // #1686: container moved to Cloud Run; the Caddy/probe upstream becomes <host>:<port> (gcp-idtoken-bridge listener on the same port)
  public: boolean;
  proxy?: ProxyPrimaryConfig | null;
  healthcheck?: string | null;
  monitoring?: MonitoringConfig | null;
  volumes?: string[];
  env_file?: boolean;
  depends_on?: string[];
  resources?: {
    memory?: string;
    cpu?: string;
    pids?: number;
  } | null;
  read_only?: boolean;
  capabilities?: string[];
  log_level?: string;
  // Database metadata — for backup dump generation
  db_user?: string | null;     // Database user for pg_dump/mariadb-dump
  db_name?: string | null;     // Database name to dump
  db_path?: string | null;     // Path to sqlite/file DB inside the container
  dump_cmd?: string | null;    // Custom dump command (runs via docker exec)
}

export interface BuildJsonEntry {
  name: string;
  category: string;
  vm: string;
  domain?: string;
  description: string;
  flake?: string;
  folder: string;
  enabled?: boolean;             // default: true — set false to exclude from topology containers
  archived_at?: string;          // ISO date — set when moving folder to a_solutions/z_archive/
  archived_reason?: string;      // why it was retired — required alongside archived_at
  // Standardized routing fields
  port?: number;               // Main listening port (REQUIRED for routable services)
  dns?: string;                // Internal DNS name, e.g. "{name}.mesh.diegonmarcos.com" (REQUIRED for routable services)
  // Declarative infrastructure fields
  proxy?: ProxyConfig;
  ports?: Record<string, PortConfig>;
  health?: HealthConfig;
  monitoring?: MonitoringConfig;
  backup?: BackupConfig;
  notifications?: NotificationsConfig;
  // Multi-container declarations (new schema)
  containers?: Record<string, ContainerSpec>;
  // Declarative API / MCP surfaces — flow into services.<name>.{api,mcp} of every
  // per-container build-{name}.json via deriveServiceConnections.
  api?: Record<string, unknown>;
  mcp?: Record<string, unknown>;
  // Deploy overrides
  fallback_vm?: string;          // deploy.fallback_host → resolved to VM ID
  // Pass-through: any extra top-level fields from build.json (models, notes, etc.)
  extra?: Record<string, unknown>;
}

const CATEGORY_PREFIX: Record<string, string> = {
  app: "aa-sui_",
  mic: "ab-mic_",
  fin: "ac-fin_",
  agi: "ad-agi_",
  cloud: "ba-clo_",
  sec: "bb-sec_",
  tools: "bc-obs_",
  data: "ca-dat_",
};

const PREFIX_CATEGORY: Record<string, string> = {};
for (const [cat, prefix] of Object.entries(CATEGORY_PREFIX)) {
  PREFIX_CATEGORY[prefix] = cat;
}

export { CATEGORY_PREFIX, PREFIX_CATEGORY };

function deriveCategory(folder: string): string | undefined {
  for (const [prefix, cat] of Object.entries(PREFIX_CATEGORY)) {
    if (folder.startsWith(prefix)) return cat;
  }
  return undefined;
}

export function scanBuildJsons(solutionsDir: string): BuildJsonEntry[] {
  const entries: BuildJsonEntry[] = [];

  let dirs: string[];
  try {
    dirs = readdirSync(solutionsDir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith("z_archive") && !d.name.startsWith("."))
      .map((d) => d.name);
  } catch {
    return entries;
  }

  for (const folder of dirs) {
    const bjPath = join(solutionsDir, folder, "build.json");
    if (!existsSync(bjPath)) continue;

    try {
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      const name = bj.name;
      if (!name) continue;

      const category = bj.category || deriveCategory(folder) || "tools";
      const host = bj.deploy?.host ?? "local";
      const fallbackHost = bj.deploy?.fallback_host;

      const expectedFolder = CATEGORY_PREFIX[category]
        ? `${CATEGORY_PREFIX[category]}${name}`
        : name;
      const flake = folder !== expectedFolder
        ? folder.replace(/^[a-z]{2}-[a-z]{3}_/, "")
        : undefined;

      // ── Container-aware parsing ──────────────────────────────────
      // If build.json has `containers` key → new multi-container schema
      // Otherwise → legacy flat schema (derive primary from top-level fields)
      const containers: Record<string, ContainerSpec> | undefined = bj.containers;

      // For backward compat: derive flat port/dns from containers or top-level
      let port: number | undefined;
      let dns: string | undefined;
      let primaryDomain: string | undefined = bj.domain;
      let primaryProxy: ProxyConfig | undefined = bj.proxy;
      let primaryHealth: HealthConfig | undefined = bj.health;
      let primaryMonitoring: MonitoringConfig | undefined = bj.monitoring;

      if (containers) {
        // Find primary container: first with public=true, or key "app"
        const primaryKey = Object.keys(containers).find(k => containers[k].public) || "app";
        const primary = containers[primaryKey];
        if (primary) {
          port = primary.port ?? undefined;
          dns = primary.dns ?? undefined;
          if (primary.proxy?.domain) primaryDomain = primary.proxy.domain;
          if (primary.proxy) {
            // Merge: container.proxy is per-container HTTP routing (domain/auth);
            // top-level bj.proxy.primary may carry service-wide fields like
            // l4_ports (port-level passthrough at the perimeter, NOT tied to a
            // single container). Container fields win for overlapping keys, but
            // l4_ports from top-level must survive — otherwise services with
            // both (stalwart, maddy*) lose their L4 declarations downstream.
            // Sibling keys of bj.proxy (well_known, mail_hub, app_hub, etc.)
            // are also service-wide and must be preserved.
            const topProxyAll = (bj.proxy ?? {}) as Record<string, any>;
            const topPrimary = (topProxyAll.primary ?? {}) as Record<string, any>;
            const { primary: _drop, ...siblingProxyKeys } = topProxyAll;
            primaryProxy = {
              ...siblingProxyKeys,
              primary: { ...topPrimary, ...primary.proxy },
            };
          }
          // health.path is a URL path for HTTP probing.
          // primary.healthcheck is the docker HEALTHCHECK directive — usually
          // a shell command (`wget -qO …`, `curl -f …`, `redis-cli ping`).
          // They are NOT interchangeable. Only adopt the container healthcheck
          // as health.path if (a) build.json did not declare its own health and
          // (b) the value is a URL path (starts with "/"). Anything else is a
          // shell command and would corrupt downstream URL construction
          // (https://${domain}${health.path}).
          if (!primaryHealth && primary.healthcheck && primary.healthcheck.startsWith("/")) {
            primaryHealth = { path: primary.healthcheck };
          }
          // Same precedence as health: top-level monitoring is the service
          // contract (tls_check/dns_check/endpoint_check). Container-level
          // monitoring is a per-container concern (e.g. only the public app
          // gets tls_check). If both are present, top-level wins; otherwise
          // fall back to the primary container's spec.
          if (!primaryMonitoring && primary.monitoring) primaryMonitoring = primary.monitoring;
        }
      }
      // Fallback: top-level port/dns override empty container-level values
      if (port == null && bj.port != null) port = bj.port;
      if (dns == null) dns = bj.dns ?? (port ? `${name}.mesh.diegonmarcos.com` : undefined);
      if (!port && !containers) {
        // Legacy flat schema without containers key
        port = bj.port;
        dns = bj.dns ?? (port ? `${name}.mesh.diegonmarcos.com` : undefined);
      }

      // Collect extra top-level fields not handled above
      const knownKeys = new Set([
        "name", "description", "category", "domain", "deploy", "dns", "port",
        "ports", "proxy", "health", "monitoring", "backup", "notifications",
        "docker", "secrets", "build", "compose", "lifecycle", "terraform",
        "multi_vm", "frozen", "version", "containers", "enabled",
        "archived_at", "archived_reason",
        "api", "mcp",
      ]);
      const extra: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(bj)) {
        if (!knownKeys.has(k)) extra[k] = v;
      }

      entries.push({
        name,
        category,
        vm: host,
        domain: primaryDomain,
        description: bj.description || "",
        flake,
        folder,
        enabled: bj.enabled ?? true,
        // Standardized routing fields (derived from containers or flat)
        ...(port != null ? { port } : {}),
        ...(dns ? { dns } : {}),
        // Pass through declarative infrastructure fields
        ...(primaryProxy ? { proxy: primaryProxy } : {}),
        ...(bj.ports ? { ports: bj.ports } : {}),
        ...(primaryHealth ? { health: primaryHealth } : {}),
        ...(primaryMonitoring ? { monitoring: primaryMonitoring } : {}),
        ...(bj.backup ? { backup: bj.backup } : {}),
        ...(bj.notifications ? { notifications: bj.notifications } : {}),
        // Multi-container declarations (new schema)
        ...(containers ? { containers } : {}),
        // Declarative API / MCP surfaces
        ...(bj.api ? { api: bj.api } : {}),
        ...(bj.mcp ? { mcp: bj.mcp } : {}),
        // Deploy overrides
        ...(fallbackHost ? { fallback_vm: fallbackHost } : {}),
        // Extra service-specific fields (models, notes, etc.)
        ...(Object.keys(extra).length > 0 ? { extra } : {}),
      });
    } catch {
      console.warn(`  WARN: invalid build.json in ${folder}`);
    }
  }

  return entries;
}

// ── normalizeToContainers ─────────────────────────────────────────────
// Converts a flat-schema BuildJsonEntry into a uniform containers format.
// If containers already exist, returns them as-is.
// Used by the consolidated generator for uniform internal representation.
export function normalizeToContainers(entry: BuildJsonEntry): Record<string, ContainerSpec> {
  if (entry.containers) return entry.containers;

  // Synthesize a single "app" container from flat fields
  const container: ContainerSpec = {
    container_name: entry.name,
    image: "", // not known from flat schema — flake.nix owns it
    public: !!entry.domain,
    ...(entry.port != null ? { port: entry.port } : {}),
    ...(entry.dns ? { dns: entry.dns } : {}),
    ...(entry.domain && entry.proxy?.primary ? {
      proxy: entry.proxy.primary,
    } : {}),
    ...(entry.health?.path ? { healthcheck: entry.health.path } : {}),
    ...(entry.monitoring ? { monitoring: entry.monitoring } : {}),
  };

  return { app: container };
}
