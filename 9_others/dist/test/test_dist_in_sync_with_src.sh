#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_dist_in_sync_with_src.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: 1_cicd/dist/ + .github/workflows/ are in sync with the
# corresponding src/cicd/ + src/scripts/ + src/test/.
#
# Why: today (2026-04-27) saw multiple agents push src changes without
# running 9_others/build.sh deploy. Result: .github/workflows/ on
# origin diverged from src/cicd/ by 2+ commits, and ship runs failed at
# the matrix-detect step (cloud-data-gha-config.json missing because
# the regen pre-step lived in src but never got deployed).
#
# Fix: this lint runs `9_others/build.sh build` then checks that
# dist/ + .github/workflows/ match what the engine emits. Any drift
# fails the lint with a clear message pointing at the build step.
set -eu

# Repo root by upward search, not a fixed ../../.. — this file exists at BOTH
# 9_others/test/ and 1_cicd/dist/test/ (generated), which sit at
# different depths, so one literal count is wrong for one of the two copies.
REPO_ROOT="$(_d="$(cd "$(dirname "$0")" && pwd)"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
# Fixture override for the deployed-only check below (its own tester).
REPO_ROOT="${DIST_SYNC_REPO_ROOT:-$REPO_ROOT}"

# ── Deployed workflow vs its src, BEFORE anything is rebuilt ───────────
#
# 2026-11-18: the #1686 step "Use the newest committed tfstate (never the
# trigger commit's)" (7ec458ab2) had been edited into the DEPLOYED
# .github/workflows/ship-terraform.yml only. The rebuild below re-emits
# .github/workflows/ from src, so it silently deleted the fix and reported
# no more than "ship-terraform.yml drifts". This check reads each deployed
# workflow's GENERATED banner for its Source, and compares the two before
# the rebuild can overwrite the evidence: it names every step that exists
# only in the deployed copy, and flags any other content difference.
DEPLOYED_ONLY=0
echo "── deployed .github/workflows/*.yml vs their src (before rebuild) ──"
for wf in "$REPO_ROOT/.github/workflows/"*.yml; do
    [ -f "$wf" ] || continue
    src_rel=$(sed -n '1,20{s/^# ║[[:space:]]*Source[[:space:]]*:[[:space:]]*//p}' "$wf" | head -1 | sed 's/[[:space:]]*║*[[:space:]]*$//')
    [ -n "$src_rel" ] || continue
    src="$REPO_ROOT/$src_rel"
    bn=$(basename "$wf")
    if [ ! -f "$src" ]; then
        echo "::error::$bn is deployed but its src $src_rel does not exist"
        DEPLOYED_ONLY=1; continue
    fi
    # Deployed body = file without the leading GENERATED banner and the one
    # blank line the engine emits after it.
    body=$(awk 'h==0 && /^# [╔║╚]/ {next} h==0 && /^$/ {h=1; next} {h=1; print}' "$wf")
    steps_only=$(comm -23 \
        <(printf '%s\n' "$body" | grep -E '^[[:space:]]*- name:' | sed 's/^[[:space:]]*- name:[[:space:]]*//' | sort) \
        <(grep -E '^[[:space:]]*- name:' "$src" | sed 's/^[[:space:]]*- name:[[:space:]]*//' | sort))
    if [ -n "$steps_only" ]; then
        printf '%s\n' "$steps_only" | while IFS= read -r st; do
            echo "::error::.github/workflows/$bn has step \"$st\" that is NOT in its src $src_rel — the next build/deploy deletes it. Port it into src."
        done
        DEPLOYED_ONLY=1
    elif [ "$body" != "$(cat "$src")" ]; then
        echo "::error::.github/workflows/$bn differs from its src $src_rel (edited in the deployed copy?) — the next build/deploy overwrites it."
        DEPLOYED_ONLY=1
    fi
done
[ "$DEPLOYED_ONLY" -eq 0 ] && echo "  ok — every deployed workflow matches its src"
if [ "${DIST_SYNC_DEPLOYED_ONLY:-0}" = 1 ]; then
    exit "$DEPLOYED_ONLY"
fi

[ -f "$REPO_ROOT/9_others/build.sh" ] || { echo "::error::build.sh not found"; exit 1; }

