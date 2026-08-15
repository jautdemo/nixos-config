# step-ca: the internal CA
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../../../cluster.json);

  k8sX509Template = pkgs.writeText "k8s.tpl" ''
    {
      "subject": {
        "commonName": {{ toJson .Subject.CommonName }}
        {{- if .Insecure.User.Organization }},
        "organization": {{ toJson .Insecure.User.Organization }}
        {{- end }}
      },
      "sans": {{ toJson .SANs }},
      "keyUsage": ["keyEncipherment", "digitalSignature"],
      "extKeyUsage": ["serverAuth", "clientAuth"]
    }
  '';
in
{
  systemd.services.step-ca = {
    description = "Smallstep CA";
    after = [
      "network-online.target"
      "step-ca-provisioners.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "step-ca-provisioners.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/etc/step-ca/config/ca.json";
    serviceConfig = {
      ExecStart = "${pkgs.step-ca}/bin/step-ca /etc/step-ca/config/ca.json --password-file /etc/step-ca/password";
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = "STEPPATH=/etc/step-ca";
    };
  };

  systemd.services.step-ca-provisioners = {
    description = "Ensure step-ca provisioners and certs are configured";
    unitConfig.ConditionPathExists = "/etc/step-ca/config/ca.json";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "STEPPATH=/etc/step-ca";
    };
    path = [
      pkgs.step-cli
      pkgs.jq
      pkgs.openssl
    ];
    script = ''
      set -euo pipefail
      CA_JSON="/etc/step-ca/config/ca.json"
      EXPECTED_SANS='["edenprairie.infra.homelab.invalid","${cluster.infra.edenprairie}"]'

      mkdir -p /etc/step-ca/templates
      cp -f ${k8sX509Template} /etc/step-ca/templates/k8s.tpl

      # Ensure dnsNames in ca.json match expected values
      current_dns=$(jq -cS '.dnsNames' "$CA_JSON")
      expected_dns=$(echo "$EXPECTED_SANS" | jq -cS '.')
      if [ "$current_dns" != "$expected_dns" ]; then
        echo "Updating dnsNames in ca.json: $current_dns -> $expected_dns"
        jq --argjson dns "$EXPECTED_SANS" '.dnsNames = $dns' "$CA_JSON" > /tmp/ca.json.new \
          && mv /tmp/ca.json.new "$CA_JSON"
      fi

      # Ensure intermediate cert has correct SANs
      CERT="/etc/step-ca/certs/intermediate_ca.crt"
      if [ -f "$CERT" ]; then
        cert_sans=$(step certificate inspect "$CERT" --format json \
          | jq -r '[.extensions.subject_alt_name.dns_names // [], .extensions.subject_alt_name.ip_addresses // []] | flatten | sort | join(",")')
        expected_sorted=$(echo "$EXPECTED_SANS" | jq -r 'sort | join(",")')
        if [ "$cert_sans" != "$expected_sorted" ]; then
          echo "Intermediate cert SANs mismatch: have=$cert_sans want=$expected_sorted"
          echo "Re-issuing intermediate certificate..."
          step certificate create "Homelab Intermediate CA" \
            "$CERT" /etc/step-ca/secrets/intermediate_ca_key \
            --profile intermediate-ca \
            --ca /etc/step-ca/certs/root_ca.crt \
            --ca-key /etc/step-ca/secrets/root_ca_key \
            --san edenprairie.infra.homelab.invalid \
            --san ${cluster.infra.edenprairie} \
            --password-file /etc/step-ca/password \
            --ca-password-file /etc/step-ca/password \
            --force
          echo "Intermediate cert re-issued"
        fi
      fi

      if [ ! -f /etc/step-ca/k8s-provisioner-password ]; then
        head -c 32 /dev/urandom | base64 > /etc/step-ca/k8s-provisioner-password
        chmod 600 /etc/step-ca/k8s-provisioner-password
      fi

      # Add k8s JWK provisioner (for k8s node cert requests)
      if ! jq -e '.authority.provisioners[] | select(.name == "k8s")' "$CA_JSON" > /dev/null 2>&1; then
        echo "Adding k8s JWK provisioner..."
        step ca provisioner add k8s --type JWK \
          --x509-template /etc/step-ca/templates/k8s.tpl \
          --x509-max-dur 8760h \
          --x509-default-dur 8760h \
          --create --password-file /etc/step-ca/k8s-provisioner-password
      fi

      # Ensure k8s provisioner uses templateFile
      if jq -e '.authority.provisioners[] | select(.name == "k8s") | .options.x509.template' "$CA_JSON" > /dev/null 2>&1; then
        echo "Switching k8s provisioner to templateFile reference..."
        jq '(.authority.provisioners[] | select(.name == "k8s") | .options.x509) |= (del(.template) | .templateFile = "/etc/step-ca/templates/k8s.tpl")' \
          "$CA_JSON" > /tmp/ca.json.new && mv /tmp/ca.json.new "$CA_JSON"
      fi

      # Add ACME provisioner (for cert-manager)
      if ! jq -e '.authority.provisioners[] | select(.name == "acme")' "$CA_JSON" > /dev/null 2>&1; then
        echo "Adding ACME provisioner..."
        step ca provisioner add acme --type ACME
      fi

      # Generate service-account key pair for k8s (shared across all nodes)
      mkdir -p /etc/step-ca/k8s
      if [ ! -f /etc/step-ca/k8s/service-account-key.pem ]; then
        echo "Generating service-account key pair..."
        openssl genrsa -out /etc/step-ca/k8s/service-account-key.pem 2048
        openssl rsa -in /etc/step-ca/k8s/service-account-key.pem -pubout \
          -out /etc/step-ca/k8s/service-account.pem
        chmod 600 /etc/step-ca/k8s/service-account-key.pem
      fi

      echo "Provisioners OK"
    '';
  };

  services.stepCerts.lldap = {
    cn = "ldap.homelab.invalid";
    sans = [
      "ldap.homelab.invalid"
      "edenprairie.infra.homelab.invalid"
      cluster.infra.edenprairie
    ];
    certFile = "/etc/lldap/tls/cert.pem";
    keyFile = "/etc/lldap/tls/cert.key";
    unit = "lldap.service";
    certMode = "0644";
    # lldap is a DynamicUser with no stable uid, so the key is group-read
    # for a group only lldap joins - nothing else on the box can read it.
    group = "lldap-tls";
    keyMode = "0640";
  };

  users.groups.lldap-tls = { };
  systemd.services.lldap.serviceConfig.SupplementaryGroups = [ "lldap-tls" ];

  services.certMetrics = {
    enable = true;
    certs = {
      step-ca-root = "/etc/step-ca/certs/root_ca.crt";
      step-ca-intermediate = "/etc/step-ca/certs/intermediate_ca.crt";
      lldap = "/etc/lldap/tls/cert.pem";
      protonmail-bridge = "/var/lib/protonmail-bridge/certs/bridge-cert.pem";
    };
  };

  # Every trust store in the fleet is built from the repo's copy of the root
  # (k8s/certs/step-ca-root.pem).
  systemd.services.ca-root-check = {
    description = "Verify the repo CA root contains the live step-ca root";
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.openssl
      pkgs.coreutils
      pkgs.gawk
    ];
    script = ''
      PROM=/var/lib/node-exporter-textfile
      mkdir -p "$PROM"
      SPLIT=$(mktemp -d)
      TMP=$(mktemp "$PROM/.ca-root-check.XXXXXX")
      trap 'rm -rf "$SPLIT" "$TMP"' EXIT

      live=$(openssl x509 -in /etc/step-ca/certs/root_ca.crt -noout -fingerprint -sha256)
      match=0
      if [ -r /etc/nixos-config/k8s/certs/step-ca-root.pem ]; then
        awk -v d="$SPLIT" '
          /-----BEGIN CERTIFICATE-----/ { n++; f = d "/" n ".pem" }
          f { print > f }
          /-----END CERTIFICATE-----/   { close(f); f = "" }
        ' /etc/nixos-config/k8s/certs/step-ca-root.pem
        for f in "$SPLIT"/*.pem; do
          [ -e "$f" ] || continue
          [ "$(openssl x509 -in "$f" -noout -fingerprint -sha256)" = "$live" ] && match=1
        done
      fi
      {
        echo '# TYPE stepca_root_in_repo gauge'
        printf 'stepca_root_in_repo %s\n' "$match"
      } > "$TMP"
      chmod 0644 "$TMP"
      mv -f "$TMP" "$PROM/ca-root-check.prom"
    '';
  };

  systemd.timers.ca-root-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:30:00";
      Persistent = true;
    };
  };

}
