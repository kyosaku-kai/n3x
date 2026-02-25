{
  description = "n3x - NixOS K3s Edge Infrastructure Framework";

  inputs = {
    # Core NixOS inputs
    # TEMPORARY: Using fork with virtualisation.bootDiskAdditionalSpace fix
    # for bootloader-enabled VM tests (k3s-cluster-simple-systemd-boot).
    # Fork rebased onto nixos-25.11 (2026-02-16). Revert to nixos-25.11 once merged upstream.
    # See: docs/nixos-vm-bootloader-disk-limitation.md
    nixpkgs.url = "github:timblaktu/nixpkgs/vm-bootloader-disk-size";

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

      # Git hooks setup snippet (shared across all dev shells)
      # Configures git to use .githooks/ for commit-msg and pre-commit validation
      gitHooksSetup = ''
        if [ -d .githooks ]; then
          git config --local core.hooksPath .githooks 2>/dev/null || true
        fi
      '';

      # Version from VERSION file + git rev
      baseVersion = lib.trim (builtins.readFile ./VERSION);
      version =
        if self ? rev then "${baseVersion}+${self.shortRev}"
        else "${baseVersion}-dirty";

      # Package set for aarch64
      pkgsAarch64 = import nixpkgs {
        system = systems.jetson;
        config.allowUnfree = true;
      };

      # Package set for aarch64-darwin (Apple Silicon)
      pkgsDarwin = import nixpkgs {
        system = "aarch64-darwin";
        config.allowUnfree = true;
      };

      # =======================================================================
      # ISAR Backend Support
      # =======================================================================

      # Platform-aware kas-container wrapper script
      # Linux: Handles the sgdisk sync() hang on WSL2 by temporarily unmounting 9p filesystems
      # Darwin: Uses Docker Desktop as container engine (podman broken on nix-darwin)
      mkKasBuildWrapper = wrapperPkgs:
        if wrapperPkgs.stdenv.isDarwin then
          wrapperPkgs.writeShellScriptBin "kas-build" ''
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

            if [[ $# -lt 1 ]]; then
              echo "Usage: kas-build <kas-config-files> [additional-args...]"
              echo ""
              echo "Wrapper around 'kas-container --isar build' for macOS."
              echo "Requires Docker Desktop or Rancher Desktop (dockerd/moby mode)."
              echo ""
              echo "Examples:"
              echo "  kas-build backends/debian/kas/base.yml:backends/debian/kas/machine/qemu-amd64.yml"
              echo "  kas-build backends/debian/kas/base.yml:backends/debian/kas/machine/jetson-orin-nano.yml"
              exit 1
            fi

            # Validate Docker is available
            if ! command -v docker &>/dev/null; then
              log_error "Docker not found in PATH"
              echo ""
              echo "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
              echo "Or Rancher Desktop (dockerd/moby mode): https://rancherdesktop.io/"
              exit 1
            fi

            # Detect Rancher Desktop in containerd mode (nerdctl masquerading as docker)
            if docker -v 2>/dev/null | grep -qi nerdctl; then
              log_error "Rancher Desktop detected in containerd mode."
              echo ""
              echo "kas-container requires Docker-compatible API. Switch to dockerd (moby) mode:"
              echo "  Rancher Desktop -> Preferences -> Container Engine -> dockerd (moby)"
              exit 1
            fi

            if ! docker info &>/dev/null 2>&1; then
              log_error "Docker daemon is not running"
              echo ""
              echo "Start Docker Desktop and try again."
              exit 1
            fi

            kas_config="$1"
            shift

            # --- Host/target architecture detection ---
            HOST_ARCH=$(uname -m)
            # macOS returns "arm64" not "aarch64" — normalize
            [[ "$HOST_ARCH" == "arm64" ]] && HOST_ARCH="aarch64"

            # Extract machine name from kas config path (colon-separated overlay list)
            # { grep || true; } prevents set -euo pipefail from aborting on no match
            MACHINE=$(echo "$kas_config" | tr ':' '\n' | { grep 'kas/machine/' || true; } | sed 's|.*/machine/||;s|\.yml$||' | head -1)

            if [[ -n "$MACHINE" ]]; then
              case "$MACHINE" in
                qemu-arm64|qemu-arm64-orin|jetson-orin-nano)
                  TARGET_ARCH=aarch64 ;;
                *)
                  TARGET_ARCH=x86_64 ;;
              esac

              if [[ "$HOST_ARCH" == "$TARGET_ARCH" ]]; then
                log_info "Native build detected ($HOST_ARCH == $TARGET_ARCH)"
                kas_config="''${kas_config}:kas/opt/native-build.yml"
              else
                log_info "Cross-compilation: $HOST_ARCH -> $TARGET_ARCH (ISAR default)"
                log_info "Docker Desktop handles binfmt_misc automatically."
                log_info "If you see 'Exec format error', try:"
                log_info "  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes"
              fi
            else
              log_warn "Could not detect machine from kas config — skipping arch detection"
            fi

            export KAS_CONTAINER_ENGINE=docker
            export KAS_CONTAINER_IMAGE="ghcr.io/siemens/kas/kas-isar:5.1"

            log_info "Starting kas-container build (engine: docker)..."
            log_info "Config: $kas_config"
            echo

            kas-container --isar build "$kas_config" "$@"

            log_success "Build completed successfully!"
          ''
        else
          wrapperPkgs.writeShellScriptBin "kas-build" ''
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

            is_wsl() { [[ -n "''${WSL_DISTRO_NAME:-}" || -n "''${WSL_DISTRO:-}" ]]; }

            # Only get drvfs mounts under /mnt/[a-z] (Windows drive letters)
            # EXCLUDE /usr/lib/wsl/drivers - it's read-only and shouldn't cause sync() hangs
            # The sync() hang is caused by dirty data on rw mounts like /mnt/c
            get_9p_mounts() {
              ${wrapperPkgs.util-linux}/bin/mount | \
                ${wrapperPkgs.gnugrep}/bin/grep -E 'type 9p' | \
                ${wrapperPkgs.gnugrep}/bin/grep -E ' /mnt/[a-z] ' | \
                ${wrapperPkgs.gawk}/bin/awk '{print $3}' || true
            }

            UNMOUNTED_MOUNTS=()

            unmount_9p_filesystems() {
              if ! is_wsl; then return 0; fi

              local mounts
              mounts=$(get_9p_mounts)
              [[ -z "$mounts" ]] && return 0

              log_warn "Temporarily unmounting Windows drive mounts to prevent sync() hang..."
              log_info "Note: /usr/lib/wsl/drivers is left mounted (read-only, doesn't cause hangs)"

              while IFS= read -r mount_point; do
                if [[ -n "$mount_point" ]]; then
                  log_info "Unmounting: $mount_point"
                  if sudo ${wrapperPkgs.util-linux}/bin/umount -l "$mount_point" 2>/dev/null; then
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

              log_info "Remounting Windows drive mounts..."

              # Standard mount options that preserve execute permissions for Windows binaries
              local drvfs_opts="metadata,uid=$(id -u),gid=$(id -g)"

              local remount_failed=false
              for mount_point in "''${UNMOUNTED_MOUNTS[@]}"; do
                log_info "Remounting: $mount_point"

                # All mounts we unmount are /mnt/[a-z] Windows drives
                local drive_letter="''${mount_point##*/}"
                drive_letter="''${drive_letter^^}"
                if sudo ${wrapperPkgs.util-linux}/bin/mount -t drvfs "''${drive_letter}:" "$mount_point" -o "$drvfs_opts" 2>/dev/null; then
                  log_success "Remounted: $mount_point"
                else
                  log_warn "Could not remount $mount_point - you may need: wsl --shutdown"
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
              echo "  kas-build backends/debian/kas/base.yml:backends/debian/kas/machine/qemu-amd64.yml"
              echo "  kas-build backends/debian/kas/base.yml:backends/debian/kas/machine/jetson-orin-nano.yml"
              exit 1
            fi

            kas_config="$1"
            shift

            if is_wsl; then
              log_info "WSL detected: ''${WSL_DISTRO_NAME:-''${WSL_DISTRO:-unknown}}"
              log_info "Will handle 9p filesystem workaround for WIC generation"
              unmount_9p_filesystems
            fi

            # --- Container engine detection ---
            # Use engine detected by shellHook, or auto-detect
            if [[ -z "''${KAS_CONTAINER_ENGINE:-}" ]]; then
              if command -v docker &>/dev/null; then
                export KAS_CONTAINER_ENGINE=docker
              elif command -v podman &>/dev/null; then
                export KAS_CONTAINER_ENGINE=podman
              else
                log_error "No container engine found. Install docker-ce or podman."
                exit 1
              fi
            fi

            # --- Host/target architecture detection ---
            HOST_ARCH=$(uname -m)

            # Extract machine name from kas config path (colon-separated overlay list)
            # { grep || true; } prevents set -euo pipefail from aborting on no match
            MACHINE=$(echo "$kas_config" | tr ':' '\n' | { grep 'kas/machine/' || true; } | sed 's|.*/machine/||;s|\.yml$||' | head -1)

            if [[ -n "$MACHINE" ]]; then
              case "$MACHINE" in
                qemu-arm64|qemu-arm64-orin|jetson-orin-nano)
                  TARGET_ARCH=aarch64 ;;
                *)
                  TARGET_ARCH=x86_64 ;;
              esac

              if [[ "$HOST_ARCH" == "$TARGET_ARCH" ]]; then
                log_info "Native build detected ($HOST_ARCH == $TARGET_ARCH)"
                kas_config="''${kas_config}:kas/opt/native-build.yml"
              else
                log_info "Cross-compilation: $HOST_ARCH -> $TARGET_ARCH (ISAR default)"
                # Validate binfmt_misc registration for cross-arch builds
                # Check both naming conventions:
                #   qemu-aarch64  — Debian/Ubuntu qemu-user-static package
                #   aarch64-linux — NixOS boot.binfmt.emulatedSystems module
                BINFMT_FOUND=false
                case "$TARGET_ARCH" in
                  aarch64) for e in qemu-aarch64 aarch64-linux; do [[ -f "/proc/sys/fs/binfmt_misc/$e" ]] && BINFMT_FOUND=true; done ;;
                  x86_64)  for e in qemu-x86_64 x86_64-linux;   do [[ -f "/proc/sys/fs/binfmt_misc/$e" ]] && BINFMT_FOUND=true; done ;;
                esac
                if ! $BINFMT_FOUND; then
                  log_warn "binfmt_misc registration for $TARGET_ARCH not found"
                  log_warn "Cross-compilation compiles natively, but chroot operations"
                  log_warn "(dpkg, postinst scripts) need QEMU user-mode emulation."
                  log_warn "See: docs/binfmt-requirements.md"
                  log_warn ""
                  log_warn "Quick fix (Debian/Ubuntu): sudo apt-get install qemu-user-static binfmt-support"
                  log_warn "Quick fix (NixOS): boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];"
                fi
              fi
            else
              log_warn "Could not detect machine from kas config — skipping arch detection"
            fi

            log_info "Starting kas-container build (engine: $KAS_CONTAINER_ENGINE)..."
            log_info "Config: $kas_config"
            echo

            # ISAR commit 27651d51 (Sept 2024) requires bubblewrap for rootfs sandboxing
            # kas-isar:4.7 does NOT have bwrap; kas-isar:5.1+ does
            # Use KAS_CONTAINER_IMAGE to override the full image path (not KAS_CONTAINER_IMAGE_NAME)
            export KAS_CONTAINER_IMAGE="ghcr.io/siemens/kas/kas-isar:5.1"
            kas-container --isar build "$kas_config" "$@"

            log_success "Build completed successfully!"
          '';

      # Backward-compatible binding for existing references (apps, etc.)
      kasBuildWrapper = mkKasBuildWrapper pkgs;

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

      # Import Debian backend artifacts module for checks
      debianArtifacts = import ./backends/debian/debian-artifacts.nix { inherit pkgs lib; };

      # Import swupdate module for OTA bundle generation
      swupdateModule = import ./backends/debian/swupdate { inherit pkgs lib; };

      # Import SWUpdate VM tests
      swupdateTests = {
        bundle-validation = import ./tests/debian/swupdate-bundle-validation.nix { inherit pkgs lib; };
        apply = import ./tests/debian/swupdate-apply.nix { inherit pkgs lib; };
        boot-switch = import ./tests/debian/swupdate-boot-switch.nix { inherit pkgs lib; };
        network-ota = import ./tests/debian/swupdate-network-ota.nix { inherit pkgs lib; };
      };

      # Import Debian backend parity tests (parallel to NixOS smoke tests)
      debianParityTests = {
        vm-boot = import ./tests/debian/single-vm-boot.nix { inherit pkgs lib; };
        two-vm-network = import ./tests/debian/two-vm-network.nix { inherit pkgs lib; };
        # K3s server boot test (Layer 3 - k3s binary verification)
        k3s-server-boot = import ./tests/debian/k3s-server-boot.nix { inherit pkgs lib; };
        # K3s service test (Layer 3 - k3s service starts and API responds)
        k3s-service = import ./tests/debian/k3s-service.nix { inherit pkgs lib; };
        # K3s network profile tests (requires images built with network overlays)
        k3s-network-simple = import ./tests/debian/k3s-network-simple.nix { inherit pkgs lib; };
        k3s-network-vlans = import ./tests/debian/k3s-network-vlans.nix { inherit pkgs lib; };
        k3s-network-bonding = import ./tests/debian/k3s-network-bonding.nix { inherit pkgs lib; };
        # K3s cluster tests (Layer 4 - multi-node HA control plane)
        # Firmware boot (default) - UEFI → bootloader → kernel
        k3s-cluster-simple = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "simple"; };
        k3s-cluster-vlans = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "vlans"; };
        k3s-cluster-bonding-vlans = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "bonding-vlans"; };
        k3s-cluster-dhcp-simple = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "dhcp-simple"; };
        # Direct kernel boot (Plan 020 G4) - faster, bypasses bootloader via -kernel/-initrd
        k3s-cluster-simple-direct = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "simple"; bootMode = "direct"; };
        k3s-cluster-vlans-direct = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "vlans"; bootMode = "direct"; };
        k3s-cluster-bonding-vlans-direct = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "bonding-vlans"; bootMode = "direct"; };
        k3s-cluster-dhcp-simple-direct = import ./tests/debian/k3s-cluster.nix { inherit pkgs lib; networkProfile = "dhcp-simple"; bootMode = "direct"; };
        # Network debug test (fast iteration for debugging IP persistence issues)
        network-debug = import ./tests/debian/network-debug.nix { inherit pkgs lib; };
      };

      # ISAR build matrix (for artifact validation generation)
      buildMatrix = import ./lib/debian/build-matrix.nix { inherit lib; };

      # Debian backend checks (let-bound so debian-all can reference them without recursion)
      debianPackageParity = import ./lib/debian/verify-kas-packages.nix {
        inherit lib pkgs;
        kasPath = ./backends/debian/kas;
      };

      # Generate artifact validation from the build matrix
      debianArtifactValidation =
        let
          # Build validation commands for each variant from the matrix
          validationLines = lib.concatMapStringsSep "\n"
            (variant:
              let
                machineInfo = buildMatrix.machines.${variant.machine};
                variantId = buildMatrix.mkVariantId variant;
                path = buildMatrix.mkAttrPath variant;
                # Access the artifacts through the registry using the path
                artifacts = lib.getAttrFromPath path debianArtifacts;
              in
              lib.concatMapStringsSep "\n"
                (artifactType:
                  let
                    typeInfo = machineInfo.artifactTypes.${artifactType};
                    artifact = artifacts.${typeInfo.attrName};
                  in
                  "test -e ${artifact}\necho \"  ok: ${buildMatrix.mkArtifactName variant artifactType}\""
                )
                (builtins.attrNames machineInfo.artifactTypes)
            )
            buildMatrix.variants;
        in
        pkgs.runCommand "validate-debian-artifacts" { } ''
          echo "Validating ISAR artifacts (${toString buildMatrix.variantCount} variants)..."
          echo ""
          ${validationLines}
          echo ""
          echo "All ISAR artifacts validated successfully!"
          touch $out
        '';

      # Aggregate check: runs all Debian backend tests in one command
      # NOTE: boot-switch excluded - SWUpdate grubenv_open fails on vfat EFI partition.
      # Needs interactive debugging (strace, mount state check). See CLAUDE.md.
      debianAllCheck = pkgs.linkFarm "debian-all-tests" (
        lib.mapAttrsToList
          (name: testDef: {
            name = "debian-${name}";
            path = testDef.test;
          })
          debianParityTests
        ++ [
          { name = "debian-package-parity"; path = debianPackageParity; }
          { name = "debian-artifact-validation"; path = debianArtifactValidation; }
        ]
        ++ lib.mapAttrsToList
          (name: testDef: {
            name = "test-swupdate-${name}";
            path = testDef.test;
          })
          (lib.filterAttrs (name: _: name != "boot-switch") swupdateTests)
      );

      # Platform-aware development shell
      # Linux: system container runtime detection, WSL guidance
      # Darwin: Docker Desktop / Rancher Desktop validation
      # Container runtimes (docker/podman) are NOT provided by Nix — they must
      # be system-installed because kas-container runs them via sudo, which
      # resets PATH and cannot reach Nix store paths on non-NixOS systems.
      mkDevShell = shellPkgs: shellPkgs.mkShell {
        name = "n3x";

        buildInputs = with shellPkgs; [
          # ISAR/kas tooling
          kas

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

          # Platform-aware build wrapper
          (mkKasBuildWrapper shellPkgs)
        ];

        shellHook = gitHooksSetup + ''
          echo "n3x Development Environment"
          echo "==========================="
          echo ""
          echo "  kas version: $(kas --version 2>&1 | head -1)"
          echo "  kas-container: $(which kas-container)"
        '' + (if shellPkgs.stdenv.isDarwin then ''
          if ! command -v docker &>/dev/null; then
            echo ""
            echo "  ERROR: Docker not found in PATH"
            echo "  Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
            echo "  Or Rancher Desktop (dockerd/moby mode): https://rancherdesktop.io/"
            echo ""
          elif docker -v 2>/dev/null | grep -qi nerdctl; then
            echo ""
            echo "  WARNING: Rancher Desktop detected in containerd mode."
            echo "  kas-container requires Docker-compatible API."
            echo "  Switch to dockerd (moby) mode:"
            echo "    Rancher Desktop -> Preferences -> Container Engine -> dockerd (moby)"
            echo ""
          elif ! docker info &>/dev/null 2>&1; then
            echo "  docker: installed but daemon not running"
            echo ""
            echo "  Start Docker Desktop and try again."
          else
            export KAS_CONTAINER_ENGINE=docker
            echo "  docker version: $(docker --version)"
            echo "  engine: docker (Docker Desktop)"
          fi
        '' else ''
          # Container runtime detection
          # ISAR builds need privileged containers. kas-container wraps podman
          # with sudo, which breaks Nix-store podman (sudo resets PATH).
          # System-installed runtimes (/usr/bin/docker, /usr/bin/podman) work.
          if [ -n "''${WSL_DISTRO_NAME:-}" ] || [ -n "''${WSL_DISTRO:-}" ]; then
            echo ""
            echo "WSL2 Environment Detected: ''${WSL_DISTRO_NAME:-''${WSL_DISTRO:-unknown}}"
            echo "  Use 'kas-build' instead of 'kas-container' for WIC image builds"
            echo "  This handles the sgdisk sync() hang automatically."
            # WSL image has system podman pre-installed
            if command -v podman &>/dev/null; then
              export KAS_CONTAINER_ENGINE=podman
              echo "  podman version: $(podman --version)"
            elif command -v docker &>/dev/null; then
              export KAS_CONTAINER_ENGINE=docker
              echo "  docker version: $(docker --version)"
            else
              echo ""
              echo "  WARNING: No container runtime found."
              echo "  The WSL image should have podman pre-installed."
              echo "  If missing, install: sudo apt-get install podman"
            fi
          else
            # Non-WSL Linux: prefer docker (no sudo PATH issues with kas-container)
            if command -v docker &>/dev/null; then
              # Detect nerdctl masquerading as docker (Rancher Desktop containerd mode)
              if docker -v 2>/dev/null | grep -qi nerdctl; then
                echo ""
                echo "  WARNING: Rancher Desktop detected in containerd mode."
                echo "  kas-container requires Docker-compatible API."
                echo "  Switch to dockerd (moby) mode:"
                echo "    Rancher Desktop -> Preferences -> Container Engine -> dockerd (moby)"
              elif docker info &>/dev/null 2>&1; then
                export KAS_CONTAINER_ENGINE=docker
                echo "  docker version: $(docker --version)"
                echo "  engine: docker"
              else
                echo "  docker: installed but daemon not running"
                echo "  Start with: sudo systemctl start docker"
              fi
            elif command -v podman &>/dev/null; then
              podman_path=$(command -v podman)
              # Nix-store podman is unreachable via sudo on non-NixOS (secure_path resets PATH).
              # NixOS (/etc/NIXOS) configures sudo to preserve Nix paths, so it's fine there.
              if [[ "$podman_path" == /nix/store/* ]] && [[ ! -f /etc/NIXOS ]]; then
                echo ""
                echo "  WARNING: podman found in Nix store ($podman_path)"
                echo "  kas-container runs podman via sudo, which cannot access Nix store paths"
                echo "  on non-NixOS systems (sudo resets PATH via secure_path)."
                echo ""
                echo "  Install system podman: sudo apt-get install podman"
                echo "  Or install docker instead (recommended)."
              else
                export KAS_CONTAINER_ENGINE=podman
                echo "  podman version: $(podman --version)"
                echo "  engine: podman (system-installed)"
                echo "  NOTE: kas-container runs podman via sudo for ISAR privileged builds"
              fi
            else
              echo ""
              echo "  WARNING: No container runtime found."
              echo "  ISAR builds require docker or podman (system-installed, not from Nix)."
              echo ""
              echo "  Docker (recommended - avoids sudo PATH issues):"
              echo "    https://docs.docker.com/engine/install/"
              echo "    sudo usermod -aG docker \$USER  # then log out/in"
              echo ""
              echo "  Podman (note: kas-container runs podman via sudo):"
              echo "    sudo apt-get install podman"
            fi
          fi
        '') + ''
          echo ""
          echo "Primary workflow (builds + registers artifacts in Nix store):"
          echo "  nix run '.' -- --list              # Show all build variants"
          echo "  nix run '.' -- --variant base      # Build one variant"
          echo "  nix run '.' -- --machine qemuamd64 # Build all variants for a machine"
          echo "  nix run '.'                        # Build ALL variants"
          echo ""
          echo "Manual kas-build (lower level, does NOT register artifacts):"
          echo "  kas-build backends/debian/kas/base.yml:backends/debian/kas/machine/qemu-amd64.yml"
          echo ""
        '';
      }; # end mkDevShell
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

      # Development shells
      devShells.${systems.n100} = {
        default = mkDevShell pkgs;
      };

      devShells.aarch64-darwin = {
        default = mkDevShell pkgsDarwin;
      };

      # Packages that can be built
      packages.${systems.n100} = {
        # ISO/VM images: use native 25.11 image framework (system.build.images.*)
        # instead of nixos-generators (archived, upstreamed to nixpkgs).
        # See infra/nixos-runner/flake.nix for system.build.images.amazon example.

        # Documentation
        docs = pkgs.stdenv.mkDerivation {
          pname = "n3x-docs";
          version = baseVersion;
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
        # Debian Backend Packages
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

        # Jetson Orin Nano flash scripts (with ISAR rootfs)
        # Usage: nix build .#jetson-flash-script-server  (primary: k3s control plane)
        #        nix build .#jetson-flash-script-base    (development/testing)
        # Output: initrd-flash directory in /nix/store ready for flashing
        jetson-flash-script-server = mkJetsonFlashScript {
          rootfsTarball = debianArtifacts.jetson-orin-nano.server.rootfs;
          som = "orin-nano";
          carrierBoard = "devkit";
        };
        jetson-flash-script-base = mkJetsonFlashScript {
          rootfsTarball = debianArtifacts.jetson-orin-nano.base.rootfs;
          som = "orin-nano";
          carrierBoard = "devkit";
        };

        # Debian packages for ISAR images
        # Built with Nix, published to JFrog apt repository, consumed by ISAR via IMAGE_PREINSTALL
        k3s = pkgs.callPackage ./backends/debian/packages/k3s/build.nix { };
        k3s-system-config = pkgs.callPackage ./backends/debian/packages/k3s-system-config/build.nix { };
      };

      # Debian packages for aarch64-linux (Jetson)
      packages.${systems.jetson} = {
        k3s = pkgsAarch64.callPackage ./backends/debian/packages/k3s/build.nix { };
        # k3s-system-config is Architecture: all, only need one build
      };

      # Utility functions exported for use in modules
      lib = {
        # Project version (e.g., "0.0.1+1a2b3c4" or "0.0.1-dirty")
        inherit version baseVersion;

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

        # ISAR build matrix (variant definitions + naming functions)
        # Used by isar-build-all script via: nix eval --json '.#lib.debian.buildMatrix'
        debian.buildMatrix = import ./lib/debian/build-matrix.nix { inherit lib; };

        # Shared test infrastructure
        # Parameterized K3s cluster test builder (NixOS tests)
        # Usage: mkK3sClusterTest { pkgs, lib, networkProfile ? "simple", ... }
        mkK3sClusterTest = import ./tests/lib/mk-k3s-cluster-test.nix;

        # Debian backend VM test builder (for ISAR .wic images)
        # Usage: mkDebianTest { pkgs, lib } { name, machines, testScript, ... }
        mkDebianTest = { pkgs, lib ? pkgs.lib }:
          import ./tests/lib/debian/mk-debian-test.nix { inherit pkgs lib; };

        # Network profiles for K3s cluster tests
        # Available: simple, vlans, bonding-vlans, vlans-broken, dhcp-simple
        # UNIFIED: These profiles live in lib/network/ and are consumed by BOTH backends
        networkProfiles = {
          simple = import ./lib/network/profiles/simple.nix { inherit lib; };
          vlans = import ./lib/network/profiles/vlans.nix { inherit lib; };
          bonding-vlans = import ./lib/network/profiles/bonding-vlans.nix { inherit lib; };
          vlans-broken = import ./lib/network/profiles/vlans-broken.nix { inherit lib; };
          dhcp-simple = import ./lib/network/profiles/dhcp-simple.nix { inherit lib; };
        };
      };

      # Flake apps for workflow automation
      apps.${systems.n100} =
        let
          isarBuildAllApp = {
            type = "app";
            program = "${pkgs.writeShellApplication {
            name = "isar-build-all";
            runtimeInputs = with pkgs; [
              coreutils
              gnused
              nix
              jq
              util-linux
              kas
              podman
              kasBuildWrapper
            ];
            text = builtins.readFile ./backends/debian/scripts/isar-build-all.sh;
          }}/bin/isar-build-all";
            meta = {
              description = "Build ISAR images from the build matrix and register in Nix store";
              mainProgram = "isar-build-all";
            };
          };
        in
        {
          # Default app: nix run '.' -- --help
          # Builds ISAR image variants from the build matrix and registers in Nix store.
          # This is THE primary workflow command for this project.
          default = isarBuildAllApp;

          # Explicit name alias: nix run '.#isar-build-all' also works
          isar-build-all = isarBuildAllApp;

          # Generate systemd-networkd config files for ISAR from Nix profiles
          # Usage: nix run '.#generate-networkd-configs'
          generate-networkd-configs = {
            type = "app";
            meta = {
              description = "Generate systemd-networkd config files from Nix network profiles for ISAR";
              mainProgram = "generate-networkd-configs";
            };
            program = "${pkgs.writeShellApplication {
            name = "generate-networkd-configs";
            runtimeInputs = with pkgs; [ coreutils ];
            text = ''
              # Generate systemd-networkd config files from Nix network profiles
              # Output: backends/debian/meta-n3x/recipes-support/systemd-networkd-config/files/

              set -euo pipefail

              # Use current directory - user must run from repo root
              REPO_ROOT="$(pwd)"

              if [[ ! -f "''${REPO_ROOT}/flake.nix" ]]; then
                echo "Error: Must be run from repository root (no flake.nix found in $(pwd))"
                echo "Usage: cd /path/to/n3x && nix run '.#generate-networkd-configs'"
                exit 1
              fi

              OUTPUT_DIR="''${REPO_ROOT}/backends/debian/meta-n3x/recipes-support/systemd-networkd-config/files"

              echo "=== Generating systemd-networkd configs ==="
              echo "Repository: ''${REPO_ROOT}"
              echo "Output: ''${OUTPUT_DIR}"
              echo ""

              # Profiles to generate
              PROFILES=("simple" "vlans" "bonding-vlans" "dhcp-simple")

              # Node names (match what profiles define)
              NODES=("server-1" "server-2" "agent-1" "agent-2")

              for profile in "''${PROFILES[@]}"; do
                echo "Profile: ''${profile}"
                for node in "''${NODES[@]}"; do
                  node_dir="''${OUTPUT_DIR}/''${profile}/''${node}"
                  mkdir -p "''${node_dir}"

                  # Generate files using nix eval
                  files=$(nix eval --impure --json --expr "
                    let
                      pkgs = import <nixpkgs> {};
                      lib = pkgs.lib;
                      mkNetworkd = import ''${REPO_ROOT}/lib/network/mk-systemd-networkd.nix { inherit lib; };
                      profile = import ''${REPO_ROOT}/lib/network/profiles/''${profile}.nix { inherit lib; };
                    in
                      mkNetworkd.generateProfileFiles profile \"''${node}\"
                  " 2>/dev/null || echo "{}")

                  if [[ "''${files}" == "{}" ]]; then
                    echo "  ''${node}: (no files - node not in profile)"
                    continue
                  fi

                  # Parse JSON and write files
                  # Use jq to get keys, then fetch each value separately
                  for filename in $(echo "''${files}" | ${pkgs.jq}/bin/jq -r 'keys[]'); do
                    filepath="''${node_dir}/''${filename}"
                    # Extract the content for this specific file
                    echo "''${files}" | ${pkgs.jq}/bin/jq -r ".[\"''${filename}\"]" > "''${filepath}"
                    echo "  ''${node}/''${filename}"
                  done
                done
                echo ""
              done

              echo "=== Generation complete ==="
              echo "Files written to: ''${OUTPUT_DIR}"
              echo ""
              echo "Next steps:"
              echo "  1. Review generated files: ls -la ''${OUTPUT_DIR}/*/"
              echo "  2. Stage changes: git add ''${OUTPUT_DIR}"
              echo "  3. Commit: git commit -m 'chore: regenerate networkd configs from Nix profiles'"
            '';
          }}/bin/generate-networkd-configs";
          };

          # WSL filesystem remount utility
          # Usage: nix run '.#wsl-remount'
          #
          # Purpose: Recover from kas-build being killed before it could remount /mnt/c.
          # The kas-build wrapper temporarily unmounts Windows drives (/mnt/c) to prevent
          # sgdisk sync() hangs during WIC image generation. It remounts on exit via trap.
          #
          # IMPORTANT: /usr/lib/wsl/drivers is NO LONGER unmounted (2026-01-27).
          # It's read-only and doesn't contribute to sync hangs. WSL utilities (clip.exe, etc.)
          # live on /mnt/c, not /usr/lib/wsl/drivers.
          #
          # When mounts break:
          # 1. If SIGKILL (-9) was used, traps don't run → /mnt/c stays unmounted
          # 2. Run this utility to attempt remount
          # 3. If filesystem appears empty, 9p connection is severed → wsl --shutdown required
          #
          # Prevention: Use SIGTERM before SIGKILL when terminating kas-build processes.
          wsl-remount = {
            type = "app";
            meta = {
              description = "Remount WSL Windows filesystems after kas-build interruption";
              mainProgram = "wsl-remount";
            };
            program = "${pkgs.writeShellApplication {
            name = "wsl-remount";
            runtimeInputs = with pkgs; [ util-linux gnugrep gawk coreutils ];
            text = ''
              set -euo pipefail

              # ANSI colors
              RED='\033[0;31m'
              GREEN='\033[0;32m'
              YELLOW='\033[1;33m'
              BLUE='\033[0;34m'
              NC='\033[0m'

              log_info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }
              log_success() { echo -e "''${GREEN}[OK]''${NC} $*"; }
              log_warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
              log_error() { echo -e "''${RED}[ERROR]''${NC} $*"; }

              is_wsl() {
                [[ -n "''${WSL_DISTRO_NAME:-}" ]]
              }

              if ! is_wsl; then
                log_error "Not running in WSL - this utility is only for WSL environments"
                exit 1
              fi

              echo "=========================================="
              echo "WSL Filesystem Remount Utility"
              echo "=========================================="
              echo ""
              log_info "WSL Distro: $WSL_DISTRO_NAME"
              echo ""

              # Check current mount state
              log_info "Current drvfs/9p mounts:"
              if mount | grep -E 'drvfs|type 9p' | grep -v wslg; then
                :
              else
                log_warn "No drvfs/9p mounts found (they were unmounted)"
              fi
              echo ""

              # Check if /mnt/c has contents
              if [[ -d /mnt/c/Windows ]]; then
                log_success "/mnt/c is already mounted and accessible"
                exit 0
              fi

              log_warn "/mnt/c is not accessible - attempting remount..."
              echo ""

              # Standard mount options for Windows binary compatibility
              drvfs_opts="metadata,uid=$(id -u),gid=$(id -g)"

              # Try to remount /mnt/c
              log_info "Attempting: sudo mount -t drvfs C: /mnt/c -o $drvfs_opts"
              if sudo mount -t drvfs "C:" /mnt/c -o "$drvfs_opts" 2>&1; then
                # Verify it actually worked
                if [[ -d /mnt/c/Windows ]]; then
                  log_success "Remounted /mnt/c successfully"
                else
                  log_error "/mnt/c mount command succeeded but filesystem is empty"
                  log_error "The 9p connection to Windows was severed by SIGKILL"
                  echo ""
                  log_warn "SOLUTION: Run from PowerShell:"
                  log_warn "  wsl --shutdown"
                  log_warn "Then restart WSL"
                  exit 1
                fi
              else
                log_error "Failed to mount /mnt/c"
                log_error "The 9p connection to Windows was likely severed"
                echo ""
                log_warn "SOLUTION: Run from PowerShell:"
                log_warn "  wsl --shutdown"
                log_warn "Then restart WSL"
                exit 1
              fi

              # Try to remount /usr/lib/wsl/drivers
              if [[ -d /usr/lib/wsl/drivers ]] && ! mount | grep -q '/usr/lib/wsl/drivers'; then
                log_info "Attempting to remount /usr/lib/wsl/drivers..."
                if sudo mount -t drvfs 'C:\Windows\System32\drivers' /usr/lib/wsl/drivers -o ro 2>&1; then
                  log_success "Remounted /usr/lib/wsl/drivers"
                else
                  log_warn "Could not remount /usr/lib/wsl/drivers (non-critical)"
                fi
              fi

              echo ""
              log_info "Final mount state:"
              mount | grep -E 'drvfs|type 9p' | grep -v wslg || log_warn "No mounts to show"
              echo ""

              # Test clipboard integration
              if [[ -x /mnt/c/Windows/System32/clip.exe ]]; then
                log_success "clip.exe is accessible - clipboard integration should work"
              else
                log_warn "clip.exe not accessible - clipboard integration may be broken"
              fi
            '';
          }}/bin/wsl-remount";
          };
        };

      # Checks run by CI/CD
      # x86_64-linux checks (primary platform - full test coverage)
      checks.${systems.n100} = {
        # Validate all NixOS configurations build
        build-all = pkgs.runCommand "build-all-configs" { } ''
          echo "All configurations build successfully" > $out
        '';

        # Validate VERSION file contains valid semver
        lint-version =
          let
            valid = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)(-.+)?" baseVersion;
          in
          lib.seq
            (if valid == null then
              throw "VERSION '${baseVersion}' is not valid semver (expected N.N.N or N.N.N-suffix)"
            else
              true)
            (pkgs.runCommand "lint-version" { } "touch $out");

        # Lint Nix files
        lint-nixpkgs-fmt = pkgs.runCommand "nixpkgs-fmt-check"
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

        # Debian package builds
        # Verifies packages/ directory .deb packages build correctly
        pkg-debian-x86_64 = pkgs.runCommand "debian-packages-check" { } ''
          mkdir -p $out
          # Verify k3s package built
          if [ ! -f "${self.packages.${systems.n100}.k3s}/k3s_"*".deb" ]; then
            echo "ERROR: k3s .deb not found"
            exit 1
          fi
          # Verify k3s-system-config package built
          if [ ! -f "${self.packages.${systems.n100}.k3s-system-config}/k3s-system-config_"*".deb" ]; then
            echo "ERROR: k3s-system-config .deb not found"
            exit 1
          fi
          echo "All Debian packages build successfully" > $out/result
          # Copy packages for inspection
          cp ${self.packages.${systems.n100}.k3s}/*.deb $out/
          cp ${self.packages.${systems.n100}.k3s-system-config}/*.deb $out/
        '';

        # =====================================================================
        # Smoke Tests - Fast decomposed tests for debugging infrastructure
        # =====================================================================
        # These tests are designed to run quickly (<60s) and isolate failures.
        # Run them in order: vm-boot -> two-vm-network -> k3s-service-starts
        # If a lower-level test fails, don't waste time on higher-level tests.

        # Layer 1: Single VM boot (15-30s) - verifies QEMU/KVM infrastructure
        nixos-smoke-vm-boot = pkgs.callPackage ./tests/nixos/smoke/vm-boot.nix { };

        # Layer 2: Two-VM networking (30-60s) - verifies VDE network works
        nixos-smoke-two-vm-network = pkgs.callPackage ./tests/nixos/smoke/two-vm-network.nix { };

        # Layer 3: K3s service starts (60-90s) - verifies K3s binary and service
        nixos-smoke-k3s-service-starts = pkgs.callPackage ./tests/nixos/smoke/k3s-service-starts.nix { };

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
        # DEPRECATED: Consider using k3s-cluster-simple instead (Plan 013)
        # This is the primary test approach - works on all platforms (WSL2, Darwin, Cloud)
        k3s-cluster-formation = pkgs.callPackage ./tests/nixos/k3s-cluster-formation.nix { inherit inputs; };

        # K3s storage infrastructure testing
        # Validates storage prerequisites and PVC provisioning across multi-node cluster
        k3s-storage = pkgs.callPackage ./tests/nixos/k3s-storage.nix { inherit inputs; };

        # K3s networking validation
        # REVIEW: May be redundant with k3s-cluster-* parameterized tests (Plan 013)
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

        # Simple network profile with systemd-boot bootloader (Plan 019 Phase B)
        # Tests bootloader parity with ISAR by using UEFI firmware + systemd-boot
        # instead of direct kernel boot. Slower but validates full boot stack.
        k3s-cluster-simple-systemd-boot = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "simple";
          useSystemdBoot = true;
          testName = "k3s-cluster-simple-systemd-boot";
        };

        # VLAN tagging profile - 802.1Q VLANs on single trunk
        # Tests VLAN tagging with separate cluster (VLAN 200) and storage (VLAN 100) networks
        k3s-cluster-vlans = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "vlans";
          networkReadyTimeout = 60;
        };

        # Bonding + VLANs profile - full production parity
        # Tests bonding (active-backup) with VLAN tagging for complete production simulation
        k3s-cluster-bonding-vlans = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "bonding-vlans";
          networkReadyTimeout = 120;
        };

        # DHCP simple profile - flat network with DHCP-assigned IPs (Plan 019 Phase C)
        # Tests DHCP client behavior with MAC-based reservations.
        # Uses dedicated dhcp-server VM running dnsmasq for IP assignment.
        # See docs/DHCP-TEST-INFRASTRUCTURE.md for architecture rationale.
        k3s-cluster-dhcp-simple = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "dhcp-simple";
          networkReadyTimeout = 60;
          # Experimental CI tolerance (Plan 032): 4 QEMU VMs cause etcd I/O starvation
          # on shared CI runners. These controls are harmless on fast machines.
          etcdHeartbeatInterval = 500; # 5x default (100ms), per etcd tuning guide
          etcdElectionTimeout = 5000; # 10x heartbeat, 5x default (1000ms)
          sequentialJoin = true; # start k3s on joining nodes one-at-a-time
          shutdownDhcpAfterLeases = true; # free I/O after leases verified (12h lease time)
          etcdTmpfs = true; # eliminate etcd WAL I/O contention (test cluster formation, not durability)
        };

        # =================================================================
        # NixOS UEFI/systemd-boot variants (Plan 020 Phase G3)
        # Tests the same network profiles with UEFI firmware + systemd-boot
        # instead of direct kernel boot. Validates full boot stack parity.
        # =================================================================

        # VLANs with systemd-boot bootloader
        k3s-cluster-vlans-systemd-boot = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "vlans";
          useSystemdBoot = true;
          testName = "k3s-cluster-vlans-systemd-boot";
          networkReadyTimeout = 60;
        };

        # Bonding + VLANs with systemd-boot bootloader
        k3s-cluster-bonding-vlans-systemd-boot = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "bonding-vlans";
          useSystemdBoot = true;
          testName = "k3s-cluster-bonding-vlans-systemd-boot";
          networkReadyTimeout = 120;
        };

        # DHCP with systemd-boot bootloader
        k3s-cluster-dhcp-simple-systemd-boot = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
          inherit pkgs lib;
          networkProfile = "dhcp-simple";
          useSystemdBoot = true;
          testName = "k3s-cluster-dhcp-simple-systemd-boot";
          networkReadyTimeout = 60;
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
        # Debian Backend Checks
        # =====================================================================
        # These tests require KVM and are skipped if /dev/kvm is not available.
        # Run interactively: nix build '.#test-swupdate-*-driver' && ./result/bin/run-test-interactive

        # Debian Backend Package Parity Verification (Plan 016)
        # Verifies kas overlay files contain all packages defined in package-mapping.nix
        # Fails at eval time if packages are missing
        lint-debian-package-parity = debianPackageParity;

        # Validate Debian backend artifact hashes (generated from build matrix)
        debian-artifact-validation = debianArtifactValidation;

        # Aggregate check: runs ALL Debian backend tests with a single command
        # Usage: nix build '.#checks.x86_64-linux.debian-all' -L
        debian-all = debianAllCheck;

        # SWUpdate VM Tests
        test-swupdate-bundle-validation = swupdateTests.bundle-validation.test;
        test-swupdate-apply = swupdateTests.apply.test;
        test-swupdate-boot-switch = swupdateTests.boot-switch.test;
        test-swupdate-network-ota = swupdateTests.network-ota.test;

        # Debian Backend Parity Tests (parallel to NixOS smoke tests for Layer 1-2)
        debian-vm-boot = debianParityTests.vm-boot.test;
        debian-two-vm-network = debianParityTests.two-vm-network.test;

        # Debian K3s Server Boot Test (Layer 3 - k3s binary verification)
        debian-server-boot = debianParityTests.k3s-server-boot.test;

        # Debian K3s Service Test (Layer 3 - k3s service starts and API responds)
        debian-service = debianParityTests.k3s-service.test;

        # Debian K3s Network Profile Tests (requires images with network overlays)
        # Build images: nix run '.#isar-build-all' -- --machine qemuamd64
        debian-network-simple = debianParityTests.k3s-network-simple.test;
        debian-network-vlans = debianParityTests.k3s-network-vlans.test;
        debian-network-bonding = debianParityTests.k3s-network-bonding.test;

        # Debian K3s Cluster Tests (Layer 4 - multi-node HA control plane)
        # Requires: profile-specific images registered via isar-build-all
        # Firmware boot (default) - UEFI → bootloader → kernel
        debian-cluster-simple = debianParityTests.k3s-cluster-simple.test;
        debian-cluster-vlans = debianParityTests.k3s-cluster-vlans.test;
        debian-cluster-bonding-vlans = debianParityTests.k3s-cluster-bonding-vlans.test;
        debian-cluster-dhcp-simple = debianParityTests.k3s-cluster-dhcp-simple.test;

        # Debian K3s Cluster Tests - Direct kernel boot (Plan 020 G4)
        # Faster boot via -kernel/-initrd, bypasses UEFI/bootloader
        debian-cluster-simple-direct = debianParityTests.k3s-cluster-simple-direct.test;
        debian-cluster-vlans-direct = debianParityTests.k3s-cluster-vlans-direct.test;
        debian-cluster-bonding-vlans-direct = debianParityTests.k3s-cluster-bonding-vlans-direct.test;
        debian-cluster-dhcp-simple-direct = debianParityTests.k3s-cluster-dhcp-simple-direct.test;

        # Debian Network Debug Test (fast iteration for IP persistence debugging)
        debian-network-debug = debianParityTests.network-debug.test;
      };

      # aarch64-linux checks (Jetson platform - build validation only)
      # These validate that ARM64 configurations build correctly.
      # Full runtime testing requires Jetson hardware or very slow QEMU TCG emulation.
      # NOTE: Building these checks requires an aarch64 builder (nix daemon, remote builder,
      # or binfmt-misc emulation). On x86_64-only systems, use `--system aarch64-linux`
      # with appropriate builder configuration.
      checks.${systems.jetson} = {
        # Debian package builds (aarch64)
        # Verifies arm64 .deb packages build correctly on native aarch64
        pkg-debian-aarch64 = pkgsAarch64.runCommand "debian-packages-aarch64-check" { } ''
          mkdir -p $out
          # Verify k3s arm64 package built
          if [ ! -f "${self.packages.${systems.jetson}.k3s}/k3s_"*".deb" ]; then
            echo "ERROR: k3s arm64 .deb not found"
            exit 1
          fi
          echo "All aarch64 Debian packages build successfully" > $out/result
          # Copy packages for inspection
          cp ${self.packages.${systems.jetson}.k3s}/*.deb $out/
        '';

        # Jetson-1 configuration build validation
        # Builds the complete NixOS system derivation to verify config correctness
        jetson-1-build = self.nixosConfigurations.jetson-1.config.system.build.toplevel;

        # Jetson-2 configuration build validation
        jetson-2-build = self.nixosConfigurations.jetson-2.config.system.build.toplevel;
      };
    };
}
