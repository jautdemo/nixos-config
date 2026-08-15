{
  description = "NixOS configurations for home infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Separate pin for cloudflared on the tunnel hosts (brainerd, edenprairie):
    # their auto-upgrades only refresh nixpkgs, so the SSH access path never
    # changes unattended. Updated only by attended nix flake update + deploy.
    nixpkgs-cloudflared.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
    };
  };

  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      disko,
      agenix,
      nixos-raspberrypi,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      cluster = builtins.fromJSON (builtins.readFile ./cluster.json);
      ldapConfig = import ./ldap/config.nix;

      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      pkgsFor = sys: nixpkgs.legacyPackages.${sys};
      pkgsUnfree =
        sys:
        import nixpkgs {
          system = sys;
          config.allowUnfree = true;
        };
    in
    rec {
      packages = lib.recursiveUpdate appPackages { x86_64-linux.brainerd-image = brainerd-image; };

      # NixOS disk image for OCI bootstrap, built natively via system.build.OCIImage
      brainerd-image =
        (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
            ./nixos/hosts/brainerd/image-configuration.nix
          ];
        }).config.system.build.OCIImage;

      nixosConfigurations = {
        brainerd = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit (inputs) nixpkgs-cloudflared; };
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./nixos/hosts/brainerd/configuration.nix
          ];
        };

        duluth = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./nixos/hosts/k8s/common.nix
            ./nixos/hosts/k8s/duluth/configuration.nix
          ];
        };
        bemidji = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./nixos/hosts/k8s/common.nix
            ./nixos/hosts/k8s/bemidji/configuration.nix
          ];
        };
        fargo = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./nixos/hosts/k8s/common.nix
            ./nixos/hosts/k8s/fargo/configuration.nix
          ];
        };
        edenprairie = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            inherit nixpkgs nixos-raspberrypi;
            inherit (inputs) nixpkgs-cloudflared;
          };
          modules = [
            agenix.nixosModules.default
            ({ ... }: {
              imports = with nixos-raspberrypi.nixosModules; [
                raspberry-pi-5.base
                raspberry-pi-5.bluetooth
              ];
            })
            ./nixos/hosts/edenprairie/nvme/configuration.nix
          ];
        };
        edenprairie-sd = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {
            inherit nixpkgs nixos-raspberrypi;
            inherit (inputs) nixpkgs-cloudflared;
          };
          modules = [
            agenix.nixosModules.default
            ({ ... }: {
              imports = with nixos-raspberrypi.nixosModules; [
                raspberry-pi-5.base
                raspberry-pi-5.bluetooth
              ];
            })
            ./nixos/hosts/edenprairie/sd/configuration.nix
          ];
        };
      };

      appPackages = forAllSystems (
        sys:
        let
          pkgs = pkgsFor sys;
          pkgsU = pkgsUnfree sys;
          mkApp = import ./apps/mk-app.nix { inherit pkgs; };
          ageIdentity = import ./apps/age-identity.nix { inherit pkgs; };
          clusterHosts = import ./apps/cluster-hosts.nix { inherit lib; };
          pushSecret = import ./apps/push-secret.nix {
            inherit
              pkgs
              cluster
              ageIdentity
              mkApp
              ;
          };
          tf = import ./apps/tf.nix {
            pkgs = pkgsU;
            inherit ageIdentity;
          };
        in
        {
          push-secret = pushSecret;
          tf = tf;
          deploy = import ./apps/deploy.nix { inherit pkgs cluster mkApp; };
          brainerd-bootstrap = import ./apps/brainerd-bootstrap.nix {
            pkgs = pkgsU;
            inherit
              cluster
              tf
              ageIdentity
              mkApp
              ;
          };
          brainerd-wg-setup = import ./apps/brainerd-wg-setup.nix {
            pkgs = pkgsU;
            inherit
              cluster
              lib
              ageIdentity
              mkApp
              ;
          };
          node-join = import ./apps/node-join.nix {
            inherit
              pkgs
              lib
              cluster
              mkApp
              ;
          };
          lldap-bootstrap = import ./apps/lldap-bootstrap.nix {
            inherit
              pkgs
              lib
              cluster
              ldapConfig
              mkApp
              ;
          };
          kerberos-keytabs = import ./apps/kerberos-keytabs.nix {
            inherit
              pkgs
              lib
              cluster
              mkApp
              ;
          };
          protonmail-bridge-setup = import ./apps/protonmail-bridge-setup.nix { inherit pkgs cluster mkApp; };
          nas-deploy = import ./apps/nas-deploy.nix {
            inherit
              pkgs
              lib
              cluster
              mkApp
              ;
          };
          ssh-config = import ./apps/ssh-config.nix { inherit lib cluster mkApp; };
          regenerate-manifests = import ./apps/regenerate-manifests.nix { inherit pkgs cluster mkApp; };
          restore-drill = import ./apps/restore-drill.nix {
            inherit
              pkgs
              cluster
              ageIdentity
              mkApp
              ;
          };
          rotate-host-key = import ./apps/rotate-host-key.nix {
            inherit
              pkgs
              cluster
              lib
              ageIdentity
              mkApp
              clusterHosts
              ;
          };
          restore-host-key = import ./apps/restore-host-key.nix {
            inherit
              pkgs
              cluster
              lib
              ageIdentity
              mkApp
              clusterHosts
              ;
          };
          rotate-ca = import ./apps/rotate-ca.nix { inherit pkgs cluster mkApp; };
        }
      );

      apps = forAllSystems (
        sys:
        lib.mapAttrs (name: p: {
          type = "app";
          program = "${p}/bin/${name}";
        }) appPackages.${sys}
      );
    };
}
