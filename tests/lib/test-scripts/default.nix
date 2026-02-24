# Test Scripts - Shared Python test snippets
#
# This module provides reusable Python code snippets for nixos-test-driver
# test scripts. Both NixOS and ISAR backends can import these snippets
# to share test logic without duplication.
#
# Structure:
#   utils     - Core utilities (tlog, logging helpers)
#   phases/   - Test phases (dhcp, boot, network, k3s)
#
# Usage:
#   let
#     testScripts = import ./test-scripts { inherit lib; };
#   in ''
#     ${testScripts.utils.all}
#     ${testScripts.phases.dhcp.startDhcpServer { node = "dhcp_server"; }}  # For DHCP profiles
#     ${testScripts.phases.boot.bootAllNodes { nodes = ["server_1"]; }}
#     ${testScripts.phases.network.verifyInterfaces { profile = "vlans"; nodePairs = [...]; }}
#     ${testScripts.phases.k3s.verifyCluster { ... }}
#   ''

{ lib ? (import <nixpkgs> { }).lib }:

{
  # Core utilities (tlog, logging helpers)
  utils = import ./utils.nix;

  # Test phases
  phases = {
    dhcp = import ./phases/dhcp.nix { inherit lib; };
    boot = import ./phases/boot.nix { inherit lib; };
    network = import ./phases/network.nix { inherit lib; };
    k3s = import ./phases/k3s.nix { inherit lib; };
  };

  # Convenience: Generate complete default test script for k3s cluster
  # This is equivalent to the current embedded script in mk-k3s-cluster-test.nix
  #
  # Parameters:
  #   profile: network profile name ("simple", "vlans", "bonding-vlans", "dhcp-simple")
  #   nodes: { primary, secondary, agent, dhcpServer? } - node variable names
  #   nodeNames: { primary, secondary, agent } - kubernetes node names
  #   dhcpReservations: (optional) { nodeName = { expectedIp, mac }; } for DHCP profiles
  #   sequentialJoin: (optional) start k3s on joining nodes one-at-a-time (Plan 032)
  #   shutdownDhcpAfterLeases: (optional) shut down DHCP server after lease verification (Plan 032)
  mkDefaultClusterTestScript = { profile, nodes, nodeNames, dhcpReservations ? null, sequentialJoin ? false, shutdownDhcpAfterLeases ? false }:
    let
      utils = import ./utils.nix;
      dhcpPhase = import ./phases/dhcp.nix { inherit lib; };
      bootPhase = import ./phases/boot.nix { inherit lib; };
      networkPhase = import ./phases/network.nix { inherit lib; };
      k3sPhase = import ./phases/k3s.nix { inherit lib; };

      # Detect DHCP profile (profile name starts with "dhcp-")
      isDhcpProfile = lib.hasPrefix "dhcp-" profile;

      # Build nodePairs for network verification
      nodePairs = [
        { node = nodes.primary; name = nodeNames.primary; clusterIpSuffix = 1; storageIpSuffix = 1; }
        { node = nodes.secondary; name = nodeNames.secondary; clusterIpSuffix = 2; storageIpSuffix = 2; }
        { node = nodes.agent; name = nodeNames.agent; clusterIpSuffix = 3; storageIpSuffix = 3; }
      ];

      # Build validation list for summary
      validations =
        if profile == "simple" || profile == "dhcp-simple" then [
          "All 3 nodes Ready"
          "System components running"
        ] ++ lib.optionals isDhcpProfile [ "DHCP leases verified" ]
        else [
          "VLAN tags (200, 100) verified"
          "Storage network (192.168.100.x) connectivity OK"
          "Cross-VLAN isolation (best-effort) verified"
          "All 3 nodes Ready"
          "System components running"
        ];

      # DHCP boot sequence: start dhcp-server first, then cluster nodes
      dhcpBootSequence = lib.optionalString isDhcpProfile ''
        # PHASE 0: Start DHCP Server (must be before cluster nodes)
        ${dhcpPhase.startDhcpServer { node = nodes.dhcpServer or "dhcp_server"; }}

      '';

      # Standard boot sequence for non-DHCP or after DHCP server is ready
      standardBootSequence = ''
        # PHASE 1: Boot All Nodes
        ${bootPhase.bootAllNodes { nodes = [ nodes.primary nodes.secondary nodes.agent ]; }}
      '';

      # DHCP lease verification (only for DHCP profiles)
      dhcpLeaseVerification = lib.optionalString (isDhcpProfile && dhcpReservations != null) ''
        # PHASE 1.5: Verify DHCP Leases
        ${dhcpPhase.verifyAllDhcpLeases {
          nodePairs = [
            { node = nodes.primary; expectedIp = dhcpReservations.${nodeNames.primary}.ip or "192.168.1.1"; interface = "eth1"; }
            { node = nodes.secondary; expectedIp = dhcpReservations.${nodeNames.secondary}.ip or "192.168.1.2"; interface = "eth1"; }
            { node = nodes.agent; expectedIp = dhcpReservations.${nodeNames.agent}.ip or "192.168.1.3"; interface = "eth1"; }
          ];
        }}

        ${lib.optionalString shutdownDhcpAfterLeases (dhcpPhase.shutdownDhcpServer {
          node = nodes.dhcpServer or "dhcp_server";
        })}
      '';

    in
    ''
      ${utils.all}

      log_banner("K3s Cluster Test", "${profile}", {
          "Architecture": "2 servers + 1 agent${lib.optionalString isDhcpProfile " + DHCP server"}",
          "${nodeNames.primary}": "k3s server (cluster init)",
          "${nodeNames.secondary}": "k3s server (joins)",
          "${nodeNames.agent}": "k3s agent (worker)"
      })

      ${dhcpBootSequence}${standardBootSequence}
      ${dhcpLeaseVerification}
      # PHASE 2: Network Verification
      ${networkPhase.verifyAll { inherit profile nodePairs; }}

      # PHASES 3-8: K3s Cluster Formation
      ${k3sPhase.verifyCluster {
        inherit profile sequentialJoin;
        primary = nodes.primary;
        secondary = nodes.secondary;
        agent = nodes.agent;
        primaryNodeName = nodeNames.primary;
        secondaryNodeName = nodeNames.secondary;
        agentNodeName = nodeNames.agent;
      }}

      # Summary
      log_summary("K3s Cluster Test", "${profile}", ${builtins.toJSON validations})
    '';
}
