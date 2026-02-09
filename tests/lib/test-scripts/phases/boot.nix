# =============================================================================
# Boot Phase - Node startup and multi-user.target verification
# =============================================================================
#
# PHASE ORDERING (Plan 019 A6):
#   Boot → Network → K3s
#   This phase MUST be first. All other phases depend on shell access.
#
# PRECONDITIONS:
#   - QEMU VM image exists and is valid
#   - Test driver infrastructure is initialized
#   - VDE switches created (for multi-node tests)
#
# POSTCONDITIONS:
#   - Shell access available via test driver backdoor
#   - systemd is running (at least rescue.target reached)
#   - Node is ready to accept commands via succeed()/execute()
#
# ORDERING RATIONALE:
#   Boot must complete before any other phase because:
#   1. Network phase needs shell access to verify/configure interfaces
#   2. K3s phase needs shell access to configure and start services
#   3. No useful work can happen without the VM being accessible
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
#     # Debian:
#     ${bootPhase.debian.bootWithBackdoor { node = "server"; displayName = "Debian server"; }}
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
  #
  # IMPORTANT: ISAR images have GRUB configured to output to serial/virtconsole.
  # This causes ANSI escape sequences to leak into the shell buffer, corrupting
  # the base64-encoded backdoor protocol. We use serial_stdout_off() during boot
  # to prevent this, then re-enable after the backdoor connects.

  debian = {
    # Boot a single ISAR node via backdoor service
    # Parameters:
    #   node: node variable name
    #   displayName: human-readable name for logging (default: node name)
    #
    # IMPORTANT: ISAR images have GRUB configured to output to virtconsole (same channel
    # as the backdoor protocol). This causes ANSI escape sequences to corrupt the shell
    # buffer. The test driver's connect() method reads until "Spawning backdoor root shell..."
    # but may not fully drain GRUB garbage. We use succeed() for the first command because
    # it tolerates buffer issues better than execute() - succeed() only needs to see exit
    # code 0, while execute() needs valid base64 output.
    bootWithBackdoor = { node, displayName ? node }: ''
      log_section("PHASE 1", "Booting ${displayName}")

      # Disable serial capture during boot to reduce log noise from GRUB
      serial_stdout_off()

      start_all()

      # Wait for backdoor shell - it starts before multi-user.target
      ${node}.wait_for_unit("nixos-test-backdoor.service")

      # Re-enable serial output now that backdoor is connected
      serial_stdout_on()

      tlog("  ${displayName} backdoor ready")

      # CRITICAL: Wait for GRUB output to fully drain from virtconsole buffer
      # GRUB may still be sending ANSI sequences when backdoor connects.
      # Use wait_until_succeeds to retry until the shell protocol is clean,
      # rather than a fixed delay that may be too short under load.
      ${node}.wait_until_succeeds("true", timeout=10)

      # Basic system check - confirms shell is now working cleanly
      ${node}.succeed("uname -a")
      os_release = ${node}.succeed("cat /etc/os-release")
      tlog(f"  OS: {os_release.splitlines()[0]}")
    '';

    # Boot multiple ISAR nodes via backdoor
    # Parameters:
    #   nodes: list of { node, displayName } attrsets
    bootAllWithBackdoor = { nodes }: ''
      log_section("PHASE 1", "Booting all ISAR nodes")

      # Disable serial capture during boot to prevent GRUB ANSI sequences
      # from corrupting the shell protocol buffer
      serial_stdout_off()

      start_all()

      ${lib.concatMapStringsSep "\n" (n: ''
      ${n.node}.wait_for_unit("nixos-test-backdoor.service")
      tlog("  ${n.displayName} backdoor ready")'') nodes}

      # Re-enable serial output now that all backdoors are connected
      serial_stdout_on()

      # Wait for GRUB output to fully drain from each node's virtconsole buffer
      # Use wait_until_succeeds to retry until shell protocol is clean
      ${lib.concatMapStringsSep "\n" (n: ''
      ${n.node}.wait_until_succeeds("true", timeout=10)'') nodes}
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
