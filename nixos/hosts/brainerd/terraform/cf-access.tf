# Break-glass: OCI Console -> instance -> Console connection, root password
# from the password manager. No Cloudflare, tunnel or DNS in that path.
#
# v5: app-scoped policies live inline on the application. The standalone
# cloudflare_zero_trust_access_policy resource is account-level (reusable)
# only and cannot adopt the policies these apps already have.
resource "cloudflare_zero_trust_access_application" "ssh_brainerd" {
  # pinned to the live value; the v5 default is true
  http_only_cookie_attribute = false
  zone_id                    = data.cloudflare_zone.homelab.id
  name                       = "SSH - brainerd (edge)"
  domain                     = "ssh-brainerd.homelab.invalid"
  type                       = "self_hosted"
  session_duration           = "24h"

  # No IdP on the account; this is the built-in one-time PIN.
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
        { service_token = { token_id = cloudflare_zero_trust_access_service_token.brainerd_deploy.id } }
      ]
    },
  ]
}

# Rotate by bumping client_secret_version (v5 has no min_days_for_renewal).
resource "cloudflare_zero_trust_access_service_token" "brainerd_deploy" {
  account_id = var.cloudflare_account_id
  name       = "brainerd-deploy"
}
