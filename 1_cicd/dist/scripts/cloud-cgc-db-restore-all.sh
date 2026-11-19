#!/bin/sh

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/ops/cloud-cgc-db-restore-all.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-restore-all.sh — restore a full octocode home from the
#  per-repo GHCR images (multi-image consumer restore)
# ──────────────────────────────────────────────────────────────────────────
#  ARCHITECTURE (see cloud-cgc-db-package.sh header, which produces these
#  images): one GHCR image per repo — ghcr.io/diegonmarcos/cgc-db-<local_name>
#  — plus one shared base image ghcr.io/diegonmarcos/cgc-db-base:latest
#  carrying the octocode home ROOT state (config.toml + fastembed/ +
#  sentencetransformer/ model caches — never project data). Each image's
#  /octocode-db/. is exactly what a `docker cp` from a throwaway container
#  should drop into the target home: base → {config.toml, fastembed/,
#  sentencetransformer/}; a repo image → its single <project_id>/ dir.
#
#  This is the CONSUMER side of that split, replacing the single-image
#  cloud-cgc-db-pull.sh / cloud-cgc-db-restore.sh path once a target has
#  cut over to the matrix producer. Both old scripts are UNTOUCHED and stay
#  the default until cutover — see the callers (dagu DAG, compose.nix).
#
#  SEQUENCE (stage first, swap once):
#    1. base image  → STAGING          (hard error if missing — nothing to
#                                        seed from; see the seed instruction
#                                        printed below)
#    2. each repo image → STAGING      (missing image = bootstrap tolerance:
#                                        warn + skip, not fatal — a matrix
#                                        producer publishes repos one at a
#                                        time and the home is legitimately
#                                        incomplete until every job has run
#                                        at least once)
#    3. verify: (# project dirs staged) == (# repo images actually pulled).
#       This is what catches a name COLLISION between two repo images —
#       cp -a would silently merge two different <project_id>/ dirs into
#       one, and an aggregate count is the only thing that would ever
#       notice — as well as a corrupt or empty image.
#    4. ONLY once (1)-(3) all succeed: wipe TARGET once, cp -a STAGING in.
#  Every fallible step (network pulls, image extraction, the count check)
#  happens in STAGING before TARGET is touched at all, so any failure along
#  the way leaves TARGET exactly as it was — never half-wiped. Re-running is
#  safe: STAGING is always a fresh mktemp -d and TARGET is only ever touched
#  by the single final swap.
#
#  Per-image docker hygiene mirrors cloud-cgc-db-pull.sh: docker rm the
#  throwaway container AND docker rmi the transport image right after each
#  cp — the known 15G-pinning leak class documented there and in
#  cloud-cgc-db-package.sh (N images left tagged locally == N copies of the
#  DB pinned in the docker data-root at once; this restores potentially
#  index_repos-many images in one run, so the leak would be N-times worse
#  here than in the single-image path if left unfreed).
#
#  Args:    $1 = target octocode home dir (default: $OCTOCODE_HOME or
#           ~/.local/share/octocode — same default as cloud-cgc-db-pull.sh).
#           Ignored when CGC_DB_TARGET_VOLUME is set (see below).
#  Env:
#    CGC_DB_TARGET_VOLUME optional. When set, TARGET/$1 is ignored and the
#                         final swap writes into this docker NAMED VOLUME
#                         instead of a host path, via a throwaway container
#                         (`docker run -v $CGC_DB_TARGET_VOLUME:/dst ...`) —
#                         the SAME idiom cloud-cgc-db-restore.sh already uses
#                         and for the same reason: a named volume's host-side
#                         data dir is typically root-owned, and the oci-apps
#                         DAG runs this over SSH as a plain (non-root) user
#                         that only has docker-group socket access, not host
#                         root. The compose.nix db-restore path does not need
#                         this — compose mounts the volume INTO the container
#                         at oct.db_path, so from inside there it already IS
#                         a plain, directly-writable directory.
#    CGC_PRIVATE_REPOS    space-separated repos to EXCLUDE, because their GitHub
#                         source is private and their DB must never reach the
#                         volume the public MCP serves. Defaults to
#                         .runtime.octocode.private_repos from build.json;
#                         set explicitly where build.json is absent (the box).
#    CGC_INCLUDE_PRIVATE  set to 1 to disable that filter entirely. Only
#                         cloud-cgc-pvt-mcp may do this, and only together with
#                         its OWN CGC_DB_TARGET_VOLUME — never the public one.
#    CGC_DB_OWNER         optional "uid:gid" to chown -R the restored tree to.
#                         REQUIRED whenever the consumer runs as a different uid
#                         than whoever runs this script, which is the normal
#                         case: the images extract as the invoking user (1001
#                         over the oci-apps SSH path) while cloud-cgc-pub-mcp
#                         runs as appuser 10001:999, and octocode then fails
#                         with "Permission denied (os error 13)" because it
#                         opens the project dir read-write. Unset = no chown.
#    CGC_BUILD_JSON       override build.json path
#    CGC_INDEX_REPOS      space-separated repo list, overrides build.json
#                         .runtime.octocode.index_repos (mirrors
#                         cloud-cgc-db-update.sh's CGC_INDEX_REPOS — same
#                         override, same variable name, for one mental model)
#    CGC_DB_IMAGE_PREFIX  default build.json .per_repo_publish.image_prefix
#                         (falls back to ghcr.io/diegonmarcos/cgc-db-)
#    CGC_DB_BASE_IMAGE    default build.json .per_repo_publish.base_image
#                         (falls back to ${CGC_DB_IMAGE_PREFIX}base:${CGC_DB_TAG})
#    CGC_DB_TAG           default build.json .per_repo_publish.tag (falls
#                         back to latest)
#    CGC_BOOTSTRAP_TOLERANT  when "1": a MISSING base image (nothing published
#                         to GHCR yet — the very first scheduled run before any
#                         cloud-cgc-db-package.sh seed) prints a ::warning:: and
#                         exits 0 instead of the hard ::error::/exit 1 below,
#                         BEFORE any target (host dir or CGC_DB_TARGET_VOLUME)
#                         is touched. Set by the cgc-db-index.yml restore-all
#                         job (CI cron path) so the very first scheduled run —
#                         before any base image has ever been seeded — goes
#                         green instead of red and blocking the graphrag phase
#                         behind it. Unset (default) keeps the hard error for
#                         the dagu/manual restore path, where a missing base
#                         really is an operator mistake to surface loudly.
#
#  A per-repo image (cloud-cgc-db-package-repo.sh) also carries that repo's
#  OWN top-level .cgc-manifest-*.json / .cgc-index-manifest.json — producer
#  change-gate bookkeeping, not consumer state. Copying N repo images into
#  one staging tree would otherwise clobber that file N-1 times (same path,
#  last repo wins) with no signal anything was lost, since the count check
#  below only looks at directories. This script's callers (the oci-apps DAG
#  and the compose db-restore profile) are pure query consumers that never
#  read those manifests — the producer keeps its OWN authoritative copy via
#  cloud-cgc-db-pull.sh's CGC_PULL_MERGE (one repo + base at a time, so there
#  is nothing to clobber there) — so this script deliberately DROPS them
#  after staging each repo rather than leave one arbitrary repo's stale
#  bookkeeping sitting in a home it does not describe.
#    MCP_CONTAINER, NTFY_URL   optional — stop-for-the-swap, then restart +
#                         notify after a successful restore, same
#                         optional/no-op-if-unset contract as
#                         cloud-cgc-db-restore.sh. The container stays UP for
#                         the pull/stage phases (the slow ones) and is down
#                         only across the volume swap. Kept HERE
#                         rather than in the DAG/compose caller, because
#                         both of those carry zero logic of their own.
#                         MCP_CONTAINER set also triggers a kg-store
#                         (SurrealDB) export/ingest refresh via `docker exec`
#                         (OCTOCODE_SKIP_INDEX=1 reindex.sh) for the repos
#                         this run staged — the fix for the pipeline split
#                         where SurrealDB used to go stale by construction.
#                         BOTH stores get refreshed, not just the one whose
#                         volume this run swapped: cloud-cgc-pub-mcp (8002,
#                         PUBLIC repos only) and cloud-cgc-pvt-mcp (8001, ALL
#                         staged repos). See the kg-store block near the end
#                         of the script for the busybox exec-env password
#                         remap this needs — a plain `docker exec` does NOT
#                         pick up the pub container's entrypoint-time
#                         KG_STORE_PASS_PUB remap, so it must be redone here.
#    CGC_PUB_CONTAINER,
#    CGC_PVT_CONTAINER   optional container-name overrides for that kg-store
#                         refresh (default: build.json .containers.app /
#                         .containers.pvt .container_name).
#
#  Requires: docker, jq on PATH. GHCR auth (if any image is private) is the
#  caller's responsibility, same as every other cgc-db consumer script here.
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# GHCR image-name component for a local repo name (repo names may carry upper case,
# a leading "_" or "-_", which docker refuses). Lower-cases, collapses separator runs,
# strips leading separators. Identity for every already-valid name.
cgc_image_name() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[._-]{2,}/-/g; s/^[._-]+//'; }


