# =============================================================================
# Network Phase - Profile-aware network verification
# =============================================================================
#
# PHASE ORDERING (Plan 019 A6):
#   Boot → Network → K3s
#   This phase MUST complete before K3s phase.
#
# PRECONDITIONS:
#   - Boot phase complete (shell access available)
#   - systemd-networkd.service running (for baked-in config)
#   - For bonding-vlans: bond0 reconfigured to active-backup mode
#   - Kernel modules loaded: 8021q (VLANs), bonding (if applicable)
#
# POSTCONDITIONS:
#   - All expected interfaces exist (eth1, eth1.200, bond0.200, etc.)
#   - Correct IPs assigned to cluster/storage interfaces
#   - Cross-node connectivity verified (arping/ping works)
#   - Routing tables configured per interface
#
# ORDERING RATIONALE:
#   Network must complete before K3s because:
#   1. K3s binds API server to --node-ip (cluster interface IP)
#   2. K3s etcd members communicate via cluster network
#   3. Nodes discover each other via IP addresses
#   4. K3s will fail to start if cluster IP is not routable
#
# This phase verifies network configuration based on the selected profile.
# Supports: simple, vlans, bonding-vlans
#
# Usage in Nix:
#   let
#     networkPhase = import ./test-scripts/phases/network.nix { inherit lib; };
#   in ''
#     ${networkPhase.verifyInterfaces { profile = "vlans"; nodes = [...]; }}
#   ''

{ lib ? (import <nixpkgs> { }).lib }:

let
  # Helper to determine VLAN interface prefix based on profile
  vlanIfaceForProfile = profile:
    if profile == "vlans" then "eth1"
    else if profile == "bonding-vlans" then "bond0"
    else "eth1"; # fallback
