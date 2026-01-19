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

{ lib }:

let
  # Single source of truth for node IPs
  nodeIPs = {
    n100-1 = "192.168.1.1";
    n100-2 = "192.168.1.2";
    n100-3 = "192.168.1.3";
  };
in
{
  # Export for test scripts
  inherit nodeIPs;

  # Server API endpoint (uses primary server IP)
  serverApi = "https://${nodeIPs.n100-1}:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # Per-node configuration function
  # Takes nodeName (e.g. "n100-1") and returns NixOS module
  nodeConfig = nodeName: { config, pkgs, lib, ... }: {
    # Single flat network via eth1
    networking.interfaces.eth1.ipv4.addresses = [{
      address = nodeIPs.${nodeName};
      prefixLength = 24;
    }];
  };

  # k3s-specific flags for this network profile
  # Returns list of extraFlags for k3s service
  k3sExtraFlags = nodeName:
    let
      nodeIP = nodeIPs.${nodeName};
      isServer = nodeName == "n100-1" || nodeName == "n100-2";
    in
    [
      "--node-ip=${nodeIP}"
      # flannel defaults to first non-loopback interface, which is eth1
    ]
    # Server nodes need to advertise on eth1 network, not QEMU NAT (eth0)
    ++ lib.optionals isServer [
      "--advertise-address=${nodeIP}"
      "--tls-san=${nodeIPs.n100-1}" # Allow joining via primary server IP
    ]
    # Flannel should use eth1 for inter-node communication
    ++ [
      "--flannel-iface=eth1"
    ];
}
