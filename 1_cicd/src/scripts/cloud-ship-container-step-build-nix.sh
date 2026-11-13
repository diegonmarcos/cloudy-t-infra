# Step: Build nix flake (or copy-only for non-nix services)
# Sourced by cloud-ship-container-engine.sh — do not execute directly

step_build() {
    CURRENT_STEP="build"

    # Simple copy mode: no nix, just copy src/ → dist/
    if [ "$BUILD_COPY_ONLY" = "true" ]; then
        log "Copying src/ -> dist/ (copy-only mode)"
        # Preserve terraform state if present
        if [ "$TERRAFORM_DEPLOY" = "true" ] && [ -d "$DIST_DIR" ]; then
            TF_BACKUP=$(mktemp -d)
            for f in terraform.tfstate terraform.tfstate.backup terraform.tfvars .terraform; do
                [ -e "$DIST_DIR/$f" ] && mv "$DIST_DIR/$f" "$TF_BACKUP/"
            done
            # Also preserve any .tfstate backups
            find "$DIST_DIR" -name '*.backup' -exec mv {} "$TF_BACKUP/" \; 2>/dev/null || true
        fi
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR"
        # Stamp every copied file with the GENERATED-FILE banner
        # (dist/ is engine output — must be distinguishable from src/).
        "$INJECT_HEADER" tree "$SRC_DIR" "$DIST_DIR"
        # Restore terraform state
        if [ -n "${TF_BACKUP:-}" ] && [ -d "$TF_BACKUP" ]; then
            cp -a "$TF_BACKUP/"* "$DIST_DIR/" 2>/dev/null || true
            rm -rf "$TF_BACKUP"
        fi
        chmod -R u+w "$DIST_DIR"
        log "Built files:"
        find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
        return 0
    fi

    # Pre-build: resolve any *.json symlink in src/ pointing OUTSIDE the service
    # dir. Nix flakes can't follow symlinks into submodules/parent dirs, so the
    # engine materialises them as real files before nix build and restores them
    # afterwards. Generic: no hardcoded filename patterns — src/ is the contract.
    CLOUD_DATA_STAGED=""
    CLOUD_DATA_DIR="$SERVICE_DIR/../../1_cicd/dist"
    HAS_EXTERNAL_SYMLINKS=false
    HAS_ESCAPING_SYMLINKS=false

    # The git repo nix will intern for this flake. Everything outside it is
    # UNREACHABLE from the store, symlink or not: nix resolves a flake in a work
    # tree as `git+file://<toplevel>?dir=<rel>` and interns that repo alone.
    FLAKE_GIT_ROOT=$(git -C "$SRC_DIR" rev-parse --show-toplevel 2>/dev/null || true)

    # Detect any *.json symlink in src/ whose target is outside the service dir
    for f in "$SRC_DIR"/*.json; do
        [ -L "$f" ] || continue
        target=$(readlink -f "$f" 2>/dev/null || true)
        case "$target" in
            "$SERVICE_DIR"/*) continue ;;  # within service (e.g. build.json -> ../build.json) — nix can follow
        esac
        HAS_EXTERNAL_SYMLINKS=true
        # Outside the interned repo too? Then no amount of git-intern cleverness
        # reaches it and the link MUST be materialised before nix build.
        if [ -n "$FLAKE_GIT_ROOT" ]; then
            case "$target" in
                "$FLAKE_GIT_ROOT"/*) ;;
                *) HAS_ESCAPING_SYMLINKS=true ;;
            esac
        fi
    done

    # Update cloud-data submodule to latest if anything depends on it.
    # In CI, dispatch already did this ONCE under flock — per-service updates
    # race on the submodule config lock, so we skip when CI pre-staged.
    if [ -n "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        log "cloud-data submodule already updated by CI dispatch — skipping"
    elif [ -f "$SERVICE_DIR/../../.gitmodules" ] && { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_EXTERNAL_SYMLINKS" = "true" ]; }; then
        log "Updating cloud-data submodule to latest (--remote --force)"
        # flock: parallel ships of different services on this host fight over
        # git submodule's per-config lock and corrupt each other. Serialize the
        # actual git invocation; once one runs --remote, the rest see the
        # already-current submodule and exit instantly. Lock-fd 9 + 60s timeout
        # guards CI runners with stuck previous flock holders.
        FLOCK_BIN="$(command -v flock || true)"
        if [ -n "$FLOCK_BIN" ]; then
            (
                "$FLOCK_BIN" -w 60 9 || { log "WARN: flock timed out — running unlocked"; }
                git -C "$SERVICE_DIR/../.." -c submodule."1_cicd/dist".update=checkout \
                    submodule update --remote --init --force 1_cicd/dist 2>&1 \
                    | while IFS= read -r line; do log "  $line"; done
            ) 9>/tmp/cloud-submodule-update.lock || \
                log "WARN: 1_cicd/dist update failed — ship will use the pinned commit (may be stale)"
        else
            git -C "$SERVICE_DIR/../.." -c submodule."1_cicd/dist".update=checkout \
                submodule update --remote --init --force 1_cicd/dist 2>&1 \
                | while IFS= read -r line; do log "  $line"; done || \
                log "WARN: 1_cicd/dist update failed — ship will use the pinned commit (may be stale)"
        fi
    fi

    # v2 engine flake reads 1_cicd/dist/ directly; skip src/ injection
    IS_V2_ENGINE_PRE="false"
    if [ -f "$SRC_DIR/flake.nix" ] && grep -q '_shared/engine.nix' "$SRC_DIR/flake.nix"; then
        IS_V2_ENGINE_PRE="true"
    fi

    # HYBRID GUARD v2 (2026-07-03, final form): EVERY v2 flake carries external
    # per-service registry symlinks — the repo-wide git intern resolves them,
    # so dereferencing is not just unnecessary, it deterministically BREAKS v2
    # evals (every "(symlinks +flag)" build tonight failed; every short-circuit
    # passed). The ONLY case that needs dereferencing is a PATH-INTERPOLATED
    # symlink inside a runCommand (cloud-spec: DATA=''${./cloud-data.json}) —
    # nix interns that single path verbatim → dangling in the store. That case
    # is declared, not inferred: build.json build.dereference_symlinks=true.
    DEREF_SYMLINKS=$(jq -r '.build.dereference_symlinks // false' "$CONFIG" 2>/dev/null)
    #
    # ...and that short-circuit only holds while the registry lives INSIDE the
    # interned repo. It stopped holding on 2026-08-27, when a_solutions became
    # its own repo (cloud-u-containers) mounted back as a submodule: the flake
    # root moved from cloud-infra to a_solutions, so every
    # `../../../1_cloud-configs/dist/build-*.json` link — 512 of them across 63
    # services — now points outside the tree nix interns. gitea died on it first
    # ("access to absolute path '/nix/store/1_cloud-configs' is forbidden in
    # pure evaluation mode"), and every other v2 service was one rebuild away
    # from the same error. HAS_ESCAPING_SYMLINKS re-enables dereferencing for
    # exactly that case, and leaves the v2 short-circuit intact everywhere the
    # git intern really does resolve the links.
    if [ "$IS_V2_ENGINE_PRE" = "true" ] && [ "$DEREF_SYMLINKS" != "true" ] && [ "$HAS_ESCAPING_SYMLINKS" != "true" ]; then
        log "v2 engine flake — cloud-data accessed via 1_cicd/dist, no src/ resolve needed"
    elif { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_EXTERNAL_SYMLINKS" = "true" ]; } && [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        # Resolve every external *.json symlink to a real file
        for f in "$SRC_DIR"/*.json; do
            [ -L "$f" ] || continue
            target=$(readlink -f "$f" 2>/dev/null || true)
            case "$target" in
                "$SERVICE_DIR"/*) continue ;;
            esac
            [ -f "$target" ] || continue
            rm "$f"
            cp "$target" "$f"
            git -C "${FLAKE_GIT_ROOT:-$SERVICE_DIR/../..}" add \
                "$(realpath --relative-to="${FLAKE_GIT_ROOT:-$SERVICE_DIR/../..}" "$f")" 2>/dev/null || true
            CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $f"
        done
        # include_cloud_data=true: also copy every 1_cicd/dist/*.json into src/ (for services
        # that need the whole dataset at runtime, e.g. c3-infra-mcp-api).
        # NEVER for v2 engine flakes (2026-07-03): they read 1_cicd/dist
        # directly through the repo-wide git intern; dumping 60 alien JSONs
        # into src/ broke their eval (rig, cgc-mcp) when the hybrid guard
        # routed them here for symlink dereferencing.
        if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ -d "$CLOUD_DATA_DIR" ] && [ "$IS_V2_ENGINE_PRE" != "true" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                BASENAME=$(basename "$f")
                TARGET="$SRC_DIR/$BASENAME"
                [ -L "$TARGET" ] && continue  # already handled above
                cp "$f" "$TARGET"
                git -C "$SERVICE_DIR/../.." add "$(realpath --relative-to="$SERVICE_DIR/../.." "$TARGET")" 2>/dev/null || true
                CLOUD_DATA_STAGED="$CLOUD_DATA_STAGED $TARGET"
            done
        fi
        log "Resolved cloud-data for nix build (${HAS_EXTERNAL_SYMLINKS:+symlinks}${INCLUDE_CLOUD_DATA:+ +flag})"
    elif { [ "$INCLUDE_CLOUD_DATA" = "true" ] || [ "$HAS_EXTERNAL_SYMLINKS" = "true" ]; }; then
        log "cloud-data already pre-staged by CI — skipping"
    fi

    # Restore a staged file to its committed state.
    #
    # `git checkout HEAD -- <path>` only works from the repo that TRACKS the
    # path. The engine used $SERVICE_DIR/../.. for this — correct while every
    # service lived directly in cloud-infra, wrong since a_solutions became its
    # own repo (cloud-u-containers) mounted back as a submodule: from cloud-infra
    # the path is inside a gitlink, the checkout fails, and the `|| rm -f`
    # fallback then DELETES the symlink it was supposed to put back (observed on
    # infra-dat_gitea/src/build-gitea.json). Ask the file's own repo instead.
    restore_staged() {
        _rs_f="$1"
        _rs_root=$(git -C "$(dirname "$_rs_f")" rev-parse --show-toplevel 2>/dev/null || true)
        if [ -n "$_rs_root" ]; then
            _rs_rel="$(realpath --relative-to="$_rs_root" "$_rs_f")"
            git -C "$_rs_root" checkout HEAD -- "$_rs_rel" 2>/dev/null && return 0
        fi
        rm -f "$_rs_f"
    }

    # build.json: src/build.json is a symlink to ../build.json (root is source of truth)
    if [ -f "$SERVICE_DIR/build.json" ] && [ ! -L "$SRC_DIR/build.json" ]; then
        ln -sf ../build.json "$SRC_DIR/build.json"
        git -C "$SERVICE_DIR/../.." add "$(realpath --relative-to="$SERVICE_DIR/../.." "$SRC_DIR/build.json")" 2>/dev/null || true
        log "Created build.json symlink in src/"
    fi

    log "Building nix flake -> dist/"
    cd "$SRC_DIR"

    BUILD_LOG=$(mktemp)
    REPO_ROOT="$SERVICE_DIR/../.."

    # nix build — runs directly (in GHA this is already inside cloud-builder container)
    # 2026-09-06: a_solutions is the RUNNER's checkout bind-mounted into this
    # root-owned container (ship.yml, since it stopped being a submodule), so
    # git rejects it as "dubious ownership" and nix's fetchGit then sees no
    # tracked file at all — "Path '_shared/engine.nix' does not exist in Git
    # repository .../a_solutions" on run 34032593774, for a file committed two
    # days earlier. safe.directory matches the CANONICAL path only, and
    # "$REPO_ROOT" is a_solutions/<svc>/../.. — never normalised — so the
    # entry above matched nothing. Register the resolved path (a_solutions),
    # the raw form, and the superproject that contains it.
    for _sd in "$(realpath "$REPO_ROOT" 2>/dev/null || true)" "$REPO_ROOT" "$(realpath "$REPO_ROOT/.." 2>/dev/null || true)"; do
        [ -n "$_sd" ] && git config --global --add safe.directory "$_sd" 2>/dev/null || true
    done
    # Belt AND braces (the per-path entries above did not clear run
    # 34034838546): the system file is read by the git CLI and by libgit2
    # alike (nix >= 2.19 fetches git trees through libgit2, which never sees
    # GIT_CONFIG_* env), and the env form covers a git CLI whose $HOME is not
    # where --global wrote. We are root inside a throwaway builder; a
    # wildcard here widens nothing that matters.
    git config --system --add safe.directory '*' 2>/dev/null || true
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
    nix build --option eval-cache false --out-link "$SERVICE_DIR/.result" 2>"$BUILD_LOG" || {
        log_error "nix build failed:"
        # BOTH streams (2026-07-03): the engine self-tees stdout into
        # <service>/build.log; an error cat'd only to stderr never reaches it
        # and failures debug blind ("Step 'build' failed" with no cause).
        cat "$BUILD_LOG"
        cat "$BUILD_LOG" >&2
        rm -f "$BUILD_LOG"
        # 2026-09-06: "Path '_shared/engine.nix' does not exist in Git
        # repository" is nix's rendering of git NOT LISTING the file — it
        # says nothing about why (ownership, stale index, wrong HEAD, a
        # sparse checkout). Print git's own view of the tree the flake was
        # evaluated in so the next failure carries its cause.
        {
            echo "── git view of $REPO_ROOT (nix flake root) ──"
            echo "nix: $(nix --version 2>&1 | head -1)   git: $(git --version 2>&1)"
            echo "uid=$(id -u) .git owner uid=$(stat -c %u "$REPO_ROOT/.git" 2>&1) type=$([ -d "$REPO_ROOT/.git" ] && echo dir || echo file)"
            echo "HEAD: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>&1)   tracked: $(git -C "$REPO_ROOT" ls-files 2>/dev/null | wc -l)   in-tree _shared/engine.nix: $(git -C "$REPO_ROOT" ls-files --error-unmatch _shared/engine.nix >/dev/null 2>&1 && echo yes || echo NO)"
            echo "status (first 8):"; git -C "$REPO_ROOT" status --short 2>&1 | head -8
            echo "safe.directory: $(git config --show-origin --get-all safe.directory 2>&1 | tr '\n' ' ')"
        } 2>&1 | sed 's/^/[nix-diag] /'
        for f in $CLOUD_DATA_STAGED; do
            restore_staged "$f"
        done
        return 1
    }

    # Show warnings.
    # `|| true` (2026-07-03, THE tonight-wide transient-failure root cause):
    # under pipefail, grep exits 1 when the (non-empty) nix stderr contains
    # no warning/error/trace line — killing the step AFTER a successful nix
    # build with only "Step 'build' failed (exit 1)" and no cause. Every
    # "intermittent" build failure tonight (cgc-mcp, gitea, dagu, gha-runner,
    # caddy-l4-image, chat-mattermost, gws-mcp) alternated with whether the
    # dirty-tree warning happened to be present to satisfy the grep.
    if [ -s "$BUILD_LOG" ]; then
        grep -i 'warning\|error\|trace' "$BUILD_LOG" | while IFS= read -r line; do
            log_warn "$line"
        done || true
    fi
    rm -f "$BUILD_LOG"

    # Copy from .result to dist/
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        cp -ra "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    else
        cp -rL "$SERVICE_DIR/.result/"* "$DIST_DIR/"
    fi
    chmod -R u+w "$DIST_DIR"
    rm -f "$SERVICE_DIR/.result"

    # Post-build: restore cloud-data files in src/ to their committed state
    # In CI, cleanup is handled by cloud-builder-ship.sh after all parallel jobs finish
    if [ -z "${CLOUD_DATA_PRESTAGED_BY_CI:-}" ]; then
        for f in $CLOUD_DATA_STAGED; do
            restore_staged "$f"
        done
    fi

    # v2 layout: flake reads 1_cicd/dist directly via builtins.readDir;
    # NO duplication into dist/. Legacy v1 flat-dump retained for v1 services.
    IS_V2_ENGINE="false"
    if [ -f "$SRC_DIR/flake.nix" ] && grep -q '_shared/engine.nix' "$SRC_DIR/flake.nix"; then
        IS_V2_ENGINE="true"
        log "v2 engine flake detected — skipping cloud-data injection into dist/"
    fi

    # Include 1_cicd/dist/ files in dist/ for runtime use (e.g. C3 API needs topology)
    # Legacy v1 behaviour only; v2 engine handles its own layout.
    if [ "$INCLUDE_CLOUD_DATA" = "true" ] && [ "$IS_V2_ENGINE" = "false" ]; then
        CLOUD_DATA_DIR="$SERVICE_DIR/../../1_cicd/dist"
        FRONT_DATA_DIR="$SERVICE_DIR/../../front-data"
        REPO_ROOT="$SERVICE_DIR/../.."
        if [ -d "$CLOUD_DATA_DIR" ]; then
            for f in "$CLOUD_DATA_DIR"/*.json "$CLOUD_DATA_DIR"/*.md; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included 1_cicd/dist/*.json + *.md in dist/"
        fi
        # Include config.json from repo root (needed by cloud-cgc-pub-mcp)
        if [ -f "$REPO_ROOT/config.json" ]; then
            cp "$REPO_ROOT/config.json" "$DIST_DIR/"
            log "Included config.json in dist/"
        fi
        # Include front-data/*.json if available
        if [ -d "$FRONT_DATA_DIR" ]; then
            for f in "$FRONT_DATA_DIR"/*.json; do
                [ -f "$f" ] || continue
                cp "$f" "$DIST_DIR/"
            done
            log "Included front-data/*.json in dist/"
        fi
    fi

    # Source hash for REMOTE_BUILD — TS/JS changes must trigger Docker rebuild
    # dist/ only has docker-compose.yml; source goes via rsync. Without this,
    # the ship hash check sees "unchanged" and skips compose (stale container).
    # `-type f` and parenthesised OR predicates: without them, find matches
    # directories whose name ends in *.js (e.g. node_modules/ipaddr.js/ — a
    # package directory), and sha256sum errors with "Is a directory", which
    # makes xargs return 123 and fails the whole build.
    if [ -n "$DOCKER_IMAGE" ]; then
        # Deterministic: hash RELATIVE paths over the git-tracked file list
        # (sorted, C locale), so the value is independent of the checkout
        # location and of untracked build outputs (node_modules/, dist JS...).
        # Falls back to find (pruning node_modules) outside a git work tree.
        src_hash_file_list "$SRC_DIR" \
            | (cd "$SRC_DIR" && xargs -r -d '\n' sha256sum --) 2>/dev/null \
            | sha256sum | cut -c1-16 > "$DIST_DIR/.src-hash"
    fi

    # Copy extra source files for on-VM builds (e.g. Rust source for rig)
    EXTRA_COPY="$(get_config_array build.extra_copy)"
    if [ -n "$EXTRA_COPY" ]; then
        echo "$EXTRA_COPY" | while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            # Handle directories (ending with /)
            if [ -d "$SRC_DIR/$pattern" ]; then
                "$INJECT_HEADER" tree "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            elif [ -f "$SRC_DIR/$pattern" ]; then
                "$INJECT_HEADER" file "$SRC_DIR/$pattern" "$DIST_DIR/$pattern"
            fi
            log "Copied extra: $pattern"
        done
    fi

    # docker-run.sh generation moved to step_compose (compose.custom=true in build.json)

    log "Built files:"
    if [ "$PRESERVE_SYMLINKS" = "true" ]; then
        find "$DIST_DIR" -type f -o -type l | sed "s|$DIST_DIR/|  |"
    else
        find "$DIST_DIR" -type f | sed "s|$DIST_DIR/|  |"
    fi
}

# ── #862: committed dist/ must equal this run's render ─────────────────
# cloud-u-containers commits each service's dist/ next to its src/. The ship
# never deploys that copy (step_build above wipes and re-renders it), but humans,
# agents and VM-side tools read it as "what is deployed", and a stale one was
# what reached gcp-proxy's redis on 2026-10-04. Untracking ~1400 files across
# the fleet would break every reader at once; this check is the smaller change:
# after the render, any TRACKED dist/ file the render modified or dropped means
# the commit lied about its own output. CI-only — a local build is exactly how
# a developer refreshes dist/ before committing it.
# Declared .src-hash input set: tracked JS/TS source (every extension node
# loads: ts tsx mts cts js jsx mjs cjs) + Dockerfile/package.json under $1, as paths relative to $1, LC_ALL=C sorted.
src_hash_file_list() {
    _shf_dir="$1"
    if git -C "$_shf_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$_shf_dir" ls-files -z -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.jsx' '*.mjs' '*.cjs' 'Dockerfile' '**/Dockerfile' 'package.json' '**/package.json' \
            | tr '\0' '\n'
    else
        (cd "$_shf_dir" && find . -name node_modules -prune -o \
            \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' -o -name 'Dockerfile' -o -name 'package.json' \) -type f -print \
            | sed 's|^\./||')
    fi | { grep -v '/node_modules/\|^node_modules/' || true; } | LC_ALL=C sort -u
}

step_verify_committed_dist() {
    [ -n "${CI:-}${GITHUB_ACTIONS:-}" ] || return 0
    [ "${SHIP_ALLOW_STALE_DIST:-}" = "1" ] && { log_warn "committed-dist guard skipped (SHIP_ALLOW_STALE_DIST=1)"; return 0; }
    git -C "$SERVICE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    # build.dist_volatile: the dist embeds the fleet declaration (ntfy channels,
    # the cloud-spec book), so ANY service added anywhere changes it. The ship
    # re-renders it every run and never deploys the committed copy, so for these
    # services the committed copy is informational and is not drift-checked --
    # otherwise each unrelated service registration breaks Build -> oci-apps.
    case "$(get_config build.dist_volatile)" in
        true|True) log "committed-dist guard skipped (build.dist_volatile: dist embeds the fleet declaration)"; return 0 ;;
    esac
    _vcd_tracked=$(git -C "$SERVICE_DIR" ls-files -- dist 2>/dev/null)
    [ -n "$_vcd_tracked" ] || return 0
    _vcd_drift=$(git -C "$SERVICE_DIR" diff --name-status -- dist 2>/dev/null)
    [ -z "$_vcd_drift" ] && { log "committed dist/ matches this run's render"; return 0; }
    log_error "committed dist/ differs from the fresh render of src/ — commit the regenerated dist/ (./build.sh build) so the repo matches what ships:"
    printf '%s\n' "$_vcd_drift" | sed 's|^|    |'
    git -C "$SERVICE_DIR" --no-pager diff --stat -- dist 2>/dev/null | tail -1 | sed 's|^|    |'
    # Show WHAT drifted (word-level, capped) so a one-line json drift is diagnosable from the log.
    # Compose/dist files carry ${VAR} placeholders only, never resolved secret values.
    git -C "$SERVICE_DIR" --no-pager diff --word-diff=porcelain --word-diff-regex='[^,{}]+|[,{}]' -U0 -- dist 2>/dev/null \
        | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | cut -c1-240 | head -40 | sed 's|^|    drift: |'
    return 1
}
