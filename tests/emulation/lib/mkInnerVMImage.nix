# mkInnerVMImage.nix - Build pre-installed qcow2 disk images for inner VMs
#
# This function creates bootable qcow2 disk images from n3x host configurations,
# ready to use as inner VM system disks in the emulation environment.
#
# USAGE:
#   mkInnerVMImage = import ./lib/mkInnerVMImage.nix {
#     inherit pkgs lib inputs;
#     baseDir = ./..; # Path to tests/emulation directory
#   };
#
#   n100-1-image = mkInnerVMImage {
#     hostname = "n100-1";
#     diskSize = 8192;  # 8GB
#   };
#
# The resulting image can be copied to /var/lib/libvirt/images/ for use with libvirt.
#
# ARCHITECTURE:
#   1. Imports the actual n3x host config from hosts/${hostname}/
#   2. Overlays inner-vm-base.nix for emulation-specific settings
#   3. Uses NixOS make-disk-image to create bootable qcow2
#
# For ARM64 (jetson-*), images are built using cross-compilation or binfmt emulation.

{ pkgs, lib, inputs, baseDir, ... }:

{ hostname
, diskSize ? 8192  # Default 8GB, sufficient for k3s + basic workloads
, arch ? (if lib.hasPrefix "jetson" hostname then "aarch64" else "x86_64")
}:

let
  # Determine system string
  system = "${arch}-linux";

  # Use appropriate pkgs for the target architecture
  targetPkgs =
    if arch == "aarch64"
    then
      import inputs.nixpkgs
        {
          system = "aarch64-linux";
          config.allowUnfree = true;
        }
    else pkgs;

  # Get the make-disk-image function
  make-disk-image = import "${inputs.nixpkgs}/nixos/lib/make-disk-image.nix";

  # Paths relative to baseDir (tests/emulation)
  # hosts/ is at backends/nixos/hosts/, not under tests/
  hostsDir = baseDir + "/../../backends/nixos/hosts";
  innerVmBaseModule = baseDir + "/lib/inner-vm-base.nix";

  # Build NixOS configuration for the inner VM
  # This combines the actual host config with emulation-specific overrides
  innerVMConfig = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [
      # First: Import the actual n3x host configuration
      # This brings in k3s server/agent role, networking intent, etc.
      (hostsDir + "/${hostname}/configuration.nix")

      # Second: Apply emulation-specific overrides
      # This adapts hardware settings for VM environment
      innerVmBaseModule

      # Third: Disko module (required by host config, but we override it)
      inputs.disko.nixosModules.disko

      # Fourth: sops-nix module (required by some configs)
      inputs.sops-nix.nixosModules.sops

      # Fifth: VM-specific settings for emulation network
      ({ config, ... }:
        let
          # Map hostnames to their emulation network IPs
          emulationIPs = {
            "n100-1" = "192.168.100.10";
            "n100-2" = "192.168.100.11";
            "n100-3" = "192.168.100.12";
            "jetson-1" = "192.168.100.20";
          };
          nodeIP = emulationIPs.${hostname} or "192.168.100.100";
          serverIP = "192.168.100.10"; # n100-1 is always the primary server
        in
        {
          # Ensure hostname is set correctly
          networking.hostName = lib.mkForce hostname;

          # For emulation, use a test k3s token (not production secrets)
          # This avoids needing sops decryption during image build
          services.k3s.tokenFile = lib.mkForce (
            targetPkgs.writeText "k3s-test-token" "emulation-test-token-not-for-production"
          );

          # Override serverAddr to use emulation network
          # n100-1 doesn't need serverAddr (it's clusterInit), others join via n100-1
          services.k3s.serverAddr = lib.mkForce (
            if hostname == "n100-1" then ""
            else "https://${serverIP}:6443"
          );

          # Completely replace extraFlags with emulation-appropriate values
          # This removes the hardcoded 10.0.1.x IPs from production configs
          services.k3s.extraFlags = lib.mkForce (
            if config.services.k3s.role == "server" then [
              "--node-ip=${nodeIP}"
              "--cluster-cidr=10.42.0.0/16"
              "--service-cidr=10.43.0.0/16"
              "--flannel-backend=vxlan" # Use vxlan instead of wireguard for VM compatibility
              "--disable=traefik"
              "--disable=servicelb"
              "--disable=local-storage"
              "--node-name=${hostname}"
              "--tls-san=${nodeIP}"
              "--tls-san=${hostname}.local"
              "--tls-san=${serverIP}" # Allow connections via primary server IP
            ]
            else [
              "--node-ip=${nodeIP}"
              "--node-name=${hostname}"
            ]
          );

          # Disable sops secrets (not available during image build)
          sops.secrets = lib.mkForce { };
        })
    ];
  };

  # Build the disk image
  image = make-disk-image {
    inherit lib;
    pkgs = targetPkgs;
    config = innerVMConfig.config;

    # Image format
    format = "qcow2";

    # Disk size in MB
    inherit diskSize;

    # We want a full installation, not just nix store
    onlyNixStore = false;

    # Use legacy MBR partitioning (simpler for VM testing)
    # BIOS boot with GRUB
    partitionTableType = "legacy";

    # Install bootloader
    installBootLoader = true;

    # Don't touch EFI vars (we're using BIOS)
    touchEFIVars = false;

    # Auto-size based on closure, plus some extra space
    additionalSpace = "1G";

    # Don't copy the channel (saves space, not needed for testing)
    copyChannel = false;

    # QEMU memory for build (may need more for larger images)
    memSize = 2048;
  };

in
{
  inherit hostname arch system;

  # The qcow2 disk image derivation
  inherit image;

  # Path to the image file
  imagePath = "${image}/nixos.qcow2";

  # Metadata for documentation
  description = "Pre-installed NixOS qcow2 image for ${hostname} (${arch})";
  diskSizeMB = diskSize;

  # The underlying NixOS configuration (useful for debugging)
  nixosConfig = innerVMConfig;
}
