# Geo-fence for the Cloudflare-proxied tier (#1104 routing tier pub, #1102 geo-fence).
# c3-pub.diegonmarcos.com is the only orange-cloud name, so Cloudflare is the only place that sees the
# real client country for it; the Caddy edge fences the grey hosts. The country set is NOT retyped here:
# geo-allowed.json is a generated copy of cloud-u-containers _shared/geo-fence.json allowed_countries,
# and a CI check there fails when the two differ. A country Cloudflare cannot place (XX, T1) is not in
# the set, so it is blocked too (fail closed).
# Plain block (default Cloudflare 403 page): the plan is not entitled to a custom response body (#1216).
locals {
  geo_allowed = jsondecode(file("${path.module}/geo-allowed.json")).allowed_countries
  c3_pub_host = "c3-pub.diegonmarcos.com"
  # #1579: Telegram's published webhook source ranges (cloud-u-containers _shared/geo-fence.json telegram_webhook) skip the
  # country check for the webhook path ONLY; the relay still rejects a post without the secret_token header.
  telegram_webhook_cidrs = ["149.154.160.0/20", "91.108.4.0/22"]
  telegram_webhook_path  = "/c3bot-webhook"
}

resource "cloudflare_ruleset" "c3_pub_geo_fence" {
  zone_id     = var.cloudflare_zone_id
  name        = "c3-pub geo-fence"
  description = "Routing tier pub (#1104): only the countries in geo-fence.json reach c3-pub (generated country set)."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "block"
    description = "c3-pub: client country not in the geo-fence allowlist (unplaceable XX/T1 included)"
    enabled     = true
    expression  = "(http.host eq \"${local.c3_pub_host}\" and not ip.src.country in {${join(" ", [for c in local.geo_allowed : "\"${c}\""])}} and not (http.request.uri.path eq \"${local.telegram_webhook_path}\" and ip.src in {${join(" ", local.telegram_webhook_cidrs)}}))"
  }
}
