#!/usr/bin/env bash
# ── Run terraform plan+apply for cloud providers + wrangler for CF worker ──
# Usage: ship-terraform.sh [project]
#   project: cloudflare, gcloud, oci, hetzner, cf-worker (omit for all)
set -euo pipefail

PROJECT="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"
export CLOUD_ROOT="$REPO_ROOT"  # ensure-deps.sh / cloud-paths.sh read this

# ── Dependencies — sourced from shared lib ────────────────────────
# Was 3 inline `ensure_*` functions; consolidated into
# 9_others/src/ensure-deps.sh on 2026-04-28 so any future engine
# (terraform, ship, gen-configs, …) gets the same idempotent bootstrap.
LIB_DIR="$REPO_ROOT/9_others/src"
# shellcheck source=../../lib/ensure-deps.sh
[ -f "$LIB_DIR/ensure-deps.sh" ] && . "$LIB_DIR/ensure-deps.sh"

# Local fallback for fresh clones where libs/ might not be deployed yet —
# defensive only; happy path uses the shared functions above.
if ! command -v ensure_sops >/dev/null 2>&1; then
  ensure_sops() {
    command -v sops >/dev/null 2>&1 && return
    echo "Installing sops..."
    curl -fsSL -o /tmp/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
    chmod +x /tmp/sops && sudo mv /tmp/sops /usr/local/bin/sops
  }
fi
if ! command -v ensure_terraform >/dev/null 2>&1; then
  ensure_terraform() {
    command -v terraform >/dev/null 2>&1 && return
    echo "Installing terraform..."
    curl -fsSL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
    unzip -o /tmp/tf.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/terraform
  }
fi
if ! command -v ensure_wrangler >/dev/null 2>&1; then
  # `wrangler` is baked into the cloud-builder image at image-build time,
  # driven by cloud/config.json:.deps.docker_npm (FIRE rule 4: data-driven,
  # rule 1: declarative). Runtime npm-install was retired 2026-05-07 — it
  # silently swallowed npm errors, version was unpinned, and ran every CI
  # invocation. If wrangler is missing here, the cloud-builder image is
  # stale; rebuild + push via:
  #   bash unix/cb_containers-builders/build.sh ship cloud-builder-x-deb-nixhm
  ensure_wrangler() {
    if ! command -v wrangler >/dev/null 2>&1; then
      echo "FATAL: wrangler not on PATH inside cloud-builder image." >&2
      echo "  Image is stale — rebuild via:" >&2
      echo "  bash unix/cb_containers-builders/build.sh ship cloud-builder-x-deb-nixhm" >&2
      exit 1
    fi
  }
fi

declare -A TF_DIRS=(
  [cloudflare]="c_vps/ba-clo_cloudflare/src"
  [gcloud]="c_vps/vps_gcloud/src"
  [oci]="c_vps/vps_oci/src"
  [hetzner]="c_vps/vps_hetzner/src"
)

OK=0; FAIL=0; SKIP=0; STATE_CHANGED=false

# ── Change detection ──
# On push events, CHANGES_* env vars indicate what changed.
# On workflow_dispatch, INPUT_PROJECT selects the target.
# Skip providers with no changes unless explicitly requested.
should_run() {
  local name="$1"
  # Explicit project filter always wins
  [ -n "$PROJECT" ] && { [ "$PROJECT" = "$name" ] && return 0 || return 1; }
  # On workflow_dispatch with no project filter, run all
  [ "${EVENT_NAME:-}" = "workflow_dispatch" ] && return 0
  # On push, check CHANGES_* env var (uppercase, hyphens to underscores)
  local var_name="CHANGES_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
  local val="${!var_name:-false}"
  [ "$val" = "true" ]
}

# ── Cloudflare Worker (wrangler) ──
if should_run "cf-worker"; then
  WORKER_DIR="a_solutions/infra-cloud_cloudflare-worker/src"
  if [ -d "$WORKER_DIR" ]; then
    echo "── Wrangler: cf-worker ($WORKER_DIR) ──"
    ensure_wrangler
    cd "$REPO_ROOT/$WORKER_DIR"
    if wrangler deploy; then
      echo "OK cf-worker"
      OK=$((OK + 1))
    else
      echo "FAIL cf-worker (deploy)"
      FAIL=$((FAIL + 1))
    fi
    cd "$REPO_ROOT"
  else
    echo "SKIP cf-worker (dir not found)"
    SKIP=$((SKIP + 1))
  fi
