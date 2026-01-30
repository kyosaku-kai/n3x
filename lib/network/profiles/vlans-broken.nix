# VLAN Broken Network Profile - Negative Test Configuration
#
# This profile intentionally misconfigures VLAN IDs to verify that
# the test infrastructure correctly detects and fails on VLAN mismatches.
#
# PURPOSE:
#   Negative testing - ensures that wrong VLAN configurations cause
#   predictable failures, validating our test assertions work correctly.
#
# MISCONFIGURATION:
#   server-1: Uses correct VLAN ID (200) for cluster
#   server-2: Uses WRONG VLAN ID (201) for cluster - intentionally broken
#   agent-1/2: Uses WRONG VLAN IDs (202/203) for cluster - intentionally broken
#
# EXPECTED BEHAVIOR:
#   - Nodes boot successfully
#   - server-1 starts k3s and becomes Ready
#   - Other nodes CANNOT communicate with server-1 (different VLANs)
#   - Cluster formation FAILS (nodes can't join)
#
# UNIFIED NETWORK SCHEMA (A4):
#   This profile intentionally VIOLATES the unified schema to test failure detection.
#   Normal schema requires consistent VLAN IDs; this profile uses different IDs per node.
#
# USAGE:
#   Used by k3s-vlan-negative test to verify failure detection
#
# NOTE: This profile retains nodeConfig (unlike other profiles) because
# mkNixOSConfig cannot handle per-node VLAN IDs - it assumes all nodes
# share the same VLAN configuration. This intentional non-standard behavior
# requires custom nodeConfig to implement the per-node VLAN misconfiguration.

{ lib }:

let
  # Single source of truth for IPs
  # Note: IPs are in same subnet but VLANs are different!
  # This simulates misconfiguration where IPs are correct but VLAN tags are wrong
  # NOTE: These are TEST VM names. Physical hosts use different naming.
  clusterIPs = {
    server-1 = "192.168.200.1";
    server-2 = "192.168.200.2";
    agent-1 = "192.168.200.3";
    agent-2 = "192.168.200.4";
  };

  storageIPs = {
    server-1 = "192.168.100.1";
    server-2 = "192.168.100.2";
    agent-1 = "192.168.100.3";
    agent-2 = "192.168.100.4";
  };

  # INTENTIONAL MISCONFIGURATION: Different VLAN IDs per node
  # This simulates a common configuration error where nodes are
  # accidentally configured with different VLAN IDs
  clusterVlanIds = {
    server-1 = 200; # Correct
    server-2 = 201; # WRONG - different VLAN, can't reach server-1
    agent-1 = 202; # WRONG - different VLAN, can't reach server-1
    agent-2 = 203; # WRONG - different VLAN, can't reach server-1
  };

  # Storage VLAN - also mismatched for consistency
  storageVlanIds = {
    server-1 = 100; # Correct
    server-2 = 101; # WRONG
    agent-1 = 102; # WRONG
    agent-2 = 103; # WRONG
  };
in
{
  # Export for test scripts
  inherit clusterIPs storageIPs clusterVlanIds storageVlanIds;

  # Server API endpoint - server-2 and agent-1 will try to reach this but can't
  # because they're on different VLANs
  serverApi = "https://${clusterIPs.server-1}:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # Per-node configuration function
  # INTENTIONALLY BROKEN: Each node gets different VLAN ID
  nodeConfig = nodeName: { config, pkgs, lib, ... }:
    let
      clusterIP = clusterIPs.${nodeName};
      storageIP = storageIPs.${nodeName};
      clusterVlanId = clusterVlanIds.${nodeName};
      storageVlanId = storageVlanIds.${nodeName};
      vlanName = "eth1.${toString clusterVlanId}";
      storageVlanName = "eth1.${toString storageVlanId}";
    in
    {
      # Enable 802.1Q VLAN support
      boot.kernelModules = [ "8021q" ];

      # Ensure systemd-networkd is used exclusively
      networking.useDHCP = false;
      networking.useNetworkd = true;

      # Configure VLANs using systemd-networkd
      # Each node creates VLANs with different IDs - this is the bug
      systemd.network = {
        enable = true;

        # Create cluster VLAN netdev with node-specific (wrong) ID
        netdevs."20-vlan-cluster" = {
          netdevConfig = {
            Kind = "vlan";
            Name = vlanName;
          };
          vlanConfig.Id = clusterVlanId;
        };

        # Create storage VLAN netdev with node-specific (wrong) ID
        netdevs."20-vlan-storage" = {
          netdevConfig = {
            Kind = "vlan";
            Name = storageVlanName;
          };
          vlanConfig.Id = storageVlanId;
        };

        # Configure eth1 as trunk (attach VLANs)
        networks."15-eth1" = {
          matchConfig.Name = "eth1";
          vlan = [ vlanName storageVlanName ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };

        # Configure cluster VLAN interface
        networks."20-vlan-cluster" = {
          matchConfig.Name = vlanName;
          address = [ "${clusterIP}/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };

        # Configure storage VLAN interface
        networks."20-vlan-storage" = {
          matchConfig.Name = storageVlanName;
          address = [ "${storageIP}/24" ];
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };
      };

      # Add diagnostic aliases (reflect actual VLAN names per node)
      environment.shellAliases = {
        vlan-list = "ip -d link show | grep vlan";
        vlan-cluster = "ip -d link show ${vlanName}";
        vlan-storage = "ip -d link show ${storageVlanName}";
      };
    };

  # k3s-specific flags for this network profile
  # Uses same IPs but nodes are on different VLANs so can't communicate
  k3sExtraFlags = nodeName:
    let
      clusterIP = clusterIPs.${nodeName};
      clusterVlanId = clusterVlanIds.${nodeName};
      vlanName = "eth1.${toString clusterVlanId}";
      isServer = nodeName == "server-1" || nodeName == "server-2";
    in
    [
      # Use cluster VLAN for node IP
      "--node-ip=${clusterIP}"
      # Explicitly set flannel to use node's VLAN interface
      "--flannel-iface=${vlanName}"
    ]
    ++ lib.optionals isServer [
      "--advertise-address=${clusterIP}"
      "--tls-san=${clusterIPs.server-1}"
    ];
}
