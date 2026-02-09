# DHCP Simple Network Profile - DHCP-assigned IPs on Flat Network
#
# This profile tests DHCP client behavior with deterministic IPs via
# MAC-based reservations. See docs/DHCP-TEST-INFRASTRUCTURE.md for
# architectural rationale.
#
# USAGE:
#   Used by mk-k3s-cluster-test.nix when networkProfile = "dhcp-simple"
#
# TOPOLOGY:
#   - dhcp-server VM provides DHCP via dnsmasq
#   - Cluster nodes on single flat network (192.168.1.0/24)
#   - MAC-based reservations for deterministic IPs
#   - No VLANs, no bonding - simplest DHCP test configuration
#
# DHCP vs STATIC:
#   - simple.nix: Static IPs baked into images
#   - dhcp-simple.nix: IPs assigned via DHCP (this profile)
#   Both result in same IP assignments - DHCP validates network init path
#
# KEY DIFFERENCE FROM STATIC:
#   - mode = "dhcp" indicates DHCP mode (vs implicit "static")
#   - dhcpServer config for test infrastructure
#   - reservations for MAC-based assignments
#   - IPs still deterministic for K3s configuration
#
# MAC ADDRESS SCHEME (Plan 019 C1):
#   52:54:00:CC:NN:HH
#   - 52:54:00: QEMU locally administered OUI
#   - CC: Cluster ID (01 = default test cluster)
#   - NN: Network type (01 = cluster)
#   - HH: Host number (00=dhcp-server, 01=server-1, etc.)

{ lib }:

let
  # MAC address generation following scheme from C1 design
  # Format: 52:54:00:01:01:XX where XX is the host number
  mkMac = hostNum:
    let
      hex = lib.toHexString hostNum;
      padded = if builtins.stringLength hex == 1 then "0${hex}" else hex;
    in
    "52:54:00:01:01:${padded}";

  # DHCP server configuration
  dhcpServerMac = mkMac 0; # 52:54:00:01:01:00
  dhcpServerIp = "192.168.1.254";

  # Single source of truth for node IPs and MACs
  nodes = {
    server-1 = {
      ip = "192.168.1.1";
      mac = mkMac 1; # 52:54:00:01:01:01
    };
    server-2 = {
      ip = "192.168.1.2";
      mac = mkMac 2; # 52:54:00:01:01:02
    };
    agent-1 = {
      ip = "192.168.1.3";
      mac = mkMac 3; # 52:54:00:01:01:03
    };
    agent-2 = {
      ip = "192.168.1.4";
      mac = mkMac 4; # 52:54:00:01:01:04
    };
  };

  # Extract just IPs for backward compatibility
  nodeIPs = lib.mapAttrs (name: cfg: cfg.ip) nodes;

  # Interface definitions
  interfaces = {
    cluster = "eth1"; # K3s and inter-node traffic
  };

  # Abstract IP map per node (for ISAR netplan generation and test scripts)
  ipAddresses = lib.mapAttrs (name: cfg: { cluster = cfg.ip; }) nodes;

  # MAC reservations for DHCP server configuration
  # Format expected by dnsmasq dhcp-host directive
  reservations = lib.mapAttrs (name: cfg: {
    mac = cfg.mac;
    ip = cfg.ip;
  }) nodes;

in
{
  # DHCP mode indicator (distinguishes from static profiles)
  mode = "dhcp";

  # Export for test scripts
  inherit nodeIPs;

  # Abstract exports for ISAR netplan generation
  inherit ipAddresses interfaces;

  # MAC reservations for DHCP server and test driver MAC assignment
  inherit reservations;

  # DHCP server configuration
  dhcpServer = {
    mac = dhcpServerMac;
    ip = dhcpServerIp;
    subnet = "192.168.1.0/24";
    rangeStart = "192.168.1.100"; # Non-reserved range for dynamic clients
    rangeEnd = "192.168.1.200";
    gateway = null; # No gateway in test network
    leaseTime = "12h";
  };

  # Server API endpoint (uses primary server IP)
  serverApi = "https://${nodeIPs.server-1}:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # NOTE: k3sExtraFlags generated from profile data by lib/k3s/mk-k3s-flags.nix
}
