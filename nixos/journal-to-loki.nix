# Ship this host's journal to Loki.
#
# Loki lives in the cluster, so a k8s node logs here only while the cluster is
# up. That still covers the case this exists for: one node dying while the
# other two serve.
{ config, pkgs, ... }:

{
  environment.etc."ssl/certs/step-ca-root.pem" = {
    text = builtins.readFile ../k8s/certs/step-ca-root.pem;
    mode = "0444";
  };

  services.alloy = {
    enable = true;
    configPath = pkgs.writeText "config.alloy" ''
      loki.source.journal "journal" {
        forward_to = [loki.write.loki.receiver]
        labels     = { host = "${config.networking.hostName}", job = "journal" }
      }

      local.file "step_ca_root" {
        filename = "/etc/ssl/certs/step-ca-root.pem"
      }

      loki.write "loki" {
        endpoint {
          url = "https://loki.infra.homelab.invalid:3100/loki/api/v1/push"
          min_backoff_period  = "1s"
          max_backoff_period  = "5m"
          // Retry forever: losing the last words of a dying node is the point.
          max_backoff_retries = 0
          tls_config {
            ca_pem = local.file.step_ca_root.content
          }
        }
      }
    '';
  };
}
