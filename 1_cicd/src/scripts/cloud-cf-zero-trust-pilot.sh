#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Cloudflare Zero Trust pilot runner (phase 1)                     ║
# ║                                                                  ║
# ║ Design: a0_docs/eng-specs/cloudflare-zero-trust.md               ║
# ║ Called by .github/workflows/cf-zero-trust.yml.                   ║
# ║                                                                  ║
# ║ Modes (all print NAMES / COUNTS / STATUS CODES only, never a     ║
# ║ credential — the repo and its Actions logs are public):          ║
# ║   probe   read-only CF API inventory (ZT org, IdPs, apps,        ║
# ║           tokens, tunnels, Gateway) + permission check           ║
# ║   plan    terraform plan of c_vps/ba-clo_cloudflare/src,         ║
# ║           resource addresses + Plan: line only                   ║
# ║   apply   plan, then apply ONLY pure-create zero-trust addresses ║
# ║           (-target); refuses if any of them is not a create.     ║
# ║           Re-encrypts state, exports tunnel token + service      ║
# ║           token to sops files encrypted to the public age key.   ║
# ║   verify  Access gate / service-token bearer / Gateway DoH tests ║
# ║   export  re-write the sops secret files from current state      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

MODE="${1:-probe}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}"
TF_DIR="$REPO_ROOT/c_vps/ba-clo_cloudflare/src"
CFG="$TF_DIR/terraform.json"
ACCT="$(jq -r .account_id "$CFG")"
ZONE="$(awk -F'"' '/^cloudflare_zone_id/{print $2}' "$TF_DIR/terraform.tfvars.template")"
AGE_RECIPIENT="$(awk '/&diego/{print $3}' "$REPO_ROOT/.sops.yaml")"
API="https://api.cloudflare.com/client/v4"

: "${CLOUDFLARE_EMAIL:?CLOUDFLARE_EMAIL missing}"
: "${CLOUDFLARE_API_KEY:?CLOUDFLARE_API_KEY missing}"
echo "::add-mask::$CLOUDFLARE_API_KEY"

# Addresses this pilot is allowed to CREATE. Anything else in the plan is
# reported and left alone (it belongs to the regular ship-terraform flow).
ZT_ADDR_RE='^(cloudflare_zero_trust_[a-z_]+\.zt_|random_bytes\.zt_|cloudflare_record\.zt_)'
# The ONE address allowed an in-place UPDATE (tunnel ingress rules, #994 step 2).
# Everything else stays create-only; a destroy or replace of it is still refused.
ZT_UPDATE_OK='cloudflare_zero_trust_tunnel_cloudflared_config.zt_fleet'

cf() { # cf <path> → JSON body (never echoed raw by callers)
  curl -sS --max-time 30 -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
       -H "Content-Type: application/json" "$API$1"
}

probe_one() { # probe_one <label> <path> <jq-summary>
  local label="$1" path="$2" summary="$3" body ok
  body="$(cf "$path" || echo '{}')"
  ok="$(jq -r '.success // false' <<<"$body" 2>/dev/null || echo false)"
  if [ "$ok" = "true" ]; then
    printf '  %-28s OK   %s\n' "$label" "$(jq -c "$summary" <<<"$body" 2>/dev/null)"
  else
    printf '  %-28s FAIL %s\n' "$label" "$(jq -c '[.errors[]? | {code, message}]' <<<"$body" 2>/dev/null)"
  fi
}

