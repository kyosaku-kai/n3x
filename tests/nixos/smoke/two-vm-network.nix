# Layer 2: Two VM Network Smoke Test
#
# Can two VMs see each other over the test network?
# Expected duration: 30-60 seconds
#
# This test verifies:
# - Two VMs can boot in parallel
# - VDE network switch works
# - VMs get IP addresses
# - VMs can ping each other
#
# If this test fails, multi-VM K3s tests will fail.
#
# Usage:
#   nix build .#checks.x86_64-linux.smoke-two-vm-network
#   nix build .#checks.x86_64-linux.smoke-two-vm-network.driverInteractive

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "smoke-two-vm-network";

  nodes = {
    vm1 = { ... }: {
      virtualisation = {
        memorySize = 512;
        cores = 1;
      };
      # Static IP to avoid DHCP delays
      networking.interfaces.eth1.ipv4.addresses = [{
        address = "192.168.1.1";
        prefixLength = 24;
      }];
    };

    vm2 = { ... }: {
      virtualisation = {
        memorySize = 512;
        cores = 1;
      };
      networking.interfaces.eth1.ipv4.addresses = [{
        address = "192.168.1.2";
        prefixLength = 24;
      }];
    };
  };

  testScript = ''
    import time
    start = time.time()

    print("=" * 60)
    print("SMOKE TEST: Two VM Network")
    print("=" * 60)

    # Start both VMs in parallel
    print("\n[1/5] Starting both VMs...")
    vm1.start()
    vm2.start()

    # Wait for boot
    print("[2/5] Waiting for VMs to boot...")
    vm1.wait_for_unit("multi-user.target", timeout=30)
    vm2.wait_for_unit("multi-user.target", timeout=30)
    print("  Both VMs booted")

    # Check IPs are configured
    print("[3/5] Verifying IP configuration...")
    vm1.succeed("ip addr show eth1 | grep 192.168.1.1")
    vm2.succeed("ip addr show eth1 | grep 192.168.1.2")
    print("  IPs configured correctly")

    # Give VDE switch a moment to learn MAC addresses
    print("[4/5] Waiting for network to settle...")
    time.sleep(2)

    # Test connectivity
    print("[5/5] Testing connectivity...")
    vm1.succeed("ping -c 1 -W 5 192.168.1.2")
    print("  vm1 -> vm2: OK")
    vm2.succeed("ping -c 1 -W 5 192.168.1.1")
    print("  vm2 -> vm1: OK")

    elapsed = time.time() - start
    print(f"\n{'=' * 60}")
    print(f"SMOKE TEST PASSED in {elapsed:.1f}s")
    print(f"{'=' * 60}")
  '';
}
