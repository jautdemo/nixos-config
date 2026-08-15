# LDAP schema, users, groups. Apply with: nix run .#lldap-bootstrap
{
  baseDN = "dc=homelab,dc=invalid";

  # Custom user attributes to create in lldap (beyond built-in ones)
  customUserAttributes = [
    {
      name = "uidnumber";
      type = "INTEGER";
      isList = false;
    }
    {
      name = "gidnumber";
      type = "INTEGER";
      isList = false;
    }
    {
      name = "sshpublickey";
      type = "STRING";
      isList = true;
    }
  ];

  # Users, each user gets a POSIX identity for NSS/SSH
  # Passwords are set interactively on first creation (not stored here).
  users = {
    jdoe = {
      displayName = "Jay";
      firstName = "Jay";
      lastName = "Doe";
      email = "jdoe@homelab.invalid";
      uidnumber = 10000;
      gidnumber = 10000;
      sshPublicKeys = [
        "ssh-rsa AAAADEADBEEF17DEADBEEF17DEADBEEF17DEADBEEF17DEADBEEF17DEADBEEF17DEADBEEF17DEADBE= admin@workstation"
        "ssh-rsa AAAADEADBEEF16DEADBEEF16DEADBEEF16DEADBEEF16DEADBEEF16DEADBEEF16DEADBEEF16DEADBE= workstation2"

      ];
    };
    asmith = {
      displayName = "Alex Smith";
      firstName = "Alex";
      lastName = "Smith";
      email = "asmith@homelab.invalid";
      uidnumber = 10001;
      gidnumber = 10000;
      sshPublicKeys = [ ];
    };
    bjones = {
      displayName = "Blake Jones";
      firstName = "Blake";
      lastName = "Jones";
      email = "bjones@homelab.invalid";
      uidnumber = 10002;
      gidnumber = 10000;
      sshPublicKeys = [ ];
    };
  };

  # Service accounts, used for LDAP bind or as POSIX identities for services.
  # needsPassword = true (default): auto-generate password, store on edenprairie.
  # needsPassword = false: no password (POSIX-only identity, no login).
  # Optional: uidnumber/gidnumber for accounts that need a POSIX identity.
  serviceAccounts = {
    nas-bind = {
      displayName = "NAS Bind Account";
      firstName = "NAS";
      lastName = "Bind";
      email = "nas-bind@homelab.invalid";
      uidnumber = 11001;
      gidnumber = 11001;
    };
    authelia-bind = {
      displayName = "Authelia Bind Account";
      firstName = "Authelia";
      lastName = "Bind";
      email = "authelia-bind@homelab.invalid";
      uidnumber = 11002;
      gidnumber = 11002;
    };
    media = {
      displayName = "Media Service";
      firstName = "Media";
      lastName = "Service";
      email = "media@homelab.invalid";
      needsPassword = false;
      uidnumber = 11000;
      gidnumber = 11000;
    };
    immich = {
      displayName = "Immich Service";
      firstName = "Immich";
      lastName = "Service";
      email = "immich@homelab.invalid";
      needsPassword = false;
      uidnumber = 11003;
      gidnumber = 11003;
    };
  };

  groups = [
    "nextcloud_users"
    "family"
    "friends"
    "home_users"
    "server_admins"
    "all_users"
    "stream"
    "media"
    "immich_users"
  ];
  memberships = {
    server_admins = [ "jdoe" ];
    home_users = [
      "jdoe"
      "asmith"
    ];
    family = [
      "jdoe"
      "asmith"
    ];
    all_users = [
      "jdoe"
      "asmith"
      "bjones"
    ];
    nextcloud_users = [
      "jdoe"
      "asmith"
    ];
    lldap_strict_readonly = [ "nas-bind" ];
    # Authelia's self-service password reset needs write access to
    # userPassword; lldap_password_manager grants exactly that without full
    # admin rights. strict_readonly alone fails with LDAP code 50.
    lldap_password_manager = [ "authelia-bind" ];
    media = [ "media" ];
    # Least privilege: this user only uses Immich, so no family/home_users membership.
    immich_users = [ "bjones" ];
  };
}
