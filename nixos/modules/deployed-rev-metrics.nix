# Publishes nixos_deployed_rev{rev=...} via the node-exporter textfile
# collector, from /etc/nixos-config/.deployed-rev (written by the deploy app
# after every sync). The label carries the git revision the host was last
# deployed from. Every host should be on the same revision; Prometheus
# alerts when they differ for long, because that means a deploy covered
# only part of the fleet.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.deployedRevMetrics;
  promDir = "/var/lib/node-exporter-textfile";
in
{
  options.services.deployedRevMetrics.enable = lib.mkEnableOption "deployed flake revision textfile metric";

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${promDir} 0755 root root -" ];

    systemd.services.deployed-rev-metrics = {
      description = "Publish deployed flake revision metric";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p ${promDir}
        TMP=$(mktemp ${promDir}/.deployed-rev.XXXXXX)
        rev=unknown
        if [ -r /etc/nixos-config/.deployed-rev ]; then
          rev=$(tr -cd 'a-f0-9' < /etc/nixos-config/.deployed-rev | head -c 40)
        fi
        # A readable file that sanitizes to nothing must not produce
        # rev="", which neither fleet alert would match.
        [ -n "$rev" ] || rev=unknown
        {
          echo '# TYPE nixos_deployed_rev gauge'
          printf 'nixos_deployed_rev{rev="%s"} 1\n' "$rev"
        } > "$TMP"
        chmod 0644 "$TMP"
        mv -f "$TMP" ${promDir}/deployed-rev.prom
      '';
    };

    systemd.timers.deployed-rev-metrics = {
      wantedBy = [ "timers.target" ];
      # 15 minutes keeps the metric fresh enough for the 2h drift alert
      # window, at negligible cost.
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "15m";
      };
    };
  };
}
