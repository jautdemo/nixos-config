{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    ../arrow-lake-gpu.nix
    (import ../kubernetes.nix {
      keepalivedPriority = 110; # duluth = primary
      autoUpgradeDay = "Fri";
    })
  ];

  networking.hostName = "duluth";
}
