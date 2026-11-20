#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-update.sh — UNIVERSAL cloud-cgc octocode DB updater (producer)
# ──────────────────────────────────────────────────────────────────────────
#  ONE reproducible script that runs IDENTICALLY anywhere (GHA x86, a VM, local).
#  The CI YAML / Dagu DAG only TRIGGER this — they carry ZERO logic. Everything
#  (octocode install, GHCR auth, fresh repo checkout, index, package, push) is
#  here and data-driven from build.json.
#
#  GHCR-upstream INCREMENTAL flow (NOT a reindex — never `octocode clear`):
#    0. ensure octocode on PATH (extract pinned x86 static binary from GHCR)
#    1. ensure GHCR auth (docker login if a token is provided)
#    2. ensure repos: clone/refresh each to its FRESH origin HEAD in a DEDICATED
#       root (never the dev tree) — this is what guarantees "freshest HEAD"
#    3. pull the last DB from GHCR (incremental base; bootstraps if absent)
#    4. octocode index each repo — git-aware, CHANGED FILES ONLY
#       GraphRAG LLM phase → my-ai-api (.runtime.octocode.llm); FastEmbed local
#    5. push the updated DB back to GHCR (single upstream for all consumers)
#  The DB (Lance + FastEmbed vectors) is arch-portable; octocode version is
#  pinned in build.json so the schema stays compatible across x86/arm/local.
#
#  INCREMENTAL-ONLY: requires an existing GHCR DB base (seed it once via
#  cloud-cgc-db-package.sh of an already-built DB, or a prod-volume snapshot).
#  It refuses a from-scratch full build (octocode's GraphRAG full build is ~12h).
#  Runtime the caller (YAML/DAG/shell) must provide: docker, git, jq + env:
#    GITHUB_TOKEN (+ GITHUB_ACTOR) for GHCR/clone auth. No LLM key: the endpoint
#    declared in .runtime.octocode.llm injects its own, so callers send a
#    placeholder and nothing here ever holds a provider credential.
# ──────────────────────────────────────────────────────────────────────────
set -eu
# Budget clock starts at SCRIPT start, not at the index loop (#352/#375). Clone +
# mtime restore + checkpoint restore + the lance integrity scan take ~17 min for
# cloud-u-android before the loop; anchoring the clock after them handed that repo a
# 300-min slice inside a 315-min STEP, so the step timeout always fired first, the
# partial checkpoint was never published, and the ratchet never advanced (was=none
# on every run). CGC_START_TS lets a caller anchor it even earlier.
START_TS="${CGC_START_TS:-$(date +%s)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# GHCR image-name component for a local repo name (repo names may carry upper case,
# a leading "_" or "-_", which docker refuses). Lower-cases, collapses separator runs,
# strips leading separators. Identity for every already-valid name.
cgc_image_name() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[._-]{2,}/-/g; s/^[._-]+//'; }

# #888: the phase must be known before the first use of it. resume_force_partial
# runs in the per-repo restore loop, long before the manifest block below; with
# MANIFEST_PHASE still empty there it asked GHCR for <repo>:latest-force-default
# while publish wrote -force-graphrag, so every forced run re-indexed from zero.
MANIFEST_PHASE="${CGC_MANIFEST_PHASE:-}"
ROOT="${CLOUD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
BJ="${CGC_BUILD_JSON:-$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
[ -f "$BJ" ] || { echo "::error::cloud-cgc-pub-mcp build.json not found at $BJ"; exit 1; }

IMAGE=$(jq -r   '.db_publish.image'                  "$BJ")
TAG=$(jq -r     '.db_publish.tag // "latest"'        "$BJ")
OCTO_HOME="${OCTOCODE_HOME:-$HOME/.local/share/octocode}"
# ── XDG alignment (per-repo/matrix mode only) — production incident 2026-08-21
# (run 32512759559): octocode 0.12.2 has NO relocation knob of its own
# (verified against the pinned binary's storage.rs:39-47) — it derives its OWN
# data dir from $XDG_DATA_HOME (preferred) else $HOME/.local/share, full stop.
# OCTOCODE_HOME/OCTO_HOME above is OUR variable only; octocode never reads it.
# Every octocode invocation below (ensure_octocode, `octocode config`,
# `octocode index`) resolves its home from XDG_DATA_HOME/HOME alone, no matter
# what OCTO_HOME points at — so the two must be made to agree BEFORE the first
# such invocation, or octocode silently indexes into one directory while this
# script packages another.
#   monolith mode (default, untouched below): OCTO_HOME defaults to
#     $HOME/.local/share/octocode — the SAME path octocode itself resolves
#     with XDG_DATA_HOME unset. The two can never disagree, which is WHY this
#     path has always worked with no XDG handling at all.
#   per-repo mode (matrix CI, cgc-db-index.yml): OCTOCODE_HOME is set to a
#     FRESH per-job dir under $RUNNER_TEMP (e.g. $RUNNER_TEMP/octocode-home),
#     never $HOME/.local/share/octocode — so without the export below,
#     `octocode index` silently writes the real DB to
#     $HOME/.local/share/octocode instead (that run: octocode indexed fine,
#     every job then failed "no project directory found" packaging the
#     empty, un-written OCTO_HOME). Fix: require/normalize OCTO_HOME to END
#     in "/octocode" and export XDG_DATA_HOME as its PARENT, so octocode's
#     own $XDG_DATA_HOME/octocode resolution lands exactly on $OCTO_HOME —
#     the same directory bootstrap_config_toml (below) already writes
#     config.toml into, now kept in alignment for the DB itself too.
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  case "$OCTO_HOME" in
    */octocode) ;;
    *)
      echo "::warning::[cgc-db] CGC_PACKAGE_MODE=per-repo: OCTOCODE_HOME ($OCTO_HOME) does not end in /octocode — normalizing to $OCTO_HOME/octocode so octocode's own XDG_DATA_HOME resolution lands on it"
      OCTO_HOME="$OCTO_HOME/octocode"
      ;;
  esac
  mkdir -p "$OCTO_HOME"
  XDG_DATA_HOME="${OCTO_HOME%/octocode}"
  export XDG_DATA_HOME
fi
# Embedding-model cache. Since 0.22 octocode keeps its fastembed models under
# $XDG_CACHE_HOME/octolib/fastembed, no longer inside the octocode home. Point the
# cache INSIDE the home, at fastembed/, so the base image keeps carrying the model
# cache exactly as before (cloud-cgc-db-package.sh's root-state allowlist and
# cloud-cgc-db-restore-all.sh's project-dir exclusion both already name that
# directory) and the consumers find the models restored instead of downloading
# them at first query. compose.nix sets the same variable on the consumer side.
XDG_CACHE_HOME="$OCTO_HOME/fastembed"; export XDG_CACHE_HOME
# FIXED clone root, identical everywhere. octocode keys each project by its
# git-root path STRING, so to do incremental ON TOP of the existing GHCR/prod
# DB (which was built in the octocode container at /repos), the producer MUST
# clone+index at the SAME path. Anything $HOME-relative (varies per machine →
# /home/diego vs /home/runner) creates a DISCONNECTED graph — the bug that made
# the 357-node orphan instead of extending the 2148-node base. Data-driven from
# build.json runtime.octocode.repos_path; NEVER the dev tree (~/git).
REPOS_ROOT="${REPOS_ROOT:-${OCTOCODE_REPOS_ROOT:-$(jq -r '.runtime.octocode.repos_path // "/repos"' "$BJ")}}"
# CGC_INDEX_REPOS overrides build.json for split-job workflows (space-separated)
if [ -n "${CGC_INDEX_REPOS:-}" ]; then
  REPOS="$CGC_INDEX_REPOS"
else
  REPOS=$(jq -r '.runtime.octocode.index_repos[]' "$BJ")
fi
# DENY CHECK — derive-repo-map.ts only validates the STATIC build.json index_repos
# at derive time; CGC_INDEX_REPOS above lets a caller (a local run with real deploy/SSH
# keys, say) override REPOS at runtime and skip that check entirely. The shared /repos
# volume is what cloud-cgc-pub-mcp indexes, so a denied repo (e.g. cloud-vault, the
# credential store) reaching this loop gets embedded in the GraphRAG DB and
# checkpoint-pushed to GHCR — i.e. published. Re-check the FINAL $REPOS (whichever path
# set it) against the SAME deny list, data-driven from build.json — never hardcode a name.
DENY=$(jq -r '(.runtime.octocode.sync_exclude // {}) | keys[]?' "$BJ")
for _r in $REPOS; do
  for _d in $DENY; do
    if [ "$_r" = "$_d" ]; then
      _reason=$(jq -r --arg r "$_r" '.runtime.octocode.sync_exclude[$r] // "denied"' "$BJ")
      echo "::error::[cgc-db] refusing to index '$_r' — denied by .runtime.octocode.sync_exclude ($_reason)"
      exit 1
    fi
  done
done
# Same deny list, ALSO checked against .runtime.octocode.repo_map — a separate list
# (local_name → github remote) that ensure_repos() below clones from independently of
# $REPOS/index_repos. A denied name added to repo_map (by hand, bypassing derive-repo-
# map.ts) would otherwise clone straight to the shared REPOS_ROOT unchecked — this loop
# above only ever sees $REPOS, never repo_map's keys. Inert today (repo_map has no
# sync_exclude entry), but the whole point of a deny list is to hold even when someone
# adds one by hand later.
for _r in $(jq -r '(.runtime.octocode.repo_map // {}) | keys[]?' "$BJ"); do
  for _d in $DENY; do
    if [ "$_r" = "$_d" ]; then
      _reason=$(jq -r --arg r "$_r" '.runtime.octocode.sync_exclude[$r] // "denied"' "$BJ")
      echo "::error::[cgc-db] refusing to clone '$_r' — denied by .runtime.octocode.sync_exclude ($_reason), present in .runtime.octocode.repo_map"
      exit 1
    fi
  done
done
LLM=$(jq -r     '.runtime.octocode.update.llm_model' "$BJ")
# #1817: free OpenRouter models are retired without notice (cohere/north-mini-code:free
# went 404 mid-run on 44646333693). The proxy tries these, in order, after llm_model.
CGC_LLM_FALLBACK_MODELS="${CGC_LLM_FALLBACK_MODELS:-$(jq -r '[.runtime.octocode.update.llm_fallback_models[]? | sub("^openrouter:"; "")] | join(",")' "$BJ")}"
export CGC_LLM_FALLBACK_MODELS
# USE_LLM selects the GraphRAG LLM phase. Two-phase orchestration (cgc-db.yml →
# cgc-db-index.yml) drives this via the environment: the `semantic` phase exports
# USE_LLM=false, the `graphrag` phase exports USE_LLM=true. The ENVIRONMENT is
# authoritative; build.json runtime.octocode.update.use_llm is only the fallback
# default when the caller does not set USE_LLM (e.g. a bare local invocation).
USE_LLM="${USE_LLM:-$(jq -r '.runtime.octocode.update.use_llm' "$BJ")}"
# GraphRAG LLM ENDPOINT (data-driven, .runtime.octocode.llm). octocode picks its
# provider from the model-string PREFIX and then reads that provider's OWN env
# pair: `openrouter:*` -> $OPENROUTER_API_URL + $OPENROUTER_API_KEY, `openai:*`
# -> $OPENAI_API_URL + $OPENAI_API_KEY, `ollama:*` -> $OLLAMA_API_URL. All three
# are exported so the declared prefix is the only thing that has to change to
# switch faces. openrouter: is the one in use: the openai provider validates the
# model against a slug allowlist and rejects `qwen/*` outright, and ollama: is
# the mimic port rather than the API this account actually pays for. Nothing
# else sets any of these, so
# without this block the graphrag phase rewrote the config models correctly and
# then died at the first call with "LLM client not initialized" -> a whole DB of
# structural-only `sibling_module` edges with only a Warning in the log.
# The endpoint is my-ai-api on the mesh, which injects the real OpenRouter key
# itself (passthrough_auth=false), so api_key here is the declared `sk-dummy`
# placeholder — there is NO credential in this path and none is needed.
# ENVIRONMENT WINS, build.json is the default — the same precedence USE_LLM uses.
# A caller that reaches the endpoint by another route (an SSH forward from a
# runner that cannot route to the mesh IP) sets these and is obeyed.
OPENROUTER_API_URL="${OPENROUTER_API_URL:-$(jq -r '.runtime.octocode.llm.openrouter_api_url // empty' "$BJ")}"
OPENAI_API_URL="${OPENAI_API_URL:-$(jq -r '.runtime.octocode.llm.openai_api_url     // empty' "$BJ")}"
OLLAMA_API_URL="${OLLAMA_API_URL:-$(jq -r '.runtime.octocode.llm.ollama_api_url     // empty' "$BJ")}"
OPENAI_API_KEY="${OPENAI_API_KEY:-$(jq -r '.runtime.octocode.llm.api_key            // empty' "$BJ")}"
LLM_HEALTH_URL="${LLM_HEALTH_URL:-$(jq -r '.runtime.octocode.llm.health_url         // empty' "$BJ")}"
# One declared placeholder feeds every provider's key var: my-ai-api ignores what
# the caller sends, but octocode refuses to build a client when the var is empty.
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$OPENAI_API_KEY}"
export OPENROUTER_API_URL OPENAI_API_URL OLLAMA_API_URL OPENAI_API_KEY OPENROUTER_API_KEY
CODE_EMBED=$(jq -r '.runtime.octocode.update.code_embedding_model // "fastembed:all-MiniLM-L6-v2"' "$BJ")
TEXT_EMBED=$(jq -r '.runtime.octocode.update.text_embedding_model // "fastembed:all-MiniLM-L6-v2"' "$BJ")
# GPU EMBEDDING (octocode `local:` provider — OpenAI-shaped POST /v1/embeddings,
# see octolib/src/embedding/provider/local.rs). RUNNER-ONLY override of the two
# lines above, for the cloud-u-android semantic phase on the GCP GPU VM (owner
# decision 2026-09-03; declared in c_vps/vps_gcloud/src/terraform.json as
# gcp-gpu-embed, started/stopped around that one job by cgc-db-index.yml).
# CGC_LOCAL_EMBED_MODEL is the activation switch and is DELIBERATELY env-only —
# no build.json fallback: unlike USE_LLM/CODE_EMBED above, there is no safe
# default for an endpoint that is a VM stopped unless the caller just started
# it, so a bare local/dagu run of this script never reaches for the GPU. When
# it IS set, LOCAL_EMBED_API_URL / the batch size fall back to build.json's
# .runtime.octocode.update.gpu_embed (env still wins — same precedence as the
# LLM block above) so the workflow only has to carry the secret bearer token
# and (once known) the GH Actions repo variable for the URL.
GPU_EMBED_URL_DEFAULT=$(jq -r '.runtime.octocode.update.gpu_embed.embed_endpoint // empty' "$BJ")
GPU_EMBED_HEALTH_DEFAULT=$(jq -r '.runtime.octocode.update.gpu_embed.health_url // empty' "$BJ")
GPU_EMBED_BATCH_DEFAULT=$(jq -r '.runtime.octocode.update.gpu_embed.embeddings_batch_size // empty' "$BJ")
LOCAL_EMBED_API_URL="${LOCAL_EMBED_API_URL:-$GPU_EMBED_URL_DEFAULT}"
LOCAL_EMBED_API_KEY="${LOCAL_EMBED_API_KEY:-}"
LOCAL_EMBED_HEALTH_URL="${LOCAL_EMBED_HEALTH_URL:-$GPU_EMBED_HEALTH_DEFAULT}"
LOCAL_EMBED_BATCH_SIZE="${CGC_LOCAL_EMBED_BATCH_SIZE:-$GPU_EMBED_BATCH_DEFAULT}"
export LOCAL_EMBED_API_URL LOCAL_EMBED_API_KEY
if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ]; then
  CODE_EMBED="$CGC_LOCAL_EMBED_MODEL"
  TEXT_EMBED="$CGC_LOCAL_EMBED_MODEL"
  echo "[cgc-db] GPU embedding override active: CODE_EMBED=TEXT_EMBED=$CGC_LOCAL_EMBED_MODEL via ${LOCAL_EMBED_API_URL:-<unset>} (batch=${LOCAL_EMBED_BATCH_SIZE:-default}) — cgc-db-base:latest / the box stay on fastembed, see seed_base_if_missing()"
fi
# Pinned UPSTREAM octocode release (see ensure_octocode): version + per-arch sha256
# of the static musl tarball — the one pin the consumer image shares.
OCTO_VERSION=$(jq -r '.runtime.octocode.version // empty' "$BJ")
OCTO_REPO=$(jq -r '.runtime.octocode.release.repo // empty' "$BJ")
OCTO_ASSET=$(jq -r '.runtime.octocode.release.asset // empty' "$BJ")
# Data-driven exclude globs. octocode honours a gitignore-syntax `.noindex` file
# (in addition to `.gitignore`). dist/, vendor/, z_archive/ are git-COMMITTED here
# so `.gitignore` misses them — without this octocode embeds ~73% generated/vendored/
# archived junk, bloating the graph and tripling every index. One `.noindex` per repo.
NOINDEX_PATTERNS=$(jq -r '.runtime.octocode.noindex_patterns // [] | .[]' "$BJ" 2>/dev/null)
# Arch-aware binary: the arm runners (oci-apps aarch64) and x86 GHA fetch the same
# release, each its own arch asset verified against its own sha256.
case "$(uname -m)" in
  aarch64|arm64) OCTO_ARCH=aarch64 ;;
  *)             OCTO_ARCH=x86_64 ;;
esac
OCTO_SHA=$(jq -r --arg a "$OCTO_ARCH" '.runtime.octocode.release.sha256[$a] // empty' "$BJ")
if [ -z "$OCTO_VERSION" ] || [ -z "$OCTO_REPO" ] || [ -z "$OCTO_ASSET" ] || [ -z "$OCTO_SHA" ]; then
  echo "::error::[cgc-db] build.json .runtime.octocode.version / .release.{repo,asset,sha256.$OCTO_ARCH} incomplete — cannot pin the indexer binary"; exit 1
fi
CFG="$OCTO_HOME/config.toml"
TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
ACTOR="${GITHUB_ACTOR:-diegonmarcos}"
export HOME OCTOCODE_HOME="$OCTO_HOME"

# ── 0) FREEZE-PROOFING ──────────────────────────────────────────────────────
# Re-exec the ENTIRE producer inside a memory+CPU-bounded transient cgroup scope
# so a runaway `octocode index` / docker build is OOM-killed in isolation and can
# NEVER freeze the host: CPUQuota leaves a core free for sshd/WireGuard, and
# MemoryMax + MemorySwapMax=0 kill the JOB, not the VM. Runs as the invoking user
# (--uid/--gid → files stay user-owned) and inherits env through `sudo -E` so
# secrets pass via the environment, never argv. Limits are data-driven
# (build.json runtime.octocode.update.*). Degrades to nice/ionice when systemd-run
# or passwordless sudo is unavailable; CGC_NO_SANDBOX=1 opts out (e.g. ephemeral CI).
if [ -z "${CGC_SANDBOXED:-}" ] && [ "${CGC_NO_SANDBOX:-}" != "1" ]; then
  SELF="$HERE/${0##*/}"
  S_MEM=$(jq -r  '.runtime.octocode.update.mem_max    // "16G"'  "$BJ")
  S_SWAP=$(jq -r '.runtime.octocode.update.swap_max   // "0"'    "$BJ")
  S_CPUQ=$(jq -r '.runtime.octocode.update.cpu_quota  // "300%"' "$BJ")
  S_CPUW=$(jq -r '.runtime.octocode.update.cpu_weight // "10"'   "$BJ")
  S_IOW=$(jq -r  '.runtime.octocode.update.io_weight  // "10"'   "$BJ")
  # `-d /run/systemd/system` is the canonical "booted with systemd as init" test
  # (systemctl uses it). Inside a container (e.g. the gha-runner) systemd-run exists
  # but there is no system manager → scope creation dies with "Host is down". There
  # the container's own cpus/memory limits already provide freeze-safety, so fall
  # back to nice/ionice.
  if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1 && sudo -n true 2>/dev/null \
     && CGC_SUDO_E_PROBE=1 sudo -n -E sh -c '[ "${CGC_SUDO_E_PROBE:-}" = 1 ]' 2>/dev/null; then
    # The last probe: sudo-rs (newer runner images) ignores -E ("preserving the entire
    # environment is not supported"), which silently dropped CGC_PACKAGE_MODE & co. and
    # sent per-repo legs down the monolith path ("no GHCR DB base restored"). Without a
    # working -E the scope cannot carry the env, so take the nice/ionice fallback.
    # --scope units have no ExecContext, so SupplementaryGroups= is rejected and
    # --uid/--gid drop the docker group → no daemon-socket access. Run with egid =
    # the docker socket's group (data-derived, not hardcoded) so the sandboxed
    # process keeps docker access while files stay owned by the invoking user.
    S_DGID="$(stat -c %g /var/run/docker.sock 2>/dev/null || id -g)"
    echo "[cgc-db] freeze-proof scope: MemoryMax=$S_MEM MemorySwapMax=$S_SWAP CPUQuota=$S_CPUQ CPUWeight=$S_CPUW IOWeight=$S_IOW gid=$S_DGID (cannot freeze host)"
    exec sudo -n -E systemd-run --scope --quiet --collect \
      --uid="$(id -u)" --gid="$S_DGID" \
      -p MemoryMax="$S_MEM" -p MemorySwapMax="$S_SWAP" \
      -p CPUQuota="$S_CPUQ" -p CPUWeight="$S_CPUW" -p IOWeight="$S_IOW" \
      env CGC_SANDBOXED=1 sh "$SELF" "$@"
  else
    echo "[cgc-db] freeze-proof: systemd-run/sudo unavailable — nice/ionice fallback"
    _pfx=""
    command -v nice   >/dev/null 2>&1 && _pfx="nice -n 19"
    command -v ionice >/dev/null 2>&1 && _pfx="$_pfx ionice -c2 -n7"
    exec env CGC_SANDBOXED=1 $_pfx sh "$SELF" "$@"
  fi
