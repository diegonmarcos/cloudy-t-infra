#!/usr/bin/env bash
# Runs the cloud-services-mcp registry self-checks (#377, #378).
#
# The registry module physically lives in the PRE-RENAME tree
# (a_solutions/infra-api_cloudy-all-api/src/code/registry/) and is symlinked
# into infra-api_cloud-services-mcp. Two defects of the same shape have already
# shipped from that arrangement, and both were silent:
#
#   #371  Both loaders restated the peer map filename as the literal
#         "build-c3-services-api.json". The container was renamed, the literal
#         stopped matching, the registry loaded ZERO services, getBaseUrl()
#         returned null for every one of them, and every tool quietly fell back
#         to a hardcoded address. infra.matomo.* dialled 10.0.0.4 for weeks
#         while the declaration said 10.0.0.6. Nothing raised.
#
#   #378  The name is derived from build.json now, but the dev-tree fallback
#         derived it by walking up from the MODULE'S OWN location. Node
#         resolves symlinks, so that always landed back in the pre-rename tree
#         and re-derived the OLD name — silently, for every container that
#         borrows the module.
#
# Both self-checks print one line per assertion and a final count. This wrapper
# asserts the count actually appeared: a runner that dies on module resolution
# exits non-zero having printed nothing that looks like a failed assertion, and
# an earlier report on this very work was called green on exactly that basis.
#
# A missing self-check is a FAILURE, never a skip. That is the whole subject of
# #368 and there is no third outcome here.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY_DIR="$ROOT/a_solutions/infra-api_cloudy-all-api/src/code/registry"
MCP_TOOLS_DIR="$ROOT/a_solutions/infra-api_cloud-services-mcp/src/code/mcp/tools"

if [ ! -d "$REGISTRY_DIR" ]; then
    echo "::error::registry source not found at $REGISTRY_DIR — cloud-u-containers is checked out into a_solutions by the workflow; without it these guards are unrun, not passing."
    exit 1
fi

if [ ! -d "$MCP_TOOLS_DIR" ]; then
    echo "::error::mcp tool handlers not found at $MCP_TOOLS_DIR — same reason; a missing directory is a failure, not a skip."
    exit 1
fi

command -v node >/dev/null || { echo "::error::node is required to run the registry self-checks"; exit 1; }

failed=0

for selfcheck in peer-map.selfcheck.mts summary.selfcheck.mts; do
    path="$REGISTRY_DIR/$selfcheck"
    if [ ! -f "$path" ]; then
        echo "::error::$selfcheck is missing from $REGISTRY_DIR"
        failed=$((failed + 1))
        continue
    fi

    echo "── $selfcheck ──"
    # Captured in ONE invocation so the exit status belongs to the self-check
    # and not to a pipe. `npx --yes tsx`: node --experimental-strip-types cannot
    # run these — the module under test imports with `.js` specifiers and the
    # loader dies before the first assertion.
    output="$(cd "$REGISTRY_DIR" && npx --yes tsx "$selfcheck" 2>&1)"
    status=$?
    echo "$output"

    if [ "$status" -ne 0 ]; then
        echo "::error::$selfcheck failed (exit $status)"
        failed=$((failed + 1))
        continue
    fi

    # Exit zero is necessary but not sufficient — the assertions must have run.
    if ! echo "$output" | grep -qE 'selfcheck: [0-9]+ assertions passed'; then
        echo "::error::$selfcheck exited 0 but never reported an assertion count. It did not run its assertions; treat this as red."
        failed=$((failed + 1))
    fi
done

# ── The projection must have exactly one implementation ─────────────
#
# #377 was fixed once and shipped still broken. `registry.services_list` is
# served from TWO entry points: src/code/mcp/index.ts registers meta.ts, and
# src/code/mcp/http.ts registers registry.ts. The fix moved meta.ts onto the
# tested projection in registry/summary.ts and left registry.ts restating it
# inline, still reading `s.api.type` unconditionally. HTTP is the transport
# every MCP client actually uses, so the tool went on returning
# `Cannot read properties of undefined (reading 'type')` on a container built
# from the fix — a green ship run deploying a defect that was already declared
# solved. The self-check above passed the whole time, because it tests the
# projection and nothing asserted who calls it.
#
# These two assertions are about CALLERS, which is the part that drifted.

echo "── projection is single-sourced ──"

# Every field of the summary is built in registry/summary.ts. `apiType` is the
# field that crashed; if it is being constructed inside a tool handler, that
# handler is restating the projection instead of calling it. #170 is the
# standing warning that a second copy drifts, and this one did.
restated="$(grep -rn 'apiType:' "$MCP_TOOLS_DIR" --include='*.ts' || true)"
if [ -n "$restated" ]; then
    echo "$restated"
    echo "::error::a tool handler builds the service summary itself instead of calling summarizeServices() from registry/summary.ts. That is the #377 defect exactly: the projection was fixed in one caller and restated in another."
    failed=$((failed + 1))