# build.json is read LAZILY, only for whichever of TAG/IMAGE_PREFIX/BASE_IMAGE/
# REPOS below the caller did NOT already supply via env. A deployed context
# with no repo checkout (the oci-apps DAG, the compose db-restore-multi
# service) supplies all four and never touches it — mirroring
# cloud-cgc-db-restore.sh's own env-first design ("the VM has no repo
# checkout"). A bare local invocation with none of those set still works
# exactly as before, resolving build.json from this script's own location.
BJ="${CGC_BUILD_JSON:-}"
need_bj() {
  [ -n "$BJ" ] && [ -f "$BJ" ] && return 0
  _root="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd || echo "")}"
  BJ="${_root:+$_root/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
  [ -n "$BJ" ] && [ -f "$BJ" ] && return 0
  echo "::error::cloud-cgc-pub-mcp build.json not found — needed because CGC_DB_TAG/CGC_DB_IMAGE_PREFIX/CGC_DB_BASE_IMAGE/CGC_INDEX_REPOS were not all supplied via env. Set CGC_BUILD_JSON, or supply every one of those (as the oci-apps DAG and the compose db-restore-multi service do)."
  exit 1
}

TARGET="${1:-${OCTOCODE_HOME:-$HOME/.local/share/octocode}}"
TAG="${CGC_DB_TAG:-}"
[ -n "$TAG" ] || { need_bj; TAG=$(jq -r '.per_repo_publish.tag // "latest"' "$BJ"); }
IMAGE_PREFIX="${CGC_DB_IMAGE_PREFIX:-}"
[ -n "$IMAGE_PREFIX" ] || { need_bj; IMAGE_PREFIX=$(jq -r '.per_repo_publish.image_prefix // "ghcr.io/diegonmarcos/cgc-db-"' "$BJ"); }
BASE_IMAGE="${CGC_DB_BASE_IMAGE:-}"
if [ -z "$BASE_IMAGE" ]; then
  need_bj
  BASE_IMAGE=$(jq -r '.per_repo_publish.base_image // empty' "$BJ")
fi
[ -n "$BASE_IMAGE" ] || BASE_IMAGE="${IMAGE_PREFIX}base:${TAG}"

if [ -n "${CGC_INDEX_REPOS:-}" ]; then
  REPOS="$CGC_INDEX_REPOS"
else
  need_bj
  REPOS=$(jq -r '.runtime.octocode.index_repos[]' "$BJ")
fi
[ -n "$REPOS" ] || { echo "::error::no repos to restore — empty .runtime.octocode.index_repos and CGC_INDEX_REPOS unset"; exit 1; }
# PUBLIC/PRIVATE SPLIT — a private repo's DB must never land in the volume the
# PUBLIC MCP mounts. Two guards exist and only one of them is visible:
#
#   1. Structural: oci-apps carries NO ghcr.io credentials ("auths": {} in its
#      ~/.docker/config.json) and pulls anonymously, so a package that really is
#      private cannot be fetched there at all. Genuine, but implicit — a single
#      `docker login` on that box silently retires it with nothing to notice.
#   2. This filter: declared in build.json, greppable, credential-independent.
#
# Deliberately applied to CGC_INDEX_REPOS as well as the build.json list. The
# manual/DAG path passes an explicit repo list, and that is precisely the path
# most likely to be handed "all 8" by a human who has lost track of which are
# private — this run of the restore was handed exactly that.
#
# cloud-cgc-pvt-mcp opts in with CGC_INCLUDE_PRIVATE=1, which MUST be paired
# with its own CGC_DB_TARGET_VOLUME — never the public one.
if [ "${CGC_INCLUDE_PRIVATE:-0}" = "1" ]; then
  # Enforced, not merely documented. Until now the "never the public one" pairing
  # above was a comment, and a comment does not stop `CGC_INCLUDE_PRIVATE=1` from
  # being set on the PUBLIC restore service — one copy-paste and every private
  # repo's DB lands in the volume the internet-facing MCP reads. The whole
  # public/private split is "the private DBs are not in that volume", so this is
  # the one invariant the split rests on; it gets a check, not a comment.
  #
  # Resolved from build.json when the caller did not name it, because the
  # container that runs this has no checkout and the env is all it has. If we
  # cannot determine the public volume name we refuse as well: an unverifiable
  # target is exactly the case where failing open loses the private repos.
  _pub_vol="${CGC_PUBLIC_DB_VOLUME:-}"
  if [ -z "$_pub_vol" ]; then
    # Same resolution the rest of the script uses (need_bj), but deliberately
    # non-fatal: when build.json is unreachable we refuse with the specific
    # message below rather than need_bj's generic "build.json not found".
    _ibj="${BJ:-}"
    if [ -z "$_ibj" ] || [ ! -f "$_ibj" ]; then
      _iroot="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd || echo "")}"
      _ibj="${_iroot:+$_iroot/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
    fi
    [ -n "$_ibj" ] && [ -f "$_ibj" ] \
      && _pub_vol=$(jq -r '.runtime.octocode.db_volume // empty' "$_ibj" 2>/dev/null)
  fi
  _eff_target="${CGC_DB_TARGET_VOLUME:-}"
  if [ -z "$_eff_target" ]; then
    echo "::error::[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 requires an explicit CGC_DB_TARGET_VOLUME (the private volume). Refusing to write private repo DBs to the default target '$TARGET'."
    exit 1
  fi
  if [ -z "$_pub_vol" ]; then
    echo "::error::[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 but the PUBLIC volume name is unknown (set CGC_PUBLIC_DB_VOLUME or make build.json readable) — cannot prove '$_eff_target' is not the public volume. Refusing."
    exit 1
  fi
  if [ "$_eff_target" = "$_pub_vol" ]; then
    echo "::error::[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 with CGC_DB_TARGET_VOLUME='$_eff_target', which IS the public volume. That would put every private repo's DB in the volume the public MCP serves. Refusing."
    exit 1
  fi
  echo "[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 — private repos NOT filtered (target $_eff_target, public volume $_pub_vol untouched)"
