# Publishes cert_not_after_timestamp_seconds for a list of PEM files via the
# node-exporter textfile collector, so Prometheus can alert on expiry. Both
# renewal mechanisms (k8s-pki, stepCerts) renew inside 30 days of expiry, so
# a cert seen closer than that means renewal has stopped working.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.certMetrics;
  promDir = "/var/lib/node-exporter-textfile";
in
{
  options.services.certMetrics = {
    enable = lib.mkEnableOption "certificate expiry textfile metrics";
    certs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Certificate PEM files to watch, keyed by metric label.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The k8s node-exporter DaemonSet mounts this as a hostPath, which must
    # exist before the pod can start.
    systemd.tmpfiles.rules = [ "d ${promDir} 0755 root root -" ];

    systemd.services.cert-metrics = {
      description = "Publish certificate expiry metrics";
      serviceConfig.Type = "oneshot";
      path = [
        pkgs.openssl
        pkgs.coreutils
      ];
      script = ''
        mkdir -p ${promDir}
        TMP=$(mktemp ${promDir}/.cert-metrics.XXXXXX)
        {
          echo '# TYPE cert_not_after_timestamp_seconds gauge'
          echo '# TYPE cert_file_readable gauge'
        ${lib.concatStrings (
          lib.mapAttrsToList (name: path: ''
            if end=$(openssl x509 -enddate -noout -in '${path}' 2>/dev/null); then
              ts=$(date -d "''${end#notAfter=}" +%s)
              printf 'cert_not_after_timestamp_seconds{cert="${name}"} %s\n' "$ts"
              printf 'cert_file_readable{cert="${name}"} 1\n'
            else
              printf 'cert_file_readable{cert="${name}"} 0\n'
            fi
          '') cfg.certs
        )}
          printf 'cert_metrics_last_run_timestamp_seconds %s\n' "$(date +%s)"
        } > "$TMP"
        chmod 0644 "$TMP"
        mv -f "$TMP" ${promDir}/cert-metrics.prom
      '';
    };

    systemd.timers.cert-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 06:15:00";
        Persistent = true;
      };
    };
  };
}
