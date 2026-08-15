data "cloudflare_zone" "homelab" {
  filter = {
    name = "homelab.invalid"
  }
}

# No wildcard record, ever. external-dns publishes an explicit record per
# Ingress, so a wildcard adds nothing and actively exposes internal-only names
# that are meant to be NXDOMAIN publicly.

# v5: record names are full fqdns, and allow_overwrite is gone - existing
# records are adopted via import instead.

# Grey-cloud: SSH cannot go through Cloudflare's proxy.
resource "cloudflare_dns_record" "brainerd" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "brainerd.homelab.invalid"
  content = oci_core_public_ip.vps.ip_address
  type    = "A"
  proxied = false
  ttl     = 60
}

resource "cloudflare_dns_record" "mumble" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "mumble.homelab.invalid"
  content = "brainerd.homelab.invalid"
  type    = "CNAME"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "dnstls" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "dnstls.homelab.invalid"
  content = oci_core_public_ip.vps.ip_address
  type    = "A"
  proxied = false
  ttl     = 60
}

# Must be proxied: tunnel routing happens inside Cloudflare's edge.
resource "cloudflare_dns_record" "ssh_brainerd" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "ssh-brainerd.homelab.invalid"
  content = "deadbeef-dead-beef-dead-beefdeadbe01.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "apex" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "homelab.invalid"
  content = oci_core_public_ip.vps.ip_address
  type    = "A"
  proxied = true
  ttl     = 1
}