else
  PRIVATE_REPOS="${CGC_PRIVATE_REPOS:-}"
  # Resolved independently of need_bj: that one only runs when the caller left
  # REPOS unset, so relying on it would silently disable this filter on exactly
  # the callers that pass an explicit repo list. A security control must not
  # fail open because of an unrelated lazy-load path.
  if [ -z "$PRIVATE_REPOS" ]; then
    _pbj="${BJ:-}"
    if [ -z "$_pbj" ] || [ ! -f "$_pbj" ]; then
      _proot="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd)}"
      _pbj="${_proot:+$_proot/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
    fi
    [ -n "$_pbj" ] && [ -f "$_pbj" ] \
      && PRIVATE_REPOS=$(jq -r '.runtime.octocode.private_repos[]?' "$_pbj" 2>/dev/null)
  fi
  # Fail LOUD, not silent. A deployed context legitimately has no build.json
  # (that is why compose passes CGC_PRIVATE_REPOS), so this cannot hard-error
  # without breaking the box — but an unfiltered restore into a public volume
  # must never pass unremarked.
  if [ -z "$PRIVATE_REPOS" ]; then
    echo "::warning::[cgc-db-restore-all] no private-repo list available (CGC_PRIVATE_REPOS unset and build.json unreadable) — restoring UNFILTERED; if this volume is served by the public MCP, confirm no private repo landed in it"
  fi
  if [ -n "$PRIVATE_REPOS" ]; then
    _kept=""
    for _r in $REPOS; do
      _skip=0
      for _p in $PRIVATE_REPOS; do
        [ "$_r" = "$_p" ] && { _skip=1; break; }
      done
      if [ "$_skip" = 1 ]; then
        echo "[cgc-db-restore-all] skipping PRIVATE repo $_r — not for the public volume"
      else
        _kept="$_kept $_r"
      fi
    done
    REPOS="${_kept# }"
    [ -n "$REPOS" ] || { echo "::error::[cgc-db-restore-all] every requested repo is private and CGC_INCLUDE_PRIVATE is not set — nothing to restore"; exit 1; }
  fi
fi

set -- $REPOS
TOTAL=$#

# STAGING LIVES OFF /tmp, DELIBERATELY — the box reaps /tmp by atime.
# oci-apps runs a disk watchdog (declared in
# b_infra/_shared/vm-pilot/src/modules/protection/watchdog.nix, installed as
# /opt/scripts/disk-watchdog.sh, timer every 5 minutes) whose WARN branch, at
# 85% root usage, runs `find /tmp -type f -atime +2 -delete` and the same for
# /var/tmp, BEFORE it prunes docker. Staging the whole multi-repo home is about
# 8GB, which by itself takes that box from 76% past 85% — so the restore
# triggers the branch that eats its own staging tree. And `docker cp` restores
# each file's timestamps from the image, so every staged file lands with an
# atime days old: measured 2026-09-15, 668 of 668 files of a freshly staged
# image matched the watchdog's own `-atime +2` predicate. The watchdog then
# deleted data fragments while this script still held the tree, leaving the
# newest manifest — just read, hence recently accessed, hence spared — naming
# fragments that no longer existed.
#
# That is what the integrity gate below kept refusing: images that are clean on
# GHCR and clean when staged alone on that same box, yet torn once staged in
# full (runs 34950604736 and 35013346878, 13 tables, same list both times).
# Staging where nothing reaps is the fix; relaxing the gate would only have
# shipped the half-deleted tree to every agent.
STAGING_PARENT="${CGC_DB_STAGING_PARENT:-${HOME:-}/.cache}"
mkdir -p "$STAGING_PARENT" 2>/dev/null || true
[ -d "$STAGING_PARENT" ] && [ -w "$STAGING_PARENT" ] || {
  echo "::error::[cgc-db-restore-all] staging parent '$STAGING_PARENT' is not a writable directory (HOME unset?)."
  echo "::error::[cgc-db-restore-all] set CGC_DB_STAGING_PARENT to a writable path that no tmp reaper touches — staging under /tmp is what tore every restore since 2026-09-12."
  exit 1
}
STAGING=$(mktemp -d "$STAGING_PARENT/cgc-db-staging.XXXXXX")
CURRENT_CID=""
# The transport image being staged right now. Each image is rmi'd right after its
# stage, but a stage that FAILS exits through this trap instead, and the image used
# to stay behind: run 38466635519 died of ENOSPC staging cgc-db-cloud-u-containers
# and left that 4.4G image on a box with 6G free, so every retry started out even
# shorter of disk than the run that failed (#988).
CURRENT_IMG=""
cleanup() {
  [ -n "$CURRENT_CID" ] && docker rm -f "$CURRENT_CID" >/dev/null 2>&1
  CURRENT_CID=""
  [ -n "$CURRENT_IMG" ] && docker rmi "$CURRENT_IMG" >/dev/null 2>&1
  CURRENT_IMG=""
  if [ -n "${STAGING:-}" ] && [ -d "$STAGING" ]; then
    rm -rf "$STAGING" 2>/dev/null
    # A file the host user cannot unlink (uid from an image layer) must not
    # leave a multi-GB orphan behind: retry as root in a throwaway container.
    if [ -d "$STAGING" ]; then
      docker run --rm -v "$STAGING_PARENT:/p" busybox rm -rf "/p/$(basename "$STAGING")" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}
# EXIT alone is not enough: POSIX sh does NOT run the EXIT trap when the job is
# killed by a signal (GHA cancel / timeout sends SIGTERM over the SSH session).
# Each such kill left a 1-4GB cgc-db-staging.* orphan in ~/.cache — 11GB of them
# on oci-apps by 2026-10-17. Trap the signals, clean up, and exit non-zero.
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT
trap 'cleanup; trap - EXIT; exit 143' TERM
trap 'cleanup; trap - EXIT; exit 129' HUP

# Sweep orphans of earlier runs that died before any trap could fire (SIGKILL,
# VM reset). Only siblings older than a day, and only when no process has them
# as cwd or holds a file in them, so a concurrent run's staging is never hit.
for _old in "$STAGING_PARENT"/cgc-db-staging.*; do
  [ -d "$_old" ] && [ "$_old" != "$STAGING" ] || continue
  [ -n "$(find "$_old" -maxdepth 0 -mmin +1440 2>/dev/null)" ] || continue
  _held=0
  for _l in /proc/[0-9]*/cwd /proc/[0-9]*/fd/*; do
    case "$(readlink "$_l" 2>/dev/null)" in "$_old"|"$_old"/*) _held=1; break;; esac
  done
  [ "$_held" = 0 ] || continue
  echo "[cgc-db-restore-all] removing stale staging orphan $_old ($(du -sh "$_old" 2>/dev/null | cut -f1))"
  rm -rf "$_old" 2>/dev/null || docker run --rm -v "$STAGING_PARENT:/p" busybox rm -rf "/p/$(basename "$_old")" >/dev/null 2>&1 || true
done

# Extract one already-pulled image's /octocode-db/. into STAGING. Always
# removes the throwaway container (including on a failed `docker cp`, via
# CURRENT_CID + the EXIT trap above); the transport image is the caller's
# call (base: drop once after staging; repo: drop after every pull — see
# the loop below and the header comment on why that matters here).
# VERBATIM copies of cloud-cgc-db-update.sh's lance_newest_manifest() and
# lance_prune_old_versions() (this file runs standalone on the box, so it cannot
# source them); cgc-db-lance-prune.test.sh asserts both copies are byte-identical.
# Pruning superseded manifests right after each image is staged is what keeps the
# staging tree -- and so the box's free disk -- bounded: run 37146011415 died with
# "no space left on device" staging cloud-u-containers, whose file_metadata.lance
# carried 3.0G of old manifests against 35M of data.
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

stage_image() { # $1 = image ref
  CURRENT_CID=$(docker create --platform linux/amd64 "$1")
  docker cp "$CURRENT_CID:/octocode-db/." "$STAGING/"
  docker rm -f "$CURRENT_CID" >/dev/null 2>&1 || true
  CURRENT_CID=""
}

# Directories in STAGING that hold PROJECT data — everything except the
# base-mode root-state entries. Deliberately the SAME exclusion set as
# cloud-cgc-db-package.sh's find_project_dir(); keep the two in sync.
count_project_dirs() {
  _n=0
  for _e in "$STAGING"/*/; do
    [ -d "$_e" ] || continue
    case "${_e%/}" in
      */fastembed | */sentencetransformer) continue ;;
    esac
    _n=$((_n + 1))
  done
  echo "$_n"
}