fi

# ── GUARANTEED NON-GIT SCRATCH DIR — STRAY-PREVENT, production incident (run
# 32572923354): packaging died with "expected exactly ONE project directory
# ... found 2". octocode initializes a project dir for the CWD's git repo on
# (apparently) ANY invocation, keyed by sha256(normalized origin URL) — so it
# is STABLE across runs for any git repo with a real origin. This script never
# `cd`s its own top-level shell anywhere (only inside `( cd ... && ... )`
# subshells for command substitution / the per-repo index below), so every
# BARE octocode call runs with this script's AMBIENT cwd — which in CI is the
# cloud-infra checkout itself ($GITHUB_WORKSPACE, a real git repo with a
# stable origin). A pre-index octocode call (version probe / config bootstrap,
# below) therefore silently stamped a stable stray <project_id>/ for
# cloud-infra into the octocode home BEFORE the target repo's own index ever
# ran, so packaging's exactly-one check (find_project_dir) saw that stray plus
# the target's own dir and hard-errored on every job.
# Every octocode invocation below that is NOT the actual 'octocode index' of a
# target repo (version probes, config bootstrap/mutation) is cd'd into this
# dir instead of running at the ambient cwd. Freshly created and deliberately
# left un-git-init'd — octocode's CWD-based project resolution has no git repo
# to key off here, so it cannot stamp anything. One dir for the whole script
# run (nothing inside it needs to persist between calls); created AFTER the
# freeze-proofing re-exec above so it belongs to the actual worker process.
CGC_SCRATCH="$(mktemp -d)"
trap '[ -n "${LLM_PROXY_PID:-}" ] && kill "$LLM_PROXY_PID" 2>/dev/null; rm -rf "$CGC_SCRATCH"' EXIT

# Never materialize Git-LFS content: cloud-u-android's element-x fork tracks
# images via LFS, and the runner's smudge filter fails ('git-lfs filter-process
# failed' on ac_cloud-matrix/docs/images-lfs/*.png) — which failed the WHOLE
# clone, and (because every matrix job clones every repo) every job with it.
# This was android's actual multi-day clone failure, invisible while clone
# stderr went to /dev/null. Indexing never needs LFS payloads (binaries are
# noindex'd anyway); pointer files are correct here.
export GIT_LFS_SKIP_SMUDGE=1

# 0b) ensure a FastEmbed-CAPABLE octocode on PATH. A binary built WITHOUT FastEmbed
#     (e.g. some nix/static builds — oci-apps' nix-profile octocode is one) fails
#     `octocode index` at runtime; the producer would then package the UNCHANGED
#     base = a silent no-op "update". So we VERIFY capability and, if the on-PATH
#     octocode lacks it, extract the pinned image binary (the *-fastembed-* images
#     are built with it). Pinned version keeps the DB schema compatible.
# FastEmbed probe. `models list` is the one read-only octocode command that names
# the compiled-in embedding providers. It still stamps a default config.toml into
# whatever home it resolves (0.22 does that on nearly every command), so it runs
# against a THROWAWAY XDG home, never $OCTO_HOME — a default config landing there
# (octocode's own jina code model, not build.json's) would make
# bootstrap_config_toml below keep it as if it were ours. The 0.12-era probe ran
# `octocode index` in an empty git repo for the same purpose; on 0.22 that also
# creates a stray project dir and starts a model download. Retired.
octocode_has_fastembed() {  # $1 = octocode binary path/name
  _t="$(mktemp -d)"
  _o="$( cd "$_t" && XDG_DATA_HOME="$_t" XDG_CONFIG_HOME="$_t" XDG_CACHE_HOME="$_t" "$1" models list 2>&1 || true )"
  rm -rf "$_t"
  case "$_o" in *"FastEmbed Provider"*) return 0 ;; *) return 1 ;; esac
}
# The octocode binary is the UPSTREAM static musl release, pinned by version +
# sha256 in build.json (.runtime.octocode.version / .release) — one pin shared with
# the consumer image (docker.native_build.cmd), asserted equal by
# 9_others/test/cgc-db-octocode-pin.test.sh. The DB schema follows the binary, so an
# on-PATH octocode is only accepted at exactly the pinned version. The 0.12.2-era
# per-arch GHCR images were hand-built once (2026-03-26) with no builder in this
# repo; upstream now ships static builds for both x86_64 and aarch64, so there is
# nothing left to build, mirror or docker-pull here.
ensure_octocode() {
  if command -v octocode >/dev/null 2>&1 \
     && [ "$(octocode --version 2>/dev/null | awk '{print $2}')" = "$OCTO_VERSION" ] \
     && octocode_has_fastembed octocode; then
    echo "[cgc-db] octocode: $OCTO_VERSION on PATH (FastEmbed ok)"; return 0
  fi
  bindir="${CGC_BIN:-$HOME/.local/bin}"; mkdir -p "$bindir"
  _asset=$(printf '%s' "$OCTO_ASSET" | sed "s/{version}/$OCTO_VERSION/g; s/{arch}/$OCTO_ARCH/g")
  _url="https://github.com/$OCTO_REPO/releases/download/$OCTO_VERSION/$_asset"
  echo "[cgc-db] fetching pinned octocode $OCTO_VERSION for $OCTO_ARCH — $_url"
  _tmp=$(mktemp -d)
  curl -fsSL --retry 5 --retry-delay 10 -o "$_tmp/$_asset" "$_url" \
    || { echo "::error::[cgc-db] octocode download failed: $_url"; exit 1; }
  _got=$(sha256sum "$_tmp/$_asset" | cut -c1-64)
  [ "$_got" = "$OCTO_SHA" ] \
    || { echo "::error::[cgc-db] octocode sha256 mismatch for $_asset — build.json .runtime.octocode.release.sha256.$OCTO_ARCH says $OCTO_SHA, download is $_got. Refusing an unverified indexer binary."; exit 1; }
  tar -xzf "$_tmp/$_asset" -C "$_tmp" octocode \
    && install -m 0755 "$_tmp/octocode" "$bindir/octocode" \
    || { echo "::error::[cgc-db] octocode tarball did not contain ./octocode"; exit 1; }
  rm -rf "$_tmp"
  PATH="$bindir:$PATH"; export PATH
  octocode_has_fastembed "$bindir/octocode" \
    || { echo "::error::[cgc-db] pinned octocode $OCTO_VERSION ($OCTO_ARCH) lacks FastEmbed"; exit 1; }
  echo "[cgc-db] octocode: $(octocode --version 2>/dev/null) (FastEmbed ok, upstream release, sha256 verified)"
}

# 1) ensure GHCR auth — only if a token is provided (local is usually pre-authed).
ensure_ghcr_auth() {
  [ -n "$TOKEN" ] || { echo "[cgc-db] no token — assuming GHCR already authed"; return 0; }
  echo "$TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null 2>&1 \
    && echo "[cgc-db] GHCR login ok" || echo "[cgc-db] WARN GHCR login failed"
}

# 2) ensure each indexed repo is present at its FRESH origin HEAD in REPOS_ROOT.
#    Data-driven local→github from build.json.repo_map. clone if missing, else
#    fetch + reset --hard to the fetched tip. Safe (dedicated clones, not dev tree).
# DETERMINISTIC MTIMES — the single reason indexing never converged.
#
# octocode's incremental reindex is mtime-based: it stores a per-file modification time in
# LanceDB (src/store/metadata.rs: "File metadata (per-file modification time, for
# incremental reindex)", store_file_metadata/get_file_mtime) and re-indexes any file whose
# filesystem mtime differs from the stored one. Git does NOT preserve mtimes, and this
# runner has no persistent /repos, so every run clones fresh and stamps EVERY file with the
# clone time. Octocode then correctly concludes the entire tree changed and re-embeds all
# of it — 1884 files for cloud-infra when only 16 actually changed since its last-indexed
# commit. That is the whole story behind the "5.2s/file" (it is real embedding work, not a
# stall) and behind the giants never finishing at any timeout setting.
#
# Fix: set each file's mtime to the timestamp of the last commit that touched it. That is
# deterministic across clones (verified: identical output over repeated runs) yet still
# changes exactly when the file's content changes, so genuine edits are still detected —
# a fixed constant would be stable but would also mask real changes forever.
# Equivalent to git-restore-mtime without taking the dependency.
restore_mtimes() {
  _rd="$1"
  [ -d "$_rd/.git" ] || return 0
  # One pass over history, newest first: the FIRST time a path appears is its last change.
  # Deleted paths still appear in history, so skip anything not present in the worktree —
  # touch would otherwise CREATE them and pollute the tree octocode walks.
  git -C "$_rd" log --pretty=format:'@%ct' --name-only --no-renames 2>/dev/null \
  | awk '/^@/{t=substr($0,2);next} NF && !seen[$0]++ {print t" "$0}' \
  | while read -r _ts _f; do
      [ -e "$_rd/$_f" ] || continue
      touch -h -d "@$_ts" "$_rd/$_f" 2>/dev/null || true
    done
}

ensure_repos() {
  # /repos is root-owned on a fresh runner — create + own it (sudo) if needed.
  mkdir -p "$REPOS_ROOT" 2>/dev/null || { sudo mkdir -p "$REPOS_ROOT" && sudo chown "$(id -un):$(id -gn)" "$REPOS_ROOT"; }
  # `jq | while read` runs the loop body in a SUBSHELL, so an `exit` inside it kills only
  # that subshell and the script sails on. Record failures in a marker file and act on it
  # after the pipeline, where we are back in the function's own shell.
  _clonefail="$REPOS_ROOT/.cgc-clone-failed"
  rm -f "$_clonefail"
  # PUBLIC run: private repos (private_repos) are never cloned or indexed here; they belong
  # to the private cloud-me-pvt-cgc run, which sets CGC_INCLUDE_PRIVATE=1. Guarded by
  # cgc-db-public-no-private.test.sh.
  jq -r --arg inc "${CGC_INCLUDE_PRIVATE:-0}" '(.runtime.octocode.private_repos // []) as $p | .runtime.octocode.repo_map | to_entries[] | select($inc == "1" or (.key as $k | $p | index($k) | not)) | "\(.key) \(.value)"' "$BJ" | while read -r lname remote; do
    [ -n "$lname" ] || continue
    d="$REPOS_ROOT/$lname"
    # PRIVATE repos need a deploy key. $TOKEN here is the job's GITHUB_TOKEN, which is scoped
    # to THIS repo only — it can never clone a different private repo, so `clone cloud-data`
    # failed on every run and the repo was simply absent from the DB. Per-repo deploy keys are
    # the established pattern in this repo (CLOUD_DATA_DEPLOY_KEY). The lookup below is generic
    # — env CGC_DEPLOY_KEY_<local_dir, with - and . folded to _>; only the secret wiring in
    # cgc-db-index.yml is per-repo, because Actions resolves secrets by literal name only.
    unset GIT_SSH_COMMAND
    eval "_key=\${CGC_DEPLOY_KEY_$(printf '%s' "$lname" | tr -c '[:alnum:]' '_'):-}"
    if [ -n "$_key" ]; then
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      _kf="$HOME/.ssh/cgc_${lname}"
      printf '%s\n' "$_key" > "$_kf" && chmod 600 "$_kf"
      # IdentitiesOnly: a deploy key grants ONE repo, so an agent offering several keys
      # authenticates as whichever is accepted first and then 403s on the wrong repo.
      export GIT_SSH_COMMAND="ssh -i $_kf -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
      url="git@github.com:diegonmarcos/${remote}.git"
    elif [ -n "$TOKEN" ]; then url="https://x-access-token:${TOKEN}@github.com/diegonmarcos/${remote}.git"
    else url="https://github.com/diegonmarcos/${remote}.git"; fi
    # octocode keys each project's DB dir on sha256(normalized origin URL)[..16], so
    # origin MUST NOT carry credentials. The token path above baked a per-run secret
    # into that hash, which meant (a) the id never matched what a consumer computes
    # from its own tokenless checkout — the per-repo images restored onto oci-apps
    # landed in dirs nothing would ever read, so every query silently built a fresh
    # empty index — and (b) the id changed whenever the token rotated, which is where
    # the monolith's drift of stale project-hash dirs came from. The SSH deploy-key
    # path was always fine (git@host:path normalizes to the same thing), so this only
    # ever bit the token repos, i.e. the public ones. Fetch with the credentialed URL
    # explicitly and keep origin canonical and stable.
    canon="https://github.com/diegonmarcos/${remote}.git"
    if [ -d "$d/.git" ]; then
      echo "[cgc-db] refresh $lname ← origin (full history for incremental detection)"
      git -C "$d" remote set-url origin "$canon" 2>/dev/null || true
      git -C "$d" fetch -q "$url" 2>/dev/null \
        && git -C "$d" reset --hard -q FETCH_HEAD 2>/dev/null \
        || echo "[cgc-db] WARN refresh $lname failed (using existing checkout)"
    else
      echo "[cgc-db] clone $lname ← $remote (full history for incremental detection)"
      # Full clone (no --depth): octocode stores the last-indexed commit in the DB and
      # diffs against it to find changed files. --depth 1 puts that stored commit outside
      # the shallow history → git can't resolve it → octocode re-indexes everything every
      # run. Full clone is small overhead; the embedding speedup is enormous (minutes vs hours).
      # Fail FAST, not four hours later. A missing repo is already fatal at the publish gate
      # ("refusing to publish an incomplete DB"), so warning here only buys a full pass of
      # embedding work before the same failure — and it read as a harmless warning for days
      # while cloud-data went unindexed. Same outcome, surfaced at minute one.
      # --filter=blob:none, NOT --depth: the comment above is right that shallow history
      # breaks incremental detection, but that argument is about COMMITS. A blobless clone
      # keeps the entire commit graph (so octocode's stored last-indexed commit still
      # resolves) and omits only historical file contents. --no-checkout defers populating
      # the working tree to an explicit step below — a plain `clone --filter=blob:none`
      # checks out immediately and pulls every blob the checkout touches in one big
      # up-front fetch anyway; splitting it out doesn't change what's fetched, but keeps
      # the two failure modes (fetch vs. checkout) distinguishable for the fallback below.
      # Runner disk is the binding constraint here — the DB alone restores to 16G on a
      # ~14G runner — so not downloading every blob of every past commit for seven repos
      # is free headroom. Falls back to a full clone if the remote refuses partial clone,
      # so this can never be the thing that fails a run.
      #
      # actions/checkout stamps a global `http.extraheader` (an Authorization token
      # scoped to THIS job's own repo, cloud-infra) into the runner's git config, and
      # that header inherits into every git command in the job — including clones of
      # DIFFERENT repos. Every ensure_repos clone is a foreign repo, so strip it
      # unconditionally: `-c http.extraheader=`. Credentials, when needed, travel in
      # $url (token-embedded https) or over SSH (deploy key), never via that header.
      # (The earlier guard `[ -z "$_key" ] && [ -z "$TOKEN" ]` was dead code — TOKEN
      # is always set at line ~188, so the strip never actually applied.)
      #
      # Clone stderr is CAPTURED and printed on failure. It used to be discarded
      # (2>/dev/null), which left cloud-u-android failing for days with zero signal
      # while three wrong theories (extraheader, auth, blobless) were chased. The
      # sed redacts any token embedded in the reported remote URL.
      _gitc="git -c http.extraheader="
      _cerr="$CGC_SCRATCH/clone-err.$$"
      # Transient network flakes (run 40692164340: "HTTP/2 framing layer ... early EOF" failed the
      # whole leg at minute one) get 3 attempts with HTTP/1.1; a real auth failure fails 3 times.
      _gitc="git -c http.extraheader= -c http.version=HTTP/1.1"
      _cok=0
      for _try in 1 2 3; do
        : > "$_cerr"; rm -rf "$d" 2>/dev/null
        if $_gitc clone -q --filter=blob:none --no-checkout "$url" "$d" 2>>"$_cerr" \
          && $_gitc -C "$d" checkout -q 2>>"$_cerr"; then _cok=1; break
        elif rm -rf "$d" 2>/dev/null; $_gitc clone -q "$url" "$d" 2>>"$_cerr"; then _cok=1; break
        fi
        [ "$_try" = 3 ] || { echo "[cgc-db] clone $lname attempt $_try failed - retrying in $((_try * 10))s"; sleep $((_try * 10)); }
      done
      if [ "$_cok" = 1 ]; then
        :
      else
        sed 's/x-access-token:[^@]*@/x-access-token:***@/g' "$_cerr" | tail -8 >&2
        echo "::error::[cgc-db] clone $lname ← $remote failed — git stderr above (private repo without a CGC_DEPLOY_KEY_* secret?)"; : > "$_clonefail"
      fi
      rm -f "$_cerr"
      # Same reason as the refresh path: strip any credential back out of origin so
      # the project_id octocode derives is the canonical, consumer-matching one.
      git -C "$d" remote set-url origin "$canon" 2>/dev/null || true
    fi
    # NO sub-repo slicing (removed 2026-09-03). A sparse-checkout slice indexed with
    # --no-git does NOT get its own octocode project: 0.22 keys the project on
    # sha256(origin URL) whenever .git+origin exist (octolib path_to_id; --no-git only
    # skips the git-root check), so every slice of one origin lands in ONE project dir
    # and slices 2..n hit the "no commit changes, skipping" gate. Over-large repos
    # ratchet across runs instead: the timeout branch below publishes the partial DB
    # and octocode skips already-embedded files (file_metadata mtime + chunk hash).
    # After BOTH paths: a refresh (reset --hard) rewrites mtimes on every touched file just
    # as a clone does, so neither path can be trusted to carry stable mtimes on its own.
    _mt0=$(date +%s)
    restore_mtimes "$d"
    echo "[cgc-db] $lname · restored deterministic mtimes in $(( $(date +%s) - _mt0 ))s"
  done
  if [ -f "$_clonefail" ]; then
    rm -f "$_clonefail"
    echo "::error::[cgc-db] one or more repos failed to clone — refusing to spend a full indexing pass on a set that cannot publish"
    return 1
  fi
}

# octocode (ignore crate) DEADLOCKS recursing nested submodules — each submodule
# is its own repo (indexed separately). Exclude them via .git/info/exclude
# (LOCAL + untracked → never touches tracked .gitignore). Data-driven from the
# repo's own .gitmodules. Idempotent.
exclude_submodules() {
  _d="$1"; _gm="$_d/.gitmodules"; _ex="$_d/.git/info/exclude"
  [ -f "$_gm" ] && [ -d "$_d/.git" ] || return 0
  mkdir -p "$_d/.git/info"
  awk -F'=' '/^[[:space:]]*path[[:space:]]*=/ { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2 }' "$_gm" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    grep -qxF "/$_p/" "$_ex" 2>/dev/null || printf '/%s/\n' "$_p" >> "$_ex"
    if cgc_repo_is_private "$(basename "$_d")"; then
      echo "[cgc-db] $_d · excluded a submodule from the octocode walk (path withheld: private repo)"
    else
      echo "[cgc-db] $_d · exclude submodule from octocode walk: $_p"
    fi
  done
}

