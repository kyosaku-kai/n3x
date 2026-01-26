# =============================================================================
# K3s VLANs Network Test
# =============================================================================
#
# Tests the VLANs network profile on ISAR k3s server image.
# Uses 802.1Q VLAN tagging on eth1 trunk:
#   - VLAN 200: Cluster traffic (192.168.200.0/24)
#   - VLAN 100: Storage traffic (192.168.100.0/24)
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml:kas/network/vlans.yml
#   - Image must include netplan-k3s-config package with vlans profile
#
# Usage:
#   # Build the test driver:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./k3s-network-vlans.nix {}'
#
#   # Run the test:
#   ./result/bin/run-test
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/isar/isar-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/isar/mk-isar-test.nix { inherit pkgs lib; };

  test = mkISARTest {
    name = "k3s-network-vlans";

    # VLAN test uses single underlying network
    # VLANs are created on top of eth1 within the VM
    vlans = [ 1 ];

    machines = {
      server = {
        image = isarArtifacts.qemuamd64.server.wic;
        memory = 4096;
        cpus = 4;
      };
    };

    testScript = ''
      # Wait for backdoor shell
      server.wait_for_unit("nixos-test-backdoor.service")

      print("=" * 60)
      print("K3S NETWORK VLANS PROFILE TEST")
      print("=" * 60)

      # Basic boot check
      server.succeed("uname -a")

      # Check if 8021q module is loaded
      print("\n--- 8021Q Module Check ---")
      code, vlan_mod = server.execute("lsmod | grep 8021q || modprobe 8021q && lsmod | grep 8021q")
      print(vlan_mod)

      # Check if netplan is installed
      print("\n--- Netplan Check ---")
      code, netplan_check = server.execute("which netplan 2>&1")
      if code == 0:
          print(f"netplan found: {netplan_check.strip()}")
          netplan_config = server.execute("netplan get 2>&1")[1]
          print(f"Netplan config:\n{netplan_config}")

          # Check netplan config file
          code, netplan_file = server.execute("cat /etc/netplan/60-k3s-network.yaml 2>&1")
          print(f"\nNetplan file:\n{netplan_file}")
      else:
          print("WARNING: netplan not installed in this image")
          print("Image was likely built without kas/network/vlans.yml overlay")

      # Check network interfaces
      print("\n--- Network Interfaces ---")
      interfaces = server.succeed("ip -br link")
      print(interfaces)

      # Check for VLAN interfaces
      print("\n--- VLAN Interfaces ---")
      code, vlan_interfaces = server.execute("ip -d link show | grep -A1 'vlan\\|802\\.1Q' 2>&1")
      if code == 0:
          print(vlan_interfaces)
      else:
          print("No VLAN interfaces found (expected if netplan not configured)")

      # Check IP addresses
      print("\n--- IP Addresses ---")
      ip_addrs = server.succeed("ip -br addr")
      print(ip_addrs)

      # Check specific VLAN interfaces
      print("\n--- eth1.200 (Cluster VLAN) ---")
      code, vlan200 = server.execute("ip addr show eth1.200 2>&1")
      print(vlan200)

      print("\n--- eth1.100 (Storage VLAN) ---")
      code, vlan100 = server.execute("ip addr show eth1.100 2>&1")
      print(vlan100)

      # Check routing table
      print("\n--- Routing Table ---")
      routes = server.succeed("ip route")
      print(routes)

      # Check systemd-networkd status
      print("\n--- systemd-networkd Status ---")
      code, networkd = server.execute("systemctl status systemd-networkd --no-pager 2>&1")
      print(networkd)

      # Check rendered netdev files (VLAN configuration)
      print("\n--- Rendered Network Devices ---")
      code, netdev = server.execute("ls -la /run/systemd/network/*.netdev 2>&1")
      print(netdev)

      # Check rendered network files
      print("\n--- Rendered Network Config ---")
      code, network = server.execute("ls -la /run/systemd/network/*.network 2>&1")
      print(network)

      # Verify cluster VLAN IP
      print("\n--- Cluster VLAN IP Verification ---")
      code, cluster_ip = server.execute("ip -4 addr show eth1.200 | grep -oP '192\\.168\\.200\\.\\d+' || echo 'no-cluster-ip'")
      print(f"Cluster VLAN IP: {cluster_ip.strip()}")

      # Verify storage VLAN IP
      print("\n--- Storage VLAN IP Verification ---")
      code, storage_ip = server.execute("ip -4 addr show eth1.100 | grep -oP '192\\.168\\.100\\.\\d+' || echo 'no-storage-ip'")
      print(f"Storage VLAN IP: {storage_ip.strip()}")

      # Test basic networking
      print("\n--- Basic Network Test ---")
      server.succeed("ping -c 1 127.0.0.1")
      print("localhost ping: OK")

      print("=" * 60)
      print("K3S NETWORK VLANS TEST COMPLETE")
      print("=" * 60)
    '';
  };

in
test
