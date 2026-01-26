# Test Scripts - Shared Python test snippets
#
# This module provides reusable Python code snippets for nixos-test-driver
# test scripts. Both NixOS and ISAR backends can import these snippets
# to share test logic without duplication.
#
# Structure:
#   utils     - Core utilities (tlog, logging helpers)
#   phases/   - Test phases (boot, network, k3s)
#
# Usage:
#   let
#     testScripts = import ./test-scripts { inherit lib; };
#   in ''
#     ${testScripts.utils.all}
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
    boot = import ./phases/boot.nix { inherit lib; };
    network = import ./phases/network.nix { inherit lib; };
    k3s = import ./phases/k3s.nix { inherit lib; };
  };

  # Convenience: Generate complete default test script for k3s cluster
  # This is equivalent to the current embedded script in mk-k3s-cluster-test.nix
  #
  # Parameters:
  #   profile: network profile name ("simple", "vlans", "bonding-vlans")
  #   nodes: { primary, secondary, agent } - node variable names
  #   nodeNames: { primary, secondary, agent } - kubernetes node names
  mkDefaultClusterTestScript = { profile, nodes, nodeNames }:
    let
      utils = import ./utils.nix;
      bootPhase = import ./phases/boot.nix { inherit lib; };
      networkPhase = import ./phases/network.nix { inherit lib; };
      k3sPhase = import ./phases/k3s.nix { inherit lib; };

      # Build nodePairs for network verification
      nodePairs = [
        { node = nodes.primary; name = nodeNames.primary; clusterIpSuffix = 1; storageIpSuffix = 1; }
        { node = nodes.secondary; name = nodeNames.secondary; clusterIpSuffix = 2; storageIpSuffix = 2; }
        { node = nodes.agent; name = nodeNames.agent; clusterIpSuffix = 3; storageIpSuffix = 3; }
      ];

      # Build validation list for summary
      validations =
        if profile == "simple" then [
          "All 3 nodes Ready"
          "System components running"
        ]
        else [
          "VLAN tags (200, 100) verified"
          "Storage network (192.168.100.x) connectivity OK"
          "Cross-VLAN isolation (best-effort) verified"
          "All 3 nodes Ready"
          "System components running"
        ];
    in
    ''
      ${utils.all}

      log_banner("K3s Cluster Test", "${profile}", {
          "Architecture": "2 servers + 1 agent",
          "${nodeNames.primary}": "k3s server (cluster init)",
          "${nodeNames.secondary}": "k3s server (joins)",
          "${nodeNames.agent}": "k3s agent (worker)"
      })

      # PHASE 1: Boot All Nodes
      ${bootPhase.bootAllNodes { nodes = [ nodes.primary nodes.secondary nodes.agent ]; }}

      # PHASE 2: Network Verification
      ${networkPhase.verifyAll { inherit profile nodePairs; }}

      # PHASES 3-8: K3s Cluster Formation
      ${k3sPhase.verifyCluster {
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