# SMART auto-noindex (GENERIC — zero hardcoded project paths). octocode CPU-pegs walking and
# GraphRAG-graphing binary/asset blobs (bootloader theme PNGs, fonts, media, compiled objects).
# Instead of a human maintaining a list of offending dirs, DETECT them: git's numstat vs the
# empty tree prints '-' for every binary file, so we aggregate binary-vs-total per directory
# and exclude any dir that is majority-binary. Regenerated each run → adapts as repos change.
# Thresholds are data-driven (build.json runtime.octocode.smart_noindex.*). Appends to .noindex.
smart_noindex() {
  _d="$1"; _nx="$_d/.noindex"
  [ -d "$_d/.git" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  _min=$(jq -r   '.runtime.octocode.smart_noindex.min_files    // 12'  "$BJ")
  _ratio=$(jq -r '.runtime.octocode.smart_noindex.binary_ratio // 0.5' "$BJ")
  _empty=$(git -C "$_d" hash-object -t tree /dev/null 2>/dev/null)
  [ -n "$_empty" ] || return 0
  _hits=$(git -C "$_d" diff --numstat "$_empty" HEAD 2>/dev/null | awk -v min="$_min" -v ratio="$_ratio" '
    { path=$3; if (path=="" || path !~ /\//) next;
      dir=path; sub(/\/[^\/]*$/,"",dir);      # immediate parent directory of the file
      tot[dir]++; if ($1=="-") bin[dir]++; }
    END { for (d in tot) if (tot[d]>=min && (bin[d]+0)/tot[d]>=ratio) print d"/"; }')
  [ -n "$_hits" ] || return 0
  # De-dup against whatever base patterns already landed in .noindex.
  printf '%s\n' "$_hits" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    grep -qxF "$_p" "$_nx" 2>/dev/null || printf '%s\n' "$_p" >> "$_nx"
  done
  if cgc_repo_is_private "$(basename "$_d")"; then
    echo "[cgc-db] $_d · smart-noindex auto-excluded $(printf '%s\n' "$_hits" | grep -c .) binary-heavy dir(s) (names withheld: private repo)"
  else
    echo "[cgc-db] $_d · smart-noindex auto-excluded binary-heavy dirs: $(printf '%s' "$_hits" | tr '\n' ' ')"
  fi
}

# Propagate the freshly-pushed DB to the DEPLOYED consumer: SSH to the deploy
# host and run cloud-cgc-db-restore.sh there (pull GHCR DB → restore the
# octocode_db volume → restart the MCP container). This is what GUARANTEES the
# deployed oci-apps server actually serves the new DB after every update — the
# restore logic is streamed (sh -s), so nothing has to be pre-deployed. Data-
# driven (host/volume/container from build.json). Non-fatal if unreachable
# (e.g. mesh down). Caller provides WG + an SSH alias for db_publish.host.
propagate_to_host() {
  _host=$(jq -r '.db_publish.host // empty' "$BJ")
  [ -n "$_host" ] && [ "$_host" != "local" ] || { echo "[cgc-db] no deploy host — skip propagate"; return 0; }
  command -v ssh >/dev/null 2>&1 || { echo "[cgc-db] no ssh — skip propagate"; return 0; }
  _vol=$(jq -r '.runtime.octocode.db_volume'   "$BJ")
  _ctr=$(jq -r '.containers.app.container_name' "$BJ")
  # Resolve the SSH target data-driven: in CI, build-gha.json maps the alias →
  # user@wg_ip (no ~/.ssh/config needed); locally, fall back to the ssh alias.
  _gha="$ROOT/1_cloud-configs/dist/build-gha.json"
  _target="$_host"
  if [ -f "$_gha" ]; then
    _wgip=$(jq -r --arg h "$_host" '.vms[$h].wg_ip // empty'  "$_gha" 2>/dev/null)
    _user=$(jq -r --arg h "$_host" '.vms[$h].user // "ubuntu"' "$_gha" 2>/dev/null)
    [ -n "$_wgip" ] && _target="$_user@$_wgip"
  fi
  # Safety guard: skip if source or destination identifiers are empty/missing.
  [ -n "$_vol" ] && [ -d "$OCTO_HOME" ] && [ -n "$(ls -A "$OCTO_HOME" 2>/dev/null)" ] \
    || { echo "[cgc-db] WARN propagate: empty OCTO_HOME/vol — skip"; return 0; }

  # Install rsync on the runner if missing (idempotent — no-op when already present).
  if ! command -v rsync >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y -qq rsync
  fi
  command -v rsync >/dev/null 2>&1 || { echo "[cgc-db] WARN propagate: rsync unavailable — skip"; return 0; }

  echo "[cgc-db] propagate → $_target (rsync $OCTO_HOME → /var/lib/docker/volumes/$_vol/_data/)"
  # Stop the MCP container so the volume is quiescent during sync.
  # shellcheck disable=SC2086
  ssh ${CGC_SSH_OPTS:-} "$_target" "sudo docker stop $_ctr" || true
  # Delta-only rsync into the live volume path via remote sudo.
  # shellcheck disable=SC2086
  if rsync -az --delete --rsync-path="sudo rsync" \
      -e "ssh ${CGC_SSH_OPTS:-}" \
      "$OCTO_HOME/" \
      "$_target:/var/lib/docker/volumes/$_vol/_data/"; then
    # shellcheck disable=SC2086
    ssh ${CGC_SSH_OPTS:-} "$_target" "sudo docker start $_ctr"
    echo "[cgc-db] propagate OK — $_host now serving the new DB (rsync)"
  else
    echo "[cgc-db] WARN propagate to $_host failed (host unreachable / mesh down)"
    # shellcheck disable=SC2086
    ssh ${CGC_SSH_OPTS:-} "$_target" "sudo docker start $_ctr" || true
    return 0
  fi
}

# STRAY-SELECT — ROBUST PROJECT-DIR SELECTION (per-repo mode). "exactly one dir under
# OCTO_HOME" (package.sh's find_project_dir) is the WRONG invariant to check
# BEFORE packaging: production incident (run 32572923354) — a stray project
# dir (see STRAY-PREVENT above for the leading cause; STRAY-SELECT is deliberately
# independent of STRAY-PREVENT actually catching every cause, since strays can in
# principle come from anywhere) sat in OCTO_HOME BEFORE this repo's own index
# ran, so find_project_dir saw two dirs and hard-errored instead of packaging.
#
# Snapshot the set of project dirs immediately BEFORE this repo's `octocode
# index`, and derive the target from the DIFF against the set immediately
# AFTER, instead of a bare count:
#   • exactly one NEW dir            → that is the target (a fresh index —
#                                       true whether OCTO_HOME started clean
#                                       or already had unrelated stray dirs;
#                                       those simply are not "new")
#   • zero new, exactly one TOUCHED  → that is the target (re-index of a
#                                       project dir this job already restored
#                                       from a prior per-repo checkpoint —
#                                       "touched" = some file under it has an
#                                       mtime newer than a marker stamped
#                                       right before the index ran)
#   • anything else                  → ambiguous; name the sets and hard-error
#                                       rather than guess (0 new+0 touched, or
#                                       >1 new, or >1 touched-with-no-new all
#                                       land here)
# Mirrors find_project_dir's fastembed/sentencetransformer exclusion (root-
# state model caches, never project dirs) so the two never disagree.
project_dirs_snapshot() {  # $1=OCTO_HOME → stdout: one dir name per line
  for _pds_e in "$1"/*; do
    [ -d "$_pds_e" ] || continue
    _pds_b="${_pds_e##*/}"
    case "$_pds_b" in fastembed|sentencetransformer) continue ;; esac
    printf '%s\n' "$_pds_b"
  done
}

resolve_project_dir() {  # $1=OCTO_HOME $2=BEFORE(newline list) $3=MARKER(mtime ref file) → stdout: dir name; rc!=0 on ambiguous
  _rpd_home="$1"; _rpd_before="$2"; _rpd_marker="$3"
  _rpd_after=$(project_dirs_snapshot "$_rpd_home")
  _rpd_new="" _rpd_n_new=0
  for _rpd_d in $_rpd_after; do
    printf '%s\n' "$_rpd_before" | grep -qxF "$_rpd_d" || { _rpd_new="$_rpd_new $_rpd_d"; _rpd_n_new=$((_rpd_n_new + 1)); }
  done
  if [ "$_rpd_n_new" -eq 1 ]; then
    printf '%s\n' "${_rpd_new# }"
    return 0
  fi
  if [ "$_rpd_n_new" -eq 0 ]; then
    _rpd_touched="" _rpd_n_touched=0
    for _rpd_d in $_rpd_after; do
      # Preexisting dir (present before too) whose contents changed since $_rpd_marker was stamped.
      [ -n "$(find "$_rpd_home/$_rpd_d" -newer "$_rpd_marker" -print -quit 2>/dev/null)" ] \
        && { _rpd_touched="$_rpd_touched $_rpd_d"; _rpd_n_touched=$((_rpd_n_touched + 1)); }
    done
    if [ "$_rpd_n_touched" -eq 1 ]; then
      printf '%s\n' "${_rpd_touched# }"
      return 0
    fi
    echo "::error::[cgc-db] ambiguous project-dir diff under $_rpd_home: before=[$(printf '%s' "$_rpd_before" | tr '\n' ' ')] after=[$(printf '%s' "$_rpd_after" | tr '\n' ' ')] new=0 touched=$_rpd_n_touched[$(printf '%s' "$_rpd_touched" | tr '\n' ' ')] — cannot determine which dir this index produced" >&2
    return 1
  fi
  echo "::error::[cgc-db] ambiguous project-dir diff under $_rpd_home: before=[$(printf '%s' "$_rpd_before" | tr '\n' ' ')] after=[$(printf '%s' "$_rpd_after" | tr '\n' ' ')] new=$_rpd_n_new[$(printf '%s' "$_rpd_new" | tr '\n' ' ')] — expected exactly one new dir" >&2
  return 1
}

# ── LANCE REFERENTIAL INTEGRITY ─────────────────────────────────────────────
# A lance table is a directory of immutable data fragments plus a chain of
# manifests; each manifest names the fragments that version needs. If a fragment
# named by the CURRENT manifest is absent, every read of that table dies with
#   lance error: Not found: .../<table>.lance/data/<id>.lance
# and because octocode opens its tables together, that kills the WHOLE query --
# a repo whose document_blocks is torn cannot answer a code question either.
#
# This is the shape that blinded the fleet from 2026-09-07 to 2026-09-10:
# cloud-u-android's document_blocks.lance had 7352 manifests and an EMPTY data/,
# every one of them naming the same absent fragment. Nothing in the pipeline
# looked, so a torn table survived re-index after re-index (see the repair at the
# per-repo restore, and the publish gate in checkpoint_publish below).
#
# lance names _versions files u64::MAX-version, so the lexicographically FIRST
# entry is the NEWEST version -- that is the one a reader opens.
# The manifest a reader opens. lance has two _versions naming schemes: V2 names a
# version u64::MAX-version (20 digits, so the SMALLEST name is the newest), V1 names
# it plainly (the LARGEST number is the newest). `ls | sort | head -1` was right only
# for V2 and, on a V1 table, picked the OLDEST manifest -- whose fragments compaction
# may legitimately have removed -- and reported a healthy table as torn. It also died
# of SIGPIPE ("sort: write error") on tables holding ~10k manifests. One awk pass,
# string-compared (20-digit names overflow awk's doubles), handles both.
lance_newest_manifest() { # $1 = table dir -> stdout: newest manifest file name
  ls "$1/_versions" 2>/dev/null | awk '
    /^[0-9]+\.manifest$/ {
      n = $0; sub(/\.manifest$/, "", n)
      if (length(n) == 20 && substr(n, 1, 6) == "184467") {
        if (v2 == "" || (n "") < (v2 "")) v2 = n
      } else if (v1 == "" || n + 0 > v1 + 0) v1 = n
    }
    END { if (v2 != "") print v2 ".manifest"; else if (v1 != "") print v1 ".manifest" }'
}

# Drop superseded lance MANIFESTS, keeping the newest $2 (default 2) per table.
# octocode never cleans up old versions, and every manifest re-lists every fragment,
# so _versions grows quadratically: measured 2026-10-04 on oci-apps,
# cloud-u-containers' file_metadata.lance was 3.0G of _versions (8800 manifests)
# against 35M of data. That bloat is what ran oci-apps out of disk mid-restore
# (run 37146011415, "no space left on device" staging cloud-u-containers) and what
# makes every pull/stage/swap slow. Old manifests serve only time travel, which
# nothing here uses. DATA files are never touched: a fragment only an old version
# names costs disk, but deleting one a live manifest needs would tear the table.
lance_prune_old_versions() { # $1 = octocode home (or staging tree), $2 = keep count
  _lpo_keep="${2:-2}"; _lpo_n=0
  for _lpo_t in "$1"/*/storage/*.lance; do
    [ -d "$_lpo_t/_versions" ] || continue
    _lpo_new=$(lance_newest_manifest "$_lpo_t")
    [ -n "$_lpo_new" ] || continue
    case "$_lpo_new" in
      184467*) _lpo_order="sort" ;;   # V2: newest first ascending
      *)       _lpo_order="sort -rn" ;;
    esac
    for _lpo_m in $(ls "$_lpo_t/_versions" | grep -E '^[0-9]+\.manifest$' | $_lpo_order | awk -v k="$_lpo_keep" 'NR > k'); do
      [ "$_lpo_m" = "$_lpo_new" ] && continue
      rm -f "$_lpo_t/_versions/$_lpo_m" && _lpo_n=$((_lpo_n + 1))
    done
  done
  [ "$_lpo_n" -gt 0 ] && echo "[cgc-db] pruned $_lpo_n superseded lance manifest(s) under $1 (kept newest $_lpo_keep per table)"
  :
}

# Delete lance DATA fragments that no remaining manifest names (run it AFTER
# lance_prune_old_versions, so "remaining" means the newest N kept above).
# lance_prune_old_versions drops old manifests but leaves every fragment only they
# named, and octocode rewrites whole tables on compaction: measured 2026-10-14 on
# oci-apps, one repo's code_blocks.lance held 1094 data files (1.6G) of which
# the two kept manifests name ONE (161M). Across both cgc volumes 9.6G of 13.3G of
# lance data was unreferenced, the per-repo images carried it too (cgc-db-
# cloud-u-containers was 4.4G), and the restore died of ENOSPC staging it (#988).
# Safety: references are read from EVERY kept manifest with the integrity gate's
# own parser, unanchored (grep -o), so the set kept here is a superset of what
# lance_dangling_tables checks -- cross-checked against pylance's own
# fragment.data_files() on three real tables: identical. Fail closed per table:
# when no reference parses, or none of them is on disk, the parse is suspect and
# the table is left alone. lance_dangling_tables still runs after this.
lance_gc_unreferenced_data() { # $1 = octocode home (or staging tree)
  _lgc_n=0; _lgc_kb=0
  for _lgc_t in "$1"/*/storage/*.lance; do
    [ -d "$_lgc_t/_versions" ] && [ -d "$_lgc_t/data" ] || continue
    _lgc_drop=$(
      { for _lgc_f in "$_lgc_t"/data/*.lance; do
          [ -e "$_lgc_f" ] && printf 'D %s\n' "${_lgc_f##*/}"
        done
        for _lgc_m in "$_lgc_t"/_versions/*.manifest; do
          [ -f "$_lgc_m" ] || continue
          tr -c '0-9a-f.ln' '\n' < "$_lgc_m" | grep -oE '[0-9a-f]{32,}\.lance' | sed 's/^/R /'
        done
      } | awk '
        $1 == "D" { d[++nd] = $2; next }
        $1 == "R" { nr++; s = $2; for (i = 1; i <= length(s); i++) ref[substr(s, i)] = 1 }
        END {
          if (nr == 0) exit 1
          k = 0; for (j = 1; j <= nd; j++) if (d[j] in ref) k++
          if (k == 0) exit 1
          for (j = 1; j <= nd; j++) if (!(d[j] in ref)) print d[j]
        }') || continue
    [ -n "$_lgc_drop" ] || continue
    _lgc_b=$(du -sk "$_lgc_t/data" 2>/dev/null | cut -f1)
    for _lgc_f in $_lgc_drop; do
      rm -f "$_lgc_t/data/$_lgc_f" && _lgc_n=$((_lgc_n + 1))
    done
    _lgc_a=$(du -sk "$_lgc_t/data" 2>/dev/null | cut -f1)
    _lgc_kb=$((_lgc_kb + ${_lgc_b:-0} - ${_lgc_a:-0}))
  done
  [ "$_lgc_n" -gt 0 ] && echo "[cgc-db] removed $_lgc_n unreferenced lance data fragment(s) under $1 ($((_lgc_kb / 1024)) MB)"
  :
}

# One line per lance table: manifest count, newest manifest name, data-file count.
# Names and counts only (hashes, no content), so it is safe in a public log. Added
# for #1061: cloud-infra-desktop's publish gate refuses every scheduled run with a
# newest manifest naming 8 fragments while data/ holds 1, but the same prune + GC on
# the same restored image leaves 8 locally, so something between the restore and the
# gate shrinks data/. These lines show at which step.
lance_state_summary() { # $1 = octocode home, $2 = label
  for _lss_t in "$1"/*/storage/*.lance; do
    [ -d "$_lss_t/_versions" ] || continue
    echo "[cgc-db] lance state ($2): $(basename "$_lss_t") manifests=$(ls "$_lss_t/_versions" 2>/dev/null | wc -l | tr -d ' ') newest=$(lance_newest_manifest "$_lss_t") data=$(ls "$_lss_t/data" 2>/dev/null | wc -l | tr -d ' ') versions=[$(ls "$_lss_t/_versions" 2>/dev/null | tr '\n' ' ')]"
  done
  :
}

# The data files a manifest's FRAGMENTS use -- not every name that appears in the file.
# A lance manifest file also embeds the Transaction that created it, and a compaction
# (Rewrite) transaction lists the OLD fragments it replaced. octocode removes those
# files itself right after committing (lance cleanup), so grepping every ".lance" name
# out of the bytes reads a healthy compacted table as torn: 2026-10-14..20 every
# scheduled run refused to publish cloud-infra-desktop (graphrag_nodes: the newest
# manifest names ONE live fragment, pylance agrees, the grep found 8 and data/ held 1;
# #1061), so its GHCR image never advanced. Real files end in "LANC" and carry the
# manifest's offset 16 bytes from the end; decode Manifest.fragments[].files[].path
# with the stdlib only. Anything that is not such a file (or no python3) falls back to
# the old grep, which can only over-report -- a missing tool must never read as clean.
lance_live_refs() { # $1 = manifest file -> stdout: one data file name per line
  python3 -I - "$1" 2>/dev/null <<'PY' || { tr -c '0-9a-f.ln' '\n' < "$1" 2>/dev/null | grep -E '[0-9a-f]{32,}\.lance$'; }
import struct, sys
def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7F) << s
        if not c & 0x80:
            return r, i
        s += 7
def fields(b):
    i = 0
    while i < len(b):
        k, i = varint(b, i)
        w = k >> 3, k & 7
        if w[1] == 0:
            v, i = varint(b, i)
        elif w[1] == 2:
            n, i = varint(b, i); v = b[i:i + n]; i += n
        elif w[1] == 1:
            v = b[i:i + 8]; i += 8
        elif w[1] == 5:
            v = b[i:i + 4]; i += 4
        else:
            raise ValueError("wire type")
        yield w[0], v
raw = open(sys.argv[1], "rb").read()
if len(raw) < 24 or raw[-4:] != b"LANC":
    sys.exit(3)
pos = struct.unpack("<Q", raw[-16:-8])[0]
n = struct.unpack("<I", raw[pos:pos + 4])[0]
out = []
for f, v in fields(raw[pos + 4:pos + 4 + n]):
    if f == 2:
        for ff, vv in fields(v):
            if ff == 2:
                for df, dv in fields(vv):
                    if df == 1:
                        out.append(dv.decode())
sys.stdout.write("".join(p + "\n" for p in out))
PY
}

lance_dangling_tables() { # $1 = octocode home -> stdout: one dangling table dir per line
  _ldt_home="$1"
  for _ldt_t in "$_ldt_home"/*/storage/*.lance; do
    [ -d "$_ldt_t/_versions" ] || continue
    _ldt_m=$(lance_newest_manifest "$_ldt_t")
    [ -n "$_ldt_m" ] || continue
    # Pull every hex-run ending in .lance out of the binary manifest. `tr`, not
    # `strings`: strings is binutils and may simply be absent on a runner, and a
    # missing tool must never read as "clean" -- fail closed, not open.
    # The charset must include l,n -- the literal letters of the ".lance" suffix.
    # With a bare hex set, tr shreds ".lance" into ".", "a", "ce" and the grep below
    # matches nothing, so EVERY table reads as clean: the check silently inverts
    # into a no-op. cgc-db-lance-integrity.test.sh pins this.
    #
    # ONE awk pass per table: data/ names go into a hash set ("D" lines, emitted
    # first), then each manifest reference ("R" lines) is tested against it. The
    # old shell loop compared every reference with every data file -- O(refs x
    # fragments) -- and octocode writes one fragment per file batch, so
    # cloud-u-android's file_metadata.lance (15.5k refs x 15.9k fragments) took
    # ~57 min PER CALL on a GHA runner, three calls per run (#888).
    # Match by TAIL, never by equality: the protobuf length byte in front of the
    # name is itself a hex character, so a reference carries one junk leading
    # char. Every suffix of the reference is looked up, so the test stays
    # length-agnostic and a future lance fragment-id width cannot silently turn
    # it into a no-op.
    { for _ldt_f in "$_ldt_t"/data/*.lance; do
        [ -e "$_ldt_f" ] && printf 'D %s\n' "${_ldt_f##*/}"   # empty data/ leaves the glob unexpanded
      done
      lance_live_refs "$_ldt_t/_versions/$_ldt_m" | sed 's/^/R /'
    } | awk '
      $1 == "D" { have[$2] = 1; next }
      # No early `exit` on the first miss: awk must drain its input, or the writers
      # above die of SIGPIPE and a caller running under pipefail reads the whole
      # pipeline as failed -- i.e. a torn table as clean.
      $1 == "R" && !torn {
        hit = 0
        for (i = 1; i <= length($2); i++) if ((substr($2, i)) in have) { hit = 1; break }
        if (!hit) torn = 1
      }
      END { exit torn ? 0 : 1 }' && printf '%s\n' "$_ldt_t"
  done
  :
}

# Checkpoint-push after one repo. CGC_PACKAGE_MODE=per-repo (matrix CI) packages
# ONLY that repo's own project dir into its OWN GHCR image; the default
# "monolith" mode keeps packaging the WHOLE octocode home into the single
# shared db_publish.image, unchanged. Same script either way —
# cloud-cgc-db-package.sh auto-detects repo/base/monolith packaging mode from
# the image name (${IMAGE##*/} — "cgc-db-<repo>" vs "cgc-db-base" vs anything
# else), so the only difference here is WHICH image name is passed.
# REPO_PREFIX/REPO_TAG are set once above (per-repo restore-base branch) —
# reused here rather than re-reading build.json per repo.
# CGC_PROJECT_DIR (STRAY-SELECT) — when the per-repo loop below has already resolved
# THIS checkpoint's project dir via the before/after diff (_proj_resolved),
# pass it through so package.sh's own find_project_dir (an exactly-one count
# over the WHOLE home, which is exactly the fragile invariant STRAY-SELECT replaces)
# is bypassed for this call. Empty when unresolved (e.g. monolith mode, where
# packaging tars the whole home and never looks at project dirs at all) —
# package.sh falls back to find_project_dir precisely as before for any
# caller that does not set it.
checkpoint_publish() {  # $1 = repo local name
  if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
    # PUBLISH GATE (fail closed). Pushing a torn table to GHCR is what makes the
    # damage permanent: the next run layers this very image back in as its
    # incremental base, octocode's change-gate sees the table present and never
    # rewrites it, and the run goes green while every consumer query dies. Refuse.
    # set -eu + a bare call site means this return FAILS the job, which is the point.
    lance_state_summary "$OCTO_HOME" "$1 before prune"
    lance_prune_old_versions "$OCTO_HOME"
    lance_state_summary "$OCTO_HOME" "$1 after prune"
    lance_gc_unreferenced_data "$OCTO_HOME"
    lance_state_summary "$OCTO_HOME" "$1 after gc"
    _cp_torn=$(lance_dangling_tables "$OCTO_HOME")
    if [ -n "$_cp_torn" ]; then
      echo "::error::[cgc-db] refusing to publish $1 — dangling lance manifest(s) in this home:"
      # Evidence per table, same shape as restore-all's refusal: run 37146011415
      # refused cloud-data-my-ai-memory's graphrag_relationships.lance right after a
      # clean restore + clean index, and the bare path left nothing to diagnose with.
      printf '%s\n' "$_cp_torn" | while IFS= read -r _cp_t; do
        _cp_m=$(lance_newest_manifest "$_cp_t")
        echo "::error::[cgc-db]   $_cp_t newest=$_cp_m versions=$(ls "$_cp_t/_versions" 2>/dev/null | wc -l) data=$(ls "$_cp_t/data" 2>/dev/null | wc -l) references=[$(lance_live_refs "$_cp_t/_versions/$_cp_m" | tr '\n' ' ' || true)] data_sample=[$(ls "$_cp_t/data" 2>/dev/null | head -3 | tr '\n' ' ')]"
      done
      echo "::error::[cgc-db] a manifest naming an absent fragment is unreadable forever; the prior image on GHCR is the better artifact and is left in place."
      return 1
    fi
    CGC_BUILD_JSON="$BJ" CGC_PROJECT_DIR="${_proj_resolved:-}" CGC_LOCAL_NAME="$1" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "${REPO_PREFIX}$(cgc_image_name "$1")" "$REPO_TAG"
  else
    CGC_BUILD_JSON="$BJ" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$IMAGE" "$TAG"
  fi
}

