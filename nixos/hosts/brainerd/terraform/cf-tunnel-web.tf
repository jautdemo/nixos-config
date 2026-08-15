resource "random_id" "tunnel_web_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "web" {
  account_id    = var.cloudflare_account_id
  name          = "k8s-web"
  tunnel_secret = random_id.tunnel_web_secret.b64_std
  # Remote config: rules are fetched at runtime, so adding a hostname needs no
  # redeploy of the Deployment.
  config_src = "cloudflare"
}

locals {
  # Public hostnames only. Internal-only names (nas, longhorn,
  # mediadb, printer, switches) have no public record and must stay that way.
  public_hostnames = [
    "dns.homelab.invalid",
    "whoami.homelab.invalid",
    "pma.homelab.invalid",
    "photos.homelab.invalid",
    "authelia.homelab.invalid",
    "grafana.homelab.invalid",
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "web" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.web.id

  config = {
    ingress = concat(
      [for hostname in local.public_hostnames : {
        hostname = hostname
        service  = "https://192.168.1.220:443"
        origin_request = {
          origin_server_name = hostname
        }
      }],
      # Required catch-all - must be last, must match everything.
      [{ service = "http_status:404" }],
    )
  }
}

# v5 dropped the tunnel_token attribute; it moved to a data source.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "web" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.web.id
}

# Installed into the cluster out-of-band; never committed.
output "cloudflared_web_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.web.token
  sensitive = true
}

output "cloudflared_web_tunnel_cname" {
  value = "${cloudflare_zero_trust_tunnel_cloudflared.web.id}.cfargotunnel.com"
}
