# protonmail-bridge: the SMTP relay
{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.stepCerts.protonmail-bridge = {
    cn = "edenprairie.infra.homelab.invalid";
    sans = [
      "edenprairie.infra.homelab.invalid"
      "localhost"
      "127.0.0.1"
    ];
    certFile = "/var/lib/protonmail-bridge/certs/bridge-cert.pem";
    keyFile = "/var/lib/protonmail-bridge/certs/bridge-key.pem";
    unit = "protonmail-bridge.service";
    owner = "protonmail-bridge";
    group = "protonmail-bridge";
    certMode = "0600";
    keyMode = "0600";
  };

  users.users.protonmail-bridge = {
    isSystemUser = true;
    group = "protonmail-bridge";
    home = "/var/lib/protonmail-bridge";
    createHome = true;
  };
  users.groups.protonmail-bridge = { };

  systemd.services.protonmail-bridge = {
    description = "Proton Mail Bridge";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.gnupg
      pkgs.pass
    ];
    environment = {
      HOME = "/var/lib/protonmail-bridge";
      GNUPGHOME = "/var/lib/protonmail-bridge/.gnupg";
      PASSWORD_STORE_DIR = "/var/lib/protonmail-bridge/.password-store";
    };
    preStart = ''
      if ! gpg --list-keys "protonmail-bridge" >/dev/null 2>&1; then
        gpg --batch --gen-key <<EOF
      Key-Type: RSA
      Key-Length: 2048
      Name-Real: protonmail-bridge
      Name-Email: bridge@localhost
      Expire-Date: 0
      %no-protection
      %commit
      EOF
      fi
      if [ ! -f "$PASSWORD_STORE_DIR/.gpg-id" ]; then
        pass init "protonmail-bridge"
      fi
    '';
    serviceConfig = {
      ExecStart = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --noninteractive --log-level info";
      Restart = "on-failure";
      RestartSec = "10s";
      User = "protonmail-bridge";
      Group = "protonmail-bridge";
      StateDirectory = "protonmail-bridge";
    };
  };

  # Bridge only listens on 127.0.0.1, so proxy 0.0.0.0:11025 -> 1025 and
  # 0.0.0.0:11143 -> 1143. These must track Bridge's DEFAULT ports: a vault
  # reset restores them, and hand-set ports then silently match nothing.
  systemd.services.protonmail-bridge-smtp-proxy = {
    description = "Proxy LAN SMTP to protonmail-bridge";
    after = [ "protonmail-bridge.service" ];
    requires = [ "protonmail-bridge.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:1025";
      DynamicUser = true;
    };
  };
  systemd.sockets.protonmail-bridge-smtp-proxy = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "0.0.0.0:11025" ];
  };

  systemd.services.protonmail-bridge-imap-proxy = {
    description = "Proxy LAN IMAP to protonmail-bridge";
    after = [ "protonmail-bridge.service" ];
    requires = [ "protonmail-bridge.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:1143";
      DynamicUser = true;
    };
  };
  systemd.sockets.protonmail-bridge-imap-proxy = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "0.0.0.0:11143" ];
  };

  # Asserts the two things a Bridge vault reset silently breaks: listen port
  # and TLS certificate. --cacert REPLACES the trust store. Uses the LAN port
  # so the proxy hop is exercised too.
  systemd.services.bridge-tls-check = {
    description = "Verify protonmail-bridge serves a step-ca certificate";
    after = [ "protonmail-bridge.service" ];
    path = [ pkgs.curl ];
    serviceConfig.Type = "oneshot";
    script = ''
      if curl -sS --ssl-reqd --max-time 20 \
           --cacert /etc/step-ca/certs/root_ca.crt \
           --url smtp://edenprairie.infra.homelab.invalid:11025 \
           -X NOOP >/dev/null 2>/tmp/bridge-tls-check.err; then
        echo "bridge TLS OK on 11025, certificate chains to the step-ca root"
      else
        echo "BRIDGE TLS CHECK FAILED on 11025 - mail will break silently" >&2
        echo "  curl: $(cat /tmp/bridge-tls-check.err)" >&2
        echo "  likely: vault reset moved the listen ports, or the TLS cert" >&2
        echo "  reverted to self-signed. See apps/protonmail-bridge-setup.nix." >&2
        exit 1
      fi
    '';
  };

  systemd.timers.bridge-tls-check = {
    description = "Periodic protonmail-bridge TLS verification";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "30min";
      Persistent = true;
    };
  };
}
