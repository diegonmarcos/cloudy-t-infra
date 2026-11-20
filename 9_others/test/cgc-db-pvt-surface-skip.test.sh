#!/usr/bin/env bash
# #1817: the PUBLIC cgc-db run never builds private images (private_repos are
# filtered out of its matrix, cgc-db-public-no-private.test.sh), so its restore
# job must not FAIL on an unpullable private image: it skips the pvt surface,
# leaving that volume untouched, and never restores it with public data only.
# Runs the real per-surface loop body, extracted from the workflow sources, with a
# stubbed probe.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
for f in cgc-db-index.yml cgc-db-restore.yml; do
  y="$ROOT/1_cicd/src/cicd/$f"
  blk=$(awk '/if \[ "\$BOX_GHCR_OK" != "1" \]; then/{p=1} p{print} p&&/^ *fi$/{exit}' "$y")
  [ -n "$blk" ] || { bad "$f: BOX_GHCR_OK gate not found"; continue; }
  printf '%s' "$blk" | grep -q 'exit 1' && bad "$f: an unpullable private image still fails the job" || ok "$f: an unpullable private image does not fail the job"
  printf '%s' "$blk" | grep -q '::warning::\[cgc-db\] skipping the pvt restore' && ok "$f: the skip is visible as a warning" || bad "$f: no warning on skip"
  # Execute the gate inside a surface loop: pvt must be skipped before the restore step.
  out=$(BLK="$blk" sh -c 'for SURFACE in pub pvt; do
      BOX_GHCR_OK=1; [ "$SURFACE" = pvt ] && BOX_GHCR_OK=0; _probe_img=ghcr.io/x/p:latest; VOL=v_$SURFACE
      eval "$BLK"
      echo "RESTORE $SURFACE"
    done' 2>&1)
  [ "$(printf '%s\n' "$out" | grep -c '^RESTORE')" = 1 ] && printf '%s' "$out" | grep -q '^RESTORE pub' \
    && ok "$f: pub is restored, pvt is skipped (never restored with public data only)" || bad "$f: loop result: $out"
  cmp -s <(sed -n '/BOX_GHCR_OK" != "1"/,/^ *fi$/p' "$y") <(sed -n '/BOX_GHCR_OK" != "1"/,/^ *fi$/p' "$ROOT/.github/workflows/$f") \
    && ok "$f: generated .github/workflows copy carries the same gate" || bad "$f: .github/workflows/$f is stale (regenerate)"
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS
