{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    ../arrow-lake-gpu.nix
    (import ../kubernetes.nix {
      keepalivedPriority = 100; # bemidji = secondary
      autoUpgradeDay = "Wed";
    })
  ];

  networking.hostName = "bemidji";

}
