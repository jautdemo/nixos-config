resource "cloudflare_dns_record" "mx_primary" {
  zone_id  = data.cloudflare_zone.homelab.id
  name     = "homelab.invalid"
  type     = "MX"
  content  = "mail.protonmail.ch"
  priority = 10
  ttl      = 1
  comment  = "protonmail"
}

resource "cloudflare_dns_record" "mx_secondary" {
  zone_id  = data.cloudflare_zone.homelab.id
  name     = "homelab.invalid"
  type     = "MX"
  content  = "mailsec.protonmail.ch"
  priority = 20
  ttl      = 1
  comment  = "protonmail"
}

resource "cloudflare_dns_record" "spf" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "homelab.invalid"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.protonmail.ch ~all\""
  ttl     = 1
  comment = "protonmail"
}

resource "cloudflare_dns_record" "protonmail_verification" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "homelab.invalid"
  type    = "TXT"
  content = "\"protonmail-verification=27067cabe3f86e282c0afeaac8cc066fdb5cb738\""
  ttl     = 1
  comment = "protonmail"
}

# DMARC: p=quarantine tells receivers to spam-folder mail failing SPF/DKIM.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "_dmarc.homelab.invalid"
  type    = "TXT"
  content = "\"v=DMARC1; p=quarantine\""
  ttl     = 1
  comment = "protonmail"
}

resource "cloudflare_dns_record" "dkim1" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "protonmail._domainkey.homelab.invalid"
  type    = "CNAME"
  content = "protonmail.domainkey.dwv6yaa5s2oxxsiedg4mdvrnbwnnjsvvo6kvomtqmgokuslhxr42q.domains.proton.ch"
  proxied = false
  ttl     = 1
  comment = "protonmail"
}

resource "cloudflare_dns_record" "dkim2" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "protonmail2._domainkey.homelab.invalid"
  type    = "CNAME"
  content = "protonmail2.domainkey.dwv6yaa5s2oxxsiedg4mdvrnbwnnjsvvo6kvomtqmgokuslhxr42q.domains.proton.ch"
  proxied = false
  ttl     = 1
  comment = "protonmail"
}

resource "cloudflare_dns_record" "dkim3" {
  zone_id = data.cloudflare_zone.homelab.id
  name    = "protonmail3._domainkey.homelab.invalid"
  type    = "CNAME"
  content = "protonmail3.domainkey.dwv6yaa5s2oxxsiedg4mdvrnbwnnjsvvo6kvomtqmgokuslhxr42q.domains.proton.ch"
  proxied = false
  ttl     = 1
  comment = "protonmail"
}
