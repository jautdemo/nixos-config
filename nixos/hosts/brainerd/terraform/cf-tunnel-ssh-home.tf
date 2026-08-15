locals {
  # v5 dropped the computed cname; it is always <tunnel id>.cfargotunnel.com.
  ssh_home_tunnel_cname = "${cloudflare_zero_trust_tunnel_cloudflared.ssh_home.id}.cfargotunnel.com"
}

resource "random_id" "tunnel_ssh_home_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "ssh_home" {
  account_id    = var.cloudflare_account_id
  name          = "edenprairie-ssh"
  tunnel_secret = random_id.tunnel_ssh_home_secret.b64_std
  # Local config: the ingress is deployed with the host that serves it, so the
  # two cannot drift.
  config_src = "local"
}

resource "cloudflare_dns_record" "ssh_home" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "ssh-home.homelab.invalid"
  content = local.ssh_home_tunnel_cname
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_zero_trust_access_application" "ssh_home" {
  # pinned to the live value; the v5 default is true
  http_only_cookie_attribute = false
  zone_id                    = data.cloudflare_zone.homelab.id
  name                       = "SSH - home LAN"
  domain                     = "ssh-home.homelab.invalid"
  type                       = "self_hosted"
  session_duration           = "24h"

  allowed_idps              = []
  auto_redirect_to_identity = false

  policies = [
    {
      name       = "Allow named operators"
      precedence = 1
      decision   = "allow"
      include = [
        for email in var.access_allowed_emails : { email = { email = email } }
      ]
    },
    {
      name       = "Deploy tooling (service token)"
      precedence = 2
      decision   = "non_identity"
      include = [
        { service_token = { token_id = cloudflare_zero_trust_access_service_token.home_deploy.id } }
      ]
    },
  ]
}

# Rotate by bumping client_secret_version (v5 has no min_days_for_renewal).
resource "cloudflare_zero_trust_access_service_token" "home_deploy" {
  account_id = var.cloudflare_account_id
  name       = "home-deploy"
}

output "home_deploy_token_id" {
  value     = cloudflare_zero_trust_access_service_token.home_deploy.client_id
  sensitive = true
}

output "home_deploy_token_secret" {
  value     = cloudflare_zero_trust_access_service_token.home_deploy.client_secret
  sensitive = true
}

# Becomes /etc/cloudflared/tunnel.json on edenprairie.
output "edenprairie_tunnel_credentials" {
  value = jsonencode({
    AccountTag   = var.cloudflare_account_id
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.ssh_home.id
    TunnelSecret = random_id.tunnel_ssh_home_secret.b64_std
  })
  sensitive = true
}

# Hardcoded into the host's cloudflared config. Not sensitive.
output "edenprairie_tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.ssh_home.id
}
