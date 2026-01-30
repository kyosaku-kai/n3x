# =============================================================================
# ISAR K3s Cluster Test (L4 - Multi-Node)
# =============================================================================
#
# Tests k3s cluster formation with 2 ISAR server nodes (HA control plane).
# Uses the shared network profiles and test infrastructure.
#
# WHAT THIS TESTS:
#   - Multi-VM boot with ISAR images
#   - Runtime network configuration (or build-time if images have it)
#   - K3s primary server initialization (--cluster-init)
#   - K3s secondary server joining (--server)
#   - HA control plane formation
#   - System components (CoreDNS, local-path-provisioner)
#
# ARCHITECTURE:
#   Uses mk-isar-cluster-test.nix builder which:
#   - Loads shared network profiles (lib/network/profiles/)
#   - Generates K3s flags using shared generator (lib/k3s/mk-k3s-flags.nix)
#   - Uses shared test script phases (tests/lib/test-scripts/)
#
# PREREQUISITES:
#   - ISAR server images must be built and registered in isar-artifacts.nix
#   - For 'simple' profile: qemuamd64.server.simple.wic (or legacy .wic)
#
# USAGE:
#   nix build '.#checks.x86_64-linux.isar-k3s-cluster-simple'
#
# NETWORK CONFIGURATION:
#   Since current images are built with NETWORKD_NODE_NAME="server-1",
#   runtime IP configuration is used to assign different IPs to each node.
#   See docs/ISAR-L4-TEST-ARCHITECTURE.md for details.
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, networkProfile ? "simple"
}:

let
  # Import the ISAR cluster test builder
  mkISARClusterTest = pkgs.callPackage ../lib/isar/mk-isar-cluster-test.nix { inherit pkgs lib; };

in
# Use the builder with simple profile (default)
  # This creates a 2-server HA cluster test
mkISARClusterTest {
  inherit networkProfile;
  # Uses default machines (2 servers)
  # Uses default test script (full L4 cluster formation)
}
