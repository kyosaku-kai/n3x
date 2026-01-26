# Boot phase - Node startup and multi-user.target verification
#
# This phase handles starting VMs and waiting for them to reach
# a usable state (multi-user.target).
#
# Includes both NixOS and ISAR variants:
# - NixOS: wait_for_unit("multi-user.target")
# - ISAR: wait_for_unit("nixos-test-backdoor.service") first, since ISAR
#         images may not reach multi-user.target cleanly in test environments
#
# Usage in Nix:
#   let
#     bootPhase = import ./test-scripts/phases/boot.nix;
#   in ''
#     # NixOS:
#     ${bootPhase.bootAllNodes { nodes = ["server_1" "server_2" "agent_1"]; }}
#     # ISAR:
#     ${bootPhase.isar.bootWithBackdoor { node = "server"; displayName = "ISAR server"; }}
#   ''

{ lib ? (import <nixpkgs> { }).lib }:

{
  # Boot all nodes and wait for multi-user.target
  # Parameters:
  #   nodes: list of node variable names (e.g., ["server_1", "server_2"])
  #
  # Returns Python code string
  bootAllNodes = { nodes }: ''
    log_section("PHASE 1", "Booting all nodes")
    start_all()

    ${lib.concatMapStringsSep "\n" (node: ''
    ${node}.wait_for_unit("multi-user.target")
    tlog("  ${node} booted")'') nodes}
  '';

  # Boot a single node
  # Parameters:
  #   node: node variable name
  #   displayName: human-readable name for logging
  bootSingleNode = { node, displayName ? node }: ''
    ${node}.wait_for_unit("multi-user.target")
    tlog("  ${displayName} booted")
  '';

  # Generic start_all() with logging
  startAll = ''
    log_section("PHASE 1", "Booting all nodes")
    start_all()
  '';

  # =============================================================================
  # ISAR-specific boot helpers
  # =============================================================================
  #
  # ISAR images use nixos-test-backdoor.service which starts before
  # multi-user.target. Since ISAR test VMs may have systemd boot issues
  # (emergency mode, stuck jobs), we wait for the backdoor instead.

  isar = {
    # Boot a single ISAR node via backdoor service
    # Parameters:
    #   node: node variable name
    #   displayName: human-readable name for logging (default: node name)
    bootWithBackdoor = { node, displayName ? node }: ''
      log_section("PHASE 1", "Booting ${displayName}")
      start_all()

      # Wait for backdoor shell - it starts before multi-user.target
      ${node}.wait_for_unit("nixos-test-backdoor.service")
      tlog("  ${displayName} backdoor ready")

      # Basic system check
      ${node}.succeed("uname -a")
      os_release = ${node}.succeed("cat /etc/os-release")
      tlog(f"  OS: {os_release.splitlines()[0]}")
    '';

    # Boot multiple ISAR nodes via backdoor
    # Parameters:
    #   nodes: list of { node, displayName } attrsets
    bootAllWithBackdoor = { nodes }: ''
      log_section("PHASE 1", "Booting all ISAR nodes")
      start_all()

      ${lib.concatMapStringsSep "\n" (n: ''
      ${n.node}.wait_for_unit("nixos-test-backdoor.service")
      tlog("  ${n.displayName} backdoor ready")'') nodes}
    '';

    # Check ISAR system status (diagnostic helper)
    # Parameters:
    #   node: node variable name
    checkSystemStatus = { node }: ''
      # Check system health
      tlog("")
      tlog("--- System Status ---")
      system_status = ${node}.execute("systemctl is-system-running 2>&1")[1]
      tlog(f"  System status: {system_status.strip()}")

      # Check failed units
      failed = ${node}.execute("systemctl --failed --no-pager 2>&1")[1]
      if "0 loaded" not in failed:
          tlog("--- Failed Units ---")
          tlog(failed)
    '';
  };
}
