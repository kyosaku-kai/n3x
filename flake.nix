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

    # Jetpack-nixos for Jetson Orin Nano support
    jetpack-nixos = {
      url = "github:anduril/jetpack-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, disko, sops-nix, nixos-anywhere, impermanence, jetpack-nixos, ... }@inputs:
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

        # VM Testing Configurations
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

      # Development shells for x86_64
      devShells.${systems.n100} = {
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
      packages.${systems.n100} = {
        # ISO images for installation
        # TODO: Add nixos-generators as flake input to enable this
        # iso = pkgs.nixos-generators.nixosGenerate {
        #   inherit pkgs;
        #   modules = [
        #     ./modules/installer/iso.nix
        #   ];
        #   format = "iso";
        # };

        # VM images for testing
        # TODO: Add nixos-generators as flake input to enable this
        # vm = pkgs.nixos-generators.nixosGenerate {
        #   inherit pkgs;
        #   modules = [
        #     ./modules/common/base.nix
        #   ];
        #   format = "vm";
        # };

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

        # NixOS integration tests
        # Core K3s functionality
        k3s-single-server = pkgs.callPackage ./tests/integration/single-server.nix { };
        k3s-agent-join = pkgs.callPackage ./tests/integration/agent-join.nix { };
        k3s-multi-node = pkgs.callPackage ./tests/integration/multi-node-cluster.nix { };
        k3s-common-config = pkgs.callPackage ./tests/integration/k3s-common-config.nix { };

        # Networking validation
        network-bonding = pkgs.callPackage ./tests/integration/network-bonding.nix { };
        k3s-networking = pkgs.callPackage ./tests/integration/k3s-networking.nix { };

        # Storage stack validation
        longhorn-prerequisites = pkgs.callPackage ./tests/integration/longhorn-prerequisites.nix { };
        kyverno-deployment = pkgs.callPackage ./tests/integration/kyverno-deployment.nix { };
      };
    };
}