do_probe() {
  echo "── CF API probe (account ${ACCT:0:6}…, zone ${ZONE:0:6}…) ──"
  probe_one "user"                 "/user"                                        '{id_set: (.result.id != null)}'
  probe_one "account"              "/accounts/$ACCT"                              '{name: .result.name, type: .result.type}'
  probe_one "account membership"   "/memberships?account.id=$ACCT"                '[.result[] | {status, roles: [.roles[]?]}]'
  probe_one "zone"                 "/zones/$ZONE"                                 '{name: .result.name, plan: .result.plan.name, status: .result.status}'
  probe_one "zone dns records"     "/zones/$ZONE/dns_records?per_page=500"        '{count: (.result|length), proxied: [.result[] | select(.proxied) | .name]}'
  probe_one "access organization"  "/accounts/$ACCT/access/organizations"         '{auth_domain: .result.auth_domain, name: .result.name, is_ui_read_only: .result.is_ui_read_only}'
  probe_one "access identity provs" "/accounts/$ACCT/access/identity_providers"  '[.result[] | {id, name, type}]'
  probe_one "access apps"          "/accounts/$ACCT/access/apps"                  '[.result[] | {name, domain, type}]'
  probe_one "access policies"      "/accounts/$ACCT/access/policies"              '[.result[] | {name, decision}]'
  probe_one "access service tokens" "/accounts/$ACCT/access/service_tokens"      '[.result[] | {name, expires_at}]'
  probe_one "tunnels (cfd)"        "/accounts/$ACCT/cfd_tunnel?is_deleted=false"  '[.result[] | {id, name, status, conns: (.connections|length), colos: ([.connections[]?.colo_name] | unique), client_versions: ([.connections[]?.client_version] | unique)}]'
  probe_one "teamnet routes"       "/accounts/$ACCT/teamnet/routes"               '[.result[] | {network, tunnel_name}]'
  probe_one "virtual networks"     "/accounts/$ACCT/teamnet/virtual_networks"     '[.result[] | {name, is_default_network}]'
  probe_one "gateway account"      "/accounts/$ACCT/gateway"                      '{gateway_tag_set: (.result.gateway_tag != null), provider: .result.provider_name}'
  probe_one "gateway locations"    "/accounts/$ACCT/gateway/locations"            '[.result[] | {name, doh_subdomain_set: (.doh_subdomain != null), client_default}]'
  probe_one "gateway rules"        "/accounts/$ACCT/gateway/rules"                '[.result[] | {name, action, enabled}]'
  probe_one "zt subscription"      "/accounts/$ACCT/subscriptions"                '[.result[] | {rate_plan: .rate_plan.id, product: .product.name?}]'
  probe_one "user api tokens"      "/user/tokens"                                 '[.result[] | {name, status, perms: [.policies[]?.permission_groups[]?.name] | unique}]'
}

tf_prepare() {
  cd "$TF_DIR"
  if [ -f terraform.tfstate.enc ] && [ ! -f terraform.tfstate ]; then
    sops -d --input-type json --output-type json terraform.tfstate.enc > terraform.tfstate
  fi
  awk 'index($0, "INJECTED_FROM_SECRETS") == 0 && index($0, "CHANGE_ME") == 0' terraform.tfvars.template > terraform.tfvars
  export TF_VAR_cloudflare_api_key="$CLOUDFLARE_API_KEY"
  export TF_IN_AUTOMATION=1
  export TF_VAR_zt_adopt_settings="${ZT_ADOPT_SETTINGS:-false}"
  terraform init -input=false -no-color >/dev/null
}

tf_cleanup() { cd "$TF_DIR" && rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars tfplan tfplan.json plan.txt apply.txt && rm -rf .terraform; }

plan_summary() { # resource headers + Plan line, nothing else
  grep -E '^\s+# [a-z_]+\.|^Plan:|^No changes|^Error|^│ Error' plan.txt | sed 's/^\s*//' || true
}

do_plan() {
  tf_prepare
  set +e; terraform plan -input=false -no-color -out=tfplan > plan.txt 2>&1; rc=$?; set -e
  echo "── terraform plan (addresses only) ──"; plan_summary
  [ "$rc" -eq 0 ] || { grep -A8 'Error' plan.txt | grep -viE 'key|secret|token' | head -40; return "$rc"; }
  terraform show -json tfplan > tfplan.json
  echo "── changes by action ──"
  jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | "\(.change.actions|join("+"))\t\(.address)"' tfplan.json | sort
  # Attribute NAMES that differ (never values) on non-secret zero-trust addresses: what to fix in code.
  jq -r '.resource_changes[] | select(.change.actions != ["no-op"] and (.address|test("zt_(org|vnet|warp|smtp|fleet|dns|fallback|gateway|posture)"))) | . as $r | ($r.change.before // {}) as $b | ($r.change.after // {}) as $a | "  attrs \($r.address): " + ([($a|keys[]?), ($b|keys[]?)] | unique | map(select(. as $k | ($b[$k]) != ($a[$k]) and ($k|test("secret|token|tunnel_secret")|not))) | join(","))' tfplan.json | sort
}