# ── 1) base image — hard error: no base means nothing to restore onto ─────
#    EXCEPT under CGC_BOOTSTRAP_TOLERANT=1 (see header): the very first
#    scheduled run before any base has ever been seeded is not an operator
#    error, it is bootstrap — warn and exit 0 BEFORE touching TARGET at all.
echo "[cgc-db-restore-all] base: $BASE_IMAGE"
# Keep the probe's stderr. It used to be thrown away with `2>&1 >/dev/null`, so
# EVERY failure mode — DNS, auth, TLS, rate limit, genuinely-absent image — printed
# the same "not found on GHCR", which sent us seeding an image that already existed.
# The real message on 2026-08-22 was `lookup ghcr.io on 127.0.0.11:53: i/o timeout`:
# a compose-bridge DNS fault, not a missing image (see compose.nix network_mode).
_base_err=$(docker manifest inspect "$BASE_IMAGE" 2>&1 >/dev/null) || {
  if [ "${CGC_BOOTSTRAP_TOLERANT:-}" = "1" ]; then
    echo "::warning::[cgc-db-restore-all] base image $BASE_IMAGE not readable on GHCR — bootstrap: nothing to propagate yet"
    echo "::warning::[cgc-db-restore-all] docker said: ${_base_err:-<no output>}"
    exit 0
  fi
  echo "::error::[cgc-db-restore-all] base image $BASE_IMAGE not readable on GHCR."
  echo "::error::[cgc-db-restore-all] docker said: ${_base_err:-<no output>}"
  echo "::error::[cgc-db-restore-all] if that is a DNS/network error the image is probably fine — check egress before re-seeding."
  echo "::error::[cgc-db-restore-all] otherwise seed it once from an existing octocode home's root state: sh $HERE/cloud-cgc-db-package.sh <octocode-home-dir> $BASE_IMAGE latest"
  exit 1
}
CURRENT_IMG="$BASE_IMAGE"
docker pull -q --platform linux/amd64 "$BASE_IMAGE" >/dev/null
stage_image "$BASE_IMAGE"
docker rmi "$BASE_IMAGE" >/dev/null 2>&1 || true
CURRENT_IMG=""
lance_prune_old_versions "$STAGING"
lance_gc_unreferenced_data "$STAGING"
echo "[cgc-db-restore-all] base staged"

# The base image's config.toml is whatever the phase that seeded it happened to
# have, and the SEMANTIC phase writes `[graphrag] enabled = false` (it skips
# graph building on purpose). That flag then rides into every consumer volume,
# which is why the box carried 45MB of graphrag_nodes.lance +
# graphrag_relationships.lance and still answered every graphrag call with
# "GraphRAG is not enabled in your configuration".
#
# A consumer is a READ-ONLY query surface: it never builds a graph, it only
# reads tables that already shipped, so `enabled` here means nothing more than
# "may I read what is present" and must be true. `use_llm` is deliberately NOT
# touched — that controls query-time LLM calls and would need a key on the box.
# Scoped by section so the identical `enabled = false` lines under
# [search.reranker] / [search.hybrid] / [graphrag.llm] are left alone.
if [ -f "$STAGING/config.toml" ]; then
  awk '
    /^\[/ { sec = $0 }
    sec == "[graphrag]" && /^enabled[[:space:]]*=[[:space:]]*false/ { print "enabled = true"; next }
    { print }
  ' "$STAGING/config.toml" > "$STAGING/config.toml.new" \
    && mv "$STAGING/config.toml.new" "$STAGING/config.toml" \
    && echo "[cgc-db-restore-all] graphrag reads enabled in consumer config.toml"
fi

# ── 2) each repo image — bootstrap tolerance: missing = warn + continue ────
FOUND=0
MISSING=""
# Repos actually staged this run — data-driven input to the kg-store
# (SurrealDB) export/ingest hook below; never a hardcoded list.
STAGED_REPOS=""
# "<project_dir> <repo>" per line, and the dirs already attributed. See the
# attribution block at the end of the loop below.
PROJECT_OF=""
SEEN_PROJECT_DIRS=" "
for r in "$@"; do
  img="${IMAGE_PREFIX}$(cgc_image_name "$r"):${TAG}"
  if ! docker manifest inspect "$img" >/dev/null 2>&1; then
    echo "::warning::[cgc-db-restore-all] $img not published yet — skipping $r (bootstrap tolerance)"
    MISSING="$MISSING $r"
    continue
  fi
  CURRENT_IMG="$img"
  docker pull -q --platform linux/amd64 "$img" >/dev/null
  # Name the exact bytes staged. The integrity gate below has refused trees whose
  # every image passes the identical check on GHCR's own layer bytes, and a tag
  # alone cannot tell "the box staged a different image" from "the box staged the
  # same image differently". The digest can.
  _digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "digest-unknown")
  stage_image "$img"
  # Drop this repo's own change-gate manifest (see header) — it would silently
  # clobber the next repo's at the same path otherwise, and neither consumer
  # wired to this script reads it.
  rm -f "$STAGING"/.cgc-manifest-*.json "$STAGING"/.cgc-index-manifest.json 2>/dev/null || true
  docker rmi "$img" >/dev/null 2>&1 || true
  CURRENT_IMG=""
  lance_prune_old_versions "$STAGING"
  lance_gc_unreferenced_data "$STAGING"
  echo "[cgc-db-restore-all] after $r: staging $(du -sh "$STAGING" 2>/dev/null | cut -f1), free $(df -h "$STAGING_PARENT" 2>/dev/null | awk 'NR==2{print $4}')"
  FOUND=$((FOUND + 1))
  STAGED_REPOS="$STAGED_REPOS $r"
  # Which project dir did THIS image carry? octocode keys a project on
  # sha256(origin URL), so the dir name says nothing a human can act on. Every
  # image holds exactly one project, so the dir that is present after staging and
  # was not present before belongs to $r. Recorded here — and nowhere else — so
  # the content gate below can name the REPO an operator has to fix rather than a
  # 64-char project id. Built by observation, never a hardcoded table.
  for _po_d in "$STAGING"/*/; do
    [ -d "$_po_d" ] || continue
    _po_b=${_po_d%/}; _po_b=${_po_b##*/}
    case "$_po_b" in fastembed | sentencetransformer) continue ;; esac
    case "$SEEN_PROJECT_DIRS" in *" $_po_b "*) continue ;; esac
    SEEN_PROJECT_DIRS="$SEEN_PROJECT_DIRS$_po_b "
    PROJECT_OF="$PROJECT_OF$_po_b $r
"
  done
  echo "[cgc-db-restore-all] staged $r ($FOUND/$TOTAL) $_digest"
done

