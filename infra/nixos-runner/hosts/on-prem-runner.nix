# On-prem bare-metal runner configuration
#
# NixOS configuration for on-premises build/test runner hardware.
# Primary role: KVM-capable VM tests (nixosTest) and hardware-in-the-loop (HIL)
# testing that cannot run on EC2 (nested virtualisation not available).
#
# Hardware requirements:
#   - x86_64 CPU with VT-x/VT-d (KVM)
#   - 32GB+ RAM (VM tests run multiple QEMU instances)
#   - NVMe SSD (500GB+) — single-disk disko layout with ZFS
#   - 2x GbE NICs recommended (management + cluster/lab)
#
# Deployment:
#   nixos-anywhere --flake '.#on-prem-runner' root@<mgmt-ip>
#
# Post-deployment:
#   1. Confirm NIC names: `ip link` — override mgmt/lab interfaces if needed
#   2. Wire agenix secrets (gitlab-runner token, cache-signing key)
#   3. Register with GitLab: `gitlab-runner register`
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  networking.hostName = "on-prem-runner";

  # KVM: required for NixOS VM tests (nixosTest / QEMU)
  boot.kernelModules = [ "kvm-intel" ];
  virtualisation.libvirtd = {
    enable = true;
    qemu.runAsRoot = true; # VM tests expect root QEMU access
  };

  # Firmware/microcode — mkDefault so host-specific hardware can override
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  hardware.enableRedistributableFirmware = true;

  # Networking: systemd-networkd
  # Default assumes dual-NIC (management + lab/cluster). Override NIC names
  # after `ip link` on real hardware.
  networking = {
    useNetworkd = true;
    useDHCP = false;
    firewall.enable = true;
  };

  systemd.network = {
    enable = true;

    # Management NIC: DHCP from office/lab LAN
    networks."10-mgmt" = {
      matchConfig.Name = lib.mkDefault "enp1s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.RouteMetric = 100;
    };

    # Lab/cluster NIC: static IP for HIL devices and/or cluster network
    # Override address in deployment-specific config
    networks."20-lab" = {
      matchConfig.Name = lib.mkDefault "enp2s0";
      networkConfig.DHCP = "no";
      # address set at deployment, e.g.:
      #   systemd.network.networks."20-lab".address = [ "10.99.0.20/24" ];
    };
  };

  # n3x runner modules
  n3x = {
    # ZFS: single-disk layout (ESP + root ext4 + ZFS on one NVMe)
    disko-zfs = {
      enable = true;
      diskLayout = "single-disk";
      device = lib.mkDefault "/dev/nvme0n1";
      hostId = "0a0b0c0d"; # Override with real value at deployment
    };

    gitlab-runner = {
      enable = true;
      tags = [ "nix" "x86_64" "kvm" "on-prem" "hil" ];
      concurrent = 1; # VM tests are resource-heavy; one at a time
      # registrationConfigFile wired via agenix after deployment
    };

    apt-cacher-ng = {
      enable = true;
      openFirewall = true;
    };

    yocto-cache.enable = true;
    nix-config.enable = true;
    harmonia.enable = true;

    cache-signing = {
      enable = true;
      privateKeyFile = "/run/agenix/cache-signing-key";
      publicKey = "cache.n3x.example.com-1:REPLACE_WITH_REAL_PUBLIC_KEY";
    };

    internal-ca = {
      enable = true;
      rootCertFile = ../certs/n3x-root-ca.pem;
    };

    caddy.enable = true;
  };

  # Substituters: EC2 builders (high priority) + upstream
  # On-prem runner fetches from EC2 caches before building locally
  n3x.nix-config.extraSubstituters = [
    "https://cache.ec2-x86-64.n3x.internal?priority=10"
    "https://cache.ec2-graviton.n3x.internal?priority=10"
  ];

  # Podman for ISAR/kas-container builds
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  # Allow gitlab-runner to access libvirt (VM tests)
  users.users.gitlab-runner.extraGroups = [ "libvirtd" ];

  # SSH for remote management and nixos-anywhere
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Administration tools
  environment.systemPackages = with pkgs; [
    git
    vim
    tmux
    htop
    iotop
    lsof
    pciutils
    usbutils
    ethtool
    iproute2
    tcpdump
    # KVM/libvirt management
    virt-manager
    virtiofsd
  ];

  system.stateVersion = "24.11";
}
