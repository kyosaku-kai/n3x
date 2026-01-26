# Layer 1: VM Boot Smoke Test
#
# The most basic test: Can we boot a NixOS VM and run commands?
# Expected duration: 15-30 seconds
#
# This test verifies:
# - QEMU/KVM infrastructure works
# - NixOS VM boots to multi-user.target
# - Backdoor shell is functional
# - Can execute basic commands
#
# If this test fails, nothing else will work.
#
# Usage:
#   nix build .#checks.x86_64-linux.smoke-vm-boot
#   nix build .#checks.x86_64-linux.smoke-vm-boot.driverInteractive  # for debugging

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "smoke-vm-boot";

  nodes = {
    machine = { ... }: {
      # Minimal VM configuration
      virtualisation = {
        memorySize = 512; # Minimal memory - just need to boot
        cores = 1;
      };
    };
  };

  # Global timeout for entire test: 60 seconds
  # If boot takes longer than this, something is very wrong
  testScript = ''
    import time
    start = time.time()

    print("=" * 60)
    print("SMOKE TEST: VM Boot")
    print("=" * 60)

    # Step 1: Start VM and wait for boot
    print("\n[1/4] Starting VM...")
    machine.start()

    print("[2/4] Waiting for multi-user.target...")
    machine.wait_for_unit("multi-user.target", timeout=30)

    # Step 3: Verify we can run commands
    print("[3/4] Testing command execution...")
    result = machine.succeed("echo 'backdoor works'")
    assert "backdoor works" in result, f"Command execution failed: {result}"

    # Step 4: Basic system info
    print("[4/4] Gathering system info...")
    machine.succeed("uname -a")
    machine.succeed("systemctl is-system-running || true")  # May be 'degraded' but that's ok

    elapsed = time.time() - start
    print(f"\n{'=' * 60}")
    print(f"SMOKE TEST PASSED in {elapsed:.1f}s")
    print(f"{'=' * 60}")
  '';
}