commit_back() { # commit_back <msg> <paths...>
  local msg="$1"; shift
  cd "$REPO_ROOT"
  git config user.name  "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add -- "$@"
  if git diff --cached --quiet; then echo "nothing to commit"; return 0; fi
  git commit -q -m "$msg [skip ci]"
  git pull -q --rebase origin "${GITHUB_REF_NAME}" || true
  git push -q origin "HEAD:${GITHUB_REF_NAME}"
  echo "committed: $msg"
}

sops_write() { # sops_write <dest> <cred-name> <cred-type> <url> <note> <KEY=ENVVAR>...
  # Values are read from the env and never printed. The file follows
  # cloud-u-containers/_shared/secrets-schema.md: app-consumed top-level keys
  # plus a _credentials.<cred-name> record that references each value.
  # --filename-override: encrypt under the repo .sops.yaml creation rule that
  # matches <dest> (secrets.<name>.yaml → public age recipient). A bare temp
  # path matches no rule and sops refuses ("no matching creation rules").
  local dest="$1" cname="$2" ctype="$3" curl_="$4" cnote="$5"; shift 5
  local tmp kv k v; tmp="$(mktemp)"
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"; printf '%s: "%s"\n' "$k" "${!v}" >> "$tmp"; done
  printf '_credentials:\n  %s:\n    type: %s\n    url: "%s"\n    note: "%s"\n' "$cname" "$ctype" "$curl_" "$cnote" >> "$tmp"
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"; printf '    %s: "%s"\n' "$(tr 'A-Z' 'a-z' <<<"$k")" "${!v}" >> "$tmp"; done
  if ! sops -e --input-type yaml --output-type yaml --filename-override "$dest" "$tmp" > "$dest.tmp"; then
    rm -f "$tmp" "$dest.tmp"; echo "sops encryption FAILED for $(basename "$dest")"; return 1
  fi
  rm -f "$tmp"; mv "$dest.tmp" "$dest"
}

export_secrets() { # run in $TF_DIR with decrypted state + initialised .terraform
  set +e
  ZT_TUNNEL_TOKEN="$(terraform output -raw zt_tunnel_token 2>/dev/null)"
  ZT_SVC_ID="$(terraform output -raw zt_service_token_client_id 2>/dev/null)"
  ZT_SVC_SECRET="$(terraform output -raw zt_service_token_client_secret 2>/dev/null)"
  set -e
  for v in "$ZT_TUNNEL_TOKEN" "$ZT_SVC_ID" "$ZT_SVC_SECRET"; do [ -n "$v" ] && echo "::add-mask::$v"; done
  export TUNNEL_TOKEN="$ZT_TUNNEL_TOKEN" CF_ACCESS_CLIENT_ID="$ZT_SVC_ID" CF_ACCESS_CLIENT_SECRET="$ZT_SVC_SECRET"
  SECRETS_OUT=()
  if [ -n "$ZT_TUNNEL_TOKEN" ]; then
    sops_write "$TF_DIR/secrets.zt-tunnel.yaml" tunnel token \
      "https://one.dash.cloudflare.com/ -> Networks -> Tunnels -> $(jq -r .zero_trust.tunnel.name "$CFG")" \
      "Remotely-managed tunnel token (terraform output zt_tunnel_token). Consumed by a_solutions/infra-net_cloudflared as src/secrets.yaml." \
      TUNNEL_TOKEN=TUNNEL_TOKEN && SECRETS_OUT+=("$TF_DIR/secrets.zt-tunnel.yaml")
  fi
  if [ -n "$ZT_SVC_ID" ] && [ -n "$ZT_SVC_SECRET" ]; then
    sops_write "$TF_DIR/secrets.zt-service-token.yaml" service_token token \
      "https://one.dash.cloudflare.com/ -> Access -> Service auth -> zt-pilot-machine" \
      "Send as headers CF-Access-Client-Id / CF-Access-Client-Secret. Expiry: terraform.json .zero_trust.service_tokens[].duration." \
      CF_ACCESS_CLIENT_ID=CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET=CF_ACCESS_CLIENT_SECRET \
      && SECRETS_OUT+=("$TF_DIR/secrets.zt-service-token.yaml")
  fi
  echo "tunnel token exported: $([ -n "$ZT_TUNNEL_TOKEN" ] && echo yes || echo no); service token exported: $([ -n "$ZT_SVC_ID" ] && echo yes || echo no)"
}

