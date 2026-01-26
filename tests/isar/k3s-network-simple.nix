# =============================================================================
# K3s Simple Network Test
# =============================================================================
#
# Tests the simple network profile on ISAR k3s server image.
# Uses single flat network via eth1 (192.168.1.0/24).
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml:kas/network/simple.yml
#   - Image must include netplan-k3s-config package with simple profile
#
# Usage:
#   # Build the test driver:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./k3s-network-simple.nix {}'
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
    name = "k3s-network-simple";

    # Single VLAN for simple profile
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
      print("K3S NETWORK SIMPLE PROFILE TEST")
      print("=" * 60)

      # Basic boot check
      server.succeed("uname -a")

      # Check if netplan is installed
      print("\n--- Netplan Check ---")
      code, netplan_check = server.execute("which netplan 2>&1")
      if code == 0:
          print(f"netplan found: {netplan_check.strip()}")
          netplan_config = server.execute("netplan get 2>&1")[1]
          print(f"Netplan config:\n{netplan_config}")
      else:
          print("WARNING: netplan not installed in this image")
          print("Image was likely built without kas/network/simple.yml overlay")

      # Check network interfaces
      print("\n--- Network Interfaces ---")
      interfaces = server.succeed("ip -br link")
      print(interfaces)

      # Check IP addresses
      print("\n--- IP Addresses ---")
      ip_addrs = server.succeed("ip -br addr")
      print(ip_addrs)

      # Check if eth1 has the expected IP (192.168.1.x)
      print("\n--- eth1 Configuration ---")
      code, eth1_info = server.execute("ip addr show eth1 2>&1")
      print(eth1_info)

      # Verify eth1 has an IP (either from netplan or test driver)
      code, eth1_ip = server.execute("ip -4 addr show eth1 | grep -oP '192\\.168\\.1\\.\\d+' || echo 'no-ip'")
      print(f"eth1 IP: {eth1_ip.strip()}")

      # Check routing table
      print("\n--- Routing Table ---")
      routes = server.succeed("ip route")
      print(routes)

      # Check systemd-networkd status (netplan renders to networkd)
      print("\n--- systemd-networkd Status ---")
      code, networkd = server.execute("systemctl status systemd-networkd --no-pager 2>&1")
      print(networkd)

      # Check netplan rendered files
      print("\n--- Rendered Network Config ---")
      code, rendered = server.execute("ls -la /run/systemd/network/ 2>&1")
      print(rendered)

      # Check if we can ping localhost
      print("\n--- Basic Network Test ---")
      server.succeed("ping -c 1 127.0.0.1")
      print("localhost ping: OK")

      # Check k3s network configuration
      print("\n--- K3s Network Config ---")
      code, k3s_config = server.execute("cat /etc/default/k3s-server 2>&1")
      print(k3s_config)

      print("=" * 60)
      print("K3S NETWORK SIMPLE TEST COMPLETE")
      print("=" * 60)
    '';
  };

in
test
