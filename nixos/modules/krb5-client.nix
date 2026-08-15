# Kerberos client for the HOMELAB.INVALID realm. DNS lookups are off: the KDC is
# named here, so Kerberos keeps working when DNS does not.
{ config, lib, ... }:

let
  cfg = config.services.krb5Client;
  realm = "HOMELAB.INVALID";
  kdc = "edenprairie.infra.homelab.invalid";
in
{
  options.services.krb5Client.enable = lib.mkEnableOption "Kerberos client configuration for the ${realm} realm";

  config = lib.mkIf cfg.enable {
    security.krb5 = {
      enable = true;
      settings = {
        libdefaults = {
          default_realm = realm;
          dns_lookup_realm = false;
          dns_lookup_kdc = false;
        };
        realms.${realm} = {
          kdc = kdc;
          admin_server = kdc;
        };
        domain_realm = {
          ".infra.homelab.invalid" = realm;
          "infra.homelab.invalid" = realm;
        };
      };
    };
  };
}
