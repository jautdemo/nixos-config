# Shared configuration for ALL hosts (k8s nodes + RPi + any future hosts)
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../cluster.json);
  keys = cluster.sshKeys;
in
{
  # Imported everywhere; each module is inert until its own enable/config is
  # set per host.
  imports = [
    ./modules/nfs-krb5-ccache.nix
    ./modules/step-cert.nix
    ./modules/krb5-client.nix
    ./modules/cert-metrics.nix
    ./modules/network-selfheal.nix
    ./modules/deployed-rev-metrics.nix
    ./modules/healthchecks-sync.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Declared host keys for every host-to-host SSH path (store sharing,
  # backups, kubectl-via-peer). A hand-grown known_hosts silently breaks on
  # key rotation; this one follows cluster.json.
  programs.ssh.knownHosts = lib.mapAttrs' (
    name: key:
    lib.nameValuePair name {
      publicKey = key;
      extraHostNames = [
        "${name}.infra.homelab.invalid"
      ]
      ++ lib.optional (cluster.nodes ? ${name}) cluster.nodes.${name}
      ++ lib.optional (
        cluster.infra ? ${name} && builtins.isString cluster.infra.${name}
      ) cluster.infra.${name};
    }
  ) cluster.hostKeys;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  users.mutableUsers = false;

  # Root only; non-root users come from LDAP.
  users.users.root = {
    hashedPassword = "!"; # Disable password login
    # every key in cluster.json, so adding one there actually authorises it.
    # No software key belongs here, nothing needs one, and a scoped
    # `command=`/`restrict` key is the answer if a remote build ever does.
    openssh.authorizedKeys.keys = lib.attrValues keys;
  };

  # sshd reads only the declared location: root's keys come from
  # authorized_keys.d, humans' from LDAP via AuthorizedKeysCommand. A file in
  # ~/.ssh then grants nothing at all, so an undeclared file there is inert
  # rather than a way in. mutableUsers = false does not cover these.
  services.openssh.authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];

  security.pam.u2f = {
    enable = true;
    settings = {
      cue = true; # Print "Please touch the device" prompt
      origin = "pam://workstation"; # Must match origin used during key registration
      authfile = pkgs.writeText "u2f_keys" "";
    };
  };
  security.pam.services.login.u2fAuth = true;

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  services.openssh.settings.PasswordAuthentication = false;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # Trust the internal step-ca root (Homelab Root CA) system-wide on every
  # host, so any local service can verify internal certs against the system
  # trust store instead of falling back to plaintext or a per-service CA mount.
  # Inlined (not a runtime path) so it is readable at build time on the remote
  # builder. Same root as /etc/step-ca/certs/root_ca.crt (edenprairie) and
  # /var/lib/kubernetes/pki/ca.pem (k8s nodes).
  security.pki.certificates = [
    (builtins.readFile ../k8s/certs/step-ca-root.pem)
  ];
}
