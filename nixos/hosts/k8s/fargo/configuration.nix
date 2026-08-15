{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    (import ../kubernetes.nix {
      keepalivedPriority = 90; # fargo = tertiary
      autoUpgradeDay = "Mon";
    })
  ];

  networking.hostName = "fargo";
}
