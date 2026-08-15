# Issue and renew a server certificate from step-ca, for services that cannot
# do ACME themselves. Renews only inside 30 days of expiry
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.stepCerts;
  cluster = builtins.fromJSON (builtins.readFile ../../cluster.json);
  caURL = "https://${cluster.infra.edenprairie}:8443";
  caCert = "/etc/step-ca/certs/root_ca.crt";

  mkService =
    name: c:
    lib.nameValuePair "${name}-cert" {
      description = "Issue/renew ${name} TLS certificate via step-ca";
      after = [
        "step-ca.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "step-ca.service" ];
      wantedBy = [ "multi-user.target" ];
      # Gate the consumer: it must not start with a missing or expired cert.
      before = lib.optional (c.unit != null) c.unit;
      requiredBy = lib.optional (c.unit != null) c.unit;
      path = [
        pkgs.step-cli
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        mkdir -p "$(dirname ${c.certFile})"

        if [ -f "${c.certFile}" ] && step certificate verify "${c.certFile}" --roots ${caCert} 2>/dev/null; then
          expiry=$(step certificate inspect "${c.certFile}" --format json | jq -r '.validity.end')
          expiry_epoch=$(date -d "$expiry" +%s)
          if [ "$expiry_epoch" -gt "$(( $(date +%s) + 2592000 ))" ]; then
            echo "${name}: certificate still valid, skipping renewal"
            exit 0
          fi
        fi

        echo "${name}: issuing certificate"
        step ca certificate \
          "${c.cn}" "${c.certFile}" "${c.keyFile}" \
          ${lib.concatMapStringsSep " " (s: "--san \"${s}\"") c.sans} \
          --provisioner k8s \
          --provisioner-password-file /etc/step-ca/k8s-provisioner-password \
          --ca-url "${caURL}" \
          --root ${caCert} \
          --not-after 8760h \
          --force

        chown ${c.owner}:${c.group} "${c.certFile}" "${c.keyFile}"
        chmod ${c.certMode} "${c.certFile}"
        chmod ${c.keyMode} "${c.keyFile}"
      '';
    };

  mkTimer =
    name: _:
    lib.nameValuePair "${name}-cert" {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
in
{
  options.services.stepCerts = lib.mkOption {
    default = { };
    description = "Server certificates to obtain from step-ca, keyed by service name.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          cn = lib.mkOption { type = lib.types.str; };
          sans = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          certFile = lib.mkOption { type = lib.types.str; };
          keyFile = lib.mkOption { type = lib.types.str; };
          # The unit that must not start without this certificate.
          unit = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          owner = lib.mkOption {
            type = lib.types.str;
            default = "root";
          };
          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
          };
          certMode = lib.mkOption {
            type = lib.types.str;
            default = "0644";
          };
          keyMode = lib.mkOption {
            type = lib.types.str;
            default = "0600";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services = lib.mapAttrs' mkService cfg;
    systemd.timers = lib.mapAttrs' mkTimer cfg;
  };
}
