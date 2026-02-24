# =============================================================================
# DHCP Phase - DHCP server startup and lease verification
# =============================================================================
#
# PHASE ORDERING (Plan 019 C1):
#   DHCP → Boot (cluster nodes) → Network → K3s
#   DHCP server MUST start before cluster nodes for IP assignment.
#
# PRECONDITIONS:
#   - VDE switch created for the VLAN (virtualisation.vlans)
#   - dhcp-server node defined with dnsmasq configured
#
# POSTCONDITIONS:
#   - dnsmasq.service is active and listening
#   - DHCP server ready to respond to DISCOVER requests
#
# ORDERING RATIONALE:
#   DHCP server must be running before cluster nodes boot because:
#   1. Cluster nodes need IP addresses from DHCP before network phase
#   2. K3s configuration depends on nodes having their expected IPs
#   3. No point booting cluster nodes if DHCP won't be available
#
# ARCHITECTURE NOTE:
#   The dhcp-server is a dedicated VM (not one of the cluster nodes) because
#   NixOS test driver VDE switches are NOT accessible from the host.
#   See docs/DHCP-TEST-INFRASTRUCTURE.md for full rationale.
#
# Usage in Nix:
#   let
#     dhcpPhase = import ./test-scripts/phases/dhcp.nix { inherit lib; };
#   in ''
#     ${dhcpPhase.startDhcpServer { node = "dhcp_server"; }}
#     ${dhcpPhase.verifyDhcpLease { node = "server_1"; expectedIp = "192.168.1.1"; }}
#   ''

{ lib ? (import <nixpkgs> { }).lib }:

