{
  description = "n3x - NixOS K3s Edge Infrastructure Framework";

  inputs = {
    # Core NixOS inputs
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

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
    # Using timblaktu fork with pluggable-rootfs support for ISAR integration
    jetpack-nixos = {
      url = "github:timblaktu/jetpack-nixos/feature/pluggable-rootfs";
      # Don't follow nixpkgs - jetpack-nixos has specific nixpkgs requirements
    };

    # Flake-utils for ISAR per-system handling
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixos-hardware, disko, sops-nix, nixos-anywhere, impermanence, jetpack-nixos, flake-utils, ... }@inputs:
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
            ./backends/nixos/modules/common/base.nix
            ./backends/nixos/modules/common/nix-settings.nix
            ./backends/nixos/modules/common/networking.nix

            # Host-specific configuration
            ./backends/nixos/hosts/${hostname}/configuration.nix

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
            ./backends/nixos/modules/common/base.nix
            ./backends/nixos/modules/common/nix-settings.nix

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

      # Standard library
      lib = pkgs.lib;

      # Package set for aarch64
      pkgsAarch64 = import nixpkgs {
        system = systems.jetson;
        config.allowUnfree = true;
      };

      # =======================================================================
      # ISAR Backend Support
      # =======================================================================

      # WSL-safe kas-container wrapper script
      # Handles the sgdisk sync() hang issue on WSL2 by temporarily unmounting 9p filesystems
      kasBuildWrapper = pkgs.writeShellScriptBin "kas-build" ''
        set -euo pipefail

        # ANSI colors
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m'

        log_info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        log_warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
        log_error() { echo -e "''${RED}[ERROR]''${NC} $*"; }
        log_success() { echo -e "''${GREEN}[SUCCESS]''${NC} $*"; }

        is_wsl() { [[ -n "''${WSL_DISTRO_NAME:-}" ]]; }

        get_9p_mounts() {
          ${pkgs.util-linux}/bin/mount | ${pkgs.gnugrep}/bin/grep -E 'type 9p' | ${pkgs.gawk}/bin/awk '{print $3}' || true
        }

        UNMOUNTED_MOUNTS=()

        unmount_9p_filesystems() {
          if ! is_wsl; then return 0; fi

          local mounts
          mounts=$(get_9p_mounts)
          [[ -z "$mounts" ]] && return 0

          log_warn "Temporarily unmounting 9p filesystems to prevent sync() hang..."

          while IFS= read -r mount_point; do
            if [[ -n "$mount_point" ]]; then
              log_info "Unmounting: $mount_point"
              if sudo ${pkgs.util-linux}/bin/umount -l "$mount_point" 2>/dev/null; then
                UNMOUNTED_MOUNTS+=("$mount_point")
                log_success "Unmounted: $mount_point"
              else
                log_warn "Failed to unmount $mount_point (may already be unmounted)"
              fi
            fi
          done <<< "$mounts"
        }

        remount_9p_filesystems() {
          if ! is_wsl; then return 0; fi
          [[ ''${#UNMOUNTED_MOUNTS[@]} -eq 0 ]] && return 0

          log_info "Remounting 9p filesystems..."

          # Standard mount options that preserve execute permissions for Windows binaries
          local drvfs_opts="metadata,uid=$(id -u),gid=$(id -g)"

          local remount_failed=false
          for mount_point in "''${UNMOUNTED_MOUNTS[@]}"; do
            log_info "Remounting: $mount_point"

            if [[ "$mount_point" =~ ^/mnt/[a-z]$ ]]; then
              local drive_letter="''${mount_point##*/}"
              drive_letter="''${drive_letter^^}"
              if sudo ${pkgs.util-linux}/bin/mount -t drvfs "''${drive_letter}:" "$mount_point" -o "$drvfs_opts" 2>/dev/null; then
                log_success "Remounted via drvfs: $mount_point"
              else
                log_warn "Could not remount $mount_point - you may need: wsl --shutdown"
                remount_failed=true
              fi
            elif [[ "$mount_point" == "/usr/lib/wsl/drivers" ]]; then
              if sudo ${pkgs.util-linux}/bin/mount -t drvfs 'C:\Windows\System32\drivers' "$mount_point" -o ro 2>/dev/null; then
                log_success "Remounted: $mount_point"
              else
                log_warn "Could not remount $mount_point"
                remount_failed=true
              fi
            elif ${pkgs.util-linux}/bin/mount "$mount_point" 2>/dev/null; then
              log_success "Explicitly mounted: $mount_point"
            elif ls "$mount_point" >/dev/null 2>&1 && ${pkgs.util-linux}/bin/mount | ${pkgs.gnugrep}/bin/grep -q "on $mount_point "; then
              log_success "Auto-remounted: $mount_point"
            else
              log_warn "Could not remount $mount_point"
              remount_failed=true
            fi
          done

          if $remount_failed; then
            log_warn "Some filesystems could not be remounted. To restore:"
            log_warn "  1. Open PowerShell: wsl --shutdown"
            log_warn "  2. Restart WSL: wsl"
          fi
        }

        cleanup() {
          local exit_code=$?
          log_info "Cleaning up..."
          remount_9p_filesystems
          exit $exit_code
        }

        trap cleanup EXIT INT TERM

        if [[ $# -lt 1 ]]; then
          echo "Usage: kas-build <kas-config-files> [additional-args...]"
          echo ""
          echo "WSL-safe wrapper around 'kas-container --isar build'"
          echo "Automatically handles 9p filesystem unmounting on WSL2."
          echo ""
          echo "Examples:"
          echo "  kas-build backends/isar/kas/base.yml:backends/isar/kas/machine/qemu-amd64.yml"
          echo "  kas-build backends/isar/kas/base.yml:backends/isar/kas/machine/jetson-orin-nano.yml"
          exit 1
        fi

        kas_config="$1"
        shift

        if is_wsl; then
          log_info "WSL detected: $WSL_DISTRO_NAME"
          log_info "Will handle 9p filesystem workaround for WIC generation"
          unmount_9p_filesystems
        fi

        log_info "Starting kas-container build..."
        log_info "Config: $kas_config"
        echo

        export KAS_CONTAINER_ENGINE=podman
        kas-container --isar build "$kas_config" "$@"

        log_success "Build completed successfully!"
      '';

      # Helper function to build Jetson flash script with ISAR rootfs
      mkJetsonFlashScript =
        { rootfsTarball
        , som ? "orin-nano"
        , carrierBoard ? "devkit"
        }:
        let
          config = jetpack-nixos.lib.mkExternalRootfsConfig {
            inherit som carrierBoard rootfsTarball;
          };
        in
        config.config.system.build.initrdFlashScript;

      # Import ISAR artifacts module for checks
      isarArtifacts = import ./backends/isar/isar-artifacts.nix { inherit pkgs lib; };

      # Import swupdate module for OTA bundle generation
      swupdateModule = import ./backends/isar/swupdate { inherit pkgs lib; };

      # Import SWUpdate VM tests
      swupdateTests = {
        bundle-validation = import ./tests/isar/swupdate-bundle-validation.nix { inherit pkgs lib; };
        apply = import ./tests/isar/swupdate-apply.nix { inherit pkgs lib; };
        boot-switch = import ./tests/isar/swupdate-boot-switch.nix { inherit pkgs lib; };
        network-ota = import ./tests/isar/swupdate-network-ota.nix { inherit pkgs lib; };
      };

      # Import ISAR parity tests (parallel to NixOS smoke tests)
      isarParityTests = {
        vm-boot = import ./tests/isar/single-vm-boot.nix { inherit pkgs lib; };
        two-vm-network = import ./tests/isar/two-vm-network.nix { inherit pkgs lib; };
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
            ./backends/nixos/modules/hardware/n100.nix
            ./backends/nixos/modules/roles/k3s-server.nix
            ./backends/nixos/modules/network/bonding.nix
          ];
        };

        n100-2 = mkSystem {
          hostname = "n100-2";
          system = systems.n100;
          modules = [
            ./backends/nixos/modules/hardware/n100.nix
            ./backends/nixos/modules/roles/k3s-server.nix
            ./backends/nixos/modules/network/bonding.nix
          ];
        };

        n100-3 = mkSystem {
          hostname = "n100-3";
          system = systems.n100;
          modules = [
            ./backends/nixos/modules/hardware/n100.nix
            ./backends/nixos/modules/roles/k3s-agent.nix
            ./backends/nixos/modules/network/bonding.nix
          ];
        };

        # Jetson Orin Nano nodes
        jetson-1 = mkSystem {
          hostname = "jetson-1";
          system = systems.jetson;
          modules = [
            ./backends/nixos/modules/hardware/jetson-orin-nano.nix
            ./backends/nixos/modules/roles/k3s-agent.nix
            ./backends/nixos/modules/network/bonding.nix
          ];
        };

        jetson-2 = mkSystem {
          hostname = "jetson-2";
          system = systems.jetson;
          modules = [
            ./backends/nixos/modules/hardware/jetson-orin-nano.nix
            ./backends/nixos/modules/roles/k3s-agent.nix
            ./backends/nixos/modules/network/bonding.nix
          ];
        };

        # VM Testing Configurations
        vm-k3s-server = mkVMSystem {
          hostname = "vm-k3s-server";
          system = systems.n100;
          modules = [
            ./backends/nixos/vms/k3s-server-vm.nix
          ];
        };

        vm-k3s-agent = mkVMSystem {
          hostname = "vm-k3s-agent";
          system = systems.n100;
          modules = [
            ./backends/nixos/vms/k3s-agent-vm.nix
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

        # ISAR development shell
        isar = pkgs.mkShell {
          name = "n3x-isar";

          buildInputs = with pkgs; [
            # ISAR/kas tooling
            kas

            # Container runtime (kas-container uses podman by default)
            podman

            # QEMU for testing
            qemu

            # Build essentials
            gnumake
            git

            # Python for ISAR scripts
            python3

            # Useful utilities
            jq
            yq-go
            tree

            # WSL-safe build wrapper
            kasBuildWrapper
          ];

          shellHook = ''
            export KAS_CONTAINER_ENGINE=podman

            echo "n3x ISAR Development Environment"
            echo "================================="
            echo ""
            echo "  kas version: $(kas --version 2>&1 | head -1)"
            echo "  kas-container: $(which kas-container)"
            echo "  podman version: $(podman --version)"

            # WSL-specific guidance
            if [ -n "''${WSL_DISTRO_NAME:-}" ]; then
              echo ""
              echo "WSL2 Environment Detected: $WSL_DISTRO_NAME"
              echo "  Use 'kas-build' instead of 'kas-container' for WIC image builds"
              echo "  This handles the sgdisk sync() hang automatically."
            fi

            echo ""
            echo "Build commands:"
            echo "  kas-build backends/isar/kas/base.yml:backends/isar/kas/machine/qemu-amd64.yml"
            echo "  kas-build backends/isar/kas/base.yml:backends/isar/kas/machine/jetson-orin-nano.yml"
            echo ""
          '';
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

        # =====================================================================
        # ISAR Backend Packages
        # =====================================================================

        # SWUpdate bundles for OTA updates (require artifact hashes to be populated)
        # swupdate-bundle-jetson-server = swupdateModule.jetson-orin-nano.server;
        # swupdate-bundle-jetson-base = swupdateModule.jetson-orin-nano.base;

        # SWUpdate test drivers (for interactive testing)
        # Run interactively: nix build '.#test-swupdate-bundle-validation-driver' && ./result/bin/run-test-interactive
        test-swupdate-bundle-validation-driver = swupdateTests.bundle-validation.driver;
        test-swupdate-apply-driver = swupdateTests.apply.driver;
        test-swupdate-boot-switch-driver = swupdateTests.boot-switch.driver;
        test-swupdate-network-ota-driver = swupdateTests.network-ota.driver;
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

        # ISAR backend helpers
        inherit mkJetsonFlashScript;

        # Shared test infrastructure
        # Parameterized K3s cluster test builder (NixOS tests)
        # Usage: mkK3sClusterTest { pkgs, lib, networkProfile ? "simple", ... }
        mkK3sClusterTest = import ./tests/lib/mk-k3s-cluster-test.nix;

        # ISAR VM test builder (for ISAR .wic images)
        # Usage: mkISARTest { pkgs, lib } { name, machines, testScript, ... }
        mkISARTest = { pkgs, lib ? pkgs.lib }:
          import ./tests/lib/isar/mk-isar-test.nix { inherit pkgs lib; };

        # Network profiles for K3s cluster tests
        # Available: simple, vlans, bonding-vlans, vlans-broken
        networkProfiles = {
          simple = import ./tests/lib/network-profiles/simple.nix { inherit lib; };
          vlans = import ./tests/lib/network-profiles/vlans.nix { inherit lib; };
          bonding-vlans = import ./tests/lib/network-profiles/bonding-vlans.nix { inherit lib; };
          vlans-broken = import ./tests/lib/network-profiles/vlans-broken.nix { inherit lib; };
        };
      };

      # Flake apps for workflow automation
      apps.${systems.n100} = {
        # Automated ISAR artifact build and registration workflow
        # Usage: nix run '.#rebuild-isar-artifacts' -- --help
        rebuild-isar-artifacts = {
          type = "app";
          program = "${pkgs.writeShellApplication {
            name = "rebuild-isar-artifacts";
            runtimeInputs = with pkgs; [
              coreutils
              gnused
              nix
              kas
              podman
              kasBuildWrapper
            ];
            text = builtins.readFile ./backends/isar/scripts/rebuild-isar-artifacts.sh;
          }}/bin/rebuild-isar-artifacts";
        };
      };

      # Checks run by CI/CD
      # x86_64-linux checks (primary platform - full test coverage)
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

        # =====================================================================
        # Smoke Tests - Fast decomposed tests for debugging infrastructure
        # =====================================================================
        # These tests are designed to run quickly (<60s) and isolate failures.
        # Run them in order: vm-boot -> two-vm-network -> k3s-service-starts
        # If a lower-level test fails, don't waste time on higher-level tests.

        # Layer 1: Single VM boot (15-30s) - verifies QEMU/KVM infrastructure
        smoke-vm-boot = pkgs.callPackage ./tests/nixos/smoke/vm-boot.nix { };

        # Layer 2: Two-VM networking (30-60s) - verifies VDE network works
        smoke-two-vm-network = pkgs.callPackage ./tests/nixos/smoke/two-vm-network.nix { };

        # Layer 3: K3s service starts (60-90s) - verifies K3s binary and service
        smoke-k3s-service-starts = pkgs.callPackage ./tests/nixos/smoke/k3s-service-starts.nix { };

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
        network-resilience = pkgs.callPackage ./tests/nixos/network-resilience.nix { inherit inputs; };

        # K3s cluster formation via vsim nested virtualization
        # Tests full cluster formation with pre-installed inner VM images
        vsim-k3s-cluster = pkgs.callPackage ./tests/nixos/vsim-k3s-cluster.nix { inherit inputs; };

        # K3s cluster formation using nixosTest multi-node (no nested virtualization)
        # This is the primary test approach - works on all platforms (WSL2, Darwin, Cloud)
        k3s-cluster-formation = pkgs.callPackage ./tests/nixos/k3s-cluster-formation.nix { inherit inputs; };

        # K3s storage infrastructure testing
        # Validates storage prerequisites and PVC provisioning across multi-node cluster
        k3s-storage = pkgs.callPackage ./tests/nixos/k3s-storage.nix { inherit inputs; };

        # K3s networking validation
        # Tests CoreDNS, flannel VXLAN, service discovery, and pod network connectivity
        k3s-network = pkgs.callPackage ./tests/nixos/k3s-network.nix { inherit inputs; };

        # K3s network constraints testing
        # Tests cluster behavior under degraded network conditions (latency, packet loss, bandwidth limits)
        # Uses tc/netem directly on nixosTest node interfaces - works on all platforms
        k3s-network-constraints = pkgs.callPackage ./tests/nixos/k3s-network-constraints.nix { inherit inputs; };

        # Parameterized K3s cluster tests with different network profiles
        # These use the shared test builder (tests/lib/mk-k3s-cluster-test.nix)

        # Simple network profile - single flat network (baseline)
        k3s-cluster-simple = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "simple";
        };

        # VLAN tagging profile - 802.1Q VLANs on single trunk
        # Tests VLAN tagging with separate cluster (VLAN 200) and storage (VLAN 100) networks
        k3s-cluster-vlans = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "vlans";
        };

        # Bonding + VLANs profile - full production parity
        # Tests bonding (active-backup) with VLAN tagging for complete production simulation
        k3s-cluster-bonding-vlans = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "bonding-vlans";
        };

        # Bond failover test - validates active-backup failover behavior
        # Tests that k3s cluster remains operational during NIC failover/failback
        k3s-bond-failover = pkgs.callPackage ./tests/nixos/k3s-bond-failover.nix {
          inherit pkgs lib inputs;
        };

        # VLAN negative test - validates that VLAN misconfigurations fail appropriately
        # Tests that nodes with wrong VLAN IDs cannot form a cluster
        k3s-vlan-negative = pkgs.callPackage ./tests/nixos/k3s-vlan-negative.nix {
          inherit pkgs lib inputs;
        };

        # =====================================================================
        # ISAR Backend Checks
        # =====================================================================
        # These tests require KVM and are skipped if /dev/kvm is not available.
        # Run interactively: nix build '.#test-swupdate-*-driver' && ./result/bin/run-test-interactive

        # Validate ISAR artifact hashes are correct
        isar-artifact-validation = pkgs.runCommand "validate-isar-artifacts" { } ''
          echo "Validating ISAR artifacts..."
          echo ""

          # Validate qemuamd64 artifacts (used for VM tests)
          echo "Checking qemuamd64 base artifacts..."
          test -e ${isarArtifacts.qemuamd64.base.wic}
          test -e ${isarArtifacts.qemuamd64.base.vmlinuz}
          test -e ${isarArtifacts.qemuamd64.base.initrd}
          echo "  ✓ qemuamd64 base: wic, vmlinuz, initrd"

          echo "Checking qemuamd64 server artifacts..."
          test -e ${isarArtifacts.qemuamd64.server.wic}
          test -e ${isarArtifacts.qemuamd64.server.vmlinuz}
          test -e ${isarArtifacts.qemuamd64.server.initrd}
          echo "  ✓ qemuamd64 server: wic, vmlinuz, initrd"

          echo "Checking qemuamd64 agent artifacts..."
          test -e ${isarArtifacts.qemuamd64.agent.wic}
          test -e ${isarArtifacts.qemuamd64.agent.vmlinuz}
          test -e ${isarArtifacts.qemuamd64.agent.initrd}
          echo "  ✓ qemuamd64 agent: wic, vmlinuz, initrd"

          # Validate qemuarm64 artifacts
          echo "Checking qemuarm64 base artifacts..."
          test -e ${isarArtifacts.qemuarm64.base.ext4}
          test -e ${isarArtifacts.qemuarm64.base.vmlinux}
          test -e ${isarArtifacts.qemuarm64.base.initrd}
          echo "  ✓ qemuarm64 base: ext4, vmlinux, initrd"

          echo "Checking qemuarm64 server artifacts..."
          test -e ${isarArtifacts.qemuarm64.server.ext4}
          test -e ${isarArtifacts.qemuarm64.server.vmlinux}
          test -e ${isarArtifacts.qemuarm64.server.initrd}
          echo "  ✓ qemuarm64 server: ext4, vmlinux, initrd"

          # Validate amd-v3c18i artifacts (real hardware - agent)
          echo "Checking amd-v3c18i agent artifacts..."
          test -e ${isarArtifacts.amd-v3c18i.agent.wic}
          echo "  ✓ amd-v3c18i agent: wic"

          # Validate jetson-orin-nano artifacts (real hardware - server)
          echo "Checking jetson-orin-nano server artifacts..."
          test -e ${isarArtifacts.jetson-orin-nano.server.rootfs}
          echo "  ✓ jetson-orin-nano server: rootfs tarball"

          echo "Checking jetson-orin-nano base artifacts..."
          test -e ${isarArtifacts.jetson-orin-nano.base.rootfs}
          echo "  ✓ jetson-orin-nano base: rootfs tarball"

          echo ""
          echo "All ISAR artifacts validated successfully!"
          touch $out
        '';

        # SWUpdate VM Tests
        test-swupdate-bundle-validation = swupdateTests.bundle-validation.test;
        test-swupdate-apply = swupdateTests.apply.test;
        test-swupdate-boot-switch = swupdateTests.boot-switch.test;
        test-swupdate-network-ota = swupdateTests.network-ota.test;

        # ISAR Parity Tests (parallel to NixOS smoke tests for Layer 1-2)
        isar-vm-boot = isarParityTests.vm-boot.test;
        isar-two-vm-network = isarParityTests.two-vm-network.test;
      };

      # aarch64-linux checks (Jetson platform - build validation only)
      # These validate that ARM64 configurations build correctly.
      # Full runtime testing requires Jetson hardware or very slow QEMU TCG emulation.
      # NOTE: Building these checks requires an aarch64 builder (nix daemon, remote builder,
      # or binfmt-misc emulation). On x86_64-only systems, use `--system aarch64-linux`
      # with appropriate builder configuration.
      checks.${systems.jetson} = {
        # Jetson-1 configuration build validation
        # Builds the complete NixOS system derivation to verify config correctness
        jetson-1-build = self.nixosConfigurations.jetson-1.config.system.build.toplevel;

        # Jetson-2 configuration build validation
        jetson-2-build = self.nixosConfigurations.jetson-2.config.system.build.toplevel;
      };
    };
}