# INTEGRITY GATE ON THE STAGED TREE (fail closed) -- see cgc-db-lance-integrity.test.sh.
#
# The swap below is `rm -rf /dst/*` followed by `cp -a`: it DESTROYS the volume the
# consumer is serving before it writes the replacement. Counting project dirs proves
# the right NUMBER of repos arrived; it says nothing about whether they are READABLE.
# On 2026-09-11 that gap was load-bearing: every per-repo image on GHCR carried a
# code_blocks.lance with 11515 manifests over a data/ holding ONE fragment that no
# manifest named, and this script faithfully wiped a volume and copied that in --
# then reported success, restarted the MCP, and every octocode query died with
# `lance error: Not found` while the run stayed green.
#
# So: a torn STAGING must never be allowed to overwrite a live volume. The prior
# volume is the better artifact and is left exactly where it is. This mirrors the
# publish gate in cloud-cgc-db-update.sh's checkpoint_publish() -- torn is refused at
# BOTH ends of the pipe, so a bad image can neither reach GHCR nor leave it.
#
# The function below is a VERBATIM copy of cloud-cgc-db-update.sh's. It cannot be
# sourced: this file is `cat`-ed whole onto the box and run standalone, so it has to
# be self-contained. cgc-db-lance-integrity.test.sh extracts BOTH copies and asserts
# they are byte-identical, because a re-implementation that drifts is precisely how
# cgc-db-gate.test.sh passed while the path it mirrored was wrong.
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

_staging_torn=$(lance_dangling_tables "$STAGING")
if [ -n "$_staging_torn" ]; then
  echo "::error::[cgc-db-restore-all] refusing to swap into $TARGET -- dangling lance manifest(s) in the STAGED tree:"
  # One line per table carrying what the verdict was computed from: the manifest
  # read, the fragment names it yielded, and what data/ actually holds. The caller
  # only surfaces the tail of this log, so the evidence has to fit on these lines;
  # without it a refusal on the box cannot be compared with the same image's bytes.
  printf '%s\n' "$_staging_torn" | while IFS= read -r _torn_table; do
    _torn_manifest=$(lance_newest_manifest "$_torn_table")
    _torn_references=$(lance_live_refs "$_torn_table/_versions/$_torn_manifest" | tr '\n' ' ' || true)
    echo "::error::[cgc-db-restore-all]   ${_torn_table#"$STAGING"/} newest=$_torn_manifest versions=$(ls "$_torn_table/_versions" 2>/dev/null | wc -l) data=$(ls "$_torn_table/data" 2>/dev/null | wc -l) references=[$_torn_references] data_sample=[$(ls "$_torn_table/data" 2>/dev/null | head -3 | tr '\n' ' ')]"
  done
  echo "::error::[cgc-db-restore-all] a manifest naming an absent fragment is unreadable forever. The volume currently being served is left untouched; fix the GHCR image (cgc-db-update.sh self-heals a torn checkpoint by re-indexing that repo from base) and re-run."
  exit 1
fi
echo "[cgc-db-restore-all] lance integrity OK -- no dangling manifests in the staged tree"

# ZERO-CONTENT GATE ON THE STAGED TREE (fail closed) -- see cgc-db-zero-content.test.sh.
#
# The two checks above ask "is it READABLE?" and "did the right NUMBER of repos
# arrive?". Neither asks the only question a consumer cares about: does this repo
# actually HOLD anything? A project dir can be present, structurally perfect and
# completely empty, and every check upstream of here passes it.
#
# That is not hypothetical, it is ticket #352. octocode had no Kotlin grammar, so
# every .kt file was dropped at the file walk and cloud-u-android shipped a
# populated-looking store that answered for a fraction of its own tree. The same
# shape reached the box as "Indexing complete! 0 of 0 files processed" publishing a
# 4.0GB checkpoint. Nothing anywhere said "not indexed" -- and THAT is the defect.
# octocode answers a query against an empty store with twenty confident rows of
# whatever else is in the volume at noise-floor similarity, so a blind repo is
# indistinguishable from a working one at the query surface. #352 sat for days
# against acceptance queries that could not pass, because the pipeline was green
# every single time.
#
# So an expected repo that staged NOTHING is refused here, before the swap, in the
# same fail-closed posture as the integrity gate: the previously-served volume is a
# better artifact than a confidently empty one.
#
# GRANULARITY, stated plainly so nobody mistakes this for more than it is: the unit
# is the REPO, because the repo is the unit octocode stores and the unit
# index_repos declares. A repo that indexed most of itself but is blind to one
# SUBTREE -- aa_cloud-superapp inside cloud-u-android, which is exactly what #352's
# acceptance queries chase -- still has content and still passes. Catching that
# needs a declared per-subtree expectation and a real read of the content rows,
# which is a different check with a different data source.
# ponytail: repo-granular by design; per-subtree coverage needs its own declared
# expectations, add it when a subtree regression actually costs a day.

# octocode's three content stores, one per search mode (code / text / docs) -- the
# same modes the MCP exposes. A project with no fragment in ANY of them has no
# retrievable content at all. All-three-empty, not any-empty, so a repo that
# legitimately carries only docs or only code is not failed for it.
CGC_CONTENT_TABLES="code_blocks text_blocks document_blocks"

zero_content_projects() { # $1 = octocode home -> stdout: one contentless project dir per line
  _zcp_home="$1"
  for _zcp_p in "$_zcp_home"/*/; do
    [ -d "$_zcp_p" ] || continue
    # Same exclusion set as count_project_dirs()/find_project_dir(): root state,
    # never project data. These two legitimately hold no content tables.
    case "${_zcp_p%/}" in */fastembed | */sentencetransformer) continue ;; esac
    _zcp_found=0
    for _zcp_t in $CGC_CONTENT_TABLES; do
      for _zcp_f in "${_zcp_p}storage/${_zcp_t}.lance"/data/*.lance; do
        # An absent table or an empty data/ leaves the glob unexpanded, so the
        # -e test is what distinguishes "no rows" from "one row". Fail closed:
        # anything we cannot positively see content in counts as no content.
        [ -e "$_zcp_f" ] || continue
        _zcp_found=1
        break
      done
      if [ "$_zcp_found" = 1 ]; then break; fi
    done
    if [ "$_zcp_found" = 0 ]; then printf '%s\n' "${_zcp_p%/}"; fi
  done
  :
}

_staging_blind=$(zero_content_projects "$STAGING")
if [ -n "$_staging_blind" ]; then
  echo "::error::[cgc-db-restore-all] refusing to swap into $TARGET -- staged repo(s) hold ZERO indexed content:"
  printf '%s\n' "$_staging_blind" | while IFS= read -r _blind_dir; do
    _blind_id=${_blind_dir##*/}
    # Name the repo, not the sha256. Falls back to the id itself rather than
    # printing an empty field if attribution somehow missed this dir.
    _blind_repo=$(printf '%s' "$PROJECT_OF" | awk -v d="$_blind_id" '$1 == d { print $2; exit }')
    echo "::error::[cgc-db-restore-all]   ${_blind_repo:-$_blind_id} (project $_blind_id) code_blocks=$(ls "$_blind_dir/storage/code_blocks.lance/data" 2>/dev/null | wc -l) text_blocks=$(ls "$_blind_dir/storage/text_blocks.lance/data" 2>/dev/null | wc -l) document_blocks=$(ls "$_blind_dir/storage/document_blocks.lance/data" 2>/dev/null | wc -l) fragments"
  done
  echo "::error::[cgc-db-restore-all] a repo with no content blocks is INVISIBLE to every query, and octocode will still answer those queries with twenty unrelated rows instead of saying so. Serving this would be worse than serving the older volume, which is left untouched. Check that repo's index job: an extension octocode has no grammar for (build.json .runtime.octocode.file_associations), a .noindex that swallowed the tree, or an index that reported '0 of 0 files processed'. A new file association needs ONE forced run (workflow input force=true) -- the incremental gate can never apply it on its own."
  exit 1