do_export() {
  tf_prepare
  export_secrets
  tf_cleanup
  [ "${#SECRETS_OUT[@]}" -eq 0 ] || commit_back "cloudflare: zero-trust secrets re-exported (sops, public age recipient)" "${SECRETS_OUT[@]}"
}

reconcile_orphan_tunnel() {
  # A run that died between apply and the state commit leaves a tunnel in
  # Cloudflare that terraform does not know (2026-10-14, first apply). Delete
  # ONLY a tunnel that (a) has this pilot's tunnel name, (b) is absent from
  # state, (c) has zero connectors — i.e. provably unused — so the next apply
  # recreates it cleanly instead of duplicating it.
  local name in_state ids id conns
  name="$(jq -r .zero_trust.tunnel.name "$CFG")"
  in_state="$(jq -r '.resources[]? | select(.type=="cloudflare_zero_trust_tunnel_cloudflared" and .name=="zt_fleet") | .instances[0].attributes.id' terraform.tfstate 2>/dev/null || true)"
  ids="$(cf "/accounts/$ACCT/cfd_tunnel?is_deleted=false&name=$name" | jq -r '.result[]? | "\(.id) \(.connections|length)"')"
  while read -r id conns; do
    [ -n "$id" ] || continue
    [ "$id" = "$in_state" ] && continue
    if [ "$conns" = "0" ]; then
      echo "deleting orphan tunnel $name ($id): not in state, 0 connectors"
      curl -sS -X DELETE -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        "$API/accounts/$ACCT/cfd_tunnel/$id" | jq -c '{success, errors}'
    else
      echo "REFUSING: tunnel $name ($id) is not in state but has $conns connectors — import it by hand"; return 1
    fi
  done <<<"$ids"
}

do_apply() {
  tf_prepare
  reconcile_orphan_tunnel
  do_plan
  cd "$TF_DIR"
  mapfile -t TARGETS < <(jq -r '.resource_changes[] | select(.change.actions != ["no-op"] or .change.importing != null) | .address' tfplan.json | grep -E "$ZT_ADDR_RE" || true)  # imports (state-only, actions no-op) are targeted too; an import that also shows a change is refused below
  [ "${#TARGETS[@]}" -gt 0 ] || { echo "no zero-trust changes to apply"; tf_cleanup; return 0; }
  BAD="$(jq -r --arg re "$ZT_ADDR_RE" --arg ok "$ZT_UPDATE_OK" '.resource_changes[] | select((.address|test($re)) and .change.actions != ["create"] and .change.actions != ["no-op"] and (.address != $ok or .change.actions != ["update"])) | "\(.change.actions|join("+")) \(.address)"' tfplan.json)"
  if [ -n "$BAD" ]; then echo "REFUSING: non-create change on a zero-trust address:"; echo "$BAD"; tf_cleanup; return 1; fi
  echo "── applying ${#TARGETS[@]} zero-trust resources (creates; update only on zt_fleet) (-target) ──"
  TARGET_ARGS=(); for t in "${TARGETS[@]}"; do TARGET_ARGS+=("-target=$t"); done
  terraform plan -input=false -no-color "${TARGET_ARGS[@]}" -out=tfplan > plan.txt 2>&1 || { plan_summary; tf_cleanup; return 1; }
  terraform show -json tfplan | jq -e --arg ok "$ZT_UPDATE_OK" '[.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["create"] and (.address != $ok or .change.actions != ["update"]))] | length == 0' >/dev/null \
    || { echo "REFUSING: targeted plan contains non-create actions"; tf_cleanup; return 1; }
  plan_summary
  APPLY_RC=0; terraform apply -input=false -no-color -auto-approve tfplan > apply.txt 2>&1 || APPLY_RC=$?
  grep -E ': Creation complete|^Apply complete|Error' apply.txt | sed -E 's/\[id=[^]]*\]//' || true
  [ "$APPLY_RC" -eq 0 ] || grep -A6 'Error' apply.txt | grep -viE 'secret|token' | head -40
  # State is re-encrypted and COMMITTED FIRST and UNCONDITIONALLY: a partial
  # apply must be recorded before anything else can fail.
  cp terraform.tfstate terraform.tfstate.enc
  sops -e -i --input-type json --output-type json terraform.tfstate.enc
  commit_back "cloudflare: zero-trust state after pilot apply (rc=$APPLY_RC)" \
    "$TF_DIR/terraform.tfstate.enc" "$TF_DIR/.terraform.lock.hcl"
  cd "$TF_DIR"
  # Secrets out of state → sops (public age recipient only).
  export_secrets
  tf_cleanup
  [ "${#SECRETS_OUT[@]}" -eq 0 ] || commit_back "cloudflare: zero-trust secrets (sops, public age recipient)" "${SECRETS_OUT[@]}"
  [ "$APPLY_RC" -eq 0 ] || { echo "apply FAILED (state recorded)"; return 1; }
  echo "apply OK"
  probe_one "tunnels after apply" "/accounts/$ACCT/cfd_tunnel?is_deleted=false" '[.result[] | {id, name, status, conns: (.connections|length)}]'
}

