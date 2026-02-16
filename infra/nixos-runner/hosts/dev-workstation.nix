# Developer workstation template
#
# NixOS configuration template for developer machines that need ISAR build capability.
# This is a reference configuration - copy and customize for specific hardware.
#
# Usage:
#   1. Copy this file to your own NixOS configuration
#   2. Add hardware-specific configuration (bootloader, filesystems)
#   3. Customize user accounts and packages
{ config, lib, pkgs, ... }:

{
  networking.hostName = lib.mkDefault "dev-workstation";

  # Enable n3x runner modules (minus GitLab runner for dev machines)
  n3x = {
    # gitlab-runner disabled - dev machines don't run CI jobs
    gitlab-runner.enable = false;

    apt-cacher-ng.enable = true;
    yocto-cache.enable = true;
    nix-config.enable = true;

    # Trust internal CA so substituters and internal services work
    internal-ca = {
      enable = true;
      rootCertFile = ../certs/n3x-root-ca.pem;
    };
  };

  # ISAR/Yocto build dependencies
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;  # Alias docker -> podman
  };

  # Common development tools
  environment.systemPackages = with pkgs; [
    git
    vim
    tmux
    htop
  ];

  # Placeholder bootloader config (override in real deployment)
  # This allows the configuration to evaluate for testing
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Placeholder filesystem (override in real deployment)
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "24.11";
}
