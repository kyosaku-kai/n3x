# K3s Extra Flags Generator
#
# This module provides a unified function to generate k3s extra flags from
# network profile data. It eliminates duplication across network profiles
# by centralizing the flag generation logic.
#
# USAGE:
#   mkK3sFlags = import ./mk-k3s-flags.nix { inherit lib; };
#   flags = mkK3sFlags.mkExtraFlags {
#     profile = import ../network/profiles/vlans.nix { inherit lib; };
#     nodeName = "server-1";
#     role = "server";  # or "agent"
#   };
#
# PARAMETERS:
#   - profile: Network profile preset containing:
#       - ipAddresses: { "server-1" = { cluster = "192.168.200.1"; }; ... }
#       - interfaces: { cluster = "eth1.200"; ... }
#   - nodeName: Name of the node (e.g., "server-1", "agent-1")
#   - role: K3s role - "server" or "agent"
#
# RETURNS:
#   List of k3s extra flags for the given node and role
#
# ARCHITECTURE (Plan 012 - DRY Pattern):
#   Profiles export data (ipAddresses, interfaces), NOT functions.
#   This module transforms that data into k3s-specific flags.
#   Same pattern as mk-network-config.nix transforms profile data into NixOS modules.

{ lib }:

{
  # Generate k3s extra flags from profile data
  #
  # The profile must have:
  #   - ipAddresses.${nodeName}.cluster - Node's cluster network IP
  #   - interfaces.cluster - Cluster network interface name
  #
  # For servers, the primary server IP is assumed to be ipAddresses."server-1".cluster
  mkExtraFlags = { profile, nodeName, role }:
    let
      # Get node's cluster IP from profile
      nodeIP = profile.ipAddresses.${nodeName}.cluster;

      # Determine if this is a server node
      isServer = role == "server";

      # Primary server IP for --tls-san (agents don't need this)
      primaryServerIP = profile.ipAddresses."server-1".cluster;

      # Cluster interface for flannel
      # This already includes VLAN suffix if applicable (e.g., "eth1.200" or "bond0.200")
      flannelIface = profile.interfaces.cluster;
    in
    [
      # All nodes need node-ip on cluster network
      "--node-ip=${nodeIP}"
      # All nodes need flannel to use cluster interface
      "--flannel-iface=${flannelIface}"
    ]
    # Server-specific flags
    ++ lib.optionals isServer [
      # Advertise on cluster network, not QEMU NAT (eth0)
      "--advertise-address=${nodeIP}"
      # Allow joining via primary server IP
      "--tls-san=${primaryServerIP}"
    ];
}