fi
echo "[cgc-db-restore-all] content OK -- every staged repo holds indexed content blocks"

# ── 3) verify before TARGET is touched at all ───────────────────────────────
STAGED=$(count_project_dirs)
if [ "$STAGED" -ne "$FOUND" ]; then
  echo "::error::[cgc-db-restore-all] staged project-dir count ($STAGED) != repo images pulled ($FOUND) — refusing to swap into $TARGET"
  echo "::error::[cgc-db-restore-all] a name collision between two repo images (cp -a silently merging two different <project_id>/ dirs), or a malformed image, produces exactly this mismatch"
  exit 1
fi
if [ -n "$MISSING" ]; then
  echo "[cgc-db-restore-all] verified: $FOUND/$TOTAL repos staged (missing:$MISSING)"
else
  echo "[cgc-db-restore-all] verified: $FOUND/$TOTAL repos staged"
fi

# Down ONLY for the swap. Sections 1-3 pull every image and assemble the whole
# tree in $STAGING with the consumer still serving from the old volume, and that
# is the part that takes ~50 min. Stopping the container for the entire restore
# (which the GHA propagation step used to do, from the outside) turns a scheduled
# refresh into a 50-minute outage to save a swap that takes seconds.
#
# The restart is NOT done here: the MCP_CONTAINER block at the end of this file
# already runs `docker restart`, which starts a stopped container. Restarting
# rather than starting is also what the consumer needs — octocode caches open
# LanceDB handles, so a container that merely kept running through the swap
# would serve from unlinked inodes.
if [ -n "${MCP_CONTAINER:-}" ]; then
  docker stop "$MCP_CONTAINER" >/dev/null 2>&1 \
    && echo "[cgc-db-restore-all] stopped $MCP_CONTAINER for the swap" \
    || echo "[cgc-db-restore-all] WARN stop $MCP_CONTAINER failed (continuing)"
fi

# ── 4) swap: everything fallible already happened in STAGING ───────────────
if [ -n "${CGC_DB_TARGET_VOLUME:-}" ]; then
  # Container-mediated write — see CGC_DB_TARGET_VOLUME in the header. busybox
  # is always pullable; -v NAME:/dst auto-creates the volume if it somehow
  # doesn't exist yet, matching plain `docker run -v name:...` behaviour.
  # chmod 0755 AFTER the cp is load-bearing, not tidiness. `cp -a /src/. /dst/`
  # stamps the SOURCE directory's mode and owner onto /dst, and $STAGING comes
  # from `mktemp -d`, which is 0700 owned by whoever ran this (uid 1001 over the
  # oci-apps SSH path). The app container runs as a different uid (10001), so the
  # volume root came back 0700 1001:1001 and octocode could not even traverse in:
  # every tool call died with "Permission denied (os error 13)" while every child
  # dir sat there readable at 0755. Consumers mount this volume read-only as an
  # unrelated uid, so the root has to be world-traversable.
  # THE SWAP MUST BE ABLE TO FAIL. This ran as `sh -c '...; :'` until 2026-09-16:
  # no `set -e`, and a trailing `:` that pinned the busybox shell's exit status at 0
  # no matter what happened inside it. So a `cp -a` that died part-way -- ENOSPC is
  # the live risk, not a hypothetical: the comment on STAGING_PARENT above measured
  # this same staging tree at ~8GB taking the box from 76% past 85% -- let chmod and
  # chown run over the half-written tree and still returned 0. `docker run` returned
  # 0, the outer `set -eu` never fired, and the script printed "restored N repo(s)"
  # over a volume whose lance manifests name fragments that were never copied, with
  # `rm -rf /dst/*` having already destroyed the good copy. That is the torn store an
  # agent hits hours later with a green run id behind it -- the restore reporting
  # success over its own failure is the defect, not the copy dying.
  #
  # The `:` was masking something real: `[ -n "$CGC_DB_OWNER" ] && chown ...` exits 1
  # when CGC_DB_OWNER is empty, and as the LAST command that became the shell's
  # status. Masking it hid every other failure too. The fix is the explicit `if` --
  # exactly what the comment at the bottom of this file already prescribes for the
  # identical trailing-`&&`-status trap it diagnosed on 2026-09-07. Never a `:`.
  #
  # PARITY is the post-swap half the integrity gate structurally cannot cover: that
  # gate proves STAGING is lance-clean BEFORE the swap and nothing ever re-read what
  # actually landed. Comparing file counts on both sides, inside the same container,
  # is what turns "a fragment is missing from the volume" from something an agent
  # discovers hours later into something this run refuses. Counts only, deliberately:
  # `du` block totals differ legitimately between a fresh dir and one that just had
  # thousands of entries unlinked, and a verification that false-positives would take
  # the index down for a healthy restore.
  docker run --rm -e CGC_DB_OWNER="${CGC_DB_OWNER:-}" \
    -v "$CGC_DB_TARGET_VOLUME:/dst" -v "$STAGING:/src:ro" busybox \
    sh -ec 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null || true
            cp -a /src/. /dst/
            chmod 0755 /dst
            if [ -n "$CGC_DB_OWNER" ]; then chown -R "$CGC_DB_OWNER" /dst; fi
            _src_n=$(find /src -type f | wc -l)
            _dst_n=$(find /dst -type f | wc -l)
            if [ "$_src_n" -ne "$_dst_n" ]; then
              echo "swap wrote an INCOMPLETE tree: staged=$_src_n files, volume=$_dst_n files" >&2
              exit 1
            fi
            echo "[cgc-db-restore-all] swap parity OK: $_dst_n files in the volume"' || {
    echo "::error::[cgc-db-restore-all] the swap into volume $CGC_DB_TARGET_VOLUME FAILED (busybox rc above). That volume is now INCOMPLETE and must not be served -- the old contents were already removed, so there is nothing to roll back to."
    echo "::error::[cgc-db-restore-all] the overwhelmingly likely cause is the box running out of disk mid-copy; staging alone is $(du -sh "$STAGING" 2>/dev/null | cut -f1). Free space and re-run: every per-repo image is still on GHCR and staging is fully re-pullable."
    exit 1
  }
  echo "[cgc-db-restore-all] restored $FOUND repo(s) + base into volume $CGC_DB_TARGET_VOLUME"
else
  mkdir -p "$TARGET"
  rm -rf "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null || true
  cp -a "$STAGING"/. "$TARGET"/
  # Same reason as the volume branch above: cp -a copies mktemp -d's 0700 onto
  # TARGET, which locks out any consumer running as a different uid.
  chmod 0755 "$TARGET"
  # Explicit if, never `[ ... ] && chown ...` -- see the volume branch.
  if [ -n "${CGC_DB_OWNER:-}" ]; then chown -R "$CGC_DB_OWNER" "$TARGET" 2>/dev/null || true; fi
  # Same post-swap parity check as the volume branch. `cp -a` here is under the
  # outer `set -e` so a reported failure already aborts, but "cp returned 0 and the
  # tree is still short" is the case neither `set -e` nor the pre-swap gate can see.
  _src_n=$(find "$STAGING" -type f | wc -l)
  _dst_n=$(find "$TARGET" -type f | wc -l)
  if [ "$_src_n" -ne "$_dst_n" ]; then
    echo "::error::[cgc-db-restore-all] swap wrote an INCOMPLETE tree into $TARGET: staged=$_src_n files, target=$_dst_n files. That target must not be served; free disk and re-run."
    exit 1
  fi
  echo "[cgc-db-restore-all] swap parity OK: $_dst_n files in $TARGET"
  echo "[cgc-db-restore-all] restored $FOUND repo(s) + base into $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
fi

