# inner-vm-base.nix - Base NixOS module for inner VMs in emulation environment
#
# This module provides emulation-specific overrides for n3x host configurations
# when they run as inner VMs inside the nested virtualization environment.
#
# It handles:
# - Network configuration for the emulated network (192.168.100.x)
# - VM-specific hardware settings (virtio, serial console)
# - Simplified storage (no disko partitioning for VM disks)
# - Test-friendly authentication
#
# USAGE:
#   This module is imported by mkInnerVMImage.nix when building inner VM disk images.
#   It's applied ON TOP of the actual n3x host configuration.

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Import QEMU guest support for proper virtio drivers
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  config = lib.mkMerge [
    {
      # Disable disko - we're using simple virtio disk, not complex partitioning
      # The host config imports disko, but we don't need it for VM testing
      disko.devices = lib.mkForce { };

      # Simple root filesystem for VM disk
      fileSystems = lib.mkForce {
        "/" = {
          device = "/dev/vda1";
          fsType = "ext4";
        };
      };

      # No swap for VMs
      swapDevices = lib.mkForce [ ];

      # Boot configuration for BIOS (simpler than UEFI for testing)
      boot = {
        loader = {
          grub = {
            enable = true;
            device = "/dev/vda";
            # Disable EFI for simpler BIOS boot
            efiSupport = lib.mkForce false;
          };
          # Disable systemd-boot if enabled
          systemd-boot.enable = lib.mkForce false;
        };

        # Faster boot for testing
        loader.timeout = lib.mkForce 1;

        # Essential kernel params for VM console access
        kernelParams = lib.mkForce [
          "console=ttyS0,115200n8"
          "console=tty0"
        ];

        # Ensure initrd has virtio drivers
        initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_net"
          "virtio_scsi"
          "9p"
          "9pnet_virtio"
        ];
      };

      # QEMU guest agent for better VM management
      services.qemuGuest.enable = true;

      # Serial console for virsh console access
      systemd.services."serial-getty@ttyS0" = {
        enable = true;
        wantedBy = [ "getty.target" ];
      };

      # Disable hardware-specific services that don't apply to VMs
      services.thermald.enable = lib.mkForce false;
      powerManagement.enable = lib.mkForce false;

      # Disable bonding - use simple DHCP for VM network via networkd
      networking = {
        useDHCP = lib.mkForce false; # Disable dhcpcd, use networkd instead
        useNetworkd = lib.mkForce true;
        # Remove bond interfaces - not needed in emulation
        bonds = lib.mkForce { };
        interfaces = lib.mkForce { };
        # Clear gateway settings - DHCP will provide
        defaultGateway = lib.mkForce null;
        nameservers = lib.mkForce [ "192.168.100.1" ];
      };

      # Enable DHCP on the primary interface via systemd-networkd
      # Match any predictable network interface name or legacy eth* naming
      # - eth*: Legacy naming (when net.ifnames=0)
      # - en*:  Predictable naming (enp0s*, ens*, etc.)
      systemd.network = {
        enable = true;
        networks."10-vm-network" = {
          matchConfig = {
            # Match virtio network interfaces by driver (most reliable)
            Driver = "virtio_net";
          };
          networkConfig = {
            DHCP = "yes";
            # Accept RA for IPv6 if available
            IPv6AcceptRA = true;
          };
          # Ensure DHCP client is configured properly
          dhcpV4Config = {
            UseDNS = true;
            UseHostname = true;
            # Don't set routes from DHCP (we want static routing)
            UseRoutes = true;
          };
        };
      };

      # Test-friendly authentication
      # Clear all password options from base.nix/nixosTest to avoid "multiple password options" warning
      users.users.root = {
        hashedPassword = lib.mkForce null;
        hashedPasswordFile = lib.mkForce null;
        initialPassword = lib.mkForce "test";
      };
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = lib.mkForce "yes";
          PasswordAuthentication = lib.mkForce true;
        };
      };

      # Disable documentation to save space
      documentation = {
        enable = lib.mkForce false;
        nixos.enable = lib.mkForce false;
        man.enable = lib.mkForce false;
      };

      # State version (should match outer VM)
      system.stateVersion = lib.mkForce "24.05";
    }
  ];
}