fi

# ── Terraform providers ──
for name in cloudflare gcloud oci hetzner; do
  if ! should_run "$name"; then
    continue
  fi

  dir="${TF_DIRS[$name]}"
  if [ ! -d "$dir" ]; then
    echo "SKIP $name (dir $dir not found)"
    SKIP=$((SKIP + 1))
    continue
  fi

  echo "── Terraform: $name ($dir) ──"
  ensure_sops
  ensure_terraform
  cd "$REPO_ROOT/$dir"

  # Decrypt tfstate from sops-encrypted file
  if [ -f terraform.tfstate.enc ] && [ ! -f terraform.tfstate ]; then
    sops -d --input-type json --output-type json terraform.tfstate.enc > terraform.tfstate
    echo "  Decrypted terraform.tfstate.enc"
  fi

  # Copy tfvars template if no tfvars exists (gitignored for security)
  if [ ! -f terraform.tfvars ] && [ -f terraform.tfvars.template ]; then
    # Strip placeholder lines — TF_VAR_ env vars from GHA secrets take precedence
    awk 'index($0, "INJECTED_FROM_SECRETS") == 0 && index($0, "CHANGE_ME") == 0' terraform.tfvars.template > terraform.tfvars
    echo "  Copied terraform.tfvars.template → terraform.tfvars (placeholders stripped)"
  fi

  # Export non-secret tfvars as TF_VAR_* so helper scripts that build resource
  # IDs by hand (import.sh) see the same values terraform auto-loads for
  # plan/apply. Without this, import.sh has no zone_id and every `terraform
  # import` fails with "Invalid zone identifier", silently skipping adoption →
  # apply then 409/allow_overwrite-conflicts on the un-adopted resources.
  # Data-driven: values come from terraform.tfvars (the SoT), never hardcoded.
  if [ -f terraform.tfvars ]; then
    eval "$(awk -F= '
      /^[[:space:]]*#/ { next }
      /=/ {
        k=$1; gsub(/[[:space:]]/, "", k)
        v=substr($0, index($0, "=") + 1)
        sub(/^[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); gsub(/"/, "", v)
        if (k != "") printf "export TF_VAR_%s='"'"'%s'"'"'\n", k, v
      }' terraform.tfvars)"
  fi

  # #1686 sops/vault -> Secret Manager: secret NAMES come from terraform.json cloud_run_secret_sources (secret name ->
  # vault key); values come from the decrypted vault env, in memory only, handed to terraform as a sensitive
  # TF_VAR (stored only in the sops-encrypted state). Nothing is echoed. A missing key is skipped with a notice;
  # main.tf then holds back any service that needs that secret.
  if [ -f terraform.json ] && grep -q '"cloud_run_secret_sources"' terraform.json; then
    for vf in "$HOME/git/cloud-vault/C_A0-env/dist/vault-keys-bash.env" /root/git/cloud-vault/C_A0-env/dist/vault-keys-bash.env; do
      [ -f "$vf" ] && { set -a; . "$vf" 2>/dev/null || true; set +a; break; }
    done
    if command -v python3 >/dev/null 2>&1; then
      TF_VAR_cloud_run_secret_values="$(python3 -I - <<'PYEOF'
import json, os, sys
src = json.load(open("terraform.json")).get("cloud_run_secret_sources", {})
out, miss = {}, []
for name, key in src.items():
    if name.startswith("_"):
        continue
    v = os.environ.get(key, "")
    (out.__setitem__(name, v) if v else miss.append(name))
if miss:
    print("  secret-sync: no vault value for: " + ", ".join(miss), file=sys.stderr)
print(json.dumps(out))
PYEOF
)"
      export TF_VAR_cloud_run_secret_values
      echo "  secret-sync: $(printf '%s' "$TF_VAR_cloud_run_secret_values" | python3 -I -c 'import json,sys;print(len(json.load(sys.stdin)))') secret value(s) staged for terraform"
    else
      echo "  secret-sync: python3 missing in builder; no secret values staged"
    fi
  fi

  tf_cleanup() { rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars tfplan; rm -rf .terraform; }
  terraform init -input=false || { echo "FAIL $name (init)"; FAIL=$((FAIL + 1)); tf_cleanup; cd "$REPO_ROOT"; continue; }
  # Adopt pre-existing infra resources into state (idempotent — `terraform import`
  # errors out cleanly when an address is already in state; import.sh swallows it).
  # Each provider may ship a src/import.sh listing OCIDs/IDs of resources that
  # were created out-of-band (OCI console, CF dashboard) BEFORE terraform took
  # over. Without this hook, `apply` hits 409-Conflict on those resources.
  if [ -x import.sh ]; then
    echo "  Running import.sh (idempotent state adoption)"
    ./import.sh || echo "  import.sh exited non-zero (expected if resources already adopted)"
  fi
  terraform plan -input=false -out=tfplan || { echo "FAIL $name (plan)"; FAIL=$((FAIL + 1)); tf_cleanup; cd "$REPO_ROOT"; continue; }

  # apply's exit code is captured, NOT branched on immediately: terraform
  # writes terraform.tfstate incrementally as each resource in the graph
  # finishes, so a PARTIAL apply (one resource created, a later one failing
  # on e.g. a zonal stock-out) leaves local state ahead of the committed
  # terraform.tfstate.enc. The old code branched straight into tf_cleanup on
  # a non-zero exit, which rm -f'd that local state before it was ever
  # re-encrypted — silently orphaning whatever DID get created: it exists in
  # the cloud, terraform has no record of it, and the next apply dies on
  # "already exists" (or, worse, quietly recreates a duplicate for a
  # resource type that allows it). 2026-09-03: exactly this, gcp-t4-embed-ip
  # created + gcp-t4-embed instance failed (GPU zonal stock-out) in the same
  # apply. Fix: re-encrypt+commit local state UNCONDITIONALLY (below) before
  # ever touching FAIL/tf_cleanup, so a partial apply's real-world result is
  # always reflected in the state the NEXT run reads.
  APPLY_RC=0
  terraform apply -input=false -auto-approve tfplan || APPLY_RC=$?

  # Re-encrypt updated tfstate — see APPLY_RC comment above: unconditional,
  # runs even when the apply failed.
  if [ -f terraform.tfstate ] && [ -f terraform.tfstate.enc ]; then
    cp terraform.tfstate terraform.tfstate.enc
    sops -e -i --input-type json --output-type json terraform.tfstate.enc
    STATE_CHANGED=true
    echo "  Re-encrypted terraform.tfstate.enc"
  fi

  tf_cleanup

  if [ "$APPLY_RC" -ne 0 ]; then
    echo "FAIL $name (apply)"
    FAIL=$((FAIL + 1))
    cd "$REPO_ROOT"
    continue
  fi

  echo "OK $name"
  OK=$((OK + 1))
  cd "$REPO_ROOT"
done

# Commit updated tfstate.enc files back to repo
#
# Identity passed via `git -c` per-command, NOT `git config` (persistent).
# Persistent `git config user.{name,email}` writes to .git/config and
# pollutes the operator's local repo identity if this script is ever run
# outside a fresh CI clone — every subsequent operator commit on that
# repo would then be authored as github-actions, masking the real author
# and potentially confusing webhook delivery / branch-protection rules.
if [ "$STATE_CHANGED" = true ]; then
  echo "── Committing updated tfstate.enc files ──"
  git add c_vps/*/src/terraform.tfstate.enc
  if ! git diff --cached --quiet; then
    # [skip ci]: the state-commit touches c_vps/*/src/terraform.tfstate.enc,
    # which matches this very workflow's push-path trigger. sops re-encryption
    # is non-deterministic, so without the marker every apply would re-trigger
    # ship-terraform → infinite loop. [skip ci] makes the state push inert.
    git \
      -c user.name="github-actions" \
      -c user.email="actions@github.com" \
      commit -m "terraform: update encrypted tfstate [skip ci]"
    # --autostash: terraform leaves regenerated dist/ artifacts
    # (.terraform.lock.hcl, terraform.tfstate.backup, dist copies) in the
    # working tree; they're intentionally NOT in the auto-commit (only
    # src/terraform.tfstate.enc is). Without --autostash, `git pull --rebase`
    # refuses with "cannot pull with rebase: You have unstaged changes."
    # autostash stashes them, rebases, then restores — correct for CI where
    # the dist drift is never pushed.
    #
    # Explicit `origin main` / `HEAD:main` refspecs: GHA actions/checkout
    # leaves a DETACHED HEAD at the commit SHA, so bare `git pull --rebase` /
    # `git push` abort with "You are not currently on a branch."
    git pull --rebase --autostash origin main
    git push origin HEAD:main
  fi
fi

echo "Terraform: $OK ok, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
