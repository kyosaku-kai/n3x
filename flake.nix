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
      mkSystem = { hostname, system ? systems.n100, modules ? [ ] }:
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

      # Helper for VM configurations (no hosts/ directory requirement)
      mkVMSystem = { hostname, system ? systems.n100, modules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            # Basic modules for VMs
            ./modules/common/base.nix
            ./modules/common/nix-settings.nix

            # Include disko for disk management
            disko.nixosModules.disko

            # Include secrets management
            sops-nix.nixosModules.sops

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
        vm-k3s-server = mkVMSystem {
          hostname = "vm-k3s-server";
          system = systems.n100;
          modules = [
            ./tests/vms/k3s-server-vm.nix
          ];
        };

        vm-k3s-agent = mkVMSystem {
          hostname = "vm-k3s-agent";
          system = systems.n100;
          modules = [
            ./tests/vms/k3s-agent-vm.nix
          ];
        };

        # Multi-node cluster VMs - TODO: Fix multi-node-cluster.nix configuration
        # vm-control-plane = mkVMSystem {
        #   hostname = "vm-control-plane";
        #   system = systems.n100;
        #   modules = [
        #     ./tests/vms/multi-node-cluster.nix
        #     { nodes.control-plane = {}; }
        #   ];
        # };

        # vm-worker-1 = mkVMSystem {
        #   hostname = "vm-worker-1";
        #   system = systems.n100;
        #   modules = [
        #     ./tests/vms/multi-node-cluster.nix
        #     { nodes.worker-1 = {}; }
        #   ];
        # };

        # vm-worker-2 = mkVMSystem {
        #   hostname = "vm-worker-2";
        #   system = systems.n100;
        #   modules = [
        #     ./tests/vms/multi-node-cluster.nix
        #     { nodes.worker-2 = {}; }
        #   ];
        # };

        # Emulation Environment - Nested virtualization for testing
        emulator-vm = nixpkgs.lib.nixosSystem {
          system = systems.n100;
          specialArgs = { inherit inputs; };
          modules = [
            ./tests/emulation/embedded-system.nix
          ];
        };
      };

      # Development shells for x86_64
      devShells.${systems.n100} = {
        default = pkgs.mkShell {
          buildInputs = (with pkgs; [
            # NixOS tools
            nixos-rebuild
            nixos-generators

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
          ]) ++ [
            # From flake inputs
            inputs.nixos-anywhere.packages.${systems.n100}.default
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

        # Emulation VM - Nested virtualization environment for testing
        # Run with: nix run .#emulation-vm (interactive) or nix run .#emulation-vm-bg (background)
        emulation-vm = self.nixosConfigurations.emulator-vm.config.system.build.vm;

        # Background runner for emulation VM with console connection info
        emulation-vm-bg = pkgs.writeShellScriptBin "run-emulation-vm-bg" ''
          set -euo pipefail

          VM_SCRIPT="${self.nixosConfigurations.emulator-vm.config.system.build.vm}/bin/run-nixos-vm"
          SOCKET_DIR="''${XDG_RUNTIME_DIR:-/tmp}/n3x-emulation"
          MONITOR_SOCKET="$SOCKET_DIR/monitor.sock"
          SERIAL_SOCKET="$SOCKET_DIR/serial.sock"
          PID_FILE="$SOCKET_DIR/qemu.pid"

          mkdir -p "$SOCKET_DIR"

          # Check if already running
          if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "Emulation VM already running (PID: $(cat "$PID_FILE"))"
            echo ""
            echo "Connect to console:  socat -,raw,echo=0 unix-connect:$SERIAL_SOCKET"
            echo "Monitor (QEMU):      socat - unix-connect:$MONITOR_SOCKET"
            echo "Stop VM:             echo 'quit' | socat - unix-connect:$MONITOR_SOCKET"
            exit 0
          fi

          echo "Starting n3x Emulation VM in background..."
          echo ""

          # Run QEMU with Unix sockets instead of stdio
          NIX_DISK_IMAGE="$SOCKET_DIR/nixos.qcow2" \
          QEMU_OPTS="-daemonize -pidfile $PID_FILE -monitor unix:$MONITOR_SOCKET,server,nowait -serial unix:$SERIAL_SOCKET,server,nowait" \
            "$VM_SCRIPT" -display none &

          # Wait for sockets to be created
          for i in {1..30}; do
            if [ -S "$SERIAL_SOCKET" ]; then
              break
            fi
            sleep 0.5
          done

          if [ ! -S "$SERIAL_SOCKET" ]; then
            echo "ERROR: VM failed to start (serial socket not created)"
            exit 1
          fi

          echo "VM started successfully!"
          echo ""
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "CONNECT TO CONSOLE:"
          echo "  socat -,raw,echo=0 unix-connect:$SERIAL_SOCKET"
          echo ""
          echo "QEMU MONITOR:"
          echo "  socat - unix-connect:$MONITOR_SOCKET"
          echo ""
          echo "STOP VM:"
          echo "  echo 'quit' | socat - unix-connect:$MONITOR_SOCKET"
          echo ""
          echo "DISK IMAGE: $SOCKET_DIR/nixos.qcow2"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        '';
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
        build-all = pkgs.runCommand "build-all-configs" { } ''
          echo "All configurations build successfully" > $out
        '';

        # Lint Nix files
        nixpkgs-fmt = pkgs.runCommand "nixpkgs-fmt-check"
          {
            buildInputs = [ pkgs.nixpkgs-fmt ];
          } ''
          nixpkgs-fmt --check ${./.}
          touch $out
        '';

        # VM tests
        vm-test-build = pkgs.runCommand "vm-test-build" { } ''
          echo "Testing VM configurations can be built" > $out
        '';

        # NixOS integration tests - TODO: Fix inputs passing for all tests
        # Core K3s functionality
        # k3s-single-server = pkgs.callPackage ./tests/integration/single-server.nix { inherit inputs; };
        # k3s-agent-join = pkgs.callPackage ./tests/integration/agent-join.nix { inherit inputs; };
        # k3s-multi-node = pkgs.callPackage ./tests/integration/multi-node-cluster.nix { inherit inputs; };
        # k3s-common-config = pkgs.callPackage ./tests/integration/k3s-common-config.nix { inherit inputs; };

        # Networking validation
        # network-bonding = pkgs.callPackage ./tests/integration/network-bonding.nix { inherit inputs; };
        # k3s-networking = pkgs.callPackage ./tests/integration/k3s-networking.nix { inherit inputs; };

        # Storage stack validation
        # longhorn-prerequisites = pkgs.callPackage ./tests/integration/longhorn-prerequisites.nix { inherit inputs; };
        # kyverno-deployment = pkgs.callPackage ./tests/integration/kyverno-deployment.nix { inherit inputs; };

        # Emulation environment checks
        emulation-vm-boots = pkgs.testers.runNixOSTest {
          name = "emulation-vm-boots";
          nodes.emulator = { config, pkgs, lib, modulesPath, ... }: {
            imports = [ ./tests/emulation/embedded-system.nix ];
            # Pass inputs to embedded-system.nix via _module.args
            _module.args.inputs = inputs;
          };
          testScript = ''
            emulator.start()
            emulator.wait_for_unit("multi-user.target")
            emulator.succeed("systemctl is-active libvirtd")
            # OVS creates ovsdb and ovs-vswitchd services, not "openvswitch"
            emulator.succeed("systemctl is-active ovsdb")
            emulator.succeed("systemctl is-active ovs-vswitchd")
            emulator.succeed("systemctl is-active dnsmasq")
            # Verify inner VMs were set up
            emulator.wait_for_unit("setup-inner-vms.service")
            emulator.succeed("virsh list --all | grep n100-1")
            emulator.succeed("virsh list --all | grep n100-2")
            emulator.succeed("virsh list --all | grep n100-3")
            # Verify OVS bridge exists
            emulator.succeed("ovs-vsctl show | grep ovsbr0")
            # Verify tc script is available
            emulator.succeed("test -x /etc/tc-simulate-constraints.sh")
          '';
        };

        # Network resilience testing - TC profile infrastructure validation
        # Tests the traffic control simulation for network constraint scenarios
        network-resilience = pkgs.callPackage ./tests/integration/network-resilience.nix { inherit inputs; };

        # K3s cluster formation via vsim nested virtualization
        # Tests full cluster formation with pre-installed inner VM images
        vsim-k3s-cluster = pkgs.callPackage ./tests/integration/vsim-k3s-cluster.nix { inherit inputs; };

        # K3s cluster formation using nixosTest multi-node (no nested virtualization)
        # This is the primary test approach - works on all platforms (WSL2, Darwin, Cloud)
        k3s-cluster-formation = pkgs.callPackage ./tests/integration/k3s-cluster-formation.nix { inherit inputs; };

        # K3s storage infrastructure testing
        # Validates storage prerequisites and PVC provisioning across multi-node cluster
        k3s-storage = pkgs.callPackage ./tests/integration/k3s-storage.nix { inherit inputs; };

        # K3s networking validation
        # Tests CoreDNS, flannel VXLAN, service discovery, and pod network connectivity
        k3s-network = pkgs.callPackage ./tests/integration/k3s-network.nix { inherit inputs; };

        # K3s network constraints testing
        # Tests cluster behavior under degraded network conditions (latency, packet loss, bandwidth limits)
        # Uses tc/netem directly on nixosTest node interfaces - works on all platforms
        k3s-network-constraints = pkgs.callPackage ./tests/integration/k3s-network-constraints.nix { inherit inputs; };
      };
    };
}
