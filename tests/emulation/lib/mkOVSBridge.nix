# mkOVSBridge.nix - OVS switch fabric configuration generator
#
# Creates NixOS module configuration for Open vSwitch bridge with internal
# host interface. Extracted and refactored from vsim/embedded-system-emulator.nix
#
# USAGE:
#   ovsConfig = mkOVSBridge {
#     bridgeName = "ovsbr0";
#     hostInterface = "vnet0";
#     hostIP = "192.168.100.1";
#     cidr = "/24";
#   };
#
# RETURNS:
#   NixOS module configuration attribute set with:
#   - networking.vswitches.* - OVS bridge definition
#   - systemd.network.* - systemd-networkd configuration for host interface
#
# NOTES:
#   - OVS service is enabled implicitly via networking.vswitches configuration
#   - Host interface is created as OVS internal interface (type=internal)
#   - systemd-networkd is enabled and configured for the host interface
#   - ConfigureWithoutCarrier allows interface to come up before VMs attach

{ config, lib, pkgs, ... }:

{ bridgeName ? "ovsbr0"
  # NOTE: Use "ovshost0" instead of "vnet0" to avoid conflict with libvirt's
  # default naming for VM tap interfaces (vnet0, vnet1, etc.)
, hostInterface ? "ovshost0"
, hostIP ? "192.168.100.1"
, cidr ? "/24"
}:

{
  #############################################################################
  # OPEN VSWITCH - Switch Fabric Configuration
  #############################################################################

  # OVS bridge configuration
  # Note: services.openvswitch.enable is implicit when networking.vswitches is used
  networking.vswitches.${bridgeName} = {
    # No initial interfaces - VMs will attach at runtime
    interfaces = { };

    # Create internal interface for host connectivity
    # The internal interface allows the hypervisor to communicate with VMs
    # Note: NixOS prepends " -- " to each line, so do NOT include leading "--"
    # Each line becomes a separate ovs-vsctl sub-command
    extraOvsctlCmds = "--may-exist add-port ${bridgeName} ${hostInterface} -- set interface ${hostInterface} type=internal";
  };

  #############################################################################
  # SYSTEMD-NETWORKD - Host Interface Configuration
  #############################################################################

  # Configure the OVS internal interface for host access
  systemd.network = {
    enable = true;

    # Network configuration for OVS internal interface
    networks."50-ovs-internal" = {
      # Match the internal interface created by OVS
      matchConfig.Name = hostInterface;

      # Assign static IP to host interface
      address = [ "${hostIP}${cidr}" ];

      # Allow interface to be configured even if no carrier is detected
      # This is critical because OVS internal interfaces may not have
      # carrier until VMs are attached
      networkConfig.ConfigureWithoutCarrier = true;
    };
  };
}
