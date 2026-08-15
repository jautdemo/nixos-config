# Shared by rotate-host-key and restore-host-key: both dispatch on "every
# host in cluster.hostKeys, resolved to its IP" via a shell `case`.
{ lib }:
let
  # k8s nodes and infra hosts live in separate cluster.json maps; hostKeys
  # spans both.
  hostIp =
    cluster: name: if cluster.nodes ? ${name} then cluster.nodes.${name} else cluster.infra.${name};
in
{
  hosts = cluster: lib.attrNames cluster.hostKeys;
  # One case arm per host; `arm` maps (name, ip) to the arm's command.
  ipCase =
    cluster: arm:
    lib.concatMapStringsSep "\n" (h: "${h}) ${arm h (hostIp cluster h)} ;;") (
      lib.attrNames cluster.hostKeys
    );
}