# GRAPH PERSISTED? (graphrag phase, #888). octocode writes graphrag_nodes.lance only
# when the graph pass COMPLETES; an index killed by the slice timeout leaves a project
# dir with storage (blocks, embeddings, metadata) and no graph. Run 37415858605: a forced
# cloud-u-containers index stopped at 2233/3462 files, published exactly that, and the job
# was green -- the timeout branch only warned, and assert_llm_graph reads a 0-node overview
# as a "small corpus". "Present" means a data fragment exists, not just the directory.
graph_nodes_present() {  # $1 = project dir name under OCTO_HOME → rc 0 when a node fragment exists
  [ -n "${1:-}" ] || return 1
  [ -n "$(find "$OCTO_HOME/$1/storage/graphrag_nodes.lance/data" -type f -name '*.lance' -print -quit 2>/dev/null)" ]
}

# FORCED-RUN RESUME (#888). A forced index restarts from base on purpose (see the restore
# loop), so a repo too big for one slice could never finish: every forced run redid the
# same 64% and then overwrote :latest with a graph-less partial. A forced run that times
# out now publishes its partial to a SEPARATE tag, never :latest (the served graph
# survives), stamped with a marker; the next forced run of the same phase resumes from it
# when the marker's octocode version matches the pinned one, else starts from base as before.
FORCE_PARTIAL_MARKER=".cgc-force-partial"
force_partial_tag() { printf '%s-force-%s' "$REPO_TAG" "${MANIFEST_PHASE:-default}"; }

resume_force_partial() {  # $1 = repo local name → layers the resumable partial into OCTO_HOME, or nothing
  _rfp_before=$(project_dirs_snapshot "$OCTO_HOME")
  CGC_PULL_MERGE=1 sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" "${REPO_PREFIX}$(cgc_image_name "$1"):$(force_partial_tag)" || true
  for _rfp_d in $(project_dirs_snapshot "$OCTO_HOME"); do
    printf '%s\n' "$_rfp_before" | grep -qxF "$_rfp_d" && continue
    _rfp_m="$OCTO_HOME/$_rfp_d/$FORCE_PARTIAL_MARKER"
    if [ -f "$_rfp_m" ] && [ "$(jq -r '.octocode // ""' "$_rfp_m" 2>/dev/null)" = "$OCTO_VERSION" ] \
       && [ "$(jq -r '.phase // ""' "$_rfp_m" 2>/dev/null)" = "${MANIFEST_PHASE:-default}" ]; then
      rm -f "$_rfp_m"   # :latest must never carry the marker
      RESUMED_FORCE_PARTIAL=1
      echo "[cgc-db] CGC_FORCE — resuming $1 from its unfinished forced index ($(force_partial_tag), project $_rfp_d)"
    else
      rm -rf "$OCTO_HOME/$_rfp_d"
      echo "[cgc-db] CGC_FORCE — $1: tag $(force_partial_tag) is not a resumable partial for octocode $OCTO_VERSION, starting from base"
    fi
  done
}