do_verify() {
  local host; host="$(jq -r '.zero_trust.pilot_app.hostname' "$CFG")"
  tf_prepare
  ID="$(terraform output -raw zt_service_token_client_id 2>/dev/null || true)"
  SECRET="$(terraform output -raw zt_service_token_client_secret 2>/dev/null || true)"
  DOH="$(terraform output -raw zt_dns_location_doh_subdomain 2>/dev/null || true)"
  for v in "$ID" "$SECRET"; do [ -n "$v" ] && echo "::add-mask::$v"; done
  tf_cleanup
  echo "── verify https://$host ──"
  printf '  no credentials        -> %s\n' "$(curl -s -o /dev/null -w '%{http_code} location=%{redirect_url}' "https://$host/" | sed -E 's/(redirect_url=[^&]*).*/\1/; s/\?.*//')"
  printf '  wrong service token  -> %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -H 'CF-Access-Client-Id: invalid.access' -H 'CF-Access-Client-Secret: invalid' "https://$host/")"
  if [ -n "$ID" ] && [ -n "$SECRET" ]; then
    printf '  valid service token   -> %s\n' "$(curl -s -o /tmp/zt-body -w '%{http_code} bytes=%{size_download} ctype=%{content_type}' -H "CF-Access-Client-Id: $ID" -H "CF-Access-Client-Secret: $SECRET" "https://$host/")"
    printf '  body title            -> %s\n' "$(grep -o '<title>[^<]*' /tmp/zt-body | head -1 | sed 's/<title>//')"
  fi
  if [ -n "$DOH" ]; then
    local name; name="$(jq -r '.zero_trust.private_dns.records[0].fqdn' "$CFG")"
    q="$(python3 -c 'import base64,struct,sys;n=sys.argv[1];m=struct.pack(">HHHHHH",0,256,1,0,0,0)+b"".join(bytes([len(p)])+p.encode() for p in n.split("."))+b"\0"+struct.pack(">HH",1,1);print(base64.urlsafe_b64encode(m).decode().rstrip("="))' "$name")"
    ans="$(curl -s -H 'accept: application/dns-message' "https://$DOH.cloudflare-gateway.com/dns-query?dns=$q" | python3 -c 'import sys,struct;d=sys.stdin.buffer.read();an=struct.unpack(">H",d[6:8])[0];print("rcode=%d answers=%d last_a=%s"%(d[3]&15,an,".".join(map(str,d[-4:])) if an else "-"))')"
    printf '  Gateway DoH %s -> %s\n' "$name" "$ans"
  fi
}

