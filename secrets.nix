# reencrypt with:
#   nix run github:ryantm/agenix -- -r
let
  yubikeyA = "age1yubikey1deadbeef04deadbeef04deadbeef04deadbeef04deadbe"; # serial deadbeef
  yubikeyB = "age1yubikey1deadbeef05deadbeef05deadbeef05deadbeef05deadbe"; # serial deadbeef
  admins = [
    yubikeyA
    yubikeyB
  ];

  # host keys come from cluster.json so knownHosts, recipients and the
  # rotate-host-key app share one source
  hostKeys = (builtins.fromJSON (builtins.readFile ./cluster.json)).hostKeys;
  inherit (hostKeys)
    duluth
    bemidji
    fargo
    edenprairie
    brainerd
    ;
  k8s = [
    duluth
    bemidji
    fargo
  ];

  # offline recovery key, private half only in the password manager
  offline = "age1deadbeef02deadbeef02deadbeef02deadbeef02deadbeef02dead";

in
{
  # Operator-side only: the gateway identity reaches the wg-gateway pod via
  # its SOPS Secret, never via agenix on the nodes.
  "secrets/wireguard-cluster-gw.age".publicKeys = admins;

  "secrets/wireguard-brainerd.age".publicKeys = admins ++ [ brainerd ];

  "secrets/cloudflared-brainerd.age".publicKeys = admins ++ [ brainerd ];

  "secrets/brainerd-root-hash.age".publicKeys = admins ++ [ brainerd ];

  "secrets/cloudflared-edenprairie.age".publicKeys = admins ++ [ edenprairie ];

  "secrets/healthchecks-ping-key.age".publicKeys = admins ++ [
    edenprairie
    brainerd
  ];

  "secrets/restic-offsite.age".publicKeys = admins ++ [ edenprairie ];

  # read-write management API key; healthchecks-sync reconciles with it
  "secrets/healthchecks-api-key.age".publicKeys = admins ++ [
    offline
    edenprairie
  ];

  # rclone proton bootstrap config (credentials only, no session tokens);
  # seeds the writable rclone configs on edenprairie and doubles as the
  # disaster-recovery copy
  "secrets/rclone-proton.age".publicKeys = admins ++ [
    offline
    edenprairie
  ];

  "secrets/k8s-encryption-config.age".publicKeys = k8s ++ admins;

  "secrets/nix-signing-key.age".publicKeys = k8s ++ admins;

  # placed on the nodes by agenix; sources of truth stay on edenprairie
  "secrets/ldap-bind-password.age".publicKeys = k8s ++ admins;
  "secrets/k8s-provisioner-password.age".publicKeys = k8s ++ admins;
  "secrets/k8s-service-account-key.age".publicKeys = k8s ++ admins;

  # captured host identities - a reinstall restores the same key, keeping
  # the host a working agenix recipient. brainerd's is pre-created, installed
  # by brainerd-bootstrap at the next reprovision.
  "secrets/duluth-host-key.age".publicKeys = admins;
  "secrets/bemidji-host-key.age".publicKeys = admins;
  "secrets/fargo-host-key.age".publicKeys = admins;
  "secrets/edenprairie-host-key.age".publicKeys = admins;
  "secrets/brainerd-host-key.age".publicKeys = admins;

  "secrets/nix-store-sharing-key.age".publicKeys = k8s ++ admins;

  "secrets/sops-age.age".publicKeys = admins;

  "secrets/terraform-brainerd.json.age".publicKeys = admins;
}