# BOOTSTRAP config.toml (per-repo mode only). Before the versioned base image
# exists on GHCR (the first cycle after every octocode bump) the base restore is a
# no-op and OCTO_HOME has no config.toml; an `octocode index` in that state would
# write octocode's OWN defaults (production incident 2026-08-21, run 32502667627:
# cloud models needing VOYAGE_API_KEY, zero files indexed). The file is generated
# by the pinned octocode itself — a hand-written template cannot track the schema
# (0.22 refuses the 0.12-era v1 file outright: "missing field `quantization`" —
# measured), while `octocode config --<flag>` always writes the loader's own
# current version. XDG_DATA_HOME is aligned to $OCTO_HOME's parent above, so the
# write lands exactly at $CFG; that is verified, never assumed. build.json's
# embedding models go in on the same call — a wrong/missing model here silently
# drop_tables data on a later restore (see cloud-cgc-db-package.sh's base DESC).
bootstrap_config_toml() {
  [ -f "$CFG" ] && return 0
  mkdir -p "$(dirname "$CFG")"
  ( cd "$CGC_SCRATCH" && octocode config --model "$LLM" \
      --code-embedding-model "$CODE_EMBED" --text-embedding-model "$TEXT_EMBED" ) >/dev/null 2>&1 || true
  [ -f "$CFG" ] || { echo "::error::[cgc-db] octocode config did not create $CFG (XDG_DATA_HOME=${XDG_DATA_HOME:-unset}) — nothing to index with"; exit 1; }
  # Parity with what every consumer was validated against: reranker + hybrid OFF
  # (0.22 turns both on by default; the reranker pulls a ~1GB jina model at query
  # time) and graphrag OFF/no-LLM until 4a/4b decide per phase. Section-scoped so
  # the same key names under [graphrag.llm] / [search.reasoning] are untouched.
  awk '
    /^\[/ { sec = $0 }
    (sec == "[search.reranker]" || sec == "[search.hybrid]" || sec == "[graphrag]") && /^enabled[[:space:]]*=/ { print "enabled = false"; next }
    sec == "[graphrag]" && /^use_llm[[:space:]]*=/ { print "use_llm = false"; next }
    { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "[cgc-db] bootstrapped config.toml with octocode $OCTO_VERSION (embedding $CODE_EMBED / $TEXT_EMBED, llm $LLM, reranker/hybrid off)"
}

# APPLY build.json's declared file associations to config.toml — ON EVERY RUN.
#
# WHY IT CANNOT LIVE IN bootstrap_config_toml(): that function returns early the
# moment a config.toml already exists, and after the very first cycle one ALWAYS
# exists (it is restored from the GHCR base/checkpoint image). A declaration added
# to build.json would therefore be applied on exactly zero of the boxes that
# matter — declared forever, never in force. Every other config.toml mutation in
# this script (graphrag, embedding models, batch size) already runs unconditionally
# for exactly that reason; this one now does too.
#
# WHAT IT BUYS: octocode 0.22.0 keeps a file only if detect_language() or
# ALLOWED_TEXT_EXTENSIONS knows its extension (src/indexer/mod.rs:401/422), and
# neither knows `kt`/`kts` — so cloud-u-android's ~9,900 Kotlin files were dropped
# at the file walk, before chunking and embedding, and the index was blind to the
# repo's primary language. `[index.file_associations]` (src/language.rs:25,
# config.rs:143/376) maps an extension onto an EXISTING grammar and is the only
# declarable lever 0.22 has for this. The pairs themselves are NOT in this script:
# they come from .runtime.octocode.file_associations, so adding a language is a
# build.json edit, never a script edit.
#
# IDEMPOTENT + NON-CLOBBERING: rewrites only assignments for extensions we declare,
# inside the [index.file_associations] section alone, leaving every other section
# (and any comment or association we do not declare) byte-identical. If the section
# is missing entirely — an older restored config — it is appended as a new table at
# the end of the file, which is where a previously-unused sub-table belongs. awk,
# never sed (see reference_awk-not-sed-secrets.md).
#
# An unknown grammar name here makes octocode REFUSE the config outright
# (normalize_file_associations bails on an unsupported language), so a typo fails
# the index loudly instead of silently indexing nothing — the failure mode this
# whole fix exists to end. derive-code-signatures.test.ts checks the grammar names
# against the pinned release's own source before they can ever reach a run.
apply_file_associations() {
  [ -f "$CFG" ] || return 0
  _fa_pairs=$(jq -r '.runtime.octocode.file_associations // {} | to_entries[] | "\(.key)=\(.value)"' "$BJ" 2>/dev/null)
  if [ -z "$_fa_pairs" ]; then
    echo "[cgc-db] no .runtime.octocode.file_associations declared in $BJ — config.toml [index.file_associations] left untouched"
    return 0
  fi
  awk -v pairs="$_fa_pairs" '
    function emit(   i) { for (i = 1; i <= count; i++) printf "%s = \"%s\"\n", ext[i], lang[ext[i]] }
    BEGIN {
      n = split(pairs, declared, "\n")
      for (i = 1; i <= n; i++) {
        eq = index(declared[i], "=")
        if (eq < 2) continue
        e = substr(declared[i], 1, eq - 1)
        sub(/^\./, "", e)
        if (!(e in lang)) ext[++count] = e
        lang[e] = substr(declared[i], eq + 1)
      }
    }
    /^\[/ {
      if (in_fa) { emit(); in_fa = 0 }
      if ($0 ~ /^\[index\.file_associations\][ \t]*$/) { in_fa = 1; seen = 1 }
      print; next
    }
    in_fa && /^[ \t]*"?\.?[A-Za-z0-9_+-]+"?[ \t]*=/ {
      key = $0
      sub(/[ \t]*=.*$/, "", key)
      gsub(/[ \t"]/, "", key)
      sub(/^\./, "", key)
      if (key in lang) next
      print; next
    }
    { print }
    END {
      if (in_fa) emit()
      else if (!seen) { printf "\n[index.file_associations]\n"; emit() }
    }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  echo "[cgc-db] config.toml [index.file_associations] applied from $BJ: $(printf '%s' "$_fa_pairs" | tr '\n' ' ')"
}

# AUTO-SEED the shared base image (per-repo mode only) — the other half of the
# 2026-08-21 bootstrap incident (see bootstrap_config_toml() above). Before this,
# cgc-db-base:latest had to be seeded OUT OF BAND by a human running
# cloud-cgc-db-package.sh once; every matrix cycle before that seed hit the same
# missing-config crash. Once THIS job has published a checkpoint, OCTO_HOME holds
# at minimum a valid config.toml (bootstrap-written above, or already restored) —
# package+push it as the base image the same way a human seed would, via
# cloud-cgc-db-package.sh's existing "base" mode (auto-detected from the
# cgc-db-base image name — see that script's header). Its build_base_tar()
# already tolerates a PARTIAL root state (config.toml alone is enough; it only
# errors if NONE of config.toml/fastembed/sentencetransformer exist), so this is
# safe even on the very first repo of the very first cycle.
#
# GUARD: BASE_SEEDED (reset once per job run, above the repo loop) — only the
# FIRST repo in THIS job attempts a seed; a second attempt in the same job would
# just re-push the same root state for no benefit. RACES BETWEEN PARALLEL MATRIX
# JOBS are deliberately left unguarded: every job in a cycle restores the SAME
# (missing) base and indexes with the SAME build.json models, so their
# config.toml/fastembed content converges to the same bytes regardless of which
# repo produced it — concurrent pushes to cgc-db-base:latest are idempotent,
# last-write-wins on content that is the same either way.
seed_base_if_missing() {
  [ "$BASE_SEEDED" = "1" ] && return 0
  BASE_SEEDED=1
  # GPU-EMBED GUARD — see CGC_LOCAL_EMBED_MODEL above. This job's OCTO_HOME
  # config.toml carries local:nomic-embed-text while the override is active;
  # seeding $BASE_IMAGE from it would publish that model into the shared base
  # that every consumer restores — including this box's own cloud-cgc-pub-mcp/
  # cloud-cgc-pvt-mcp, which embed search QUERIES and must stay on fastembed.
  # Refuse instead: the base stays whatever it already was (present, per the
  # docker manifest check below, in every run that matters — this only bites
  # the astronomically rare case of a GPU-embed run landing on the very first
  # cycle after an octocode version bump, before any fastembed job has re-
  # seeded the base) and a later non-GPU job seeds it for real if ever needed.
  if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ]; then
    echo "::warning::[cgc-db] CGC_LOCAL_EMBED_MODEL is set — refusing to auto-seed $BASE_IMAGE from this job's config.toml (would leak '$CGC_LOCAL_EMBED_MODEL' into the shared base/box, which must stay fastembed). Skipping; a fastembed job will seed it if it is genuinely still missing."
    return 0
  fi
  if docker manifest inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "[cgc-db] base image $BASE_IMAGE already on GHCR — skip auto-seed"
    return 0
  fi
  _sbm_img="${BASE_IMAGE%:*}"
  case "$BASE_IMAGE" in *:*) _sbm_tag="${BASE_IMAGE##*:}" ;; *) _sbm_tag="latest" ;; esac
  echo "[cgc-db] $BASE_IMAGE missing on GHCR — auto-seeding from this job's octocode home"
  if CGC_BUILD_JSON="$BJ" sh "$HERE/cloud-cgc-db-package.sh" "$OCTO_HOME" "$_sbm_img" "$_sbm_tag"; then
    echo "[cgc-db] auto-seed OK — $BASE_IMAGE published"
  else
    echo "::warning::[cgc-db] auto-seed of $BASE_IMAGE failed — next job's bootstrap will retry"
  fi
}

# ── run ───────────────────────────────────────────────────────────────────
# GHCR auth FIRST — the base / per-repo checkpoint images below are GHCR pulls, so
# docker must be logged in before any of them. (ensure_octocode itself no longer
# needs docker: the indexer binary comes straight from the upstream release.)
ensure_ghcr_auth
ensure_octocode
ensure_repos

# SMALLEST-FIRST. index_repos is authoring order, not run order, and it happened to put
# the two largest repos first — both blew their repo_timeout_min, consumed the whole
# max_minutes budget, and the remaining five were deferred with "deferring front (+rest)".
# Net effect on 2026-08-20: 180m spent, zero repos indexed, nothing published, while five
# repos that finish in minutes never got a turn. Ordering by tracked-file count ascending
# makes every run publish the cheap repos FIRST, so a giant that cannot finish can only
# ever cost itself its own slot — never the whole cycle. Measured from the clone (git
# ls-files), not declared in build.json, so it stays true as repos grow. Ties keep
# authoring order; a repo whose count cannot be read sorts last rather than blocking.
order_repos_by_size() {
  for _r in $REPOS; do
    _n=$(git -C "$REPOS_ROOT/$_r" ls-files 2>/dev/null | wc -l)
    [ "$_n" -gt 0 ] 2>/dev/null || _n=99999999
    printf '%s\t%s\n' "$_n" "$_r"
  done | sort -n -s -k1,1 | cut -f2
}
REPOS=$(order_repos_by_size)
echo "[cgc-db] index order (smallest first): $(printf '%s' "$REPOS" | tr '\n' ' ')"

# 3) restore the incremental base from GHCR. The producer is INCREMENTAL-ONLY —
# it must NEVER full-build from scratch (octocode's GraphRAG full build is ~12h,
# O(N²) relationships). The base is created ONCE by a seed: cloud-cgc-db-package.sh
# of an already-built octocode DB, or a prod-volume snapshot. Refuse without a base.
#
# CGC_PACKAGE_MODE=per-repo (matrix CI): OCTO_HOME is a FRESH per-job dir, and
# there is no monolith base to refuse-without — restore the SHARED base image
# (config.toml + fastembed/ + sentencetransformer/ caches, NOT the 15G monolith)
# then, layered on top, THIS repo's own prior per-repo checkpoint image if one
# exists. A repo with no prior image starts empty — that is the documented
# first-build case (per-repo images bootstrap from empty), not an error.
mkdir -p "$OCTO_HOME"
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  BASE_IMAGE=$(jq -r '.per_repo_publish.base_image // "ghcr.io/diegonmarcos/cgc-db-base:latest"' "$BJ")
  REPO_PREFIX=$(jq -r '.per_repo_publish.image_prefix // "ghcr.io/diegonmarcos/cgc-db-"' "$BJ")
  REPO_TAG=$(jq -r '.per_repo_publish.tag // "latest"' "$BJ")
  sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" "$BASE_IMAGE" || true
  for _r in $REPOS; do
    # FORCED graphrag = FULL re-index: do not layer this repo's prior checkpoint.
    # octocode 0.12.2 feeds its graph builder only the files the current update
    # actually processes, and TWO metadata tables in the prior image gate that
    # set down to "changed since last run" (git_metadata.lance by commit,
    # file_metadata.lance by content hash) — so force-dropping graphrag_* on
    # top of a restored checkpoint rebuilt the graph from a 29-file sliver of a
    # 1000-file corpus (run 32664198030, measured). Starting from the shared
    # base instead (config + embedder caches, no blocks, no metadata) makes the
    # update process EVERY file, which is the only full-graph path this octocode
    # has. Embeddings recompute — that cost is the per-repo semantic pass, not
    # the ~12h monolith figure, and the 8-wide matrix absorbs it. Safety is
    # unchanged: preflight failure aborts before package/push, so the prior
    # image on GHCR survives until a full replacement is actually built.
    # ...and a forced SEMANTIC run just the same: `force` is the documented lever
    # "after an INDEXER change" (cgc-db.yml), and an octocode bump is exactly that —
    # layering a checkpoint written by another octocode version under the new
    # binary is the one thing that must never happen (the DB schema follows the
    # binary). Forced means from base, in both phases.
    if [ "${CGC_FORCE:-0}" = "1" ]; then
      echo "[cgc-db] CGC_FORCE — skipping prior checkpoint of $_r: full re-index from base (USE_LLM=$USE_LLM)"
      resume_force_partial "$_r"
      continue
    fi
    CGC_PULL_MERGE=1 sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" "${REPO_PREFIX}$(cgc_image_name "$_r"):${REPO_TAG}" || true
  done
  # SELF-HEAL a torn checkpoint. Dropping only the broken TABLE would not work and
  # would be worse than not trying: file_metadata.lance (content hash) and
  # git_metadata.lance (commit) still say those files are unchanged, so octocode
  # would skip them and rebuild the table EMPTY -- which answers "no results"
  # instead of erroring, i.e. looks repaired while being exactly as blind. Same
  # reasoning as the CGC_FORCE note above: the metadata tables gate the changed-file
  # set, so the only full-corpus path this octocode has is starting from the shared
  # base. Treat a torn checkpoint as NO checkpoint.
  lance_state_summary "$OCTO_HOME" "restored, before prune"
  lance_prune_old_versions "$OCTO_HOME"
  lance_gc_unreferenced_data "$OCTO_HOME"
  lance_state_summary "$OCTO_HOME" "restored, after prune+gc"
  _torn=$(lance_dangling_tables "$OCTO_HOME")
  if [ -n "$_torn" ]; then
    echo "::warning::[cgc-db] torn checkpoint restored from GHCR — dangling lance manifest(s):"
    printf '%s\n' "$_torn" | sed 's|^|[cgc-db]   |'
    for _p in "$OCTO_HOME"/*/; do
      # Same exclusion set as package.sh's find_project_dir() -- root state, never
      # project data. Dropping fastembed/ here would re-download the embedder.
      case "${_p%/}" in */fastembed | */sentencetransformer) continue ;; esac
      rm -rf "$_p"
    done
    echo "[cgc-db] dropped the restored project dir(s) — re-indexing this repo from base"
  fi
else
  sh "$HERE/cloud-cgc-db-pull.sh" "$OCTO_HOME" || true
  if [ -z "$(ls -A "$OCTO_HOME" 2>/dev/null | grep -v '^config\.toml$')" ]; then
    echo "::error::no GHCR DB base restored — refusing a from-scratch full build (~12h)."
    echo "::error::seed once first: sh $HERE/cloud-cgc-db-package.sh <existing-octocode-home> $IMAGE $TAG"
    exit 1
  fi
fi
# FIX 1 (per-repo mode only — see bootstrap_config_toml() above for why): must run
# BEFORE the generic fallback below, which is a documented no-op for this exact
# case (kept, untouched, as the monolith-mode safety net it always was).
[ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && bootstrap_config_toml
[ -f "$CFG" ] || ( cd "$CGC_SCRATCH" && octocode config ) >/dev/null 2>&1 || true

# 4a) force the GraphRAG LLM phase on (use_llm + model). awk, never sed.
# STRAY-PREVENT: `octocode config` here (and in the else branch below) is a bare,
# non-index octocode invocation — cd into CGC_SCRATCH (see its definition
# above) rather than the script's ambient cwd, so it cannot stamp a project
# dir for the CI checkout. This is best-effort only: the awk block right
# after each call is what actually enforces the resulting config.toml state
# either way, so this cd change cannot regress correctness even if the CLI
# call itself behaves differently outside a git repo.
if [ "$USE_LLM" = "true" ] && [ -f "$CFG" ]; then
  ( cd "$CGC_SCRATCH" && octocode config --model "$LLM" --graphrag-enabled true ) >/dev/null 2>&1 || true
  awk -v m="$LLM" '
    /^\[graphrag\]/                                { in_gr=1 }
    /^\[/ && !/^\[graphrag\]/                      { in_gr=0 }
    # [llm] model is what the architectural-analysis pass uses, and the old
    # bootstrap hardcoded a fixed `openrouter:openai/gpt-4o-mini` there,
    # ignoring the declared model entirely. octocode picks its provider from that
    # prefix and reads the env pair that provider names, which nothing exported,
    # so it reported "LLM client not initialized" regardless. Every DB
    # pulled from an existing image still carries that line, so rewriting it
    # here is what actually repairs the inherited configs.
    /^\[llm\]/                                     { in_llm=1 }
    /^\[/ && !/^\[llm\]/                          { in_llm=0 }
    in_llm && /^[[:space:]]*model[[:space:]]*=/    { print "model = \"" m "\""; next }
    in_gr && /^[[:space:]]*enabled[[:space:]]*=/   { print "enabled = true"; next }
    /^[[:space:]]*use_llm[[:space:]]*=/            { print "use_llm = true"; next }
    /^[[:space:]]*description_model[[:space:]]*=/  { print "description_model = \"" m "\""; next }
    /^[[:space:]]*relationship_model[[:space:]]*=/ { print "relationship_model = \"" m "\""; next }
    { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  grep -q "use_llm = true" "$CFG" 2>/dev/null || printf '\n[graphrag]\nenabled = true\nuse_llm = true\n' >> "$CFG"
  echo "[cgc-db] GraphRAG LLM = $LLM (enabled=true use_llm=true)"
  # PREFLIGHT — fail loudly, never degrade silently. octocode treats an
  # unreachable/unauthenticated LLM as a WARNING and keeps going, emitting a
  # graph of structural `sibling_module` edges only. That is indistinguishable
  # from success in the exit code, so the run "passed" and shipped a DB with no
  # semantic relationships at all. If the graphrag phase was explicitly asked
  # for, an LLM it cannot reach is a hard error.
  # The model string is no longer a literal in this script -- it comes from
  # build.json, and its prefix is what selects the provider. A missing key would
  # write `model = "null"`, octocode would fail to resolve a provider, and we
  # would be right back at a silent structural-only graph.
  case "$LLM" in
    ""|null)
      echo "::error::[cgc-db] .runtime.octocode.update.llm_model is unset in $BJ — the provider prefix is what octocode resolves its LLM from"
      exit 1 ;;
  esac
  # WHICH url matters is decided by the model prefix, so check the one this
  # model actually resolves. Hardcoding the openai var passed a model routed
  # through ollama even with no ollama url declared -- a preflight that green-lights
  # the exact config it exists to reject.
  case "$LLM" in
    openrouter:*) _llm_url="$OPENROUTER_API_URL"; _llm_field="openrouter_api_url" ;;
    ollama:*)     _llm_url="$OLLAMA_API_URL";     _llm_field="ollama_api_url" ;;
    *)            _llm_url="$OPENAI_API_URL";     _llm_field="openai_api_url" ;;
  esac
  # The url has to be the full completions path, not the /v1 base: with the base,
  # octocode builds a client fine and every call then comes back empty ("Failed to
  # parse JSON from response"), which degrades exactly like no client at all.
  case "$_llm_url" in
    ""|*/chat/completions) ;;
    *) echo "::warning::[cgc-db] .runtime.octocode.llm.$_llm_field is '$_llm_url' — octocode posts to it verbatim and a bare /v1 base returns an empty body" ;;
  esac
  if [ -z "$_llm_url" ]; then
    echo "::error::[cgc-db] graphrag phase requested but .runtime.octocode.llm.$_llm_field is unset in $BJ — $LLM resolves to it, and octocode would silently produce structural-only edges"
    exit 1
  fi
  if [ -n "$LLM_HEALTH_URL" ]; then
    # Retry: a WireGuard tunnel brought up seconds ago has not necessarily
    # completed a handshake with the far peer yet, and a first-packet timeout
    # there is normal rather than a fault.
    _lh=0; _llm_ok=0; _lerr=""
    while [ "$_lh" -lt 6 ]; do
      _lh=$((_lh + 1))
      _lerr=$(curl -fsS -m 15 -o /dev/null "$LLM_HEALTH_URL" 2>&1) && { _llm_ok=1; break; }
      [ "$_lh" -lt 6 ] && sleep 10
    done
    if [ "$_llm_ok" = "1" ]; then
      echo "[cgc-db] LLM endpoint healthy: $LLM_HEALTH_URL (attempt $_lh)"
    else
      # Say WHICH layer failed. "unreachable" alone sent the last investigation
      # after a missing credential that never existed; the mesh was the problem.
      _lhost=$(printf '%s' "$LLM_HEALTH_URL" | sed -e 's|^[a-z]*://||' -e 's|[:/].*$||')
      echo "::error::[cgc-db] graphrag phase requested but the LLM endpoint failed its health check: $LLM_HEALTH_URL"
      echo "[cgc-db] curl said: ${_lerr:-<no output>}"
      echo "[cgc-db] mesh triage for $_lhost (the endpoint is mesh-only, so this distinguishes 'no route' from 'port filtered'):"
      ping -c 2 -W 3 10.0.0.1 >/dev/null 2>&1 && echo "[cgc-db]   hub 10.0.0.1: reachable" || echo "[cgc-db]   hub 10.0.0.1: NO — WireGuard is not carrying traffic at all"
      ping -c 2 -W 3 "$_lhost" >/dev/null 2>&1 && echo "[cgc-db]   $_lhost icmp: reachable" || echo "[cgc-db]   $_lhost icmp: no reply"
      if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$_lhost" 22 >/dev/null 2>&1 && echo "[cgc-db]   $_lhost:22 open — the host IS routable, so the LLM port specifically is blocked" || echo "[cgc-db]   $_lhost:22 closed too — this is routing, not a port filter"
      fi
      echo "[cgc-db] refusing to ship a structural-only graph."
      exit 1
    fi
  fi

  # CREDIT PREFLIGHT (#1817). /models answers 200 with an exhausted balance, so the
  # check above green-lights a run whose every completion is HTTP 402 "Insufficient
  # credits": all matrix jobs then spend 20-60 min each (retries, 90-min windows)
  # before octocode aborts, and the run ends red hours later. One 1-token completion
  # fails that in seconds with the real cause. Only a definite 402 fails the job;
  # any other probe outcome (network blip, 429) is left to the normal retry paths.
  case "$LLM" in
    openrouter:*)
      _cp_code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$_llm_url" \
        -H "Authorization: Bearer ${OPENROUTER_API_KEY:-}" -H 'Content-Type: application/json' \
        -d "{\"model\":\"${LLM#openrouter:}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" 2>/dev/null) || _cp_code=""
      if [ "$_cp_code" = "402" ]; then
        echo "::error::[cgc-db] OpenRouter answered HTTP 402 Insufficient credits to a 1-token probe: the account balance is exhausted. Top up at https://openrouter.ai/settings/credits; every graphrag LLM call fails until then, so this job stops now instead of after the retry/window budget."
        exit 1
      fi
      echo "[cgc-db] LLM credit preflight: HTTP ${_cp_code:-n/a} (only 402 is fatal)" ;;
  esac

  # FORCE INVALIDATES THE GRAPH, NOT THE EMBEDDINGS.
  # octocode gates its two passes separately: it skips the chunk reindex when the
  # commit is unchanged ("No commit changes since last index, skipping reindex"),
  # and it builds the graph only when it finds none ("No GraphRAG nodes found in
  # database"). So once a degraded run has written a structural-only graph at this
  # HEAD, every later run finds a graph present and leaves it alone -- the repair
  # would silently never happen, which is the same silent-degradation shape this
  # phase already guards against elsewhere.
  #
  # CGC_FORCE means "the INDEXER changed, so this DB is stale at an unchanged
  # HEAD". In per-repo mode the real force mechanism now lives at the restore
  # step above: the prior checkpoint is never layered in, so this home holds no
  # graph (or metadata) to begin with and the drop below finds nothing — kept
  # anyway as the monolith-mode fallback, where a restored home DOES carry the
  # stale graph and dropping graphrag_* while keeping code_blocks.lance is
  # still the right (and only affordable) repair for a 15G monolith.
  #
  # Deliberately placed AFTER the preflight: the graph is only ever destroyed once
  # the LLM endpoint has answered, so we cannot delete a graph we then cannot
  # rebuild. A failure after this point aborts before package/push anyway, so the
  # DB on GHCR is never the damaged one.
  # A resumed forced partial carries the graph its completed chunks built (chunk mode,
  # #888): purging it would throw away exactly the progress the resume exists to keep.
  if [ "${CGC_FORCE:-0}" = "1" ] && [ "${RESUMED_FORCE_PARTIAL:-0}" != "1" ]; then
    _purged=0
    for _t in "$OCTO_HOME"/*/storage/graphrag_nodes.lance \
              "$OCTO_HOME"/*/storage/graphrag_relationships.lance \
              "$OCTO_HOME"/*/storage/graphrag_git_metadata.lance; do
      [ -e "$_t" ] || continue
      rm -rf "$_t" && _purged=$((_purged + 1))
    done
    echo "[cgc-db] CGC_FORCE=1 — dropped $_purged graphrag table(s); embeddings kept, graph will rebuild"
  fi
else
  # GPU EMBEDDING PREFLIGHT — same posture as the LLM preflight above: fail
  # loudly before doing anything expensive rather than let octocode degrade
  # silently. octocode's local: provider probes the embedding dimension from
  # a live response at first use (LocalEmbeddingProvider::new), so a dead/mis-
  # authed endpoint would otherwise surface as a cryptic mid-index failure (or
  # worse, a partially-written project if it dies after some chunks embedded).
  # POST a real one-text embedding request — this also verifies the bearer
  # token and that the model is pulled, not just that the port answers.
  if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ]; then
    if [ -z "$LOCAL_EMBED_API_URL" ]; then
      echo "::error::[cgc-db] CGC_LOCAL_EMBED_MODEL=$CGC_LOCAL_EMBED_MODEL but LOCAL_EMBED_API_URL is unset (neither env nor build.json .runtime.octocode.update.gpu_embed.embed_endpoint) — octocode's local: provider has nowhere to POST"
      exit 1
    fi
    _ge=0; _ge_ok=0; _ge_err=""
    while [ "$_ge" -lt 6 ]; do
      _ge=$((_ge + 1))
      _ge_err=$(curl -fsS -m 30 -o /dev/null \
        -H "Content-Type: application/json" \
        ${LOCAL_EMBED_API_KEY:+-H "Authorization: Bearer $LOCAL_EMBED_API_KEY"} \
        -d "{\"model\":\"${CGC_LOCAL_EMBED_MODEL#local:}\",\"input\":[\"preflight\"]}" \
        "$LOCAL_EMBED_API_URL" 2>&1) && { _ge_ok=1; break; }
      [ "$_ge" -lt 6 ] && sleep 10
    done
    if [ "$_ge_ok" = "1" ]; then
      echo "[cgc-db] GPU embedding endpoint healthy: $LOCAL_EMBED_API_URL (attempt $_ge, model ${CGC_LOCAL_EMBED_MODEL#local:})"
    else
      echo "::error::[cgc-db] semantic phase requested CGC_LOCAL_EMBED_MODEL=$CGC_LOCAL_EMBED_MODEL but the endpoint failed preflight: $LOCAL_EMBED_API_URL"
      echo "[cgc-db] curl said: ${_ge_err:-<no output>}"
      echo "[cgc-db] is the gcp-gpu-embed VM started? (devops_vm_start gcp-gpu-embed / the workflow's start step before this job)"
      exit 1
    fi
  fi

  # Force structural-only to MATCH build.json (use_llm=false). The base config.toml
  # may carry a STALE `use_llm = true` + an unreachable LLM model (e.g. ollama:*),
  # which makes octocode block on per-batch LLM timeouts → glacial. Previously this
  # branch only PRINTED "structural-only" without disabling it. Disable it for real.
  if [ -f "$CFG" ]; then
    ( cd "$CGC_SCRATCH" && octocode config --graphrag-enabled false --code-embedding-model "$CODE_EMBED" --text-embedding-model "$TEXT_EMBED" ) >/dev/null 2>&1 || true
    awk '
      /^\[graphrag\]/                              { in_gr=1 }
      /^\[/ && !/^\[graphrag\]/                    { in_gr=0 }
      in_gr && /^[[:space:]]*enabled[[:space:]]*=/ { print "enabled = false"; next }
      /^[[:space:]]*use_llm[[:space:]]*=/          { print "use_llm = false"; next }
      { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    grep -q "use_llm = false" "$CFG" 2>/dev/null || printf '\n[graphrag]\nenabled = false\nuse_llm = false\n' >> "$CFG"
    # embeddings_batch_size — no CLI flag (verified against octocode's config
    # command source), config.toml [index] only. GPU-embed only: raising this
    # for the fastembed/CPU repos is untested and out of scope here. awk, never
    # sed (see reference_awk-not-sed-secrets.md).
    if [ -n "${CGC_LOCAL_EMBED_MODEL:-}" ] && [ -n "$LOCAL_EMBED_BATCH_SIZE" ]; then
      awk -v n="$LOCAL_EMBED_BATCH_SIZE" '
        /^\[index\]/                                        { in_idx=1 }
        /^\[/ && !/^\[index\]/                              { in_idx=0 }
        in_idx && /^[[:space:]]*embeddings_batch_size[[:space:]]*=/ { print "embeddings_batch_size = " n; next }
        { print }' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
      echo "[cgc-db] GPU embedding: embeddings_batch_size=$LOCAL_EMBED_BATCH_SIZE"
    fi
  fi
  echo "[cgc-db] GraphRAG structural-only (enabled=false use_llm=false forced — no LLM calls)"
fi

# 4a-ter) BOUNDED LLM CALLS (#888) — graphrag phase, openrouter: models only.
# octocode 0.22.0 / octolib 0.34.2 send every GraphRAG request with NO per-request
# timeout, and octocode holds the whole relationship pass in memory until its last call
# returns: one stuck call held cloud-u-containers' second window for 3h on run
# 37929244331 and the slice expiry threw the pass away. octolib reads OPENROUTER_API_URL
# per request, so octocode is pointed at cloud-cgc-llm-proxy.py on 127.0.0.1, which
# forwards to the real endpoint with a per-attempt deadline, bounded retries, a capped
# Retry-After, a bounded outcome when a call's budget is spent, and one JSON line per
# call (no headers, so the key never reaches the log). The chunk loop turns that log
# into one LLM line per window. CGC_LLM_PROXY=0 goes direct.
LLM_PROXY_LOG=""; LLM_PROXY_PID=""
if [ "$USE_LLM" = "true" ] && [ "${CGC_LLM_PROXY:-1}" = "1" ]; then
  case "$LLM" in
    openrouter:*)
      if command -v python3 >/dev/null 2>&1 && [ -f "$HERE/cloud-cgc-llm-proxy.py" ]; then
        mkdir -p "$CGC_SCRATCH/llm-proxy"
        LLM_PROXY_LOG="$CGC_SCRATCH/llm-proxy/calls.jsonl"; : > "$LLM_PROXY_LOG"
        python3 "$HERE/cloud-cgc-llm-proxy.py" --upstream "$OPENROUTER_API_URL" --log "$LLM_PROXY_LOG" \
          --port-file "$CGC_SCRATCH/llm-proxy/port" >"$CGC_SCRATCH/llm-proxy/stderr" 2>&1 &
        LLM_PROXY_PID=$!
        _lp_port=""; _lp_i=0
        while [ "$_lp_i" -lt 50 ]; do
          [ -s "$CGC_SCRATCH/llm-proxy/port" ] && { _lp_port=$(cat "$CGC_SCRATCH/llm-proxy/port"); break; }
          _lp_i=$((_lp_i + 1)); sleep 0.2
        done
        if [ -n "$_lp_port" ] && curl -fsS --noproxy "*" -m 5 -o /dev/null "http://127.0.0.1:$_lp_port/health" 2>/dev/null; then
          OPENROUTER_API_URL="http://127.0.0.1:$_lp_port/api/v1/chat/completions"; export OPENROUTER_API_URL
          echo "[cgc-db] LLM calls bounded by cgc-llm-proxy on 127.0.0.1:$_lp_port: ${CGC_LLM_REQUEST_TIMEOUT_S:-120}s per attempt, ${CGC_LLM_MAX_ATTEMPTS:-3} attempts in ${CGC_LLM_CALL_BUDGET_S:-360}s per call, Retry-After capped at ${CGC_LLM_RETRY_AFTER_CAP_S:-60}s, breaker after ${CGC_LLM_BREAKER_FAILS:-5} spent calls"
        else
          kill "$LLM_PROXY_PID" 2>/dev/null || true
          LLM_PROXY_PID=""; LLM_PROXY_LOG=""
          echo "::warning::[cgc-db] cgc-llm-proxy did not come up ($(tail -n 3 "$CGC_SCRATCH/llm-proxy/stderr" 2>/dev/null | tr '\n' ' ')) — LLM calls go direct, with NO per-request timeout"
        fi
      else
        echo "::warning::[cgc-db] python3 or cloud-cgc-llm-proxy.py missing — LLM calls go direct, with NO per-request timeout"
      fi
      ;;
  esac
fi

# 4a-bis) declared file associations — after every other config.toml mutation above
# and before any `octocode index` below, so the walk that decides which files exist
# at all runs with build.json's extension map in force. See apply_file_associations().
apply_file_associations

# 4b) SMART INCREMENTAL index — per-repo change-GATED + checkpoint-PUSHED.
#
#   Why every prior run got CANCELLED: one job re-ran `octocode index` for ALL 6
#   repos every time (~2.5h each incl. the GraphRAG relationship pass, which is
#   O(graph) regardless of how few files changed) → ~15h → past the runner cap →
#   cancelled BEFORE the single end-of-run push → GHCR DB never advanced.
#
#   Three engine-level fixes, all data-driven, NO topology change (still one job):
#     • CHANGE GATE  — skip `octocode index` entirely for any repo whose git HEAD
#       equals the commit last indexed into THIS DB. The last-indexed commit per
#       repo lives in a manifest INSIDE the octocode home, so it is packaged and
#       pulled with the DB (single source of truth, reproducible). Between twice-
#       daily runs most repos are unchanged → seconds, not hours.
#     • CHECKPOINT PUSH — package+push after EACH changed repo. A later cancel now
#       loses at most the in-flight repo; every finished repo is already on GHCR
#       AND recorded in the manifest, so the next run skips it and resumes the
#       rest. The pipeline self-heals across runs instead of restarting from zero.
#     • TIME BUDGET — stop taking on NEW repos past runtime.octocode.update.max_minutes
#       and exit cleanly (already-pushed via checkpoints); the next run resumes the
#       remainder via the change gate. We are never killed mid-repo after the budget.
command -v git >/dev/null 2>&1 && git config --global --add safe.directory '*' >/dev/null 2>&1 || true

# PER-PHASE manifest: each phase (semantic / graphrag) tracks its OWN last-indexed
# commit per repo, so the change gate for one phase is independent of the other.
# Without this, the semantic phase advances HEAD in a single shared manifest and the
# graphrag phase — which needs to enrich the SAME commit with LLM relationships —
# would be skipped as "unchanged" and never run. CGC_MANIFEST_PHASE selects the file
# (semantic → .cgc-manifest-semantic.json, graphrag → .cgc-manifest-graphrag.json).
# Both manifests live inside OCTO_HOME so they are packaged into and pulled from the
# GHCR DB snapshot, travelling with the DB (single reproducible source of truth).
# Falls back to the legacy single-manifest filename when no phase is set (bare local
# invocation), preserving the pre-two-phase behaviour.
MANIFEST_PHASE="${CGC_MANIFEST_PHASE:-}"
if [ -n "$MANIFEST_PHASE" ]; then
  MANIFEST_NAME=".cgc-manifest-${MANIFEST_PHASE}.json"
else
  MANIFEST_NAME=".cgc-index-manifest.json"
fi
# Home-ROOT copy. Correct for monolith mode (packaging tars the whole home) and the
# fallback for per-repo mode whenever this job's project dir cannot be named.
MANIFEST="$OCTO_HOME/$MANIFEST_NAME"
echo "[cgc-db] phase=${MANIFEST_PHASE:-default} USE_LLM=$USE_LLM manifest=$MANIFEST_NAME"
[ -s "$MANIFEST" ] || echo '{}' > "$MANIFEST"

# THE MANIFEST HAS TO LIVE INSIDE THE PROJECT DIR, NOT AT THE HOME ROOT.
#
# The comment above used to promise that a home-root manifest "is packaged into and
# pulled from the GHCR DB snapshot". That is true in monolith mode and FALSE in
# per-repo mode, which is the only mode CI has run since the matrix landed:
# cloud-cgc-db-package.sh's build_repo_tar tars ONLY "$PROJECT_DIR", and
# build_base_tar tars ONLY config.toml + fastembed/ + sentencetransformer/. A file at
# the home root is in neither allowlist, so every run wrote the manifest, packaged an
# image without it, and the next run started from an empty {} again.
#
# Measured, not inferred: run 34267362724 (2026-09-08) and run 34392223176
# (2026-09-09) both logged "was=none" for EVERY repo, including cloud-infra at a
# commit the previous run had indexed hours earlier.
#
# What that cost is not wasted CPU -- octocode still de-duplicates by file mtime, so
# the re-index is mostly a no-op -- it is that the pipeline had NO RECORD of which
# commit the served index corresponds to. The change gate never skipped, the
# "publish the partial but do NOT advance the manifest" ratchet had nothing to
# advance or resume from, and a repo that never converged was indistinguishable in
# the logs from one that was perfectly current. That is why cloud-u-android served a
# deleted FairEmail tree for a full day with every run reporting green.
#
# Fix: put the manifest where the packaging already looks. Each repo's project dir is
# tarred whole into that repo's own GHCR image, so a manifest inside it travels with
# the DB it describes -- and because every repo carries only its OWN entry, the
# per-repo images can never clobber each other's when restore-all layers them with
# cp -a into one home. Reading it back needs no new bookkeeping: a per-repo job starts
# from a FRESH home holding base root-state plus exactly the one restored project dir.
manifest_path() {  # $1 = project dir name ("" = discover the only one) → stdout: manifest file path
  _mp_dir="${1:-}"
  [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] || { printf '%s\n' "$MANIFEST"; return 0; }
  if [ -z "$_mp_dir" ]; then
    _mp_n=0
    for _mp_d in $(project_dirs_snapshot "$OCTO_HOME"); do _mp_dir="$_mp_d"; _mp_n=$((_mp_n + 1)); done
    # 0 dirs = this repo has no checkpoint on GHCR yet; 2+ = not a per-repo home.
    # Either way fall back to the root copy, which reads as "never indexed" rather
    # than as some other repo's commit.
    [ "$_mp_n" -eq 1 ] || { printf '%s\n' "$MANIFEST"; return 0; }
  fi
  [ -d "$OCTO_HOME/$_mp_dir" ] || { printf '%s\n' "$MANIFEST"; return 0; }
  printf '%s\n' "$OCTO_HOME/$_mp_dir/$MANIFEST_NAME"
}

manifest_read() {  # $1 = manifest file, $2 = repo local name → stdout: recorded commit, empty if none
  [ -s "$1" ] || return 0
  jq -r --arg r "$2" '.[$r] // ""' "$1" 2>/dev/null || true
}
# CGC_BUDGET_MIN (env) overrides build.json: the CI step that runs this script knows
# its own timeout-minutes, and the budget MUST end before it with room left for the
# partial-checkpoint publish -- otherwise the slice never ends cleanly (see START_TS).
BUDGET_MIN="${CGC_BUDGET_MIN:-$(jq -r '.runtime.octocode.update.max_minutes // 330' "$BJ")}"
REPO_TIMEOUT_MIN=$(jq -r '.runtime.octocode.update.repo_timeout_min // "0"' "$BJ")
PUSHED=0
# FIX 2 guard (per-repo mode) — see seed_base_if_missing() above: only the FIRST
# repo in this job attempts a base-image seed, even if this job indexes more than
# one repo (CGC_INDEX_REPOS can list several). Meaningless/unused in monolith mode.
BASE_SEEDED=0
# Outcome tally. "no repo changed — DB already current" was printed on 2026-08-20 after two
# repos had TIMED OUT and five were deferred: a green log during a six-day outage. Count
# every terminal state per repo so the summary can never claim currency it has not earned.
N_INDEX=0; N_SKIP=0; N_TIMEOUT=0; N_DEFER=0
# Repos this run did NOT bring level with their own HEAD, named rather than merely
# counted. A count tells you something is behind; only the name tells you WHICH
# served answers are lies, and that is the whole difference between the twice-daily
# run being a drift detector and being a green tick nobody reads.
STALE_REPOS=""
NO_GRAPH_REPOS=""

# What to show of octocode's own output once an index run ends. octocode drives
# a progress spinner: thousands of \r-separated frames that together form ONE
# \n-terminated line, and every eprintln it emits lands glued onto whichever
# frame is current. The branches below used to `tail -N` that file, which shows
# the spinner and drops everything printed before its last line — and that is
# precisely where octocode reports LLM trouble ("Warning: AI architectural
# analysis failed", "⚠️  Batch AI description failed", "🔄 Falling back to
# individual AI calls"). Runs 32721840450 / 32746314822 shipped graphs with
# ZERO LLM relationships as green jobs this way: every batch had failed and the
# replayed log showed a healthy spinner. This drops the frames (all of them,
# they are noise), recovers any message glued onto one, strips the ANSI erase
# sequences, and prints the last $2 real lines. awk only, so the dagu/box path
# (busybox) and the GHA path (mawk/gawk) behave the same.
octo_log_digest() { # $1 = octocode log file, $2 = max lines to print
  tr '\r' '\n' < "$1" | awk -v n="$2" -v esc="$(printf '\033')" '
    { gsub(esc "\\[[0-9;]*[A-Za-z]", "") }
    /Indexing: [0-9]+(\/[0-9]+)? files|Counting files/ {
      # Spinner frames are dropped from the digest, but the LAST one is the only
      # progress signal a timed-out run leaves behind — keep it for the END line.
      if (match($0, /Indexing: [0-9]+(\/[0-9]+)? files( \([0-9]+%\))?/)) prog = substr($0, RSTART, RLENGTH)
      i = 0
      if (match($0, /(Info|Warning|Error|Debug): /)) i = RSTART
      else if (match($0, /⚠️|🔄|✓|📋|📊/)) i = RSTART
      if (!i) next
      $0 = substr($0, i)
    }
    NF { l[++k] = $0 }
    END { s = k - n + 1; if (s < 1) s = 1; for (i = s; i <= k; i++) print l[i]; if (prog) print "[cgc-db] last octocode progress: " prog }'
}

# PUBLIC-LOG REDACTION FOR PRIVATE REPOS. The workflow that runs this script lives in a
# PUBLIC repository, so its Actions logs are public. octocode prints one line per file it
# touches (paths, and in the graphrag phase exported symbols and AI descriptions), and the
# digest above replays the last 40-60 of them. For a repo listed in
# .runtime.octocode.private_repos that published private paths and content (run
# 37843203892: cloud-data-my-ai-memory's backlog paths and export strings). For those repos
# every log line that carries repo content goes through octo_log_redact instead: only
# count-shaped summary lines survive, warnings keep their class but lose their detail, and
# the rest is withheld with a count. Fail-safe: an unreadable build.json or a jq error
# counts as PRIVATE. CGC_LOG_REDACT=1 forces redaction for every repo.
cgc_repo_is_private() { # $1 = local repo name -> rc 0 = treat as private (redact)
  [ "${CGC_LOG_REDACT:-0}" = "1" ] && return 0
  [ -n "${1:-}" ] || return 0
  _crp_rc=0
  jq -e --arg r "$1" '(.runtime.octocode.private_repos // []) | index($r) != null' "$BJ" >/dev/null 2>&1 || _crp_rc=$?
  case "$_crp_rc" in 0) return 0 ;; 1) return 1 ;; *) return 0 ;; esac
}

octo_log_redact() { # stdin = octocode log lines -> stdout = path-free, content-free summary
  awk '
    /^\[cgc-db\] last octocode progress: Indexing: [0-9]+(\/[0-9]+)? files( \([0-9]+%\))?$/ { print; next }
    /^✓ Indexing complete! [0-9]+ of [0-9]+ files processed(, GraphRAG: [0-9]+ blocks)?$/ { print; next }
    /^✅ Indexed [0-9]+ commits$/ { print; next }
    /^📊 Loaded metadata for [0-9]+ files from database$/ { print; next }
    /^Info: AI analyzing [0-9]+ files for architectural relationships$/ { print; next }
    /^🔄 (Updating|Applying AI descriptions to) [0-9]+ (pending )?nodes/ { print; next }
    /^(Warning|Error): / {
      c = $0; sub(/^(Warning|Error): /, "", c); k = substr($0, 1, index($0, ":") - 1)
      sub(/:.*/, "", c)
      if (c ~ /^[A-Za-z ]+$/) print k ": " c " [detail withheld: private repo]"
      else print k ": [withheld: private repo]"
      next
    }
    NF { w++ }
    END { if (w) print "[cgc-db] " w " octocode line(s) withheld from this public log (private repo: they name files or carry content)" }'
}