# ── optional: restart + notify (mirrors cloud-cgc-db-restore.sh; kept here
# because the DAG and the compose caller both carry zero logic of their own)
CONTAINER="${MCP_CONTAINER:-}"
NTFY="${NTFY_URL:-}"
if [ -n "$CONTAINER" ]; then
  # Bring the MCP back up on the swapped volume, then VERIFY it is actually
  # running before trusting it. `docker restart` only works on a container that
  # still EXISTS; if a concurrent op removed it (observed 2026-09-03: restart
  # failed, container gone, and because the kg-store refresh below was gated on
  # THIS restart's exit, the SurrealDB ingest was skipped — 8001/8002 kept STALE
  # data while the run went green and the MCP stayed DOWN). So: restart, else
  # start, then gate the refresh on the container being RUNNING — not on which
  # command brought it up.
  #
  # 2026-09-07: one shot at restart/start, with BOTH stderrs sent to /dev/null,
  # was not enough and left nothing to diagnose. Run 34093679038 (graphrag/pub)
  # staged all 6 repos, swapped the volume, then failed here — and the only
  # thing the log could say was "likely removed by a concurrent op", which was
  # wrong: Ship's Deploy job waited correctly on the ship-wg-runner group and
  # did not start until 09:57:09, two seconds AFTER this job had already given
  # up. The container was not removed; it just would not come back on the first
  # try (a stop→start inside a few seconds races the port release, which
  # userland-proxy made likelier), and the swallowed stderr is why that took a
  # log dive to establish rather than being on the line above.
  #
  # So: keep the real error, retry over ~40 s, and if it still will not come up,
  # do the compose recovery this script's own failure message tells a human to
  # run instead of just printing it. A restore that has already staged and
  # swapped everything correctly should not end with the MCP down and the
  # kg-store stale because docker needed one more second.
  mcp_up() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
  bring_up() {
    _c="$1"; _err=""
    _i=0
    while [ "$_i" -lt 8 ]; do
      _i=$((_i + 1))
      _err=$(docker restart "$_c" 2>&1 >/dev/null) || \
        _err="$_err; $(docker start "$_c" 2>&1 >/dev/null)"
      # Explicit if, not `mcp_up && { ...; return 0; }`: in that form a false
      # inner test makes the group's status false and the `return 0` never
      # runs. That short-circuit is exactly the bug this script's exit status
      # had at the bottom of the file; not repeating it here.
      if mcp_up "$_c"; then
        if [ "$_i" -gt 1 ]; then
          echo "[cgc-db-restore-all] $_c came up on attempt $_i"
        fi
        return 0
      fi
      echo "[cgc-db-restore-all] WARN $_c not up (attempt $_i/8): ${_err:-no error text}"
      sleep 5
    done
    # Last resort: the container may genuinely be gone (removed by a concurrent
    # op — the 2026-09-03 case). A second, routine way to reach "No such
    # container" is the box's own disk watchdog: its WARN branch at 85% root
    # usage runs `docker container prune -f`
    # (b_infra/_shared/vm-pilot/src/modules/protection/watchdog.nix), the swap
    # above deliberately leaves $MCP_CONTAINER STOPPED, and a stopped container
    # is exactly what that prune removes. Staging this tree is measured to take
    # oci-apps from 76% past 85%, so the restore itself arms the watchdog that
    # then deletes the container it is about to restart.
    # compose recreates it; `|| true` because a missing compose dir must not
    # mask the real report below.
    #
    # THE COMPOSE PROJECT NAME IS LOAD-BEARING. Ship deploys these containers as
    # `cd $DEPLOY_PATH && docker compose -f compose/docker-compose.yml --project-directory . up -d`
    # (cloud-ship-container-step-deploy-compose.sh), so every container and
    # volume is recorded under project basename($DEPLOY_PATH) — for this
    # deployment, "cloud-cgc-pub-mcp". Recreating with `cd .../compose && docker
    # compose ...` instead names the project "compose", and under a foreign
    # project name compose does not recognise the already-running SIBLING
    # container as its own: it tries to CREATE it, hits "container name already
    # in use", and aborts the whole `up` as one transaction — so the container
    # that actually needed recreating never gets created either. That is run
    # 35037956239 (job 104674281984) exactly: pub was gone, pvt was healthy, the
    # recreate died on pvt's name and left pub down with the volume already
    # swapped and the kg-store stale. deploy-compose.sh's own "Foreign-project
    # container eviction" comment names this same hazard, naming `cd compose &&
    # docker compose up` (project="compose") as the way to cause it. Mirror
    # Ship's invocation; never invent a second project for one deployment.
    # --project-directory is also what makes the YAML's relative `env_file:` and
    # `./data` bind mounts resolve to the same paths Ship gave them.
    #
    # And bring up ONLY $_c. Naming both containers is what dragged the healthy
    # sibling into the transaction and turned its name conflict into this one's
    # failure; $_c is the only one this function was asked to revive.
    _dir="${CGC_COMPOSE_DIR:-/opt/containers/cloud-cgc-pub-mcp/compose}"
    _proj_dir=$(dirname "$_dir")
    _compose_rel=""
    for _cf in docker-compose.yml compose.yml; do
      if [ -z "$_compose_rel" ] && [ -f "$_dir/$_cf" ]; then
        _compose_rel="$(basename "$_dir")/$_cf"
      fi
    done
    if [ -n "$_compose_rel" ]; then
      # Same probe order as Ship's COMPOSE_HEADER: the deploy symlinks
      # $DEPLOY_PATH/.secrets -> compose/.secrets so that --project-directory .
      # and the YAML's `env_file: [".secrets"]` resolve to one file.
      _env_flag=""
      if [ -e "$_proj_dir/.secrets" ]; then
        _env_flag="--env-file .secrets"
      elif [ -e "$_dir/.secrets" ]; then
        _env_flag="--env-file $(basename "$_dir")/.secrets"
      fi
      echo "[cgc-db-restore-all] $_c still down — recreating via compose in $_proj_dir (project $(basename "$_proj_dir"), service $_c)"
      # shellcheck disable=SC2086
      (cd "$_proj_dir" && docker compose -f "$_compose_rel" --project-directory . $_env_flag up -d "$_c" 2>&1) || true
      sleep 5
    else
      echo "[cgc-db-restore-all] WARN no compose file under $_dir — cannot recreate $_c"
    fi
    mcp_up "$_c"
  }
  bring_up "$CONTAINER" || true
  if mcp_up "$CONTAINER"; then
    echo "[cgc-db-restore-all] restarted $CONTAINER"
    # ── kg-store (SurrealDB) refresh — closes the split-pipeline gap ─────────
    # Both MCP containers run the SAME binaries image (python3 + node +
    # octocode-export.py + kg-ingest.mjs baked in) and both just came back up
    # on the LanceDB tree swapped in above, so both get the cheap
    # OCTOCODE_SKIP_INDEX=1 export→ingest tail — not just $CONTAINER, the one
    # this run happened to restart for the volume swap. Without this, only
    # whichever store's password happened to already be correct for a plain
    # `docker exec` ever received data (see the remap note below), which is
    # exactly the "pvt gets data, pub stays empty" bug this closes.
    #
    # BUSYBOX EXEC-ENV PASSWORD REMAP: cloud-cgc-pub-mcp and cloud-cgc-pvt-mcp
    # are the SAME image run twice. Each container's own entrypoint remaps its
    # KG_STORE_PASS_PUB (pub) onto KG_STORE_PASS for the server PROCESS it
    # starts — but that remap happens once, inside that entrypoint shell, and
    # is invisible to a fresh `docker exec`, which only ever sees the
    # container's ORIGINAL env_file. Both containers ship the SAME base
    # KG_STORE_PASS (the pvt password), so an un-remapped `docker exec` into
    # the pub container hits kg_store_pub (8002) with the pvt password →
    # HTTP 401, silently swallowed by the best-effort warning below. The pvt
    # container needs no remap: its base KG_STORE_PASS is already correct for
    # kg_store_pvt (8001). The fix re-does the remap ourselves for the pub
    # call only, evaluated INSIDE the container via `sh -c` so the real
    # secret is read from the container's own env and never touches this
    # script or its logs.
    #
    # PUBLIC/PRIVATE FILTER: kg_store_pub (feeds the public MCP) must never
    # carry a private repo's graph — same invariant as the LanceDB volume
    # split above. STAGED_REPOS is whatever THIS run actually staged (already
    # private-filtered on the default path, or every repo under
    # CGC_INCLUDE_PRIVATE=1); the pub tail additionally strips
    # CGC_PRIVATE_REPOS/build.json private_repos from it so a pvt-mode run
    # (CGC_INCLUDE_PRIVATE=1) can never leak a private repo into 8002.
    # kg_store_pvt (full store) always gets STAGED_REPOS as-is.
    if [ -n "$STAGED_REPOS" ]; then
      _kbj="${BJ:-}"
      if [ -z "$_kbj" ] || [ ! -f "$_kbj" ]; then
        _kroot="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd || echo "")}"
        _kbj="${_kroot:+$_kroot/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
      fi
      KG_PRIVATE_REPOS="${CGC_PRIVATE_REPOS:-}"
      if [ -z "$KG_PRIVATE_REPOS" ] && [ -n "$_kbj" ] && [ -f "$_kbj" ]; then
        KG_PRIVATE_REPOS=$(jq -r '.runtime.octocode.private_repos[]?' "$_kbj" 2>/dev/null)
      fi
      PUB_CONTAINER="${CGC_PUB_CONTAINER:-}"
      [ -n "$PUB_CONTAINER" ] || [ -z "$_kbj" ] || [ ! -f "$_kbj" ] \
        || PUB_CONTAINER=$(jq -r '.containers.app.container_name // empty' "$_kbj" 2>/dev/null)
      PVT_CONTAINER="${CGC_PVT_CONTAINER:-}"
      [ -n "$PVT_CONTAINER" ] || [ -z "$_kbj" ] || [ ! -f "$_kbj" ] \
        || PVT_CONTAINER=$(jq -r '.containers.pvt.container_name // empty' "$_kbj" 2>/dev/null)
      # Final fallback: on the BOX neither the CGC_*_CONTAINER env nor the build.json
      # ($_kbj) is available, so derive both names from the already-resolved $CONTAINER
      # (=MCP_CONTAINER, e.g. cloud-cgc-pub-mcp) by the pub<->pvt name swap. Without
      # this the tail skipped ("container name unresolved") and NEITHER store refreshed.
      [ -n "$PUB_CONTAINER" ] || PUB_CONTAINER=$(printf '%s' "$CONTAINER" | sed 's/-pvt-/-pub-/')
      [ -n "$PVT_CONTAINER" ] || PVT_CONTAINER=$(printf '%s' "$CONTAINER" | sed 's/-pub-/-pvt-/')

      KG_PUBLIC_REPOS="$STAGED_REPOS"
      if [ -n "$KG_PRIVATE_REPOS" ]; then
        _kept=""
        for _r in $STAGED_REPOS; do
          _skip=0
          for _p in $KG_PRIVATE_REPOS; do
            [ "$_r" = "$_p" ] && { _skip=1; break; }
          done
          [ "$_skip" = 1 ] || _kept="$_kept $_r"
        done
        KG_PUBLIC_REPOS="${_kept# }"
      fi

      kg_refresh() { # $1 = container, $2 = repos, $3 = in-container wrapper cmd (or "sh /app/reindex.sh")
        _c="$1"; _repos="$2"; _cmd="$3"
        if [ -z "$_c" ]; then
          echo "[cgc-db-restore-all] kg-store refresh skipped — container name unresolved"
          return 0
        fi
        if [ -z "$_repos" ]; then
          echo "[cgc-db-restore-all] kg-store refresh skipped for $_c — no eligible repos"
          return 0
        fi
        if docker exec -e OCTOCODE_REPOS="$_repos" -e OCTOCODE_SKIP_INDEX=1 "$_c" sh -c "$_cmd"; then
          echo "[cgc-db-restore-all] kg-store refresh OK ($_c)"
        else
          echo "::warning::[cgc-db-restore-all] kg-store refresh failed for $_c (continuing — LanceDB restore already succeeded)"
        fi
      }

      kg_refresh "$PUB_CONTAINER" "$KG_PUBLIC_REPOS" 'KG_STORE_PASS="$KG_STORE_PASS_PUB" sh /app/reindex.sh'
      kg_refresh "$PVT_CONTAINER" "${STAGED_REPOS# }" 'sh /app/reindex.sh'
    else
      echo "[cgc-db-restore-all] kg-store refresh skipped — no repos staged this run"
    fi
  else
    echo "::error::[cgc-db-restore-all] $CONTAINER is DOWN after the swap — 8 restart/start attempts over ~40s AND the compose recreate all failed (per-attempt docker errors are in the WARN lines above). The kg-store SurrealDB was NOT refreshed, so 8001/8002 hold STALE data. Recover: from $(dirname "${CGC_COMPOSE_DIR:-/opt/containers/cloud-cgc-pub-mcp/compose}") run 'docker compose -f $(basename "${CGC_COMPOSE_DIR:-/opt/containers/cloud-cgc-pub-mcp/compose}")/docker-compose.yml --project-directory . --env-file .secrets up -d $CONTAINER', then re-run the per-container OCTOCODE_SKIP_INDEX=1 reindex.sh tail. Run it from the DEPLOY PATH with --project-directory ., not from the compose/ subdir: the subdir form names the project 'compose', which cannot see the existing containers and dies on the sibling's container name."
    RESTORE_MCP_FAILED=1
  fi