else
    echo "  ok — no tool handler restates the summary projection"
fi

# Both entry points must reach the tested projection. registry.ts had zero
# calls to it while meta.ts had one, which is how the deployed HTTP handler
# stayed broken after #377 was called done.
for handler in registry.ts meta.ts; do
    if ! grep -q 'summarizeServices(' "$MCP_TOOLS_DIR/$handler"; then
        echo "::error::$handler serves registry.services_list but never calls summarizeServices(). One entry point fixed is not the tool fixed."
        failed=$((failed + 1))
    else
        echo "  ok — $handler routes through summarizeServices()"
    fi
done


# ── The peer-map symlinks are dependency edges, not broken links ────────
#
# a_solutions/*/src/build-*.json are relative symlinks to
# 1_cloud-configs/dist/build-*.json. There are 671 of them and ALL of them
# dangle in a standalone cloud-u-containers checkout, because the path resolves
# only when the repo sits at a_solutions/ inside cloud-infra — which is exactly
# how CI checks it out and how .gitmodules (lines 33-43) says the split was
# designed.
#
# That dangle looks like a bug and repointing it would be a real one. ship.yml
# reverse-walks these links with `readlink -f` to map a regenerated dist file
# back to the services that consume it; a link that no longer resolves to
# 1_cloud-configs/dist stops being found, and its service silently stops being
# rebuilt when its own peer map changes. A no-ship that reports success is the
# #371 failure mode, and it would have been introduced by "fixing" the link.
#
# So the assertion is that the convention HOLDS, not that the link resolves here.
# Content is never read through this path: the loaders probe /app first and
# peer-map.ts derives its development candidate from the container ROOT, one
# level above src/. Nothing dereferences src/build-*.json for content, which is
# why #378's fallback is unaffected by any of this and stays exercisable.

echo "── peer-map symlink convention ──"

PEER_LINKS_DIR="$ROOT/a_solutions"
mismatched=""
link_count=0
while IFS= read -r link; do
    # A heredoc fed by a find that matched nothing still delivers one empty
    # line. Counting it would make "no links found" look like one healthy link,
    # which is the shape of every fail-open in this pipeline.
    [ -n "$link" ] || continue
    link_count=$((link_count + 1))
    target="$(readlink "$link")"
    case "$target" in
        ../../../1_cloud-configs/dist/build-*.json) ;;
        *) mismatched="$mismatched
  $link -> $target" ;;
    esac
done <<INNER
$(find -H "$PEER_LINKS_DIR" -mindepth 3 -maxdepth 3 -type l -path '*/src/build-*.json' 2>/dev/null)
INNER

if [ "$link_count" -eq 0 ]; then
    echo "::error::found no */src/build-*.json symlinks under $PEER_LINKS_DIR. They are the dependency edges ship.yml reverse-walks to decide what to rebuild; zero of them means this guard is measuring nothing."
    failed=$((failed + 1))
elif [ -n "$mismatched" ]; then
    echo "$mismatched"
    echo "::error::a service's src/build-*.json no longer points at ../../../1_cloud-configs/dist/. ship.yml reverse-walks these with readlink -f to map a regenerated config back to its consumers; a repointed link drops the service from change detection and it stops shipping without reporting anything."
    failed=$((failed + 1))
else
    echo "  ok — all $link_count src/build-*.json links point into 1_cloud-configs/dist"
fi

# The projection and the folder lookup must both read the declaration, not a
# category→prefix table. That table was pre-rename and made getDriftReport()
# report 69 of 76 services as missing from disk.
prefix_table="$(grep -rn 'CATEGORY_PREFIX\|PREFIX_TO_CATEGORY' \
    "$ROOT/a_solutions/infra-api_c3-infra-api/src/code/shared/libs/config.ts" \
    "$ROOT/a_solutions/user-ai_cloud-cgc-pub-mcp/src/code/tools/a-knowledge/specs.ts" 2>/dev/null || true)"
if [ -n "$prefix_table" ]; then
    echo "$prefix_table"
    echo "::error::a category→prefix table is back. The folder is declared at services[*].folder for every service; rebuilding it from a prefix table is what made the drift report call 69 of 76 services missing."
    failed=$((failed + 1))
else
    echo "  ok — folder and category come from the declaration, not a prefix table"
fi

if [ "$failed" -ne 0 ]; then
    echo "::error::$failed registry self-check(s) failed"
    exit 1
fi

echo "cloud-services-mcp registry self-checks, projection single-sourcing and peer-map symlink convention: all passed"
