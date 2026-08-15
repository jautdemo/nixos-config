# Minimal NixOS bootstrap image for the OCI brainerd VPS.
# Uses the nixpkgs OCIImage build output for correct OCI disk layout and boot.
# Full config is pushed afterwards via: nix run .#deploy -- brainerd
{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [ ../../common.nix ];

  networking.hostName = "brainerd";
  networking.useDHCP = true;

  system.stateVersion = "25.05";
}