# drift: fail when the live Cloudflare One account differs from the repo (#994).
# (1) any zero-trust address with a pending change in the plan = live != code;
# (2) a live object of a managed type that terraform state does not hold =
#     created on the server only (dashboard/API) and therefore not in code.
# Nothing is changed. Prints addresses and counts only.
do_drift() {
  do_plan || { tf_cleanup; return 1; }
  cd "$TF_DIR"
  DRIFT=0
  CH="$(jq -r --arg re "$ZT_ADDR_RE" '.resource_changes[] | select((.address|test($re)) and .change.actions != ["no-op"]) | "\(.change.actions|join("+")) \(.address)"' tfplan.json)"
  if [ -n "$CH" ]; then echo "DRIFT: zero-trust resources differ from the live account:"; echo "$CH"; DRIFT=1; fi
  terraform state list > state.txt 2>/dev/null || true
  for spec in "access/apps?per_page=100|cloudflare_zero_trust_access_application" \
              "access/identity_providers|cloudflare_zero_trust_access_identity_provider" \
              "access/service_tokens?per_page=100|cloudflare_zero_trust_access_service_token" \
              "gateway/rules|cloudflare_zero_trust_gateway_policy" \
              "gateway/locations|cloudflare_zero_trust_dns_location" \
              "teamnet/virtual_networks?is_deleted=false|cloudflare_zero_trust_tunnel_virtual_network" \
              "cfd_tunnel?is_deleted=false&per_page=100|cloudflare_zero_trust_tunnel_cloudflared" \
              "teamnet/routes?is_deleted=false|cloudflare_zero_trust_tunnel_route" \
              "devices/posture|cloudflare_zero_trust_device_posture_rule" \
              "gateway/certificates|cloudflare_zero_trust_gateway_certificate"; do
    path="${spec%%|*}"; typ="${spec##*|}"
    # The Cloudflare-managed WARP enrolment app (type "warp", created by Cloudflare itself the first time device
    # enrolment is configured; not creatable as code on the free plan) is excluded from the app count and asserted
    # separately below, so a server-only SELF_HOSTED app still trips the guard.
    live="$(cf "/accounts/$ACCT/$path" | jq --arg t "$typ" 'if (.result|type)!="array" then 0 elif $t=="cloudflare_zero_trust_access_application" then [.result[] | select((.type // "") != "warp")] | length else (.result|length) end')"
    held="$(grep -c "^$typ\." state.txt || true)"
    echo "  live $typ=$live state=$held"
    if [ "$live" != "$held" ]; then echo "DRIFT: $typ has $live live object(s) but terraform holds $held (server-only objects are not in code)"; DRIFT=1; fi
  done
  rm -f state.txt
  WARPAPPS="$(cf "/accounts/$ACCT/access/apps?per_page=100" | jq -r --arg d "$(jq -r '.zero_trust.adopted.org.auth_domain' "$CFG")/warp" '[.result[] | select(.type=="warp")] | "\(length) \(map(.domain)|unique|join(","))" ' )"
  WARPWANT="$(jq -r '.zero_trust.adopted.org.auth_domain' "$CFG")/warp"
  case "$WARPAPPS" in
    "0 "*|"1 $WARPWANT") echo "  warp enrolment app(s): $WARPAPPS (Cloudflare-managed, asserted)" ;;
    *) echo "DRIFT: unexpected WARP app set '$WARPAPPS' (want none or exactly $WARPWANT)"; DRIFT=1 ;;
  esac
  # Settings the provider cannot manage (gateway settings crash it): compared with the pinned values.
  while IFS=$'\t' read -r path jqx want; do
    got="$(cf "/accounts/$ACCT/$path" | jq -r "$jqx")"
    if [ "$got" = "$want" ]; then echo "  asserted $path $jqx = $got"; else echo "DRIFT: $path $jqx is '$got', code pins '$want'"; DRIFT=1; fi
  done < <(jq -r '.zero_trust.adopted.asserted_settings[]|[.path,.jq,.equals]|@tsv' "$CFG")
  tf_cleanup
  [ "$DRIFT" -eq 0 ] && echo "no drift: live Cloudflare One == repo" || return 1
}

case "$MODE" in
  probe)  do_probe ;;
  plan)   do_probe; do_plan; tf_cleanup ;;
  apply)  do_apply ;;
  verify) do_probe; do_verify ;;
  export) do_export ;;
  drift)  do_probe; do_drift ;;
  *) echo "usage: $0 probe|plan|apply|verify|export|drift" >&2; exit 2 ;;
esac