# Digest for the log of repo $3: the plain digest, redacted when $3 is private.
octo_log_report() { # $1 = octocode log file, $2 = max lines, $3 = repo
  if cgc_repo_is_private "$3"; then
    octo_log_digest "$1" "$2" | octo_log_redact
  else
    octo_log_digest "$1" "$2"
  fi
}

# After a graphrag-phase index, prove the LLM pass contributed. Structural extraction
# yields imports / calls / references / sibling_module / parent_module / child_module
# / contains; only the LLM prompt emits configures / factory_creates /
# observer_pattern / strategy_pattern / adapter_pattern / architectural_dependency
# (octocode src/indexer/graphrag/ai.rs — the vocabulary the prompt hands the model,
# kept as distinct RelationType variants). A graphrag checkpoint carrying none of
# them is the 2026-08-24 failure again — every LLM reply discarded, exit 0 — and
# must not be published as enriched. The text overview is asserted on purpose: it
# is the exact output the MCP surfaces hand to users.
# ponytail: repos under the node floor are exempt — a 17-node corpus can honestly
# hold no architectural pattern; switch to a description-shape check if a mid-size
# repo ever trips this falsely.
assert_llm_graph() { # $1 = repo dir, $2 = repo name → rc 1 when no LLM-derived type exists
  _alg_ov=$( cd "$1" && octocode graphrag overview --format text 2>&1 )
  _alg_nodes=$(printf '%s\n' "$_alg_ov" | awk '/contains [0-9]+ nodes and [0-9]+ relationships/ { for (i = 1; i <= NF; i++) if ($i == "contains") { print $(i + 1); exit } }')
  _alg_types=$(printf '%s\n' "$_alg_ov" | awk '/^[[:space:]]*- [a-z_]+: [0-9]+ relationship/ { t = $2; sub(/:$/, "", t); printf "%s ", t }')
  for _alg_t in $_alg_types; do
    case "$_alg_t" in
      configures|factory_creates|observer_pattern|strategy_pattern|adapter_pattern|architectural_dependency) return 0 ;;
    esac
  done
  if [ "${_alg_nodes:-0}" -lt 30 ] 2>/dev/null; then
    echo "[cgc-db] $2 · graphrag guard: ${_alg_nodes:-0} nodes (< 30) and no LLM-derived type — small corpus, accepted"
    return 0
  fi
  echo "::error::[cgc-db] $2 · graphrag phase produced NO LLM-derived relationship across ${_alg_nodes:-?} nodes (types present: ${_alg_types:-none}) — every LLM reply was discarded (empty or unparseable), the silent failure of 2026-08-24; refusing to publish a structural-only graph as a graphrag checkpoint"
  # The overview names nodes, so a private repo's stays out of the public log.
  if cgc_repo_is_private "$2"; then
    echo "[cgc-db] $2 · graphrag overview withheld (private repo)"
  else
    printf '%s\n' "$_alg_ov" | tail -20
  fi
  return 1
}

# ── CHUNKED INDEX (#888) — spec a0_docs/eng-specs/cgc-incremental-chunked.md ──────────
# Per-repo mode with a phase: every `octocode index` runs over a bounded WINDOW (files
# already done + files changed since the last window + the next chunk of the sorted
# remainder) so it can COMPLETE inside the slice. Only a completed run records skip state
# for touched-but-unchanged files and only a completed walk reaches the graph pass, so a
# repo too big for one slice used to make no durable progress at all (cloud-u-android sat
# at ~13.6k files for days). Chunks repeat within one job while the budget allows, with a
# checkpoint publish between them; the chunk state travels inside the project dir.
. "$HERE/cloud-cgc-db-chunk.sh"
CHUNK_N_DEFAULT="${CGC_CHUNK_FILES:-$(jq -r --arg p "${MANIFEST_PHASE:-default}" '(.runtime.octocode.update.chunk // {}) | (.[$p] // .default // (if $p == "graphrag" then 1000 elif $p == "semantic" then 3000 else 0 end))' "$BJ")}"
CHUNK_MIN=$(jq -r '.runtime.octocode.update.chunk.min // 100' "$BJ")
CHUNK_MAX=$(jq -r '.runtime.octocode.update.chunk.max // 20000' "$BJ")
CHUNK_STALE_ALERT=$(jq -r '.runtime.octocode.update.chunk.stale_alert_runs // 6' "$BJ")
# Reserve for the publish that follows a window, used until this run has measured one.
# 40 was sized to the ~58-min publishes of run 37929244331, which were the quadratic
# lance_dangling_tables scan, not the push: package + build + push of cloud-u-android's
# 1G home measured 60s. 15 covers a several-GB home on a slow registry day (#888).
CHUNK_PUBLISH_RESERVE_MIN="${CGC_PUBLISH_RESERVE_MIN:-$(jq -r '.runtime.octocode.update.chunk.publish_reserve_min // 15' "$BJ")}"
# Fraction (percent) of a slice a rate-sized window may plan to use; the rest absorbs
# per-file variance so the window completes instead of timing out (#888).
CHUNK_FILL_PCT="${CGC_CHUNK_FILL_PCT:-$(jq -r '.runtime.octocode.update.chunk.fill_pct // 80' "$BJ")}"
# GRAPHRAG WINDOWS ARE TIME-CAPPED, NOT SLICE-SIZED (#888). The graphrag phase is LLM
# bound and not linear in the window: octocode re-runs AI relationship analysis for every
# already-done file that imports a symbol of the window, keeps every relationship in
# memory until the last LLM call returns, and a timed-out window keeps none of them. Run
# 37929244331: window 1 (1000 files) took 24m, window 2 (2000 files) was planned against
# the whole 204m slice and was still in its relationship pass when that expired -- three
# hours and the job gone. So a graphrag window PLANS for at most graphrag_window_min of
# work at the measured rate, and is KILLED at graphrag_window_timeout_min whatever the
# slice; a killed window halves the next one and the loop goes on in the same job.
CHUNK_GR_WINDOW_MIN="${CGC_GRAPHRAG_WINDOW_MIN:-$(jq -r '.runtime.octocode.update.chunk.graphrag_window_min // 45' "$BJ")}"
CHUNK_GR_TIMEOUT_MIN="${CGC_GRAPHRAG_WINDOW_TIMEOUT_MIN:-$(jq -r '.runtime.octocode.update.chunk.graphrag_window_timeout_min // 90' "$BJ")}"
# Floor under the graphrag rate a window is planned with. A window's measured rate can be
# far too low: run 38044529950's window 1 re-fed 1004 files of which most already had
# nodes from the killed window of the run before (same hash, skipped, no LLM call) and
# measured 360 ms/file; window 2 then took 2342 ms/file for 2358 files (92m). Planned at
# 360 ms/file, a 45m window would have been 6000 files and died at its 90m cap -- and a
# killed window's persisted nodes are skipped as unchanged forever after, so their edges
# are never computed. 2500 ms/file is that measured real rate, rounded up.
CHUNK_GR_MIN_MSPF="${CGC_GRAPHRAG_MIN_MS_PER_FILE:-$(jq -r '.runtime.octocode.update.chunk.graphrag_min_ms_per_file // 2500' "$BJ")}"
# Liveness line every this many seconds while a window runs (0 = off).
CGC_HEARTBEAT_S="${CGC_HEARTBEAT_S:-600}"
CHUNK_MODE=0
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && [ -n "$MANIFEST_PHASE" ] \
   && [ "${CHUNK_N_DEFAULT:-0}" -gt 0 ] 2>/dev/null && [ "${CGC_CHUNK:-1}" != "0" ]; then
  CHUNK_MODE=1
fi
echo "[cgc-db] chunk mode=${CHUNK_MODE} (default chunk ${CHUNK_N_DEFAULT:-0} files, min ${CHUNK_MIN}, max ${CHUNK_MAX}, publish reserve ${CHUNK_PUBLISH_RESERVE_MIN}m)"

# The one project dir of a per-repo home, or empty.
chunk_home_project() {
  _chp=""; _chn=0
  for _chd in $(project_dirs_snapshot "$OCTO_HOME"); do _chp="$_chd"; _chn=$((_chn + 1)); done
  [ "$_chn" -eq 1 ] && printf '%s\n' "$_chp"
  return 0
}

# Runs the chunk loop for one repo. In: $1 repo, $2 dir, $3 head; uses _before_dirs,
# _idx_marker (STRAY-SELECT). Out: _rc (0 converged, 124 not converged or slice expired,
# else octocode failure), _log (last octocode log), _proj_resolved when known,
# CHUNK_STATUS (one JSON line).

# Persist the chunk state NOW, right after a stall decision (halved window, forced rework,
# quarantine), so a job the platform cuts off later cannot lose it: the next dispatch pulls the
# checkpointed image with this state inside. Non-fatal: a failed persist only costs the decision.
# Uses the loop's variables; skipped when too little of the slice is left (the final publish does it).
cgc_chunk_persist_decision() {
  _cp_next=$(( BUDGET_MIN - ( $(date +%s) - START_TS ) / 60 - 2 * _cr_pub_s / 60 ))
  [ "$_cp_next" -ge "${CGC_MIN_SLICE_MIN:-20}" ] || return 0
  if [ -z "${_proj_resolved:-}" ]; then
    _proj_resolved=$(resolve_project_dir "$OCTO_HOME" "$_before_dirs" "$_idx_marker") || { echo "::warning::[cgc-db] $_cr_r · could not resolve the project dir; the stall decision is persisted by the final publish"; return 0; }
  fi
  cp "$_cr_sf_stage" "$(chunk_state_path "$OCTO_HOME/$_proj_resolved" "$MANIFEST_PHASE")" || return 0
  _cp_p0=$(date +%s)
  if [ "${CGC_FORCE:-0}" = "1" ]; then
    printf '{"octocode":"%s","phase":"%s","commit":"%s"}\n' "$OCTO_VERSION" "$MANIFEST_PHASE" "$_cr_head" > "$OCTO_HOME/$_proj_resolved/$FORCE_PARTIAL_MARKER"
    ( REPO_TAG="$(force_partial_tag)"; checkpoint_publish "$_cr_r" ) || echo "::warning::[cgc-db] $_cr_r · checkpoint of the stall decision failed (continuing)"
    rm -f "$OCTO_HOME/$_proj_resolved/$FORCE_PARTIAL_MARKER"
  else
    checkpoint_publish "$_cr_r" || echo "::warning::[cgc-db] $_cr_r · checkpoint of the stall decision failed (continuing)"
  fi
  _cr_pub_s=$(( $(date +%s) - _cp_p0 + 300 ))
  echo "[cgc-db] $_cr_r · stall decision checkpointed (publish took $(( _cr_pub_s / 60 - 5 ))m)"
}

