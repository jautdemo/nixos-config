# Control-plane certificates from step-ca, not the NixOS module's own CA
# (easyCerts = false), so there is one root instead of two.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../../cluster.json);
  hostname = config.networking.hostName;
  nodeIP = cluster.nodes.${hostname};
  apiVIP = cluster.apiVIP;
  pki = "/var/lib/kubernetes/pki";
  caURL = "https://edenprairie.infra.homelab.invalid:8443";
  serviceCidrFirstIP = "10.0.0.1";
in
{
  # Requests certs from step-ca on boot. Needs ca.pem, provisioner-password
  # and the service-account keypair already in ${pki}/; a deploy places them
  # via agenix. The service-account keypair cannot be reissued: replacing it
  # invalidates every existing ServiceAccount token.
  systemd.services.k8s-pki-request = {
    description = "Request Kubernetes PKI certificates from step-ca";
    wantedBy = [ "multi-user.target" ];
    before = [
      "etcd.service"
      "kube-apiserver.service"
      "kubelet.service"
      "kube-controller-manager.service"
      "kube-scheduler.service"
    ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.step-cli ];
    script = ''
      set -euo pipefail
      mkdir -p "${pki}"

      # Require bootstrap files
      for f in "${pki}/ca.pem" "${pki}/provisioner-password" \
               "${pki}/service-account.pem" "${pki}/service-account-key.pem"; do
        if [ ! -f "$f" ]; then
          echo "ERROR: $f not found." >&2
          echo "Deploy this node: agenix places the pki bootstrap files" >&2
          exit 1
        fi
      done

      request_cert() {
        local name="$1" cn="$2"
        shift 2
        local cert="${pki}/$name.pem" key="${pki}/$name-key.pem"
        if [ -f "$cert" ] && [ -f "$key" ]; then
          # Renew if expiring within 30 days
          if step certificate needs-renewal --expires-in 720h "$cert" 2>/dev/null; then
            echo "  Renewing $name (expires soon)"
            rm -f "$cert" "$key"
          else
            return 0
          fi
        fi
        echo "  Requesting $name"
        step ca certificate "$cn" "$cert" "$key" \
          --ca-url "${caURL}" \
          --root "${pki}/ca.pem" \
          --provisioner k8s \
          --provisioner-password-file "${pki}/provisioner-password" \
          --not-after 8760h \
          --force \
          "$@"
      }

      echo "==> Requesting certificates from step-ca (skipping existing)"

      request_cert "etcd" "etcd-${hostname}" \
        --san ${nodeIP} --san 127.0.0.1 --san localhost --san ${hostname}

      request_cert "kube-apiserver" "kube-apiserver" \
        --san ${nodeIP} --san ${apiVIP} --san 127.0.0.1 --san ${serviceCidrFirstIP} \
        --san kubernetes --san kubernetes.default --san kubernetes.default.svc \
        --san kubernetes.default.svc.cluster.local --san ${hostname}

      request_cert "kubelet" "system:node:${hostname}" \
        --san ${nodeIP} --san 127.0.0.1 --san ${hostname} \
        --set 'Organization=["system:nodes"]'

      request_cert "kubelet-client" "system:node:${hostname}" \
        --set 'Organization=["system:nodes"]'

      request_cert "apiserver-etcd-client" "kube-apiserver-etcd-client"

      request_cert "apiserver-kubelet-client" "kube-apiserver-kubelet-client" \
        --set 'Organization=["system:masters"]'

      request_cert "apiserver-proxy-client" "front-proxy-client"

      request_cert "kube-controller-manager-client" "system:kube-controller-manager"

      request_cert "kube-scheduler-client" "system:kube-scheduler"

      request_cert "cluster-admin" "cluster-admin" \
        --set 'Organization=["system:masters"]'

      # kube-proxy is disabled (Cilium kubeProxyReplacement).
      # Remove any leftover cert so the daily renewal check never trips on a
      # cert nothing requests.
      rm -f "${pki}/kube-proxy-client.pem" "${pki}/kube-proxy-client-key.pem"

      # skip symlinks: agenix owns the files it links in and their perms
      find "${pki}" -maxdepth 1 -type f -exec chown kubernetes:kubernetes {} +
      for f in "${pki}"/*.pem; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        chmod 644 "$f"
      done
      for f in "${pki}"/*-key.pem; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        chmod 600 "$f"
      done
      chown etcd:etcd "${pki}/etcd-key.pem"
      chown root:kubernetes "${pki}/cluster-admin-key.pem"
      chmod 0640 "${pki}/cluster-admin-key.pem"

      # Ensure etcd data directory exists (etcd runs as non-root)
      mkdir -p /var/lib/etcd
      chown etcd:etcd /var/lib/etcd

      echo "==> PKI ready"
    '';
  };

  systemd.services.etcd.after = [ "k8s-pki-request.service" ];
  systemd.services.etcd.requires = [ "k8s-pki-request.service" ];
  systemd.services.kube-apiserver.requires = [ "k8s-pki-request.service" ];
  systemd.services.kubelet.after = [ "k8s-pki-request.service" ];
  systemd.services.kubelet.requires = [ "k8s-pki-request.service" ];
  systemd.services.kube-controller-manager.after = [ "k8s-pki-request.service" ];
  systemd.services.kube-controller-manager.requires = [ "k8s-pki-request.service" ];
  systemd.services.kube-scheduler.after = [ "k8s-pki-request.service" ];
  systemd.services.kube-scheduler.requires = [ "k8s-pki-request.service" ];

  # Re-runs k8s-pki-request which renews any cert expiring within 30 days.
  systemd.timers.k8s-pki-renewal = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
  systemd.services.k8s-pki-renewal = {
    description = "Renew Kubernetes PKI certificates approaching expiry";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.step-cli ];
    script = ''
      set -euo pipefail
      # Only trigger a full restart cycle if any cert actually needs renewal
      needs_renewal=false
      for cert in "${pki}"/*.pem; do
        [ -f "$cert" ] || continue
        [[ "$cert" == *-key.pem ]] && continue
        [[ "$cert" == */ca.pem ]] && continue
        [[ "$cert" == */service-account.pem ]] && continue
        if step certificate needs-renewal --expires-in 720h "$cert" 2>/dev/null; then
          echo "Certificate needs renewal: $cert"
          needs_renewal=true
        fi
      done
      if [ "$needs_renewal" = true ]; then
        echo "==> Triggering cert renewal and service restart"
        systemctl restart k8s-pki-request.service
      else
        echo "==> All certificates valid, no renewal needed"
      fi
    '';
  };
}
