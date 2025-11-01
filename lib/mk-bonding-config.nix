# Helper function to generate network bonding configuration
{ lib, ... }:

{
  # Function to create bonding configuration with sensible defaults
  mkBondingConfig = {
    interfaces ? [ "enp1s0" "enp2s0" ],
    bondName ? "bond0",
    mode ? "active-backup",
    ipAddress ? null,
    gateway ? null,
    vlanConfigs ? [],
    miimon ? 100,
    primary ? null,
    ...
  }@args:
    let
      # Convert mode string to systemd-networkd format
      bondMode = {
        "balance-rr" = "balance-rr";
        "active-backup" = "active-backup";
        "balance-xor" = "balance-xor";
        "broadcast" = "broadcast";
        "802.3ad" = "802.3ad";
        "balance-tlb" = "balance-tlb";
        "balance-alb" = "balance-alb";
      }.${mode} or mode;

      # Generate VLAN configurations
      vlanNetdevs = lib.listToAttrs (map (vlan: {
        name = "20-vlan-${toString vlan.id}";
        value = {
          netdevConfig = {
            Kind = "vlan";
            Name = "${bondName}.${toString vlan.id}";
          };
          vlanConfig.Id = vlan.id;
        };
      }) vlanConfigs);

      vlanNetworks = lib.listToAttrs (map (vlan: {
        name = "20-vlan-${toString vlan.id}-network";
        value = {
          matchConfig.Name = "${bondName}.${toString vlan.id}";
          address = lib.optional (vlan.ipAddress != null) vlan.ipAddress;
          networkConfig = {
            DHCP = if vlan.dhcp or false then "yes" else "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          } // lib.optionalAttrs (vlan.gateway != null) {
            Gateway = vlan.gateway;
          };
        };
      }) vlanConfigs);
    in
    {
      # Enable systemd-networkd
      networking.useNetworkd = true;
      networking.networkmanager.enable = lib.mkForce false;

      # Kernel modules for bonding
      boot.kernelModules = [ "bonding" ] ++ (
        if (lib.elem mode [ "balance-tlb" "balance-alb" ]) then [ "arp_monitor" ] else []
      );

      systemd.network = {
        enable = true;

        # Bond interface definition
        netdevs."10-${bondName}" = {
          netdevConfig = {
            Kind = "bond";
            Name = bondName;
          };
          bondConfig = {
            Mode = bondMode;
            MIIMonitorSec = "${toString miimon}ms";
            UpDelaySec = "200ms";
            DownDelaySec = "200ms";
          } // lib.optionalAttrs (primary != null && mode == "active-backup") {
            PrimaryReselectPolicy = "always";
            ActiveSlave = primary;
          } // lib.optionalAttrs (mode == "802.3ad") {
            LACPTransmitRate = "slow";
            TransmitHashPolicy = "layer2+3";
          } // lib.optionalAttrs (lib.elem mode [ "balance-xor" "802.3ad" "balance-tlb" ]) {
            TransmitHashPolicy = "layer2+3";
          };
        } // vlanNetdevs;

        # Physical interface configurations
        networks = (lib.listToAttrs (map (iface: {
          name = "10-${iface}";
          value = {
            matchConfig.Name = iface;
            networkConfig = {
              Bond = bondName;
              DHCP = "no";
              IPv6AcceptRA = false;
              LinkLocalAddressing = "no";
            };
          };
        }) interfaces)) // {
          # Bond interface network configuration
          "15-${bondName}" = {
            matchConfig.Name = bondName;
            address = lib.optional (ipAddress != null) ipAddress;
            networkConfig = {
              DHCP = if (ipAddress == null) then "yes" else "no";
              IPv6AcceptRA = false;
              LinkLocalAddressing = if (ipAddress == null) then "yes" else "no";
            } // lib.optionalAttrs (gateway != null) {
              Gateway = gateway;
            };
            vlan = map (vlan: "${bondName}.${toString vlan.id}") vlanConfigs;
          };
        } // vlanNetworks;
      };

      # Disable DHCP on physical interfaces through networking.interfaces
      networking.interfaces = lib.listToAttrs (map (iface: {
        name = iface;
        value = {
          useDHCP = lib.mkForce false;
        };
      }) interfaces);

      # Monitoring and debugging tools
      environment.systemPackages = with (import <nixpkgs> {}); [
        ethtool
        iproute2
        tcpdump
      ];

      # Useful aliases
      environment.shellAliases = {
        "bond-status" = "cat /proc/net/bonding/${bondName}";
        "bond-info" = "ip -d link show ${bondName}";
        "bond-slaves" = "ip link show | grep -E '${lib.concatStringsSep "|" interfaces}'";
      };
    };

  # Function to create a simple dual-NIC bonding setup for HA
  mkHABondingConfig = {
    interfaces ? [ "enp1s0" "enp2s0" ],
    ipAddress,
    gateway ? "10.0.1.1",
    nameservers ? [ "10.0.1.1" "1.1.1.1" ],
    enableStorageVlan ? false,
    storageVlanId ? 100,
    storageIpAddress ? null,
    ...
  }@args:
    mkBondingConfig {
      inherit interfaces ipAddress gateway;
      mode = "active-backup";
      primary = lib.head interfaces;
      vlanConfigs = lib.optional enableStorageVlan {
        id = storageVlanId;
        ipAddress = storageIpAddress;
        dhcp = false;
      };
    } // {
      networking.nameservers = nameservers;
    };

  # Function to create a performance-optimized bonding setup
  mkPerformanceBondingConfig = {
    interfaces ? [ "enp1s0" "enp2s0" ],
    ipAddress,
    gateway ? "10.0.1.1",
    useLACP ? true,
    ...
  }@args:
    mkBondingConfig {
      inherit interfaces ipAddress gateway;
      mode = if useLACP then "802.3ad" else "balance-alb";
      miimon = if useLACP then 100 else 50;
    } // {
      # Performance tuning
      boot.kernel.sysctl = {
        "net.core.netdev_max_backlog" = 5000;
        "net.ipv4.tcp_congestion_control" = "bbr";
        "net.core.default_qdisc" = "fq";
      };
    };
}