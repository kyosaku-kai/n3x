{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Boot configuration
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "rtsx_pci_sdmmc"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware
  hardware.enableRedistributableFirmware = true;

  # Network interfaces (adjust based on actual hardware)
  # These will be bonded by the bonding module
  networking.interfaces = {
    # First Ethernet interface
    enp1s0 = {
      useDHCP = false;
    };

    # Second Ethernet interface
    enp2s0 = {
      useDHCP = false;
    };
  };

  # Power management
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # Hardware video acceleration (if needed)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };

  # System architecture
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
