# LDAP client configuration, user resolution via nslcd + SSH key lookup
# Imported by hosts that resolve users from the central lldap server.
# not imported by edenprairie (the LDAP server itself) to avoid chicken-and-egg.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cluster = builtins.fromJSON (builtins.readFile ../cluster.json);

  ldapSSHKeyScript = pkgs.writeShellScript "ldap-ssh-keys" ''
    USER="$1"
    LDAPTLS_REQCERT=never ${pkgs.openldap}/bin/ldapsearch -x \
      -o ldif-wrap=no \
      -H ldaps://${cluster.infra.edenprairie}:6360 \
      -D "uid=admin,ou=people,dc=homelab,dc=invalid" \
      -y /etc/ldap-bind-password \
      -b "uid=$USER,ou=people,dc=homelab,dc=invalid" \
      -LLL sshPublicKey 2>/dev/null \
      | ${pkgs.gnused}/bin/sed -n 's/^sshPublicKey: //p'
  '';
in
{
  users.ldap = {
    enable = true;
    server = "ldaps://${cluster.infra.edenprairie}:6360";
    base = "dc=homelab,dc=invalid";
    bind = {
      distinguishedName = "uid=admin,ou=people,dc=homelab,dc=invalid";
      passwordFile = "/etc/ldap-bind-password";
    };
    daemon.enable = true;
    daemon.extraConfig = ''
      tls_reqcert never
      filter passwd (objectClass=person)
      map passwd uid uid
      map passwd homeDirectory "/home/$uid"
      map passwd loginShell "/bin/sh"
      map passwd gecos displayName
    '';
  };

  systemd.tmpfiles.rules = [
    "z /etc/ldap-bind-password 0640 root nslcd -"
  ];

  security.pam.services.sshd.makeHomeDir = true;

  # Place LDAP SSH key script under /etc so sshd considers the path safe
  environment.etc."ssh/ldap-ssh-keys" = {
    source = ldapSSHKeyScript;
    mode = "0555";
  };

  services.openssh.authorizedKeysCommand = "/etc/ssh/ldap-ssh-keys %u";
  services.openssh.authorizedKeysCommandUser = "root";
}
