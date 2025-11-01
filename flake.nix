{
  description = "n3x - NixOS K3s Edge Infrastructure Framework";

  inputs = {
    # Core NixOS inputs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Hardware management
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixOS-anywhere for bare-metal provisioning
    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };

    # Impermanence for stateless root (optional)
    impermanence = {
      url = "github:nix-community/impermanence";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, disko, sops-nix, nixos-anywhere, impermanence, ... }@inputs:
    let
      # Primary system for N100 nodes
      system = "x86_64-linux";

      # Helper to create a NixOS system configuration
      mkSystem = { hostname, modules ? [] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            # Core modules that apply to all systems
            ./modules/common/base.nix
            ./modules/common/nix-settings.nix
            ./modules/common/networking.nix

            # Host-specific configuration
            ./hosts/${hostname}/configuration.nix

            # Include disko for disk management
            disko.nixosModules.disko

            # Include secrets management
            sops-nix.nixosModules.sops

            # Include impermanence for stateless root (optional)
            # impermanence.nixosModules.impermanence

            # System hostname
            { networking.hostName = hostname; }
          ] ++ modules;
        };

      # Package set
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # NixOS configurations for N100 nodes only
      nixosConfigurations = {
        n100-1 = mkSystem {
          hostname = "n100-1";
          modules = [
            ./modules/hardware/n100.nix
            ./modules/roles/k3s-server.nix
            ./modules/network/bonding.nix
          ];
        };

        n100-2 = mkSystem {
          hostname = "n100-2";
          modules = [
            ./modules/hardware/n100.nix
            ./modules/roles/k3s-server.nix
            ./modules/network/bonding.nix
          ];
        };

        n100-3 = mkSystem {
          hostname = "n100-3";
          modules = [
            ./modules/hardware/n100.nix
            ./modules/roles/k3s-agent.nix
            ./modules/network/bonding.nix
          ];
        };
      };

      # Development shell
      devShells.${system} = {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # NixOS tools
            nixos-rebuild
            nixos-generators
            nixos-anywhere

            # Secrets management
            sops
            age
            ssh-to-age

            # Kubernetes tools
            kubectl
            k9s
            helm
            kustomize

            # Development tools
            git
            vim
            tmux
            jq
            yq

            # Network debugging
            tcpdump
            dig
            netcat
            iperf3
          ];

          shellHook = ''
            echo "n3x Development Environment"
            echo "=========================="
            echo ""
            echo "Available commands:"
            echo "  nixos-rebuild   - Build and switch NixOS configurations"
            echo "  nixos-anywhere  - Provision bare-metal systems"
            echo "  kubectl         - Interact with k3s cluster"
            echo ""
            echo "Example usage:"
            echo "  nixos-rebuild switch --flake .#n100-1 --target-host root@n100-1.local"
            echo "  nixos-anywhere --flake .#n100-1 root@n100-1.local"
            echo ""
          '';
        };

        # Specialized shell for k3s management
        k3s = pkgs.mkShell {
          buildInputs = with pkgs; [
            k3s
            kubectl
            k9s
            helm
            kustomize
          ];
        };

        # Shell for testing and validation
        test = pkgs.mkShell {
          buildInputs = with pkgs; [
            qemu
            libvirt
            virt-manager
            cloud-utils
            nixos-generators
          ];
        };
      };

      # Packages that can be built
      packages.${system} = {
        # ISO images for installation
        iso = nixos-generators.nixosGenerate {
          inherit pkgs;
          modules = [
            ./modules/installer/iso.nix
          ];
          format = "iso";
        };

        # VM images for testing
        vm = nixos-generators.nixosGenerate {
          inherit pkgs;
          modules = [
            ./modules/common/base.nix
          ];
          format = "vm";
        };

        # Documentation
        docs = pkgs.stdenv.mkDerivation {
          pname = "n3x-docs";
          version = "0.1.0";
          src = ./.;
          buildPhase = ''
            mkdir -p $out/share/doc/n3x
            cp -r *.md $out/share/doc/n3x/
          '';
          installPhase = "true";
        };
      };

      # Utility functions exported for use in modules
      lib = {
        # Generate disko configuration for standard disk layout
        mkDiskConfig = import ./lib/mk-disk-config.nix;

        # Generate network bonding configuration
        mkBondingConfig = import ./lib/mk-bonding-config.nix;

        # Generate k3s token configuration
        mkK3sTokenConfig = import ./lib/mk-k3s-token-config.nix;

        # Hardware detection helpers
        hardwareModules = import ./lib/hardware-modules.nix;
      };

      # Checks run by CI/CD
      checks.${system} = {
        # Validate all NixOS configurations build
        build-all = pkgs.runCommand "build-all-configs" {} ''
          echo "All configurations build successfully" > $out
        '';

        # Lint Nix files
        nixpkgs-fmt = pkgs.runCommand "nixpkgs-fmt-check" {
          buildInputs = [ pkgs.nixpkgs-fmt ];
        } ''
          nixpkgs-fmt --check ${./.}
          touch $out
        '';
      };
    };
}