fi
if [ -n "$NTFY" ]; then
  if [ -n "$MISSING" ]; then
    _msg="cloud-cgc octocode DB restored (multi-image) — $FOUND/$TOTAL repos, missing:$MISSING"
  else
    _msg="cloud-cgc octocode DB restored (multi-image) — $FOUND/$TOTAL repos"
  fi
  [ -n "$CONTAINER" ] && _msg="$_msg + $CONTAINER restarted"
  curl -sf -d "$_msg" -H "Title: cgc-db restore-all" -H "Tags: arrow_down,white_check_mark" "$NTFY/ops" >/dev/null 2>&1 || true
fi
echo "[cgc-db-restore-all] RESTORE COMPLETE"
# A down MCP + un-refreshed store is a FAILED restore, not a warning — exit
# non-zero so the pipeline goes RED instead of reporting success over stale data.
#
# 2026-09-07: this was written as `[ cond ] && { ...; exit 1; }` on the LAST
# line of the script. When cond is FALSE — i.e. on SUCCESS — the && chain
# short-circuits and the compound command's status is 1, which becomes the
# script's exit status. So every successful restore-all exited 1 and the
# caller reported "restore-all failed on oci-apps (rc=1)" immediately after
# its own log said RESTORE COMPLETE (run 34093679038: 2376 nodes + 502758
# edges ingested, 0 failed, then rc=1). The disk exhaustion that used to
# kill this step hid the bug; once there was room to finish, it surfaced.
# An explicit if + explicit exit 0 — never rely on a trailing test's status.
if [ "${RESTORE_MCP_FAILED:-0}" = 1 ]; then
  echo "::error::[cgc-db-restore-all] restore FAILED — MCP down and kg-store not refreshed (see recovery above)"
  exit 1
fi
exit 0
