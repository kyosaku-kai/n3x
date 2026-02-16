{
  description = "NixOS configurations for n3x build runners";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Secrets management
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, agenix, disko, ... }:
    let
      # Systems we build runners for
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Common module imports for all runner hosts
      commonModules = [
        agenix.nixosModules.default
        disko.nixosModules.disko
        ./modules/gitlab-runner.nix
        ./modules/apt-cacher-ng.nix
        ./modules/yocto-cache.nix
        ./modules/nix-config.nix
        ./modules/disko-zfs.nix
        ./modules/harmonia.nix
        ./modules/cache-signing.nix
        ./modules/internal-ca.nix
        ./modules/caddy.nix
        ./modules/first-boot-format.nix
      ];
    in
    {
      nixosModules = {
        gitlab-runner = import ./modules/gitlab-runner.nix;
        apt-cacher-ng = import ./modules/apt-cacher-ng.nix;
        yocto-cache = import ./modules/yocto-cache.nix;
        nix-config = import ./modules/nix-config.nix;
        disko-zfs = import ./modules/disko-zfs.nix;
        harmonia = import ./modules/harmonia.nix;
        cache-signing = import ./modules/cache-signing.nix;
        internal-ca = import ./modules/internal-ca.nix;
        caddy = import ./modules/caddy.nix;
        first-boot-format = import ./modules/first-boot-format.nix;
      };

      nixosConfigurations = {
        # x86_64 EC2 runner
        ec2-x86_64 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = commonModules ++ [
            ./hosts/ec2-x86_64.nix
            {
              # AMI-only config: first-boot-format runs on initial boot to format
              # secondary EBS volumes. Not needed for nixos-anywhere (disko handles it).
              # image.modules.amazon is a deferred module — config merges into the
              # image variant (system.build.images.amazon) but not the base config.
              image.modules.amazon = {
                n3x.first-boot-format.enable = true;
              };
            }
          ];
        };

        # aarch64 Graviton runner
        ec2-graviton = nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = commonModules ++ [
            ./hosts/ec2-graviton.nix
            {
              image.modules.amazon = {
                n3x.first-boot-format.enable = true;
              };
            }
          ];
        };

        # Developer workstation template
        dev-workstation = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = commonModules ++ [ ./hosts/dev-workstation.nix ];
        };

        # ZFS cluster prototype: 3x Intel N100 mini PCs
        zfs-proto-1 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = commonModules ++ [ ./hosts/zfs-proto-1.nix ];
        };
        zfs-proto-2 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = commonModules ++ [ ./hosts/zfs-proto-2.nix ];
        };
        zfs-proto-3 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = commonModules ++ [ ./hosts/zfs-proto-3.nix ];
        };

        # On-prem bare-metal runner (KVM for VM tests, HIL)
        on-prem-runner = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = commonModules ++ [ ./hosts/on-prem-runner.nix ];
        };
      };

      # Custom NixOS AMIs for EC2 deployment
      # Build: nix build '.#packages.x86_64-linux.ami-ec2-x86_64'
      # Uses the native 25.11 image framework (system.build.images.amazon):
      #   - image.modules.amazon (in nixosConfigurations above) injects AMI-only config
      #   - system.build.images.amazon uses extendModules to compose the builder
      #   - No manual builder module import needed — the framework handles it
      # first-boot-format is AMI-only via image.modules.amazon (not in base config).
      # nixos-anywhere deployments use the base nixosConfiguration + disko instead.
      packages = {
        x86_64-linux.ami-ec2-x86_64 =
          self.nixosConfigurations.ec2-x86_64.config.system.build.images.amazon;

        aarch64-linux.ami-ec2-graviton =
          self.nixosConfigurations.ec2-graviton.config.system.build.images.amazon;
      };

      # Formatter for nix fmt
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
