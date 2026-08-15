# v5 split cloudflare_zone_settings_override into one resource per setting.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = data.cloudflare_zone.homelab.id
  setting_id = "ssl"
  value      = "strict"
}
