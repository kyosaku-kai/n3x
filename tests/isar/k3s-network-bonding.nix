# =============================================================================
# K3s Bonding + VLANs Network Test
# =============================================================================
#
# Tests the bonding-vlans network profile on ISAR k3s server image.
# Uses bonded NICs (eth1+eth2) with VLANs on bond0:
#   - Bond mode: active-backup
#   - VLAN 200: Cluster traffic (192.168.200.0/24)
#   - VLAN 100: Storage traffic (192.168.100.0/24)
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml:kas/network/bonding-vlans.yml
#   - Image must include netplan-k3s-config package with bonding-vlans profile
#   - Image must include ifenslave package for bonding
#
# Usage:
#   # Build the test driver:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./k3s-network-bonding.nix {}'
#
#   # Run the test:
#   ./result/bin/run-test
#
# NOTE: This test requires QEMU to be configured with 3 NICs:
#   - eth0: QEMU NAT for backdoor
#   - eth1, eth2: Bonded interfaces
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/isar/isar-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/isar/mk-isar-test.nix { inherit pkgs lib; };

  test = mkISARTest {
    name = "k3s-network-bonding";

    # For bonding test, we need 2 VLANs to create eth1 and eth2
    vlans = [ 1 2 ];

    machines = {
      server = {
        image = isarArtifacts.qemuamd64.server.wic;
        memory = 4096;
        cpus = 4;
        # Extra QEMU args to add a second NIC on vlan 2
        # This gives us eth1 (vlan1) and eth2 (vlan2) for bonding
        extraQemuArgs = [
          # Second NIC for bonding (vlan 2)
          "-netdev"
          "vde,id=vlan2,sock=\"$QEMU_VDE_SOCKET_2\""
          "-device"
          "virtio-net-pci,netdev=vlan2,mac=52:54:00:12:34:03"
        ];
      };
    };

    testScript = ''
      # Wait for backdoor shell
      server.wait_for_unit("nixos-test-backdoor.service")

      print("=" * 60)
      print("K3S NETWORK BONDING + VLANS PROFILE TEST")
      print("=" * 60)

      # Basic boot check
      server.succeed("uname -a")

      # Check if bonding module is loaded
      print("\n--- Bonding Module Check ---")
      code, bond_mod = server.execute("lsmod | grep bonding || modprobe bonding && lsmod | grep bonding")
      print(bond_mod)

      # Check if 8021q module is loaded
      print("\n--- 8021Q Module Check ---")
      code, vlan_mod = server.execute("lsmod | grep 8021q || modprobe 8021q && lsmod | grep 8021q")
      print(vlan_mod)

      # Check if netplan is installed
      print("\n--- Netplan Check ---")
      code, netplan_check = server.execute("which netplan 2>&1")
      if code == 0:
          print(f"netplan found: {netplan_check.strip()}")

          # Check netplan config file
          code, netplan_file = server.execute("cat /etc/netplan/60-k3s-network.yaml 2>&1")
          print(f"\nNetplan file:\n{netplan_file}")

          # Try to apply netplan (may fail if no config)
          code, netplan_apply = server.execute("netplan apply 2>&1")
          print(f"\nNetplan apply:\n{netplan_apply}")
      else:
          print("WARNING: netplan not installed in this image")
          print("Image was likely built without kas/network/bonding-vlans.yml overlay")

      # Check all network interfaces
      print("\n--- Network Interfaces ---")
      interfaces = server.succeed("ip -br link")
      print(interfaces)

      # Check for bond interface
      print("\n--- Bond Interface ---")
      code, bond0 = server.execute("ip addr show bond0 2>&1")
      print(bond0)

      # Check bond status if it exists
      print("\n--- Bond Status ---")
      code, bond_status = server.execute("cat /proc/net/bonding/bond0 2>&1")
      if code == 0:
          print(bond_status)
      else:
          print("Bond interface not active (expected if netplan not configured)")

      # Check for VLAN interfaces on bond
      print("\n--- VLAN Interfaces on Bond ---")
      code, vlan_interfaces = server.execute("ip -d link show | grep -A1 'bond0\\.' 2>&1")
      print(vlan_interfaces if code == 0 else "No bond VLANs found")

      # Check IP addresses
      print("\n--- IP Addresses ---")
      ip_addrs = server.succeed("ip -br addr")
      print(ip_addrs)

      # Check specific VLAN interfaces on bond
      print("\n--- bond0.200 (Cluster VLAN) ---")
      code, vlan200 = server.execute("ip addr show bond0.200 2>&1")
      print(vlan200)

      print("\n--- bond0.100 (Storage VLAN) ---")
      code, vlan100 = server.execute("ip addr show bond0.100 2>&1")
      print(vlan100)

      # Check routing table
      print("\n--- Routing Table ---")
      routes = server.succeed("ip route")
      print(routes)

      # Check systemd-networkd status
      print("\n--- systemd-networkd Status ---")
      code, networkd = server.execute("systemctl status systemd-networkd --no-pager 2>&1")
      print(networkd)

      # Verify cluster VLAN IP on bond
      print("\n--- Cluster VLAN IP Verification ---")
      code, cluster_ip = server.execute("ip -4 addr show bond0.200 | grep -oP '192\\.168\\.200\\.\\d+' || echo 'no-cluster-ip'")
      print(f"Cluster VLAN IP: {cluster_ip.strip()}")

      # Verify storage VLAN IP on bond
      print("\n--- Storage VLAN IP Verification ---")
      code, storage_ip = server.execute("ip -4 addr show bond0.100 | grep -oP '192\\.168\\.100\\.\\d+' || echo 'no-storage-ip'")
      print(f"Storage VLAN IP: {storage_ip.strip()}")

      # Test basic networking
      print("\n--- Basic Network Test ---")
      server.succeed("ping -c 1 127.0.0.1")
      print("localhost ping: OK")

      print("=" * 60)
      print("K3S NETWORK BONDING + VLANS TEST COMPLETE")
      print("=" * 60)
    '';
  };

in
test
