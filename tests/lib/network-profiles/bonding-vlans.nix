# Bonding + VLAN Network Profile - Full Production Parity
#
# Configures bonding (active-backup) with 802.1Q VLAN tagging on top.
# This matches the production deployment architecture:
#   - Two physical NICs bonded for redundancy
#   - VLANs on bond for traffic separation
#
# USAGE:
#   Used by mk-k3s-cluster-test.nix when networkProfile = "bonding-vlans"
#
# TOPOLOGY:
#   eth1 ─┐
#         ├─ bond0 ─┬─ bond0.200 (cluster)  - 192.168.200.0/24
#   eth2 ─┘         └─ bond0.100 (storage)  - 192.168.100.0/24
#
# COMPATIBILITY:
#   Works on all platforms (native Linux, WSL2, Darwin in Lima/UTM, Cloud)
#   nixosTest creates two NICs per node for bonding
#
# PRODUCTION PARITY:
#   Exact match for production hardware deployment
#   Tests bonding failover + VLAN tagging together

{ lib }:

let
  # Single source of truth for IPs
  clusterIPs = {
    n100-1 = "192.168.200.1";
    n100-2 = "192.168.200.2";
    n100-3 = "192.168.200.3";
  };

  storageIPs = {
    n100-1 = "192.168.100.1";
    n100-2 = "192.168.100.2";
    n100-3 = "192.168.100.3";
  };

  # VLAN IDs
  clusterVlanId = 200;
  storageVlanId = 100;
in
{
  # Export for test scripts
  inherit clusterIPs storageIPs clusterVlanId storageVlanId;

  # Server API endpoint (uses cluster VLAN)
  serverApi = "https://${clusterIPs.n100-1}:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # Per-node configuration function
  # Takes nodeName (e.g. "n100-1") and returns NixOS module
  nodeConfig = nodeName: { config, pkgs, lib, ... }:
    let
      clusterIP = clusterIPs.${nodeName};
      storageIP = storageIPs.${nodeName};
    in
    {
      # Need two NICs per node for bonding
      virtualisation.vlans = [ 1 2 ];

      # Import bonding module
      imports = [ ../../../modules/network/bonding.nix ];

      # Configure bonding
      n3x.networking.bonding = {
        enable = true;
        interfaces = [ "eth1" "eth2" ];
        bondName = "bond0";
        mode = "active-backup";
        miimon = 100;
        primary = "eth1";
      };

      # Enable 802.1Q VLAN support
      boot.kernelModules = [ "8021q" ];

      # Configure VLANs on bond0 using systemd-networkd
      systemd.network = {
        enable = true;

        # Create cluster VLAN netdev (bond0.200)
        netdevs."20-vlan-cluster" = {
          netdevConfig = {
            Kind = "vlan";
            Name = "bond0.${toString clusterVlanId}";
          };
          vlanConfig.Id = clusterVlanId;
        };

        # Create storage VLAN netdev (bond0.100)
        netdevs."20-vlan-storage" = {
          netdevConfig = {
            Kind = "vlan";
            Name = "bond0.${toString storageVlanId}";
          };
          vlanConfig.Id = storageVlanId;
        };

        # Configure bond0 as trunk (attach VLANs)
        networks."20-bond0" = {
          matchConfig.Name = "bond0";
          vlan = [ "bond0.${toString clusterVlanId}" "bond0.${toString storageVlanId}" ];
          networkConfig = {
            # Trunk interface doesn't need IP
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
          linkConfig = {
            RequiredForOnline = false; # VLANs will be online
          };
        };

        # Configure cluster VLAN interface
        networks."30-vlan-cluster" = {
          matchConfig.Name = "bond0.${toString clusterVlanId}";
          address = [ "${clusterIP}/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
          linkConfig = {
            RequiredForOnline = true; # This is our primary network
          };
        };

        # Configure storage VLAN interface
        networks."30-vlan-storage" = {
          matchConfig.Name = "bond0.${toString storageVlanId}";
          address = [ "${storageIP}/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
          linkConfig = {
            RequiredForOnline = false; # Storage is secondary
          };
        };
      };

      # Disable default networking
      networking.useDHCP = false;
      networking.useNetworkd = true;

      # Add diagnostic aliases
      environment.shellAliases = {
        bond-status = "cat /proc/net/bonding/bond0";
        bond-info = "ip -d link show bond0";
        vlan-list = "ip -d link show | grep vlan";
        vlan-cluster = "ip -d link show bond0.${toString clusterVlanId}";
        vlan-storage = "ip -d link show bond0.${toString storageVlanId}";
      };
    };

  # k3s-specific flags for this network profile
  # Returns list of extraFlags for k3s service
  k3sExtraFlags = nodeName:
    let
      clusterIP = clusterIPs.${nodeName};
      isServer = nodeName == "n100-1" || nodeName == "n100-2";
    in
    [
      # Use cluster VLAN for node IP
      "--node-ip=${clusterIP}"
      # Explicitly set flannel to use cluster VLAN interface
      "--flannel-iface=bond0.${toString clusterVlanId}"
    ]
    # Server nodes need to advertise on cluster VLAN, not QEMU NAT (eth0)
    ++ lib.optionals isServer [
      "--advertise-address=${clusterIP}"
      "--tls-san=${clusterIPs.n100-1}" # Allow joining via primary server IP
    ];
}
