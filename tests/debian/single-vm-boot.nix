# =============================================================================
# Single VM Boot Test
# =============================================================================
#
# A minimal test to verify the ISAR VM + nixos-test-driver integration.
# This test boots a single VM and verifies the backdoor shell works.
#
# This is a Layer 1 test (VM Boot) using shared test-scripts for consistency
# with NixOS smoke tests.
#
# Usage:
#   nix build '.#checks.x86_64-linux.test-single-vm-boot'
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/debian/debian-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/debian/mk-debian-test.nix { inherit pkgs lib; };

  # Import shared test utilities
  testScripts = import ../lib/test-scripts { inherit lib; };
  bootPhase = import ../lib/test-scripts/phases/boot.nix { inherit lib; };

  test = mkISARTest {
    name = "single-vm-boot";

    machines = {
      testvm = {
        # Use swupdate image - it includes nixos-test-backdoor service
        image = isarArtifacts.qemuamd64.swupdate.wic;
        memory = 2048;
        cpus = 2;
      };
    };

    testScript = ''
      ${testScripts.utils.all}

      log_banner("ISAR Single VM Boot Test", "swupdate-image", {
          "Layer": "1 (VM Boot)",
          "Image": "qemuamd64 swupdate",
          "Purpose": "Verify backdoor shell works"
      })

      # Boot VM and wait for backdoor
      ${bootPhase.debian.bootWithBackdoor { node = "testvm"; displayName = "ISAR testvm"; }}

      # Verify basic system info
      log_section("PHASE 2", "Verifying system info")
      result = testvm.succeed("hostname")
      tlog(f"  Hostname: {result.strip()}")

      # Check system status (diagnostic, not asserted)
      ${bootPhase.debian.checkSystemStatus { node = "testvm"; }}

      # Final success assertion
      testvm.succeed("echo 'Single VM boot test passed - backdoor is functional!'")

      log_summary("ISAR Single VM Boot Test", "swupdate-image", [
          "VM booted successfully",
          "Backdoor shell functional",
          "Basic commands execute"
      ])
    '';
  };

in
test
