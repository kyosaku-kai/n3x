# =============================================================================
# mkNetworkConfig - Generate network configuration for ISAR VMs
# =============================================================================
#
# Provides functions to configure ISAR VM networking at runtime using data
# from shared network profiles.
#
# This bridges the gap between:
#   - Network profiles that define IPs/interfaces abstractly
#   - ISAR VMs that need runtime configuration commands
#
# KEY DIFFERENCE FROM NIXOS:
#   - NixOS test VMs use eth1 (predictable naming disabled)
#   - ISAR VMs use enp0s2 (predictable naming via systemd)
#   - The VDE VLAN socket is the SAME, just different interface name inside VM
#
# USAGE:
#   networkConfig = mkNetworkConfig {
#     profile = import ../../../lib/network/profiles/simple.nix { inherit lib; };
#     # Map profile's abstract interface names to ISAR's actual interface names
#     interfaceMapping = {
#       cluster = "enp0s2";  # VDE VLAN 1 appears as enp0s2 in ISAR
#       # storage = "enp0s3";  # Would be second VDE VLAN if present
#     };
#   };
#
#   # In test script:
#   testScript = ''
#     ${networkConfig.setupScript "vm1"}
#     ${networkConfig.setupScript "vm2"}
#   '';
#
# =============================================================================

{ lib }:

{
  # Network profile from lib/network/profiles/
  profile
, # Map abstract interface names to ISAR interface names
  # Default: VDE VLAN 1 appears as enp0s2 in ISAR VMs
  interfaceMapping ? { cluster = "enp0s2"; }
}:

let
  # Get the interface abstraction from profile
  profileInterfaces = profile.interfaces or { cluster = "eth1"; };

  # Get IP addresses from profile
  ipAddresses = profile.ipAddresses or { };

  # Map NixOS machine names to ISAR VM names
  # Profile uses: server-1, server-2, agent-1, agent-2
  # ISAR tests may use: vm1, vm2 OR server, agent, etc.
  defaultMachineMapping = {
    "vm1" = "server-1";
    "vm2" = "server-2";
    "server" = "server-1";
    "agent" = "agent-1";
    "agent1" = "agent-1";
    "agent2" = "agent-2";
  };

in
{
  # Export the profile for reference
  inherit profile;

  # Export interface mapping for documentation
  inherit interfaceMapping;

  # Get IP for a machine on a given network
  # machineId: ISAR VM name (e.g., "vm1", "server")
  # network: abstract network name (e.g., "cluster", "storage")
  # Returns: IP address string or null
  getIP = machineId: network:
    let
      # Map ISAR machine ID to profile machine name
      profileMachineName = defaultMachineMapping.${machineId} or machineId;
      machineIPs = ipAddresses.${profileMachineName} or { };
    in
      machineIPs.${network} or null;

  # Get interface name for a network in ISAR VM
  # network: abstract network name (e.g., "cluster")
  # Returns: ISAR interface name (e.g., "enp0s2")
  getInterface = network:
    interfaceMapping.${network} or (
      builtins.trace "WARNING: No interface mapping for network '${network}', using profile's interface"
        profileInterfaces.${network} or "eth1"
    );

  # Generate Python test script commands to configure network for a machine
  # machineId: ISAR VM name (e.g., "vm1", "server")
  # Returns: Python code string to configure network
  setupCommands = machineId:
    let
      profileMachineName = defaultMachineMapping.${machineId} or machineId;
      machineIPs = ipAddresses.${profileMachineName} or { };

      # Generate setup commands for each network the machine has an IP on
      networks = builtins.attrNames machineIPs;

      # Generate command for one network
      mkNetworkSetup = network:
        let
          ip = machineIPs.${network};
          iface = interfaceMapping.${network} or profileInterfaces.${network} or "enp0s2";
        in
        ''
          # Configure ${network} network on ${iface}
          ${machineId}.succeed("ip link set ${iface} up")
          ${machineId}.succeed("ip addr add ${ip}/24 dev ${iface}")
          tlog(f"  ${machineId}: configured ${iface} with ${ip} (${network})")
        '';
    in
    lib.concatMapStrings mkNetworkSetup networks;

  # Generate Python code to verify IP configuration for a machine
  # machineId: ISAR VM name
  # Returns: Python code string
  verifyCommands = machineId:
    let
      profileMachineName = defaultMachineMapping.${machineId} or machineId;
      machineIPs = ipAddresses.${profileMachineName} or { };
      networks = builtins.attrNames machineIPs;

      mkVerify = network:
        let
          ip = machineIPs.${network};
          iface = interfaceMapping.${network} or profileInterfaces.${network} or "enp0s2";
        in
        ''
          ${machineId}.succeed("ip addr show ${iface} | grep ${ip}")
          tlog(f"  ${machineId}: ${ip} on ${iface} verified (${network})")
        '';
    in
    lib.concatMapStrings mkVerify networks;

  # Get all IPs for a machine (for connectivity tests)
  # Returns: { cluster = "192.168.1.1"; storage = "192.168.100.1"; ... }
  getMachineIPs = machineId:
    let
      profileMachineName = defaultMachineMapping.${machineId} or machineId;
    in
      ipAddresses.${profileMachineName} or { };

  # Get the server API endpoint from profile
  serverApi = profile.serverApi or "https://192.168.1.1:6443";

  # Get K3s CIDRs from profile
  clusterCidr = profile.clusterCidr or "10.42.0.0/16";
  serviceCidr = profile.serviceCidr or "10.43.0.0/16";
}