in
rec {
  # Verify network interfaces exist and have correct IPs
  # Parameters:
  #   profile: "simple" | "vlans" | "bonding-vlans"
  #   nodePairs: list of { node = "server_1"; name = "server-1"; }
  #   timeout: optional seconds to wait for interfaces (default: null = no wait)
  verifyInterfaces = { profile, nodePairs, timeout ? null }: ''
    log_section("PHASE 2", "Verifying network configuration")

    ${if timeout != null then ''
    # Wait for interfaces to be ready before verification
    tlog("  Waiting up to ${toString timeout}s for interfaces to be ready...")
    for node, name in [${lib.concatMapStringsSep ", " (np: "(${np.node}, \"${np.name}\")") nodePairs}]:
        ${if profile == "simple" || profile == "dhcp-simple" then ''
        # Simple/DHCP-simple profile: wait for eth1 with 192.168.1.x
        node.wait_until_succeeds("ip -4 addr show eth1 | grep -q '192.168.1.'", timeout=${toString timeout})
        tlog(f"  {name}: eth1 with IP ready")
        '' else if profile == "vlans" then ''
        # VLANs profile: wait for both cluster and storage VLANs
        # systemd-networkd creates VLAN interfaces asynchronously — eth1.100 may
        # lag behind eth1.200, especially with fast boot (direct kernel boot).
        node.wait_until_succeeds("ip -4 addr show eth1.200 | grep -q '192.168.200.'", timeout=${toString timeout})
        tlog(f"  {name}: eth1.200 with IP ready")
        node.wait_until_succeeds("ip -4 addr show eth1.100 | grep -q '192.168.100.'", timeout=${toString timeout})
        tlog(f"  {name}: eth1.100 with IP ready")
        '' else if profile == "bonding-vlans" then ''
        # Bonding + VLANs: wait for both cluster and storage VLANs
        node.wait_until_succeeds("ip -4 addr show bond0.200 | grep -q '192.168.200.'", timeout=${toString timeout})
        tlog(f"  {name}: bond0.200 with IP ready")
        node.wait_until_succeeds("ip -4 addr show bond0.100 | grep -q '192.168.100.'", timeout=${toString timeout})
        tlog(f"  {name}: bond0.100 with IP ready")
        '' else ''
        # Unknown profile - no wait
        pass
        ''}
    '' else ""}
    for node, name in [${lib.concatMapStringsSep ", " (np: "(${np.node}, \"${np.name}\")") nodePairs}]:
        interfaces = node.succeed("ip -br addr show")
        tlog(f"  {name} interfaces:\n{interfaces}")

        ${if profile == "simple" || profile == "dhcp-simple" then ''
        # Simple/DHCP-simple profile: eth1 with 192.168.1.x IP
        assert "eth1" in interfaces, f"Missing eth1 interface on {name}"
        assert "192.168.1." in interfaces, f"Missing 192.168.1.x IP on {name} (${profile} profile requires eth1 with 192.168.1.x)"
        tlog(f"  {name}: eth1 interface with 192.168.1.x IP - OK")
        '' else if profile == "vlans" then ''
        # VLANs profile: eth1.200 and eth1.100 with their respective IPs
        assert "eth1.200" in interfaces, f"Missing eth1.200 (cluster VLAN) interface on {name}"
        assert "eth1.100" in interfaces, f"Missing eth1.100 (storage VLAN) interface on {name}"
        assert "192.168.200." in interfaces, f"Missing 192.168.200.x cluster VLAN IP on {name}"
        assert "192.168.100." in interfaces, f"Missing 192.168.100.x storage VLAN IP on {name}"
        tlog(f"  {name}: eth1.200 (192.168.200.x) and eth1.100 (192.168.100.x) - OK")
        '' else if profile == "bonding-vlans" then ''
        # Bonding + VLANs profile: bond0, bond0.200, bond0.100 with IPs
        assert "bond0 " in interfaces or "bond0\t" in interfaces, f"Missing bond0 interface on {name}"
        assert "bond0.200" in interfaces, f"Missing bond0.200 (cluster VLAN) interface on {name}"
        assert "bond0.100" in interfaces, f"Missing bond0.100 (storage VLAN) interface on {name}"
        assert "192.168.200." in interfaces, f"Missing 192.168.200.x cluster VLAN IP on {name}"
        assert "192.168.100." in interfaces, f"Missing 192.168.100.x storage VLAN IP on {name}"
        tlog(f"  {name}: bond0, bond0.200 (192.168.200.x), bond0.100 (192.168.100.x) - OK")
        '' else ''
        # Unknown profile - skip interface checks
        tlog(f"  {name}: Unknown profile '${profile}', skipping interface checks")
        ''}

    tlog("  Network configuration verified for ${profile} profile!")
  '';

  # Verify VLAN tags are configured correctly
  # Only applicable for vlans and bonding-vlans profiles
  verifyVlanTags = { profile, nodePairs }:
    if profile == "simple" || profile == "dhcp-simple" then ""
    else
      let
        vlan_iface = vlanIfaceForProfile profile;
      in
      ''
        log_section("PHASE 2.5", "Verifying VLAN tag configuration")

        # VLAN interface prefix for ${profile} profile
        vlan_iface = "${vlan_iface}"

        for node, name in [${lib.concatMapStringsSep ", " (np: "(${np.node}, \"${np.name}\")") nodePairs}]:
            # Verify cluster VLAN (200)
            cluster_vlan = node.succeed(f"ip -d link show {vlan_iface}.200")
            cluster_vlan_lower = cluster_vlan.lower()
            assert ("vlan protocol 802.1q id 200" in cluster_vlan_lower or
                    "vlan id 200" in cluster_vlan_lower), f"VLAN 200 not configured correctly on {name}. Output: {cluster_vlan}"
            tlog(f"  {name}: {vlan_iface}.200 - VLAN ID 200 OK")

            # Verify storage VLAN (100)
            storage_vlan = node.succeed(f"ip -d link show {vlan_iface}.100")
            storage_vlan_lower = storage_vlan.lower()
            assert ("vlan protocol 802.1q id 100" in storage_vlan_lower or
                    "vlan id 100" in storage_vlan_lower), f"VLAN 100 not configured correctly on {name}. Output: {storage_vlan}"
            tlog(f"  {name}: {vlan_iface}.100 - VLAN ID 100 OK")

        tlog("  VLAN tag verification complete!")
      '';

  # Verify storage network connectivity between nodes
  # Only applicable for vlans and bonding-vlans profiles
  verifyStorageNetwork = { profile, nodePairs }:
    if profile == "simple" || profile == "dhcp-simple" then ""
    else ''
      log_section("PHASE 2.6", "Verifying storage network connectivity")

      storage_ips = {
          ${lib.concatMapStringsSep ",\n        " (np: "\"${np.name}\": \"192.168.100.${toString np.storageIpSuffix}\"") nodePairs}
      }

      for node, name in [${lib.concatMapStringsSep ", " (np: "(${np.node}, \"${np.name}\")") nodePairs}]:
          # Verify node has storage IP
          own_ip = storage_ips[name]
          node.succeed(f"ip addr show | grep {own_ip}")
          tlog(f"  {name}: has storage IP {own_ip}")

          # Ping other nodes on storage network
          for target_name, target_ip in storage_ips.items():
              if target_name != name:
                  node.succeed(f"ping -c 1 -W 2 {target_ip}")
                  tlog(f"  {name} -> {target_name} ({target_ip}): OK")

      tlog("  Storage network connectivity verified!")
    '';

  # Cross-VLAN isolation check (best-effort in nixosTest)
  # Only applicable for vlans and bonding-vlans profiles
  verifyCrossVlanIsolation = { profile, nodePairs }:
    if profile == "simple" || profile == "dhcp-simple" then ""
    else
      let
        vlan_iface = vlanIfaceForProfile profile;
      in
      ''
        log_section("PHASE 2.7", "Cross-VLAN isolation check (best-effort)")
        tlog("  NOTE: nixosTest shared network limits true L2 isolation testing.")
        tlog("  These checks verify configuration correctness, not switch enforcement.")

        # VLAN interface prefix for ${profile} profile
        vlan_iface = "${vlan_iface}"

        cluster_ips = {
            ${lib.concatMapStringsSep ",\n        " (np: "\"${np.name}\": \"192.168.200.${toString np.clusterIpSuffix}\"") nodePairs}
        }
        storage_ips = {
            ${lib.concatMapStringsSep ",\n        " (np: "\"${np.name}\": \"192.168.100.${toString np.storageIpSuffix}\"") nodePairs}
        }

        for node, name in [${lib.concatMapStringsSep ", " (np: "(${np.node}, \"${np.name}\")") nodePairs}]:
            # 1. Populate ARP cache
            for target_name, target_ip in cluster_ips.items():
                if target_name != name:
                    node.succeed(f"ping -c 1 -W 2 {target_ip} || true")
            for target_name, target_ip in storage_ips.items():
                if target_name != name:
                    node.succeed(f"ping -c 1 -W 2 {target_ip} || true")

            # Check ARP table
            arp_output = node.succeed("ip neigh show")
            tlog(f"  {name} ARP table:\n{arp_output}")

            # 2. Verify routing table shows separate networks per VLAN
            route_output = node.succeed("ip route show")
            tlog(f"  {name} routes:\n{route_output}")

            # Cluster network should route via cluster VLAN interface
            assert f"192.168.200.0/24 dev {vlan_iface}.200" in route_output, \
                f"Cluster network not routed via {vlan_iface}.200 on {name}"

            # Storage network should route via storage VLAN interface
            assert f"192.168.100.0/24 dev {vlan_iface}.100" in route_output, \
                f"Storage network not routed via {vlan_iface}.100 on {name}"

            tlog(f"  {name}: routing correctly segregated per VLAN")

            # 3. Verify no cross-contamination of IPs
            cluster_iface_output = node.succeed(f"ip addr show dev {vlan_iface}.200")
            storage_iface_output = node.succeed(f"ip addr show dev {vlan_iface}.100")

            # Cluster VLAN interface should NOT have storage IPs
            assert "192.168.100." not in cluster_iface_output, \
                f"Storage IP leaked to cluster VLAN interface on {name}"

            # Storage VLAN interface should NOT have cluster IPs
            assert "192.168.200." not in storage_iface_output, \
                f"Cluster IP leaked to storage VLAN interface on {name}"

            tlog(f"  {name}: no IP cross-contamination between VLANs")

        tlog("  Cross-VLAN isolation checks complete!")
        tlog("  NOTE: For true L2 isolation testing, use OVS emulation or hardware.")
      '';

  # Complete network verification for a profile
  # Combines all network checks appropriate for the profile
  # Parameters:
  #   timeout: optional seconds to wait for interfaces (default: null = no wait)
  verifyAll = { profile, nodePairs, timeout ? null }: ''
    ${verifyInterfaces { inherit profile nodePairs timeout; }}
    ${verifyVlanTags { inherit profile nodePairs; }}
    ${verifyStorageNetwork { inherit profile nodePairs; }}
    ${verifyCrossVlanIsolation { inherit profile nodePairs; }}
  '';
}
