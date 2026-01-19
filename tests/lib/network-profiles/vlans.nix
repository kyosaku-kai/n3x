# VLAN Network Profile - 802.1Q VLAN Tagging
#
# Configures 802.1Q VLAN tagging on single trunk interface for production parity.
# Uses eth1 as trunk with two VLANs:
#   - VLAN 200: Cluster traffic (k3s, flannel)
#   - VLAN 100: Storage traffic (Longhorn, iSCSI)
#
# USAGE:
#   Used by mk-k3s-cluster-test.nix when networkProfile = "vlans"
#
# TOPOLOGY:
#   eth1 (trunk) ─┬─ eth1.200 (cluster)  - 192.168.200.0/24
#                 └─ eth1.100 (storage)  - 192.168.100.0/24
#
# COMPATIBILITY:
#   Works on all platforms (native Linux, WSL2, Darwin in Lima/UTM, Cloud)
#   nixosTest creates single shared network, VLANs tag traffic within it
#
# PRODUCTION PARITY:
#   Matches future deployment with external managed switch
#   Tests VLAN tagging behavior before hardware deployment

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
      # Enable 802.1Q VLAN support
      boot.kernelModules = [ "8021q" ];

      # Configure VLANs using systemd-networkd
      systemd.network = {
        enable = true;

        # Create cluster VLAN netdev (eth1.200)
        netdevs."20-vlan-cluster" = {
          netdevConfig = {
            Kind = "vlan";
            Name = "eth1.${toString clusterVlanId}";
          };
          vlanConfig.Id = clusterVlanId;
        };

        # Create storage VLAN netdev (eth1.100)
        netdevs."20-vlan-storage" = {
          netdevConfig = {
            Kind = "vlan";
            Name = "eth1.${toString storageVlanId}";
          };
          vlanConfig.Id = storageVlanId;
        };

        # Configure eth1 as trunk (attach VLANs)
        networks."15-eth1" = {
          matchConfig.Name = "eth1";
          vlan = [ "eth1.${toString clusterVlanId}" "eth1.${toString storageVlanId}" ];
          networkConfig = {
            # Trunk interface doesn't need IP
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };

        # Configure cluster VLAN interface
        networks."20-vlan-cluster" = {
          matchConfig.Name = "eth1.${toString clusterVlanId}";
          address = [ "${clusterIP}/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };

        # Configure storage VLAN interface
        networks."20-vlan-storage" = {
          matchConfig.Name = "eth1.${toString storageVlanId}";
          address = [ "${storageIP}/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };
      };

      # Add diagnostic aliases
      environment.shellAliases = {
        vlan-list = "ip -d link show | grep vlan";
        vlan-cluster = "ip -d link show eth1.${toString clusterVlanId}";
        vlan-storage = "ip -d link show eth1.${toString storageVlanId}";
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
      "--flannel-iface=eth1.${toString clusterVlanId}"
    ]
    # Server nodes need to advertise on cluster VLAN, not QEMU NAT (eth0)
    ++ lib.optionals isServer [
      "--advertise-address=${clusterIP}"
      "--tls-san=${clusterIPs.n100-1}" # Allow joining via primary server IP
    ];
}