# Snapshot dist + .github/workflows BEFORE build, then re-build, diff.
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Snapshot dist/ verbatim. .github/workflows has symlinks (scripts/, hooks/,
# test/) into dist — so we snapshot only .yml files, not the symlinked dirs.
# The dirs themselves are part of the dist/ check above; double-comparing
# them via the symlink fails with "No such file or directory" when cp
# behaves oddly with broken/replaced symlinks.
cp -r "$REPO_ROOT/1_cicd/dist" "$TMP/dist-before" 2>/dev/null || true
mkdir -p "$TMP/wf-before"
find "$REPO_ROOT/.github/workflows" -maxdepth 1 -name '*.yml' -exec cp {} "$TMP/wf-before/" \; 2>/dev/null || true

# Re-emit dist + .github/workflows from src/.
( cd "$REPO_ROOT" && bash 9_others/build.sh ) >/dev/null 2>&1 || {
    echo "::error::9_others/build.sh failed — fix the engine before lint"
    exit 1
}

DRIFT=$DEPLOYED_ONLY

# --no-dereference: dist/ legitimately holds symlinks that point into
# submodule build outputs (e.g. front-fleet-gh-declared.json →
# III_front/2_configs/dist/). Those targets are absent unless the
# submodule has been built, and without this flag diff reports the
# dangling link as "No such file or directory" and the test fails for
# a reason that has nothing to do with src→dist drift. Comparing the
# link targets themselves is also the more correct check here: the
# engine owns the link, not the file behind it.
if ! diff -rq --no-dereference "$TMP/dist-before" "$REPO_ROOT/1_cicd/dist" >/tmp/dist-drift 2>&1; then
    if [ -s /tmp/dist-drift ]; then
        echo "::error::1_cicd/dist/ is out of sync with 9_others/src/"
        echo "Drift:"
        head -20 /tmp/dist-drift | sed 's/^/  /'
        echo "Fix: run 'bash 9_others/build.sh' and commit the dist/ changes."
        DRIFT=1
    fi
fi

# Compare only the .yml workflow files; symlinked subdirs (scripts, hooks,
# test) are validated as part of the dist/ check above.
WF_DRIFT=$(
    for f in "$REPO_ROOT/.github/workflows/"*.yml; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        before="$TMP/wf-before/$bn"
        if [ ! -f "$before" ] || ! cmp -s "$before" "$f"; then
            echo "  $bn drifts"
        fi
    done
    for f in "$TMP/wf-before/"*.yml; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        [ -f "$REPO_ROOT/.github/workflows/$bn" ] || echo "  $bn removed by build but still in .github/workflows/ snapshot"
    done
)
if [ -n "$WF_DRIFT" ]; then
    echo "::error::.github/workflows/ is out of sync with 1_cicd/src/cicd/"
    echo "Drift:"
    printf '%s\n' "$WF_DRIFT"
    echo "Fix: run 'bash 9_others/build.sh' and commit the .github/workflows/ changes."
    DRIFT=1
fi

# ── The compile-only verb must be non-destructive and mode-faithful ────
#
# Both checks above invoke `build.sh` with no verb — the full ship pipeline —
# and compare with `diff -rq`, which does not look at permissions. Between them
# they were blind to #399 in both of its halves:
#
#   · `build.sh build` purged _dotfiles/apps/dist and _dotfiles/git/dist but had no step that
#     re-emits the dotfiles tree or dist/LICENSE, so the compile-only verb
#     DELETED 15 committed artifacts. `ship` put them straight back, so this
#     lint never saw a thing.
#   · The exec bit arrived from a `chmod +x` in the DEPLOY phase, which reached
#     into dist through the .github/workflows/scripts symlink. `build` alone
#     therefore left 34 scripts at 644 — and a mode diff is exactly what
#     `diff -rq` does not report.
#
# git is the right oracle: it tracks content AND the exec bit, and "clean status
# after a rebuild" is precisely the contract dist/ has to meet. Checking the
# cheap verb also matters on its own — `build` is what an agent reaches for when
# it does not want to touch install paths, and it must be safe to run.
echo "── build.sh build is non-destructive and mode-faithful ──"
( cd "$REPO_ROOT" && bash 9_others/build.sh build ) >/dev/null 2>&1 || {
    echo "::error::9_others/build.sh build failed — fix the engine before lint"
    exit 1
}
BUILD_DIRT=$(git -C "$REPO_ROOT" status --porcelain -- \
    _dotfiles/git/dist _dotfiles/apps/dist 1_cicd/dist 2_sops/dist 9_others/dist)
if [ -n "$BUILD_DIRT" ]; then
    echo "$BUILD_DIRT" | sed 's/^/  /'
    echo "::error::'build.sh build' left dist/ dirty. Every line above is an artifact the compile-only verb deleted, re-moded or failed to reproduce byte-for-byte — dist/ is supposed to be a faithful, executable copy of src/."
    echo "Fix: run 'bash 9_others/build.sh build' and commit the dist/ changes, or repair the engine step that does not re-emit them."
    DRIFT=1
else
    echo "  ok — dist/ is clean after a rebuild (content and exec bits)"
fi

[ "$DRIFT" -eq 1 ] && exit 1

echo "1_cicd/dist/ + .github/workflows/ are in sync with src/, and 'build.sh build' leaves dist/ clean."
