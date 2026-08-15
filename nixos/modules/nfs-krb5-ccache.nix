# Maintain Kerberos credential caches for non-root UIDs so that
# rpc.gssd can authenticate NFS mounts on their behalf.
# Each entry maps a UID to a Kerberos principal + keytab.
{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.nfsKrb5Ccache;

  resolvedCreds = map (
    entry:
    entry
    // {
      ccache = if entry.ccache == "" then "/tmp/krb5cc_${toString entry.uid}" else entry.ccache;
      gid = if entry.gid == 0 && entry.uid != 0 then entry.uid else entry.gid;
    }
  ) cfg.credentials;

  refreshScript = pkgs.writeShellScript "nfs-krb5-ccache-refresh" ''
    set -euo pipefail
    ${concatMapStringsSep "\n" (entry: ''
      ${pkgs.krb5}/bin/kinit -k -t "${entry.keytab}" "${entry.principal}" \
        -c "${entry.ccache}"
      chown "${toString entry.uid}:${toString entry.gid}" "${entry.ccache}"
      chmod 0600 "${entry.ccache}"
    '') resolvedCreds}
  '';
in
{
  options.services.nfsKrb5Ccache = {
    enable = mkEnableOption "NFS Kerberos credential cache maintenance for non-root UIDs";

    credentials = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            uid = mkOption {
              type = types.int;
              description = "UID that owns the credential cache.";
            };
            gid = mkOption {
              type = types.int;
              default = 0;
              description = "GID that owns the credential cache. Defaults to uid if not set.";
            };
            principal = mkOption {
              type = types.str;
              description = "Kerberos principal to kinit as.";
            };
            keytab = mkOption {
              type = types.str;
              description = "Path to the keytab containing the principal's key.";
            };
            ccache = mkOption {
              type = types.str;
              default = "";
              description = "Path to the credential cache file. Defaults to /tmp/krb5cc_<uid>.";
            };
          };
        }
      );
      default = [ ];
      description = "List of principal/keytab mappings to maintain.";
    };

    refreshInterval = mkOption {
      type = types.str;
      default = "4h";
      description = "How often to refresh the credential caches (systemd OnUnitActiveSec).";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.nfs-krb5-ccache = {
      description = "Refresh Kerberos credential caches for NFS";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "rpc-gssd.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = refreshScript;
      };
    };

    systemd.timers.nfs-krb5-ccache = {
      description = "Periodically refresh NFS Kerberos ccaches";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.refreshInterval;
      };
    };
  };
}
