# Simple Network Profile - Single Flat Network
#
# This is the baseline profile used in current tests.
# Provides single flat network via eth1 interface.
#
# USAGE:
#   Used by mk-k3s-cluster-test.nix when networkProfile = "simple"
#
# TOPOLOGY:
#   All nodes on single flat network (192.168.1.0/24)
#   No VLANs, no bonding - simplest possible configuration
#
# COMPATIBILITY:
#   Works on all platforms (native Linux, WSL2, Darwin in Lima/UTM, Cloud)
#
# UNIFIED NETWORK SCHEMA (A4):
#   This profile implements the unified network schema with minimal complexity.
#   Schema keys: cluster (K3s traffic), storage (optional), external (NAT)
#
# EXPORTS (P2.1 - Abstraction Layer for ISAR):
#   ipAddresses - Per-node map: { server-1 = { cluster = "192.168.1.1"; }; ... }
#   interfaces - Interface names: { cluster = "eth1"; }
#   These allow ISAR to generate netplan YAML without understanding NixOS modules.

{ lib }:

let
  # Single source of truth for node IPs
  # NOTE: These are TEST VM names. Physical hosts use different naming.
  # Supports both topology patterns:
  #   - 2 servers + 1 agent (HA control plane)
  #   - 1 server + 2 agents (workload scaling)
  nodeIPs = {
    server-1 = "192.168.1.1";
    server-2 = "192.168.1.2";
    agent-1 = "192.168.1.3";
    agent-2 = "192.168.1.4";
  };

  # Interface definitions (for ISAR netplan generation)
  # Uses unified schema: cluster (K3s traffic), storage (optional), external (NAT)
  interfaces = {
    cluster = "eth1"; # K3s and inter-node traffic
    # external = "eth0";  # NAT/DHCP (implicit, managed by test harness)
  };

  # Abstract IP map per node (for ISAR netplan generation)
  # Format: { nodeName = { networkName = "ip"; ... }; }
  ipAddresses = {
    "server-1" = { cluster = nodeIPs."server-1"; };
    "server-2" = { cluster = nodeIPs."server-2"; };
    "agent-1" = { cluster = nodeIPs."agent-1"; };
    "agent-2" = { cluster = nodeIPs."agent-2"; };
  };
in
{
  # Export for test scripts
  inherit nodeIPs;

  # P2.1: Abstract exports for ISAR netplan generation
  inherit ipAddresses interfaces;

  # Server API endpoint (uses primary server IP)
  serverApi = "https://${nodeIPs.server-1}:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # Per-node configuration function
  # Takes nodeName (e.g. "server-1") and returns NixOS module
  nodeConfig = nodeName: { config, pkgs, lib, ... }: {
    # Single flat network via cluster interface (eth1)
    networking.interfaces.${interfaces.cluster}.ipv4.addresses = [{
      address = nodeIPs.${nodeName};
      prefixLength = 24;
    }];
  };

  # k3s-specific flags for this network profile
  # Returns list of extraFlags for k3s service
  k3sExtraFlags = nodeName:
    let
      nodeIP = nodeIPs.${nodeName};
      isServer = nodeName == "server-1" || nodeName == "server-2";
      clusterIface = interfaces.cluster;
    in
    [
      "--node-ip=${nodeIP}"
    ]
    # Server nodes need to advertise on cluster network, not QEMU NAT (eth0)
    ++ lib.optionals isServer [
      "--advertise-address=${nodeIP}"
      "--tls-san=${nodeIPs.server-1}" # Allow joining via primary server IP
    ]
    # Flannel should use cluster interface for inter-node communication
    ++ [
      "--flannel-iface=${clusterIface}"
    ];
}