chunk_index_repo() {
  _cr_r="$1"; _cr_d="$2"; _cr_head="$3"
  _cr_o="${CGC_SCRATCH:?}/chunk-$_cr_r"; rm -rf "${_cr_o:?}"; mkdir -p "$_cr_o"
  _cr_pd=$(chunk_home_project)
  _cr_sf_stage="$OCTO_HOME/.cgc-chunks-$MANIFEST_PHASE.json"
  rm -f "$_cr_sf_stage"
  if [ -n "$_cr_pd" ] && [ -f "$(chunk_state_path "$OCTO_HOME/$_cr_pd" "$MANIFEST_PHASE")" ]; then
    cp "$(chunk_state_path "$OCTO_HOME/$_cr_pd" "$MANIFEST_PHASE")" "$_cr_sf_stage"
  fi
  # graphrag never runs ahead of the embeddings: its chunks come from the semantic
  # phase's done set. A repo whose semantic index converged before chunk mode existed
  # (manifest entry, no state) has every file embedded, so no allowlist is needed.
  _cr_allow=""
  if [ "$MANIFEST_PHASE" = "graphrag" ] && [ -n "$_cr_pd" ]; then
    _cr_sem="$(chunk_state_path "$OCTO_HOME/$_cr_pd" semantic)"
    if [ -f "$_cr_sem" ]; then
      jq -r '.done[]' "$_cr_sem" > "$_cr_o/allow"; _cr_allow="$_cr_o/allow"
      echo "[cgc-db] $_cr_r · graphrag chunks limited to the $(wc -l < "$_cr_o/allow" | tr -d ' ') files the semantic phase has embedded"
    fi
  fi
  _cr_n=$(chunk_state_read "$_cr_sf_stage" | jq -r '.chunk // 0')
  [ "${_cr_n:-0}" -gt 0 ] 2>/dev/null || _cr_n="$CHUNK_N_DEFAULT"
  [ -n "${CGC_CHUNK_FILES:-}" ] && _cr_n="$CGC_CHUNK_FILES"
  _cr_stallcap=0
  # graphrag (#1061): a window's cost is dominated by a fixed relationship-discovery phase after its
  # file loop (octocode re-resolves the imports of every unchanged importer of the window's
  # symbols), so BIG windows amortise it and a stalled one is split by halving down to ONE file.
  # The rate-based sizing below measures that fixed cost as ms/file and shrank every window to
  # the floor, so graphrag starts each run at CGC_GRAPHRAG_START_CHUNK and only halves on a stall.
  _cr_min="$CHUNK_MIN"
  if [ "$MANIFEST_PHASE" = "graphrag" ] && [ -z "${CGC_CHUNK_FILES:-}" ]; then
    _cr_min="${CGC_GRAPHRAG_CHUNK_MIN:-1}"
    [ "$_cr_n" -lt "${CGC_GRAPHRAG_START_CHUNK:-400}" ] && _cr_n="${CGC_GRAPHRAG_START_CHUNK:-400}"
  fi
  _cr_pub_s=$(( CHUNK_PUBLISH_RESERVE_MIN * 60 ))
  _cr_i=0; _rc=0; _log="$(mktemp)"; _cr_conv=0
  while :; do
    _cr_i=$((_cr_i + 1))
    _cr_remain=$(( BUDGET_MIN - ( $(date +%s) - START_TS ) / 60 ))
    # Leave room for the publish that follows this window (the last one is the outer
    # loop's), so the slice can never end inside the step's own timeout.
    _cr_slice=$(( _cr_remain - _cr_pub_s / 60 ))
    if [ -n "$REPO_TIMEOUT_EFF" ] && [ "$REPO_TIMEOUT_EFF" != "0" ] && [ "$REPO_TIMEOUT_EFF" -lt "$_cr_slice" ]; then
      _cr_slice="$REPO_TIMEOUT_EFF"
    fi
    if [ "$_cr_slice" -lt "${CGC_MIN_SLICE_MIN:-20}" ]; then
      echo "[cgc-db] $_cr_r · chunk $_cr_i: only ${_cr_slice}m usable — stopping here, the next run continues"
      _rc=124; break
    fi
    # Size the window to the slice (#888). A fixed chunk that cannot finish in what is
    # left of the budget times out, and a timed-out window keeps nothing: run 37929244331
    # would have spent its second slice on a 3000-file window that needed 120m in 109m.
    # Once this repo+phase has a measured rate (ms per new-work file, kept in the chunk
    # state across runs), plan only what fits in CHUNK_FILL_PCT of the slice.
    # graphrag (#888): plan for at most CHUNK_GR_WINDOW_MIN of work and kill the window at
    # CHUNK_GR_TIMEOUT_MIN, so one slow window can never eat the job (see the knobs above).
    _cr_wplan="$_cr_slice"; _cr_wto="$_cr_slice"
    if [ "$MANIFEST_PHASE" = "graphrag" ]; then
      [ "${CHUNK_GR_WINDOW_MIN:-0}" -gt 0 ] 2>/dev/null && [ "$_cr_wplan" -gt "$CHUNK_GR_WINDOW_MIN" ] && _cr_wplan="$CHUNK_GR_WINDOW_MIN"
      [ "${CHUNK_GR_TIMEOUT_MIN:-0}" -gt 0 ] 2>/dev/null && [ "$_cr_wto" -gt "$CHUNK_GR_TIMEOUT_MIN" ] && _cr_wto="$CHUNK_GR_TIMEOUT_MIN"
    fi
    _cr_plan_n="$_cr_n"
    _cr_mspf=$(chunk_state_read "$_cr_sf_stage" | jq -r '.ms_per_file // 0')
    if [ "$MANIFEST_PHASE" = "graphrag" ] && [ "${CHUNK_GR_MIN_MSPF:-0}" -gt "${_cr_mspf:-0}" ] 2>/dev/null; then
      _cr_mspf="$CHUNK_GR_MIN_MSPF"
    fi
    if [ "$MANIFEST_PHASE" = "graphrag" ] && [ -z "${CGC_CHUNK_FILES:-}" ]; then
      _cr_plan_n="$_cr_n"
      [ "$CHUNK_MAX" -gt 0 ] && [ "$_cr_plan_n" -gt "$CHUNK_MAX" ] && _cr_plan_n="$CHUNK_MAX"
      # Growth stays inside the planning cap (#1061): the window starts big (the fixed
      # relationship phase is amortised) but may not GROW past CHUNK_GR_WINDOW_MIN of work
      # at the measured rate (floored at CHUNK_GR_MIN_MSPF), and never below the start size.
      if [ "${_cr_mspf:-0}" -gt 0 ] 2>/dev/null; then
        _cr_rate_n=$(( _cr_wplan * 60 * 10 * CHUNK_FILL_PCT / _cr_mspf ))
        [ "$_cr_rate_n" -lt "${CGC_GRAPHRAG_START_CHUNK:-400}" ] && _cr_rate_n="${CGC_GRAPHRAG_START_CHUNK:-400}"
        [ "$_cr_rate_n" -lt "$_cr_plan_n" ] && _cr_plan_n="$_cr_rate_n"
      fi
      # A size that already stalled in this job is not tried again (every retry of a
      # stalling size cost 50-60 min of silence in run 39841993539).
      [ "${_cr_stallcap:-0}" -gt 0 ] && [ "$_cr_plan_n" -gt "$_cr_stallcap" ] && _cr_plan_n="$_cr_stallcap"
      echo "[cgc-db] $_cr_r · chunk $_cr_i: graphrag window of up to ${_cr_plan_n} files (halved on a stall, down to one file)"
    elif [ "${_cr_mspf:-0}" -gt 0 ] 2>/dev/null && [ -z "${CGC_CHUNK_FILES:-}" ]; then
      _cr_plan_n=$(( _cr_wplan * 60 * 10 * CHUNK_FILL_PCT / _cr_mspf ))
      # The rate may only SHRINK the adapted chunk, never grow past it (#888). A window
      # of mostly already-indexed files measures a rate the next window cannot keep:
      # run 38044529950's android semantic window 1 did 3031 files at 230 ms/file, the
      # rate then planned all 15387 remaining files into the 263m slice, and that window
      # died at 74% with the slice gone. chunk_adapt still doubles the chunk after a
      # quick window, so growth is geometric instead of a jump to the whole remainder.
      [ "$_cr_plan_n" -gt "$_cr_n" ] && _cr_plan_n="$_cr_n"
      [ "$_cr_plan_n" -lt "$CHUNK_MIN" ] && _cr_plan_n="$CHUNK_MIN"
      [ "$CHUNK_MAX" -gt 0 ] && [ "$_cr_plan_n" -gt "$CHUNK_MAX" ] && _cr_plan_n="$CHUNK_MAX"
      echo "[cgc-db] $_cr_r · chunk $_cr_i sized to the slice: ${_cr_plan_n} files at ${_cr_mspf}ms/file in ${CHUNK_FILL_PCT}% of ${_cr_wplan}m (chunk cap ${_cr_n})"
    elif [ "$MANIFEST_PHASE" = "graphrag" ] && [ -z "${CGC_CHUNK_FILES:-}" ] && [ "$_cr_plan_n" -gt "$CHUNK_N_DEFAULT" ] 2>/dev/null; then
      # No measured rate yet: never grow past the first-window default on a guess.
      _cr_plan_n="$CHUNK_N_DEFAULT"
    fi
    chunk_plan "$_cr_d" "$_cr_sf_stage" "$_cr_head" "$_cr_plan_n" "$_cr_allow" "$_cr_o"
    if [ ! -s "$_cr_o/next" ]; then
      chunk_exclude_clear "$_cr_d"
      if chunk_converged "$_cr_o/state" "$_cr_o/indexable" ""; then
        jq --arg h "$_cr_head" '.seen = $h' "$_cr_o/state" > "$_cr_sf_stage"
        echo "[cgc-db] $_cr_r · converged — nothing outstanding in the $MANIFEST_PHASE phase"
        _cr_conv=1; _rc=0
      else
        cp "$_cr_o/state" "$_cr_sf_stage"
        echo "[cgc-db] $_cr_r · nothing plannable this run (graphrag waits for the semantic phase to embed the rest)"
        _rc=124
      fi
      break
    fi
    [ "$MANIFEST_PHASE" = "graphrag" ] && chunk_touch_next "$_cr_d" "$_cr_o/next"
    # octocode's own commit marker would short-circuit a same-HEAD window ("No commit
    # changes since last index, skipping reindex") or narrow it to its own git diff. The
    # window is ours; let octocode walk it with its per-file mtime check.
    for _cr_gm in "${OCTO_HOME:?}"/*/storage/git_metadata.lance; do
      [ -d "$_cr_gm" ] && rm -rf "${_cr_gm:?}"
    done
    echo "[cgc-db] $_cr_r · chunk $_cr_i: $(wc -l < "$_cr_o/next" | tr -d ' ') new-work files in a $(wc -l < "$_cr_o/window" | tr -d ' ')-file window, slice ${_cr_slice}m, window timeout ${_cr_wto}m"
    _cr_nn=$(wc -l < "$_cr_o/next" | tr -d ' ')
    _cr_l0=0; [ -n "${LLM_PROXY_LOG:-}" ] && [ -f "$LLM_PROXY_LOG" ] && _cr_l0=$(wc -l < "$LLM_PROXY_LOG" | tr -d ' ')
    _cr_hb=""
    # Stall watchdog (graphrag only, see chunk_heartbeat): octocode runs in the background so
    # the heartbeat can find and kill it; a kill it ordered is reported as the window's 124.
    _cr_pidf="$_cr_o/octocode.pid"; _cr_stalled="$_cr_o/stalled"; rm -f "$_cr_pidf" "$_cr_stalled"
    _cr_stall_s=0
    # Silence limit scales with the window (a 400-file window legitimately goes quiet for
    # ~25 min in discovery, a handful of files does not): base minutes at the start size,
    # never under 8 min; one file ALONE gets its own long budget before it is quarantined.
    [ "$MANIFEST_PHASE" = "graphrag" ] && _cr_stall_s=$(( ${CGC_STALL_MIN:-30} * 60 * _cr_nn / ${CGC_GRAPHRAG_START_CHUNK:-400} ))
    if [ "$MANIFEST_PHASE" = "graphrag" ]; then
      [ "$_cr_stall_s" -lt 480 ] && _cr_stall_s=480
      [ "$_cr_stall_s" -gt $(( ${CGC_STALL_MIN:-30} * 60 )) ] && _cr_stall_s=$(( ${CGC_STALL_MIN:-30} * 60 ))
      if [ "$_cr_nn" -le 1 ]; then
        _cr_stall_s=$(( ${CGC_ALONE_BUDGET_MIN:-20} * 60 ))
        [ "$_cr_wto" -gt "${CGC_ALONE_BUDGET_MIN:-20}" ] && _cr_wto="${CGC_ALONE_BUDGET_MIN:-20}"
      fi
    fi
    # Files a stalled window left with a node but no edges are forced this time (marker line).
    _cr_marked="$_cr_o/marked"; : > "$_cr_marked"
    [ "$MANIFEST_PHASE" = "graphrag" ] && chunk_rework_apply "$_cr_d" "$_cr_o/next" "$_cr_sf_stage" > "$_cr_marked"
    [ ! -s "$_cr_marked" ] || echo "[cgc-db] $_cr_r · chunk $_cr_i: forcing $(wc -l < "$_cr_marked" | tr -d ' ') file(s) a stalled window left without edges"
    if [ "${CGC_HEARTBEAT_S:-0}" -gt 0 ] 2>/dev/null; then
      : > "$_log"
      chunk_heartbeat "$_cr_r · chunk $_cr_i" "$_log" "${LLM_PROXY_LOG:-}" "$_cr_l0" "$CGC_HEARTBEAT_S" "$_cr_pidf" "$_cr_stall_s" "$_cr_stalled" &
      _cr_hb=$!
    fi
    _cr_t0=$(date +%s); _rc=0
    ( cd "$_cr_d" && timeout "${_cr_wto}m" octocode index ) >"$_log" 2>&1 &
    _cr_op=$!; echo "$_cr_op" > "$_cr_pidf"
    wait "$_cr_op" || _rc=$?
    [ -f "$_cr_stalled" ] && _rc=124
    _cr_dt=$(( $(date +%s) - _cr_t0 ))
    if [ -n "$_cr_hb" ]; then kill "$_cr_hb" 2>/dev/null || true; wait "$_cr_hb" 2>/dev/null || true; fi
    chunk_rework_restore "$_cr_d" "$_cr_marked"
    chunk_exclude_clear "$_cr_d"
    _cr_llm=0
    chunk_llm_summary "${LLM_PROXY_LOG:-}" "$_cr_l0" "$_cr_dt" "$_cr_nn" "$_cr_r · chunk $_cr_i (rc=$_rc)" "$_cr_o" || _cr_llm=$?
    if [ "$_rc" = "124" ]; then
      if [ "$MANIFEST_PHASE" = "graphrag" ] && [ "$_cr_nn" -le 1 ] && [ -s "$_cr_o/next" ]; then
        # ONE file, alone, with the long budget, and it still hangs: the only case that leaves
        # a file out. Name it (private repos: count only) and say why.
        chunk_quarantine "$_cr_o/state0" "$_cr_o/next" "hangs ALONE: octocode made no progress on this file for ${CGC_ALONE_BUDGET_MIN:-20}m, $(date -u +%Y-%m-%d), run ${GITHUB_RUN_ID:-local}" "$_cr_sf_stage"
        chunk_rework_add "$_cr_sf_stage" "$_cr_o/next" "$_cr_sf_stage"
        if cgc_repo_is_private "$_cr_r"; then _cr_qnames="(name withheld: private repo)"; else _cr_qnames=$(tr '\n' ' ' < "$_cr_o/next"); fi
        echo "::error::[cgc-db] $_cr_r · QUARANTINED $_cr_qnames: it hangs ALONE (> ${CGC_ALONE_BUDGET_MIN:-20}m); skipped from now on, node without edges"
      elif [ "$MANIFEST_PHASE" = "graphrag" ]; then
        # Split: halve the window (down to one file). A stalled window left its files with
        # nodes but no edges, so they are forced (marker) in the windows that follow.
        _cr_n=$(( _cr_nn / 2 )); [ "$_cr_n" -ge 1 ] || _cr_n=1
        _cr_stallcap="$_cr_n"
        _cr_sus=$(chunk_suspect "$_log" "$_cr_o/next")
        jq --argjson n "$_cr_n" --arg s "$_cr_sus" '.chunk = $n | if $s != "" then .probe = $s else del(.probe) end' "$_cr_o/state0" > "$_cr_sf_stage"
        [ -z "$_cr_sus" ] || echo "[cgc-db] $_cr_r · chunk $_cr_i: suspect file isolated for the next window (it runs ALONE; quarantined only if it hangs alone)"
        chunk_rework_add "$_cr_sf_stage" "$_cr_o/next" "$_cr_sf_stage"
        echo "::warning::[cgc-db] $_cr_r · chunk $_cr_i of ${_cr_nn} file(s) stalled/timed out (${_cr_dt}s) — splitting: next window ${_cr_n} file(s)"
      else
      _cr_n=$(chunk_adapt "$_cr_n" timeout "$_cr_dt" $(( _cr_wto * 60 )) "$_cr_min" "$CHUNK_MAX")
      # The rate was too optimistic: double it so the next sized window is half as big.
      jq --argjson n "$_cr_n" '.chunk = $n | if (.ms_per_file // 0) > 0 then .ms_per_file *= 2 else . end' "$_cr_o/state0" > "$_cr_sf_stage"
      echo "::warning::[cgc-db] $_cr_r · chunk $_cr_i did not finish in ${_cr_wto}m — chunk size halved to $_cr_n; this window's files stay outstanding"
      fi
      [ "$MANIFEST_PHASE" != "graphrag" ] || cgc_chunk_persist_decision
      # A window killed at its own cap (graphrag) leaves the rest of the slice: go on in
      # this job with the halved window. The top of the loop stops when too little is left.
      [ "$_cr_wto" -lt "$_cr_slice" ] && [ "$_cr_llm" != "3" ] && continue
      break
    fi
    [ "$_rc" = "0" ] || break
    _cr_n=$(chunk_adapt "$_cr_n" ok "$_cr_dt" $(( _cr_wto * 60 )) "$_cr_min" "$CHUNK_MAX")
    chunk_commit "$_cr_o" "$_cr_head" "$_cr_sf_stage" "$_cr_o/deferred"
    [ "$MANIFEST_PHASE" != "graphrag" ] || chunk_rework_clear "$_cr_sf_stage" "$_cr_o/next" "$_cr_sf_stage"
    _cr_prev=$(chunk_state_read "$_cr_sf_stage" | jq -r '.ms_per_file // 0')
    _cr_mspf=$(( _cr_dt * 1000 / (_cr_nn > 0 ? _cr_nn : 1) ))
    # graphrag gets slower as the done set grows (more importers re-analysed per window):
    # a faster window only pulls the rate halfway down, a slower one sets it outright.
    if [ "$MANIFEST_PHASE" = "graphrag" ] && [ "${_cr_prev:-0}" -gt "$_cr_mspf" ] 2>/dev/null; then
      _cr_mspf=$(( (_cr_prev + _cr_mspf) / 2 ))
    fi
    jq --argjson n "$_cr_n" --argjson r "$_cr_mspf" '.chunk = $n | .ms_per_file = $r' "$_cr_sf_stage" > "$_cr_sf_stage.tmp" && mv "$_cr_sf_stage.tmp" "$_cr_sf_stage"
    echo "[cgc-db] $_cr_r · chunk $_cr_i done in ${_cr_dt}s (${_cr_nn} files, ${_cr_mspf}ms/file); next chunk size $_cr_n"
    if chunk_converged "$_cr_sf_stage" "$_cr_o/indexable" ""; then _cr_conv=1; break; fi
    if [ "$_cr_llm" = "3" ]; then
      echo "::warning::[cgc-db] $_cr_r · the LLM circuit breaker opened in chunk $_cr_i (consecutive calls ran out of budget) — stopping this repo for this run; the window completed with bounded fallbacks, see the LLM line above"
      _rc=124; break
    fi
    # ONE publish per stop (#888). The outer loop publishes this repo as soon as we
    # return, carrying the final state and status. If a publish here would leave no
    # usable slice for another window, it would be followed straight away by that outer
    # publish of the same index -- run 37929244331 paid 58m twice for exactly that. Stop
    # now and let the outer publish be the only one. Same arithmetic as the top of the
    # loop: after a publish of ~_cr_pub_s, the next slice is what remains minus another.
    _cr_next=$(( BUDGET_MIN - ( $(date +%s) - START_TS ) / 60 - 2 * _cr_pub_s / 60 ))
    if [ "$_cr_next" -lt "${CGC_MIN_SLICE_MIN:-20}" ]; then
      echo "[cgc-db] $_cr_r · chunk $((_cr_i + 1)) would get only ${_cr_next}m after a checkpoint — stopping here; the final publish carries chunk $_cr_i, the next run continues"
      _rc=124; break
    fi
    # Durable progress before the next window: resolve this repo's project dir, put the
    # state inside it and publish. A forced run publishes to its partial tag only.
    if [ -z "${_proj_resolved:-}" ]; then
      _proj_resolved=$(resolve_project_dir "$OCTO_HOME" "$_before_dirs" "$_idx_marker") || { _rc=1; break; }
    fi
    cp "$_cr_sf_stage" "$(chunk_state_path "$OCTO_HOME/$_proj_resolved" "$MANIFEST_PHASE")"
    _cr_p0=$(date +%s)
    if [ "${CGC_FORCE:-0}" = "1" ]; then
      printf '{"octocode":"%s","phase":"%s","commit":"%s"}\n' "$OCTO_VERSION" "$MANIFEST_PHASE" "$_cr_head" > "$OCTO_HOME/$_proj_resolved/$FORCE_PARTIAL_MARKER"
      ( REPO_TAG="$(force_partial_tag)"; checkpoint_publish "$_cr_r" ) || { _rc=1; break; }
      rm -f "$OCTO_HOME/$_proj_resolved/$FORCE_PARTIAL_MARKER"
    else
      checkpoint_publish "$_cr_r" || { _rc=1; break; }
    fi
    _cr_pub_s=$(( $(date +%s) - _cr_p0 + 300 ))
    echo "[cgc-db] $_cr_r · chunk $_cr_i checkpointed (publish took $(( _cr_pub_s / 60 - 5 ))m)"
  done
  # Convergence record: stale_runs counts consecutive runs that ended outstanding.
  if [ "$_cr_conv" = "1" ]; then
    chunk_state_read "$_cr_sf_stage" | jq '.stale_runs = 0' > "$_cr_sf_stage.tmp"
  else
    chunk_state_read "$_cr_sf_stage" | jq '.stale_runs = ((.stale_runs // 0) + 1)' > "$_cr_sf_stage.tmp"
  fi
  mv "$_cr_sf_stage.tmp" "$_cr_sf_stage"
  [ -s "$_cr_o/indexable" ] || chunk_indexable "$_cr_d" > "$_cr_o/indexable"
  CHUNK_STATUS=$(chunk_status_json "$_cr_r" "$MANIFEST_PHASE" "$_cr_sf_stage" "$_cr_o/indexable" "$_cr_head" "$_cr_conv")
  echo "[cgc-db] CONVERGENCE $CHUNK_STATUS"
  _cr_stale=$(printf '%s' "$CHUNK_STATUS" | jq -r '.stale_runs')
  if [ "$_cr_stale" -ge "$CHUNK_STALE_ALERT" ] 2>/dev/null; then
    echo "::error::[cgc-db] $_cr_r has ended $_cr_stale consecutive $MANIFEST_PHASE runs without converging ($(printf '%s' "$CHUNK_STATUS" | jq -r '"\(.done)/\(.total) done, \(.dirty) dirty"')) — check the chunk size and the per-chunk timings above"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s' "$CHUNK_STATUS" | jq -r '"| \(.repo) | \(.phase) | \(.done)/\(.total) | \(.dirty) | \(.chunk) | \(.stale_runs) | \(if .converged then "yes" else "no" end) | \(.head[0:8]) |"' \
      | { [ -s "$GITHUB_STEP_SUMMARY" ] || printf '| repo | phase | done/total | dirty | chunk | stale runs | converged | head |\n|---|---|---|---|---|---|---|---|\n'; cat; } >> "$GITHUB_STEP_SUMMARY"
  fi
  # Put state + status inside the project dir so the outer publish carries them.
  _cr_pd=${_proj_resolved:-$(chunk_home_project)}
  if [ -n "$_cr_pd" ]; then
    cp "$_cr_sf_stage" "$(chunk_state_path "$OCTO_HOME/$_cr_pd" "$MANIFEST_PHASE")"
    printf '%s\n' "$CHUNK_STATUS" > "$OCTO_HOME/$_cr_pd/.cgc-status-$MANIFEST_PHASE.json"
  fi
  return 0
}

# The HEAD-only change gate is not enough in chunk mode: a manifest entry written by a
# run that graphed 11 of 3,470 files (cloud-u-containers, before chunking) matches HEAD
# forever. Skip only when this phase's chunk state also says converged at this HEAD.
chunk_gate_current() {  # $1 = head → rc 0 when the repo may be skipped
  [ "$CHUNK_MODE" = "1" ] || return 0
  _cg_pd=$(chunk_home_project)
  [ -n "$_cg_pd" ] || return 1
  _cg_sf=$(chunk_state_path "$OCTO_HOME/$_cg_pd" "$MANIFEST_PHASE")
  [ -f "$_cg_sf" ] || return 1
  [ "$(jq -r '"\(.seen)|\(.stale_runs)|\(.dirty | length)"' "$_cg_sf" 2>/dev/null)" = "$1|0|0" ]
}

for r in $REPOS; do
  d="$REPOS_ROOT/$r"
  [ -d "$d" ] || { echo "::error::missing repo $d — refusing to publish an incomplete DB"; exit 1; }

  # GRAPHRAG SKIP (data-driven, .runtime.octocode.graphrag_skip — no hardcoded names
  # here). Pure prose/text corpora (e.g. cloud-data-my-ai-memory) have no code semantics to
  # relate, so the GraphRAG LLM relationship pass is real per-node LLM cost for zero
  # graph nodes. Only the graphrag phase (USE_LLM=true) skips these repos — structural/
  # FastEmbed indexing (the semantic phase, USE_LLM=false) still runs normally for them,
  # so they are fully search/embed-able, just never LLM-graphed. Checked BEFORE the time
  # budget below so a skipped repo never consumes a reserve slot or gets counted deferred.
  if [ "$USE_LLM" = "true" ]; then
    _gskip=$(jq -r --arg r "$r" '(.runtime.octocode.graphrag_skip // []) | index($r) != null' "$BJ")
    if [ "$_gskip" = "true" ]; then
      echo "[cgc-db] === graphrag skip: $r (text corpus, no code graph — .runtime.octocode.graphrag_skip) ==="
      N_SKIP=$(( N_SKIP + 1 ))
      continue
    fi
  fi

  # TIME BUDGET: stop before the runner cap so we always reach a clean push+exit.
  # RESERVE the repo's worst case (a full repo_timeout_min) BEFORE admitting it. Gating
  # only on "budget not yet spent" admits a repo at minute 299 that is then allowed to run
  # repo_timeout_min longer — so the true worst case is max_minutes + repo_timeout_min, not
  # max_minutes. That overshoots GitHub's hard job ceiling, which kills the runner mid-repo:
  # no final package/push, and the checkpoint for the in-flight repo is lost. Reserving up
  # front is what actually makes the "never killed mid-repo" invariant above true.
  # A repo_timeout_min of 0 (no per-repo timeout) reserves nothing and keeps the old gate.
  # ADAPTIVE RESERVE. A FIXED reserve deadlocks: it must be large enough for the slowest
  # repo to finish (cloud-infra-desktop needs ~200m+ at measured throughput) yet small enough that a
  # repo is still admitted late in the run — and those cannot both hold, because admission
  # requires elapsed + reserve <= max_minutes. With reserve=180 nothing is admitted after
  # 120m; raise it so the giants fit and they are never admitted at all, since the small
  # repos alone consume ~75m. Clamp instead: give each repo the SMALLER of its configured
  # ceiling and the budget actually left. Worst case is still bounded by max_minutes (the
  # clamp can never hand out more time than remains), giants get every minute available
  # rather than a fixed slice, and a repo is only skipped when too little time remains to
  # be worth starting. REPO_TIMEOUT_MIN is now a CEILING, not a reservation.
  REPO_TIMEOUT_EFF="$REPO_TIMEOUT_MIN"
  if [ -n "$BUDGET_MIN" ] && [ "$BUDGET_MIN" != "0" ]; then
    _elapsed=$(( ( $(date +%s) - START_TS ) / 60 ))
    _remain=$(( BUDGET_MIN - _elapsed ))
    _reserve="${REPO_TIMEOUT_MIN:-0}"
    [ -n "$_reserve" ] || _reserve=0
    # Clamp the ceiling to what is left; 0 means "no ceiling configured" so take the remainder.
    if [ "$_reserve" = "0" ] || [ "$_remain" -lt "$_reserve" ]; then REPO_TIMEOUT_EFF="$_remain"; fi
    # Floor: starting a repo with only a few minutes left burns a 15G checkpoint push for
    # almost no indexing. Defer instead and give it a full slice next run.
    if [ "$_remain" -lt "${CGC_MIN_SLICE_MIN:-20}" ]; then
      _n_left=0; for _q in $REPOS; do _n_left=$(( _n_left + 1 )); done
      N_DEFER=$(( _n_left - N_INDEX - N_SKIP - N_TIMEOUT ))
      echo "::warning::[cgc-db] only ${_remain}m of the ${BUDGET_MIN}m budget left (<${CGC_MIN_SLICE_MIN:-20}m floor) — deferring $r (+${N_DEFER} total) to next run; its ${MANIFEST_PHASE:-default} index stays STALE until then"
      STALE_REPOS="$STALE_REPOS $r"
      break
    fi
  fi

  # CHANGE GATE: HEAD unchanged since last index into this DB → nothing to do.
  # CGC_FORCE=1 bypasses it. The manifest is keyed on repo HEAD alone, but the
  # DB's freshness also depends on HOW it was indexed — when the INDEXER changes
  # (embedding model, graphrag settings, a fixed LLM endpoint), every entry is
  # stale at an unchanged HEAD and the gate would skip all of them forever. That
  # is not hypothetical: the graphrag manifest was advanced by runs that silently
  # produced structural-only graphs, so re-running after fixing the LLM wiring is
  # a no-op without this. Reindexing on a config change is the whole point.
  cur=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")
  last=$(manifest_read "$(manifest_path '')" "$r")
  if [ "${CGC_FORCE:-0}" = "1" ] && [ -n "$last" ]; then
    echo "[cgc-db] === force $r — ignoring manifest entry @ $last (CGC_FORCE=1) ==="
  elif [ -n "$cur" ] && [ "$cur" = "$last" ] && chunk_gate_current "$cur"; then
    echo "[cgc-db] === skip $r — unchanged @ $cur ==="
    N_SKIP=$(( N_SKIP + 1 ))
    continue
  fi

  exclude_submodules "$d"
  # Base .noindex from build.json conventions (dist/vendor/node_modules/z_archive/lockfiles).
  : > "$d/.noindex"
  if [ -n "$NOINDEX_PATTERNS" ]; then
    printf '%s\n' "$NOINDEX_PATTERNS" > "$d/.noindex"
    echo "[cgc-db] $r · .noindex base: $(printf '%s' "$NOINDEX_PATTERNS" | tr '\n' ' ')"
  fi
  # PER-REPO noindex extension (data-driven, .runtime.octocode.noindex_extra keyed by
  # local repo name — no hardcoded paths here). Layered on top of the global base above,
  # for content only ONE repo needs excluded (e.g. cloud-data-my-ai-memory's a_sessions/ and
  # a_commits/ — see build.json's _noindex_extra_comment for why).
  NOINDEX_EXTRA=$(jq -r --arg r "$r" '((.runtime.octocode.noindex_extra // {})[$r] // []) | .[]' "$BJ" 2>/dev/null)
  if [ -n "$NOINDEX_EXTRA" ]; then
    printf '%s\n' "$NOINDEX_EXTRA" >> "$d/.noindex"
    echo "[cgc-db] $r · .noindex extra: $(printf '%s' "$NOINDEX_EXTRA" | tr '\n' ' ')"
  fi
  # SMART: auto-append binary-dominated dirs (generic, no hardcoded paths).
  smart_noindex "$d"

  # Throughput + pressure, so the NEXT run diagnoses itself instead of needing a log
  # archaeology pass. 2026-08-20 measured ~5.2s/file on a structural no-LLM index, which is
  # ~100x too slow and is the real root cause behind every symptom above; the suspect is the
  # 16G DB (du -sh, cloud-cgc-db-pull.sh) restored under MemoryMax=16G + MemorySwapMax=0 on
  # a 16GB runner, i.e. page cache thrash on every vector lookup. Do NOT tune mem_max on a
  # hunch — these two lines plus the files/min below say whether it is memory or disk.
  _files=$(git -C "$d" ls-files 2>/dev/null | wc -l)
  echo "[cgc-db] $r · pressure before index: mem=$(free -g 2>/dev/null | awk '/^Mem:/{print $3"/"$2"G used, "$6"G cache"}') disk=$(df -h "$OCTO_HOME" 2>/dev/null | awk 'NR==2{print $4" free"}')"
  # STRAY-SELECT (per-repo mode only — see project_dirs_snapshot()/resolve_project_dir()
  # above): snapshot the project dirs under OCTO_HOME and stamp an mtime marker
  # RIGHT BEFORE this repo's own index, so the diff after it can tell which dir
  # this specific index run produced/touched regardless of what else is in the home.
  _before_dirs="" _idx_marker="" _proj_resolved=""
  if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
    _before_dirs=$(project_dirs_snapshot "$OCTO_HOME")
    _idx_marker=$(mktemp)
  fi
  _t0=$(date +%s)
  echo "[cgc-db] === incremental index: $r (was=${last:-none} now=$cur, ${_files} files) ==="
  # Capture octocode's REAL exit status (a pipe to `tail` would mask it) and make a
  # failed index FATAL — never package/push an unindexed base as a fake update.
  _log="$(mktemp)"
  _rc=0
  CHUNK_STATUS=""
  if [ "$CHUNK_MODE" = "1" ]; then
    rm -f "$_log"
    chunk_index_repo "$r" "$d" "$cur"
  elif [ -n "$REPO_TIMEOUT_EFF" ] && [ "$REPO_TIMEOUT_EFF" != "0" ]; then
    echo "[cgc-db] $r · slice ${REPO_TIMEOUT_EFF}m (ceiling ${REPO_TIMEOUT_MIN:-none}m, budget left ${_remain:-?}m)"
    ( cd "$d" && timeout "${REPO_TIMEOUT_EFF}m" octocode index ) >"$_log" 2>&1 || _rc=$?
  else
    ( cd "$d" && octocode index ) >"$_log" 2>&1 || _rc=$?
  fi
  _dt=$(( $(date +%s) - _t0 ))
  if [ "$_rc" = "124" ]; then
    # On timeout the denominator is unknown: dividing the slice by the FULL file count
    # (2026-09-03: "0.53s/file" for android, real rate ~670 files per 240m slice) reads
    # as a throughput number and misled the sizing. The digest below prints octocode's
    # own "Loaded metadata for N files" (files already in the DB when this run began) and
    # its last progress state; the delta between consecutive runs is the real rate.
    echo "[cgc-db] $r · index took ${_dt}s of ${_files} files (TIMEOUT — partial, s/file not meaningful, rc=124)"
  else
    echo "[cgc-db] $r · index took ${_dt}s for ${_files} files ($(awk -v d="$_dt" -v f="$_files" 'BEGIN{printf (f>0? "%.2f":"n/a"), d/(f>0?f:1)}')s/file, rc=$_rc)"
  fi
  # STRAY-SELECT resolution — only for runs that actually reached/touched a project
  # dir (rc=0 success or rc=124 partial, both checkpoint below); a hard failure
  # (the else branch) exits before ever reaching checkpoint_publish, so it needs no
  # resolved dir. Ambiguity is fatal here, same severity as an index failure: we
  # refuse to package/push a checkpoint we cannot positively identify.
  if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && { [ "$_rc" = "0" ] || [ "$_rc" = "124" ]; }; then
    [ -n "${_proj_resolved:-}" ] || _proj_resolved=$(resolve_project_dir "$OCTO_HOME" "$_before_dirs" "$_idx_marker") \
      || { rm -f "$_idx_marker" "$_log" 2>/dev/null; echo "::error::[cgc-db] $r · cannot identify which project dir this index produced — refusing to package/push an unidentifiable checkpoint"; exit 1; }
    echo "[cgc-db] $r · resolved project dir: $_proj_resolved"
  fi
  rm -f "$_idx_marker" 2>/dev/null || true
  if [ "$_rc" = "0" ]; then
    # NO-OP INDEX. The change gate above only lets a repo through when its HEAD
    # MOVED (or CGC_FORCE), so an index that reports "0 of 0 files processed" did
    # nothing while something was owed. On 2026-09-15 cloud-u-android came through as
    #   === incremental index: cloud-u-android (was=none now=30fedcdae..., 26257 files) ===
    #   cloud-u-android · index took 1s for 26257 files (0.00s/file, rc=0)
    #   ✓ Indexing complete! 0 of 0 files processed
    # and the run published a 4.0GB checkpoint and RECORDED that HEAD as indexed.
    # So the image answers for a tree nobody indexed: ac_cloud-mail's
    # SignatureEditor.kt, committed SIX DAYS before that HEAD, is absent from every
    # content table of the published store while the manifest swears the repo is
    # current. Exactly the shape of the timeout branch below — publishing the bytes
    # is fine, advancing the manifest is the lie — so it takes the same treatment.
    _noop_index=0
    grep -qE 'Indexing complete!.*0 of 0 files processed' "$_log" && _noop_index=1
    octo_log_report "$_log" 40 "$r"; rm -f "$_log"
    # graphrag phase only: no LLM-derived edges = no checkpoint (see assert_llm_graph).
    if [ "$USE_LLM" = "true" ]; then assert_llm_graph "$d" "$r" || exit 1; fi
    if [ "$USE_LLM" = "true" ] && [ -n "${_proj_resolved:-}" ] && [ "${_files:-0}" -ge 30 ] && ! graph_nodes_present "$_proj_resolved"; then
      echo "::error::[cgc-db] $r · graphrag phase finished but project dir $_proj_resolved holds NO graphrag_nodes data — nothing was persisted, refusing to publish a graph-less checkpoint as a graphrag result (#888)"
      exit 1
    fi
    if [ "$_noop_index" = "1" ]; then
      echo "::warning::[cgc-db] $r · the indexer processed 0 of 0 files although the change gate let it through (was=${last:-none} now=$cur) — octocode treats the DB as current at a commit it never indexed, so the published store answers for an older tree. The checkpoint is published, the manifest is NOT advanced, and this repo stays 'not indexed' and retries. Only a reindex (workflow input force=true) actually clears it."
      STALE_REPOS="$STALE_REPOS $r"
      echo "[cgc-db] checkpoint publish after $r (NO-OP index — manifest not advanced)"
      checkpoint_publish "$r"
      PUSHED=1
      continue
    fi
  elif [ "$_rc" = "124" ]; then
    [ -n "$CHUNK_STATUS" ] && echo "[cgc-db] $r · not converged this run: $(printf '%s' "$CHUNK_STATUS" | jq -r '"\(.done)/\(.total) done, \(.dirty) dirty, next chunk \(.chunk)"') — completed chunks are durable"
    echo "::warning::[cgc-db] $r is STALE in the ${MANIFEST_PHASE:-default} index: the slice of ${REPO_TIMEOUT_EFF}m expired mid-index, so the DB stays at ${last:-no indexed commit} while origin/main is at $cur. Partial progress is published and the next run resumes; every run until it converges repeats this warning."
    STALE_REPOS="$STALE_REPOS $r"
    octo_log_report "$_log" 40 "$r"; rm -f "$_log"
    N_TIMEOUT=$(( N_TIMEOUT + 1 ))
    # PUBLISH the partial index, but do NOT advance the manifest. Those two are separate
    # decisions and conflating them is what made the outage permanent: on timeout the
    # embeddings octocode already wrote ARE in the DB, yet the old code discarded them by
    # returning without a push, so every run redid and rediscarded the same 55% of
    # cloud-infra forever — a repo too big for one timeout could never finish, ever.
    # Pushing without advancing the manifest is the safe half of the pair: the repo stays
    # "not indexed" and retries next run, but the work it did survives in the base DB, so
    # successive runs ratchet forward instead of resetting. Worst case if octocode does not
    # skip already-embedded files, this costs one extra push and converges no slower than
    # before; it cannot mark a repo done that is not done, because the manifest is untouched.
    if [ "$USE_LLM" = "true" ] && [ -n "${_proj_resolved:-}" ] && [ "${_files:-0}" -ge 30 ] && ! graph_nodes_present "$_proj_resolved"; then
      NO_GRAPH_REPOS="$NO_GRAPH_REPOS $r"
      echo "::error::[cgc-db] $r · the slice expired before the graph pass: project dir $_proj_resolved has storage but NO graphrag_nodes — this is a resumable partial, not a graphrag result, and the job fails below so it cannot read as success (#888)"
      if [ "${CGC_FORCE:-0}" = "1" ]; then
        printf '{"octocode":"%s","phase":"%s","commit":"%s"}\n' "$OCTO_VERSION" "${MANIFEST_PHASE:-default}" "$cur" > "$OCTO_HOME/$_proj_resolved/$FORCE_PARTIAL_MARKER"
        echo "[cgc-db] checkpoint publish after $r to $(force_partial_tag) (forced partial — :latest and the manifest untouched)"
        ( REPO_TAG="$(force_partial_tag)"; checkpoint_publish "$r" )
        continue
      fi
    fi
    # Chunk mode (#888): a forced rebuild restarts from base, so any not-yet-converged
    # state of it is SMALLER than the served graph even when it already holds graph nodes.
    # It goes to the force tag; :latest keeps the last complete graph until the forced
    # rebuild converges and replaces it in one publish.
    if [ "$CHUNK_MODE" = "1" ] && [ "${CGC_FORCE:-0}" = "1" ] && [ -n "${_proj_resolved:-}" ]; then
      printf '{"octocode":"%s","phase":"%s","commit":"%s"}\n' "$OCTO_VERSION" "${MANIFEST_PHASE:-default}" "$cur" > "$OCTO_HOME/$_proj_resolved/$FORCE_PARTIAL_MARKER"
      echo "[cgc-db] checkpoint publish after $r to $(force_partial_tag) (forced, not converged — :latest and the manifest untouched)"
      ( REPO_TAG="$(force_partial_tag)"; checkpoint_publish "$r" )
      continue
    fi
    echo "[cgc-db] checkpoint publish after $r (PARTIAL — manifest not advanced)"
    checkpoint_publish "$r"
    PUSHED=1
    continue
  else
    echo "::error::octocode index FAILED for $r (rc=$_rc) — aborting BEFORE package/push so no no-op DB is published:"
    octo_log_report "$_log" 60 "$r"; rm -f "$_log"; exit 1
  fi

  # Record the indexed commit in the DB home (travels via package/pull), THEN
  # checkpoint-push so this repo's progress is durable before we touch the next.
  _mf=$(manifest_path "${_proj_resolved:-}")
  [ -s "$_mf" ] || echo '{}' > "$_mf"
  _tmp=$(mktemp); jq --arg r "$r" --arg c "$cur" '.[$r]=$c' "$_mf" > "$_tmp" && mv "$_tmp" "$_mf"
  echo "[cgc-db] checkpoint publish after $r"
  checkpoint_publish "$r"
  if [ "${CGC_FORCE:-0}" = "1" ] && [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
    # The forced index finished: overwrite the resume tag with the (marker-less) result so
    # a later forced run cannot resume from a stale partial.
    ( REPO_TAG="$(force_partial_tag)"; checkpoint_publish "$r" ) || echo "::warning::[cgc-db] $r · could not clear $(force_partial_tag); its marker may still read as resumable"
  fi
  # FIX 2 — see seed_base_if_missing() above. Only after a genuinely SUCCESSFUL
  # index + checkpoint (not the PARTIAL/timeout branch above): the home now holds
  # a complete config.toml + whatever model caches this index run touched.
  [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ] && seed_base_if_missing
  PUSHED=1
  N_INDEX=$(( N_INDEX + 1 ))
done

echo "[cgc-db] SUMMARY phase=${MANIFEST_PHASE:-default}: ${N_INDEX} indexed, ${N_SKIP} unchanged, ${N_TIMEOUT} timed out, ${N_DEFER} deferred"
if [ -n "$STALE_REPOS" ]; then
  echo "::warning::[cgc-db] ${MANIFEST_PHASE:-default} index NOT current for:${STALE_REPOS} — the cgc surfaces are serving an older tree for these repos. A run whose matrix job is green but whose repo appears here has published progress, not currency."
fi

if [ -n "$NO_GRAPH_REPOS" ]; then
  echo "::error::[cgc-db] graphrag phase persisted NO graph for:${NO_GRAPH_REPOS} — the slice expired before graphrag_nodes was written. A forced run's partial is on tag $(force_partial_tag) (re-dispatch force=true to resume); the served image was not replaced by it."
  exit 1
fi

# 5/6) Propagate to the deployed consumer (oci-apps) so it serves the new DB now.
#      Only when something actually changed this cycle (checkpoints already pushed
#      it to GHCR). CGC_SKIP_PROPAGATE=1 lets a caller defer propagation.
#      CGC_PACKAGE_MODE=per-repo ALWAYS skips this rsync-whole-home path, even if a
#      caller forgot CGC_SKIP_PROPAGATE=1: OCTO_HOME here is a fresh home that has, at
#      most, the shared base state plus ONE repo's project dir — rsync --delete'ing
#      that over the live volume (which holds every OTHER repo's data too) would
#      DESTROY the rest. The matrix workflow's own restore-all job (base + every
#      per-repo image, assembled together) propagates instead.
if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  echo "[cgc-db] per-repo mode — propagate_to_host (rsync whole home) is never used here; the matrix workflow's restore-all job propagates instead"
elif [ "$PUSHED" = "0" ] && [ "$N_TIMEOUT" = "0" ] && [ "$N_DEFER" = "0" ]; then
  echo "[cgc-db] no repo changed — DB already current, nothing to publish or propagate"
elif [ "$PUSHED" = "0" ]; then
  # NOT the same as "already current" — this is an incomplete cycle. Say so loudly enough
  # that a scheduled run reads as the outage it is, instead of six days of quiet green.
  echo "::warning::[cgc-db] nothing published: ${N_TIMEOUT} repo(s) timed out, ${N_DEFER} deferred — DB is STALE, not current"
elif [ "${CGC_SKIP_PROPAGATE:-}" = "1" ]; then
  echo "[cgc-db] propagation deferred (CGC_SKIP_PROPAGATE=1)"
else
  propagate_to_host
fi

if [ "${CGC_PACKAGE_MODE:-monolith}" = "per-repo" ]; then
  echo "[cgc-db] UPDATE COMPLETE → ${REPO_PREFIX:-}<repo>:${REPO_TAG:-latest} (per-repo)"
else
  echo "[cgc-db] UPDATE COMPLETE → $IMAGE:$TAG"
fi
