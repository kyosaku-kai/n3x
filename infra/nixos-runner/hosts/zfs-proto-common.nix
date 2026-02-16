# ZFS cluster prototype - shared configuration
#
# Common configuration for 3x Intel N100 mini PCs used as the ZFS binary
# cache prototype cluster. Each node runs Harmonia behind Caddy (HTTPS),
# with ZFS-backed /nix/store for compression and integrity.
#
# Hardware: Intel N100, 16GB RAM, NVMe (500GB-1TB), 2x 1GbE
# Network: MikroTik CRS326-24G-2S+ managed switch
#   - NIC 1 (mgmt): office LAN / management (DHCP)
#   - NIC 2 (cluster): isolated cluster network 10.99.0.0/24
#
# Deployment: nixos-anywhere over SSH from management network
#   nixos-anywhere --flake '.#zfs-proto-1' root@<mgmt-ip>
{ config, lib, pkgs, modulesPath, ... }:

{
  # Import NixOS base hardware detection
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Intel N100 firmware/microcode
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Networking: systemd-networkd for predictable configuration
  #
  # NIC naming on Intel N100 mini PCs will vary by motherboard.
  # Common patterns: enp1s0/enp2s0, eno1/eno2, enp0s20f0u*/enp0s20f0u*
  #
  # TODO (deployment): Confirm actual NIC names with `ip link` and override
  # mgmtInterface/clusterInterface in per-host configs if needed.
  networking = {
    useNetworkd = true;
    useDHCP = false; # We configure per-interface below
    firewall.enable = true;
  };

  systemd.network = {
    enable = true;

    # Management NIC: DHCP from office LAN
    networks."10-mgmt" = {
      # matchConfig set per-host (NIC names may differ)
      matchConfig.Name = lib.mkDefault "enp1s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.RouteMetric = 100;
    };

    # Cluster NIC: static IP on isolated 10.99.0.0/24
    networks."20-cluster" = {
      matchConfig.Name = lib.mkDefault "enp2s0";
      networkConfig = {
        DHCP = "no";
        # Address set per-host
      };
      # Gateway not needed on cluster network (L2 only)
    };
  };

  # Enable n3x runner modules
  n3x = {
    # ZFS: single-disk layout (ESP + root ext4 + ZFS on one NVMe)
    disko-zfs = {
      enable = true;
      diskLayout = "single-disk";
      device = lib.mkDefault "/dev/nvme0n1";
    };

    # GitLab runner: tags identify prototype cluster capabilities
    gitlab-runner = {
      enable = true;
      tags = [ "nix" "x86_64" "zfs-proto" ];
      # registrationConfigFile wired after deployment via agenix
    };

    apt-cacher-ng = {
      enable = true;
      openFirewall = true; # Allow other cluster nodes to use this proxy
    };

    yocto-cache.enable = true;
    nix-config.enable = true;
    harmonia.enable = true;

    cache-signing = {
      enable = true;
      privateKeyFile = "/run/agenix/cache-signing-key";
      publicKey = "cache.n3x.example.com-1:REPLACE_WITH_REAL_PUBLIC_KEY";
      # secretsFile wired after key generation during deployment
    };

    internal-ca = {
      enable = true;
      rootCertFile = ../certs/n3x-root-ca.pem;
    };

    caddy.enable = true;
  };

  # Cross-node substituters: each node fetches from the other two
  # Priority 10 = prefer cluster peers over cache.nixos.org (40)
  # Actual hostnames resolved via /etc/hosts (or DNS after MikroTik config)
  #
  # NOTE: Per-host configs add the other two nodes as substituters.
  # The node's OWN cache is served by Harmonia, not consumed as substituter.

  # Static /etc/hosts for cluster name resolution (until DNS configured)
  networking.extraHosts = ''
    10.99.0.11 zfs-proto-1 cache.zfs-proto-1.n3x.internal
    10.99.0.12 zfs-proto-2 cache.zfs-proto-2.n3x.internal
    10.99.0.13 zfs-proto-3 cache.zfs-proto-3.n3x.internal
  '';

  # SSH server for remote management and nixos-anywhere
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Common packages for administration
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
  ];

  system.stateVersion = "24.11";
}
