data "cloudflare_ip_ranges" "cloudflare" {}

resource "cloudflare_ruleset" "late_transform" {
  zone_id     = data.cloudflare_zone.homelab.id
  name        = "default"
  description = ""
  kind        = "zone"
  phase       = "http_request_late_transform"

  rules = [{
    action      = "rewrite"
    description = "Remove X-Forwarded-For header"
    enabled     = true
    # v5 splits the ranges into ipv4_cidrs + ipv6_cidrs; concat merges them
    # for the expression.
    expression = "(not ip.src in {${join(" ", concat(data.cloudflare_ip_ranges.cloudflare.ipv4_cidrs, data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs))}})"

    action_parameters = {
      headers = {
        "X-Forwarded-For" = {
          operation = "remove"
        }
      }
    }
  }]
}
