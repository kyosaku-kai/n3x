# Bonding + VLAN Network Profile - Full Production Parity
#
# NOTE: BONDING IS DEFERRED (Architecture Review 2026-01-26)
# This profile exists for future use but is not part of MVP test matrix.
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
#
# UNIFIED NETWORK SCHEMA (A4):
#   This profile implements the unified schema with MAXIMUM complexity.
#   Schema keys: cluster (K3s traffic on VLAN 200), storage (Longhorn on VLAN 100)
#   Bonding: active-backup mode with eth1/eth2 members
#   NOTE: Bonding tests deferred indefinitely per Architecture Review decision.
#
# EXPORTS (P2.1 - Abstraction Layer for ISAR):
#   ipAddresses - Per-node map: { server-1 = { cluster = "192.168.200.1"; storage = "192.168.100.1"; }; ... }
#   interfaces - Interface names: { cluster = "bond0.200"; storage = "bond0.100"; trunk = "bond0"; bondMembers = ["eth1" "eth2"]; }
#   vlanIds - VLAN ID map: { cluster = 200; storage = 100; }
#   bondConfig - Bonding params: { mode = "active-backup"; primary = "eth1"; miimon = 100; }
#   These allow ISAR to generate netplan YAML without understanding NixOS modules.

{ lib }:

let
  # Single source of truth for IPs
  # NOTE: These are TEST VM names. Physical hosts use different naming.
  # Supports both topology patterns:
  #   - 2 servers + 1 agent (HA control plane)
  #   - 1 server + 2 agents (workload scaling)
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

  # VLAN IDs
  clusterVlanId = 200;
  storageVlanId = 100;

  # Interface definitions (for ISAR netplan generation)
  interfaces = {
    trunk = "bond0";
    cluster = "bond0.${toString clusterVlanId}";
    storage = "bond0.${toString storageVlanId}";
    bondMembers = [ "eth1" "eth2" ];
  };

  # VLAN ID map (for ISAR netplan generation)
  vlanIds = {
    cluster = clusterVlanId;
    storage = storageVlanId;
  };

  # Bond configuration (for ISAR netplan generation)
  bondConfig = {
    mode = "active-backup";
    primary = "eth1";
    miimon = 100;
  };

  # Abstract IP map per node (for ISAR netplan generation)
  # Format: { nodeName = { networkName = "ip"; ... }; }
  ipAddresses = {
    "server-1" = { cluster = clusterIPs."server-1"; storage = storageIPs."server-1"; };
    "server-2" = { cluster = clusterIPs."server-2"; storage = storageIPs."server-2"; };
    "agent-1" = { cluster = clusterIPs."agent-1"; storage = storageIPs."agent-1"; };
    "agent-2" = { cluster = clusterIPs."agent-2"; storage = storageIPs."agent-2"; };
  };
in
{
  # Export for test scripts (legacy format)
  inherit clusterIPs storageIPs clusterVlanId storageVlanId;

  # P2.1: Abstract exports for ISAR netplan generation
  inherit ipAddresses interfaces vlanIds bondConfig;

  # Server API endpoint (uses cluster VLAN)
  serverApi = "https://${clusterIPs.server-1}:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # Per-node configuration function
  # Takes nodeName (e.g. "server-1") and returns NixOS module
  nodeConfig = nodeName: { config, pkgs, lib, ... }:
    let
      clusterIP = clusterIPs.${nodeName};
      storageIP = storageIPs.${nodeName};
    in
    {
      # Need two NICs per node for bonding
      virtualisation.vlans = [ 1 2 ];

      # Import bonding module
      imports = [ ../../../backends/nixos/modules/network/bonding.nix ];

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
      isServer = nodeName == "server-1" || nodeName == "server-2";
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
      "--tls-san=${clusterIPs.server-1}" # Allow joining via primary server IP
    ];
}