{
  # Start the DHCP server VM and wait for dnsmasq to be ready
  # Parameters:
  #   node: dhcp server node variable name (e.g., "dhcp_server")
  #   displayName: human-readable name for logging (default: "DHCP server")
  #
  # Returns Python code string
  startDhcpServer = { node, displayName ? "DHCP server" }: ''
    log_section("PHASE 0", "Starting ${displayName}")

    ${node}.start()
    ${node}.wait_for_unit("multi-user.target")
    ${node}.wait_for_unit("dnsmasq.service")

    # Verify dnsmasq is actually running and listening
    ${node}.succeed("systemctl is-active dnsmasq")
    ${node}.succeed("ss -ulnp | grep -q ':67 '")  # DHCP listens on UDP 67

    tlog("  ${displayName} ready (dnsmasq listening on port 67)")
  '';

  # Verify a node received its expected IP via DHCP
  # Parameters:
  #   node: cluster node variable name
  #   expectedIp: expected IP address from DHCP reservation
  #   interface: network interface to check (default: "eth1")
  #   timeout: max seconds to wait for IP (default: 60)
  #
  # Returns Python code string
  verifyDhcpLease = { node, expectedIp, interface ? "eth1", timeout ? 60 }: ''
    tlog("  Verifying DHCP lease on ${node}: expecting ${expectedIp} on ${interface}")

    # Wait for IP assignment
    ${node}.wait_until_succeeds(
        "ip -4 addr show ${interface} | grep -q '${expectedIp}'",
        timeout=${toString timeout}
    )

    # Verify IP is marked as dynamic (DHCP-assigned, not static)
    result = ${node}.succeed("ip -4 addr show ${interface}")
    if "dynamic" not in result.lower():
        tlog("    WARNING: IP ${expectedIp} not marked as dynamic (may be static fallback)")
    else:
        tlog("    ${expectedIp} confirmed as DHCP-assigned (dynamic)")
  '';

  # Verify all nodes in a list received their expected IPs
  # Parameters:
  #   nodePairs: list of { node, expectedIp, interface? } attrsets
  #   timeout: max seconds per node (default: 60)
  #
  # Returns Python code string
  verifyAllDhcpLeases = { nodePairs, timeout ? 60 }: ''
    log_section("DHCP VERIFICATION", "Verifying DHCP leases and routes on all nodes")

    ${lib.concatMapStringsSep "\n" (np: ''
    # Verify ${np.node}
    tlog("  Verifying DHCP lease on ${np.node}: expecting ${np.expectedIp}")
    ${np.node}.wait_until_succeeds(
        "ip -4 addr show ${np.interface or "eth1"} | grep -q '${np.expectedIp}'",
        timeout=${toString timeout}
    )
    tlog("    ${np.expectedIp} assigned successfully")

    # Verify subnet route exists (critical for inter-node communication)
    ${np.node}.wait_until_succeeds(
        "ip route show | grep -q '192.168.1.0/24'",
        timeout=30
    )
    tlog("    Subnet route (192.168.1.0/24) present")'') nodePairs}

    tlog("  All DHCP leases and routes verified")
  '';

  # Shutdown the DHCP server VM to free I/O resources (Plan 032)
  # Parameters:
  #   node: dhcp server node variable name
  #   displayName: human-readable name for logging (default: "DHCP server")
  #
  # RATIONALE: After DHCP leases are verified, the DHCP server is no longer
  # needed (lease time is 12h, test completes in <30 min). Shutting it down
  # frees 512MB RAM and removes one QEMU VM from I/O contention, reducing
  # etcd WAL write starvation on resource-constrained CI runners.
  #
  # Returns Python code string
  shutdownDhcpServer = { node, displayName ? "DHCP server" }: ''
    tlog("  Shutting down ${displayName} to free I/O resources (leases valid for 12h)")
    ${node}.shutdown()
    tlog("  ${displayName} shut down — reduced VM count from 4 to 3")
  '';

  # Collect DHCP diagnostics on failure
  # Parameters:
  #   dhcpNode: dhcp server node variable name
  #   clusterNodes: list of cluster node variable names
  #
  # Returns Python code string (for use in except blocks)
  collectDhcpDiagnostics = { dhcpNode, clusterNodes }: ''
    tlog("=== DHCP DIAGNOSTICS ===")

    # DHCP server logs
    tlog("--- dnsmasq journal (${dhcpNode}) ---")
    ${dhcpNode}.execute("journalctl -u dnsmasq --no-pager | tail -30")

    # DHCP leases file
    tlog("--- DHCP leases ---")
    ${dhcpNode}.execute("cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || cat /var/lib/misc/dnsmasq.leases 2>/dev/null || echo 'No lease file found'")

    # Cluster node network state
    ${lib.concatMapStringsSep "\n" (node: ''
    tlog("--- ${node} network state ---")
    ${node}.execute("ip addr show")
    ${node}.execute("journalctl -u systemd-networkd --no-pager | tail -20")'') clusterNodes}

    tlog("=== END DHCP DIAGNOSTICS ===")
  '';

  # Complete DHCP boot sequence: start DHCP server, then cluster nodes in parallel
  # Parameters:
  #   dhcpNode: dhcp server node variable name
  #   clusterNodes: list of cluster node variable names
  #   reservations: attrset of { nodeName = { expectedIp, interface? }; }
  #
  # Returns Python code string
  bootWithDhcp = { dhcpNode, clusterNodes, reservations }: ''
    # Phase 0: Start DHCP server first
    log_section("PHASE 0", "Starting DHCP infrastructure")
    ${dhcpNode}.start()
    ${dhcpNode}.wait_for_unit("multi-user.target")
    ${dhcpNode}.wait_for_unit("dnsmasq.service")
    ${dhcpNode}.succeed("systemctl is-active dnsmasq")
    tlog("  DHCP server ready")

    # Phase 1: Start cluster nodes (parallel)
    log_section("PHASE 1", "Booting cluster nodes")
    ${lib.concatMapStringsSep "\n" (node: "${node}.start()") clusterNodes}

    # Wait for nodes to reach multi-user.target
    ${lib.concatMapStringsSep "\n" (node: ''
    ${node}.wait_for_unit("multi-user.target")
    tlog("  ${node} booted")'') clusterNodes}

    # Phase 1.5: Verify DHCP leases
    log_section("PHASE 1.5", "Verifying DHCP leases")
    ${lib.concatMapStringsSep "\n" (node:
      let
        res = reservations.${node} or { expectedIp = "UNKNOWN"; interface = "eth1"; };
      in ''
    ${node}.wait_until_succeeds(
        "ip -4 addr show ${res.interface or "eth1"} | grep -q '${res.expectedIp}'",
        timeout=60
    )
    tlog("  ${node}: ${res.expectedIp} assigned via DHCP")'') clusterNodes}

    tlog("  All DHCP leases verified")
  '';
}
