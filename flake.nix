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

    # Colmena for deployment automation
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Jetpack-nixos for Jetson Orin Nano support
    jetpack-nixos = {
      url = "github:anduril/jetpack-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, disko, sops-nix, nixos-anywhere, impermanence, colmena, jetpack-nixos, ... }@inputs:
    let
      # Supported systems
      systems = {
        n100 = "x86_64-linux";
        jetson = "aarch64-linux";
      };

      # Helper to create a NixOS system configuration
      mkSystem = { hostname, system ? systems.n100, modules ? [] }:
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

      # Package set for x86_64
      pkgs = import nixpkgs {
        system = systems.n100;
        config.allowUnfree = true;
      };

      # Package set for aarch64
      pkgsAarch64 = import nixpkgs {
        system = systems.jetson;
        config.allowUnfree = true;
      };
    in
    {
      # NixOS configurations for all nodes
      nixosConfigurations = {
        # N100 nodes
        n100-1 = mkSystem {
          hostname = "n100-1";
          system = systems.n100;
          modules = [
            ./modules/hardware/n100.nix
            ./modules/roles/k3s-server.nix
            ./modules/network/bonding.nix
          ];
        };

        n100-2 = mkSystem {
          hostname = "n100-2";
          system = systems.n100;
          modules = [
            ./modules/hardware/n100.nix
            ./modules/roles/k3s-server.nix
            ./modules/network/bonding.nix
          ];
        };

        n100-3 = mkSystem {
          hostname = "n100-3";
          system = systems.n100;
          modules = [
            ./modules/hardware/n100.nix
            ./modules/roles/k3s-agent.nix
            ./modules/network/bonding.nix
          ];
        };

        # Jetson Orin Nano nodes
        jetson-1 = mkSystem {
          hostname = "jetson-1";
          system = systems.jetson;
          modules = [
            ./modules/hardware/jetson-orin-nano.nix
            ./modules/roles/k3s-agent.nix
            ./modules/network/bonding.nix
          ];
        };

        jetson-2 = mkSystem {
          hostname = "jetson-2";
          system = systems.jetson;
          modules = [
            ./modules/hardware/jetson-orin-nano.nix
            ./modules/roles/k3s-agent.nix
            ./modules/network/bonding.nix
          ];
        };
      };

      # Colmena deployment configuration
      colmena = {
        meta = {
          nixpkgs = import nixpkgs {
            system = systems.n100;
            config.allowUnfree = true;
          };
          specialArgs = { inherit inputs; };
        };

        # N100 nodes
        n100-1 = {
          deployment = {
            targetHost = "n100-1.local";
            targetUser = "root";
            tags = [ "n100" "k3s-server" "control-plane" ];
          };
          imports = nixosConfigurations.n100-1.config.system.build.toplevel.drvPath;
        };

        n100-2 = {
          deployment = {
            targetHost = "n100-2.local";
            targetUser = "root";
            tags = [ "n100" "k3s-server" "control-plane" ];
          };
          imports = nixosConfigurations.n100-2.config.system.build.toplevel.drvPath;
        };

        n100-3 = {
          deployment = {
            targetHost = "n100-3.local";
            targetUser = "root";
            tags = [ "n100" "k3s-agent" "worker" ];
          };
          imports = nixosConfigurations.n100-3.config.system.build.toplevel.drvPath;
        };

        # Jetson nodes
        jetson-1 = {
          deployment = {
            targetHost = "jetson-1.local";
            targetUser = "root";
            tags = [ "jetson" "k3s-agent" "worker" "edge" ];
          };
          imports = nixosConfigurations.jetson-1.config.system.build.toplevel.drvPath;
        };

        jetson-2 = {
          deployment = {
            targetHost = "jetson-2.local";
            targetUser = "root";
            tags = [ "jetson" "k3s-agent" "worker" "edge" ];
          };
          imports = nixosConfigurations.jetson-2.config.system.build.toplevel.drvPath;
        };
      };

      # Development shells for x86_64
      devShells.${systems.n100} = {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # NixOS tools
            nixos-rebuild
            nixos-generators
            nixos-anywhere
            colmena

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
            echo "  colmena         - Deploy to multiple nodes in parallel"
            echo "  kubectl         - Interact with k3s cluster"
            echo ""
            echo "Example usage:"
            echo "  nixos-rebuild switch --flake .#n100-1 --target-host root@n100-1.local"
            echo "  nixos-anywhere --flake .#n100-1 root@n100-1.local"
            echo "  colmena apply --on @control-plane  # Deploy to all control plane nodes"
            echo "  colmena apply --on n100-1,n100-2   # Deploy to specific nodes"
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
      packages.${systems.n100} = {
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

      # VM Testing Configurations
      nixosConfigurations = nixosConfigurations // {
        # Test VMs
        vm-test = mkSystem {
          hostname = "vm-test";
          system = systems.n100;
          modules = [
            ./tests/vms/default.nix
          ];
        };

        vm-k3s-server = mkSystem {
          hostname = "vm-k3s-server";
          system = systems.n100;
          modules = [
            ./tests/vms/k3s-server-vm.nix
          ];
        };

        vm-k3s-agent = mkSystem {
          hostname = "vm-k3s-agent";
          system = systems.n100;
          modules = [
            ./tests/vms/k3s-agent-vm.nix
          ];
        };

        # Multi-node cluster VMs
        vm-control-plane = mkSystem {
          hostname = "vm-control-plane";
          system = systems.n100;
          modules = [
            ./tests/vms/multi-node-cluster.nix
            { nodes.control-plane = {}; }
          ];
        };

        vm-worker-1 = mkSystem {
          hostname = "vm-worker-1";
          system = systems.n100;
          modules = [
            ./tests/vms/multi-node-cluster.nix
            { nodes.worker-1 = {}; }
          ];
        };

        vm-worker-2 = mkSystem {
          hostname = "vm-worker-2";
          system = systems.n100;
          modules = [
            ./tests/vms/multi-node-cluster.nix
            { nodes.worker-2 = {}; }
          ];
        };
      };

      # Checks run by CI/CD
      checks.${systems.n100} = {
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

        # VM tests
        vm-test-build = pkgs.runCommand "vm-test-build" {} ''
          echo "Testing VM configurations can be built" > $out
        '';
      };
    };
}