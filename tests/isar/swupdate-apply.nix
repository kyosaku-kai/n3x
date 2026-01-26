# =============================================================================
# SWUpdate Apply Test
# =============================================================================
#
# Tests that SWUpdate can apply an update to the inactive (APP_b) partition.
# This is a key step in validating A/B OTA updates.
#
# Test validates:
# 1. System boots from APP partition (slot A)
# 2. APP_b partition exists and is accessible
# 3. SWUpdate can apply an ext4 image to APP_b using raw handler
# 4. The updated partition contains the expected filesystem
#
# Note: This test does NOT reboot into the updated partition - that's T3.
#
# Usage:
#   nix build '.#test-swupdate-apply'
#   # Or run interactively:
#   nix build '.#test-swupdate-apply.driver'
#   ./result/bin/run-test-interactive
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/isar/isar-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/isar/mk-isar-test.nix { inherit pkgs lib; };

  test = mkISARTest {
    name = "swupdate-apply";

    machines = {
      testvm = {
        image = isarArtifacts.qemuamd64.swupdate.wic;
        memory = 2048;
        cpus = 2;
      };
    };

    testScript = ''
      import os

      # Wait for VM to boot
      testvm.wait_for_unit("nixos-test-backdoor.service")
      print("VM booted successfully")

      # ===== Test 1: Verify boot from APP partition =====
      print("\n" + "=" * 60)
      print("Test 1: Verify boot from APP partition (slot A)")
      print("=" * 60)

      # Get current root device
      root_mount = testvm.succeed("findmnt -n -o SOURCE /").strip()
      print(f"Current root device: {root_mount}")

      # Verify we're on APP (slot A) - could be by label or by device path
      # The device will be /dev/sda2 (partition 2) or contain LABEL=APP
      root_label = testvm.succeed("findmnt -n -o LABEL / 2>/dev/null || echo 'no-label'").strip()
      print(f"Root partition label: {root_label}")

      if root_label == "APP" or "sda2" in root_mount:
          print("Confirmed: Booted from APP partition (slot A)")
      else:
          raise Exception(f"Expected boot from APP, got label={root_label} device={root_mount}")

      # ===== Test 2: Verify A/B partition layout =====
      print("\n" + "=" * 60)
      print("Test 2: Verify A/B partition layout")
      print("=" * 60)

      # Show block device info
      blkid = testvm.succeed("blkid")
      print(f"Block devices:\n{blkid}")

      # Verify APP_b exists
      testvm.succeed("blkid | grep -i 'LABEL=\"APP_b\"'")
      print("APP_b partition found")

      # Get APP_b device path
      app_b_dev = testvm.succeed("blkid -L APP_b").strip()
      print(f"APP_b device: {app_b_dev}")

      # ===== Test 3: Generate signing keys =====
      print("\n" + "=" * 60)
      print("Test 3: Generate RSA key pair for signing")
      print("=" * 60)

      # Debian swupdate is compiled with CONFIG_SIGNED_IMAGES and CONFIG_SIGALG_CMS
      # This means it uses PKCS#7/CMS signature format
      # We generate a self-signed certificate and use CMS signing
      testvm.succeed(
          "set -e && "
          "mkdir -p /tmp/swupdate-test && "
          "cd /tmp/swupdate-test && "
          "openssl genrsa -out priv.pem 2048 && "
          "openssl req -new -x509 -key priv.pem -out cert.pem -days 1 "
          "-subj '/CN=SWUpdate Test/O=ISAR-K3S/C=US' && "
          "echo 'Generated RSA key and X.509 certificate:' && "
          "ls -la /tmp/swupdate-test/*.pem && "
          "openssl x509 -in cert.pem -text -noout | head -15"
      )
      print("RSA key and X.509 certificate generated for CMS signing")

      # ===== Test 4: Prepare update bundle =====
      print("\n" + "=" * 60)
      print("Test 4: Prepare signed update bundle with raw ext4 handler")
      print("=" * 60)

      # Create a minimal ext4 image to write to APP_b
      # This simulates what a real OTA update would do
      # IMPORTANT: Keep the label as APP_b so by-label symlink still works after update
      testvm.succeed(
          "set -e && "
          "cd /tmp/swupdate-test && "
          "dd if=/dev/zero of=rootfs.ext4 bs=1M count=50 && "
          "mkfs.ext4 -F -L APP_b rootfs.ext4 && "
          "mkdir -p mnt && "
          "mount rootfs.ext4 mnt && "
          "echo 'Updated rootfs from SWUpdate test' > mnt/swupdate-marker.txt && "
          "date >> mnt/swupdate-marker.txt && "
          "mkdir -p mnt/etc && "
          "echo 'NAME=isar-k3s-updated' > mnt/etc/os-release && "
          "umount mnt && "
          "ROOTFS_SHA256=$(sha256sum rootfs.ext4 | cut -d' ' -f1) && "
          "echo \"Rootfs SHA256: $ROOTFS_SHA256\" && "
          "printf '%s\\n' "
          "'software = {' "
          "'  version = \"test-apply-1.0.0\";' "
          "'  hardware-compatibility = [ \"1.0\" ];' "
          "'  images: (' "
          "'    {' "
          "'      filename = \"rootfs.ext4\";' "
          "'      type = \"raw\";' "
          "'      device = \"/dev/disk/by-label/APP_b\";' "
          "'      sha256 = \"'\"$ROOTFS_SHA256\"'\";' "
          "'    }' "
          "'  );' "
          "'};' > sw-description && "
          "echo 'sw-description content:' && "
          "cat sw-description && "
          "echo 'Signing sw-description with CMS (PKCS#7)...' && "
          "openssl cms -sign -in sw-description -out sw-description.sig -signer cert.pem -inkey priv.pem -outform DER -nosmimecap -binary && "
          "echo 'Creating signed bundle...' && "
          "(echo sw-description; echo sw-description.sig; echo rootfs.ext4) | cpio -o -H crc > update-bundle.swu && "
          "echo 'Bundle created:' && "
          "ls -la /tmp/swupdate-test/"
      )

      # Verify bundle was created
      bundle_size = testvm.succeed("stat -c%s /tmp/swupdate-test/update-bundle.swu").strip()
      print(f"Created signed update bundle: {bundle_size} bytes")

      # ===== Test 5: Validate bundle before applying =====
      print("\n" + "=" * 60)
      print("Test 5: Validate bundle before applying")
      print("=" * 60)

      # Check bundle structure with certificate
      result = testvm.execute("swupdate -c -k /tmp/swupdate-test/cert.pem -i /tmp/swupdate-test/update-bundle.swu 2>&1")
      print(f"Validation result (exit={result[0]}):\n{result[1]}")

      # ===== Test 6: Apply update to APP_b =====
      print("\n" + "=" * 60)
      print("Test 6: Apply update to APP_b partition")
      print("=" * 60)

      # First check current state of APP_b
      print("APP_b before update:")
      result = testvm.execute("mount /dev/disk/by-label/APP_b /mnt && ls -la /mnt && umount /mnt")
      print(f"APP_b contents: {result[1]}")

      # Set up /etc/hwrevision for hardware compatibility check
      # SWUpdate reads this file to determine system hardware identity
      # Format: <boardname> <revision>
      testvm.succeed("echo 'qemu-amd64 1.0' > /etc/hwrevision")
      print("Created /etc/hwrevision with 'qemu-amd64 1.0'")

      # Create grubenv at the default location SWUpdate expects
      # SWUpdate GRUB handler looks for /boot/grub/grubenv by default
      testvm.succeed(
          "mkdir -p /boot/grub && "
          "grub-editenv /boot/grub/grubenv create && "
          "grub-editenv /boot/grub/grubenv set rootfs_slot=a"
      )
      print("Created /boot/grub/grubenv for SWUpdate GRUB handler")

      # Apply the update using swupdate with certificate for signature verification
      # -k = certificate file for signature verification
      # -v = verbose
      # -i = input file
      print("\nApplying signed update...")
      apply_result = testvm.succeed(
          "swupdate -v -k /tmp/swupdate-test/cert.pem -i /tmp/swupdate-test/update-bundle.swu 2>&1 || { "
          "echo 'SWUpdate failed with exit code $?'; "
          "journalctl -u swupdate --no-pager -n 50 2>/dev/null || true; "
          "exit 1; }"
      )
      print(f"SWUpdate output:\n{apply_result}")

      # ===== Test 7: Verify APP_b was updated =====
      print("\n" + "=" * 60)
      print("Test 7: Verify APP_b partition contents after update")
      print("=" * 60)

      # Mount APP_b and check for our marker file
      testvm.succeed(
          "set -e && "
          "mkdir -p /mnt/app_b && "
          "mount /dev/disk/by-label/APP_b /mnt/app_b && "
          "echo 'APP_b contents after update:' && "
          "ls -la /mnt/app_b/ && "
          "if [ -f /mnt/app_b/swupdate-marker.txt ]; then "
          "  echo 'SUCCESS: Found swupdate-marker.txt'; "
          "  cat /mnt/app_b/swupdate-marker.txt; "
          "else "
          "  echo 'ERROR: swupdate-marker.txt not found'; "
          "  exit 1; "
          "fi && "
          "if [ -f /mnt/app_b/etc/os-release ]; then "
          "  echo 'os-release content:'; "
          "  cat /mnt/app_b/etc/os-release; "
          "fi && "
          "umount /mnt/app_b"
      )

      print("APP_b partition successfully updated!")

      # ===== Test 8: Verify grubenv can be modified for boot switch =====
      print("\n" + "=" * 60)
      print("Test 8: Verify grub-editenv works (prep for T3)")
      print("=" * 60)

      # Check current grubenv state
      testvm.succeed("which grub-editenv")

      # Use /boot/grub/grubenv which we already created for SWUpdate
      grubenv_result = testvm.execute(
          "echo 'Current grubenv:' && "
          "grub-editenv /boot/grub/grubenv list"
      )
      print(f"grubenv state: {grubenv_result[1]}")

      # Verify we can set rootfs_slot (but don't actually switch yet - that's T3)
      testvm.succeed(
          "grub-editenv /boot/grub/grubenv set test_var=test_value && "
          "grub-editenv /boot/grub/grubenv unset test_var && "
          "echo 'grub-editenv read/write verified'"
      )
      print("grub-editenv verified working")

      print("\n" + "=" * 60)
      print("ALL TESTS PASSED")
      print("=" * 60)
      print("")
      print("Summary:")
      print("  - Booted from APP partition (slot A)")
      print("  - Generated RSA key and X.509 certificate for bundle signing")
      print("  - Created test ext4 image with marker file")
      print("  - Built signed .swu bundle with raw handler")
      print("  - Validated bundle signature with certificate")
      print("  - Applied signed update to APP_b partition")
      print("  - Verified marker file present in APP_b")
      print("  - Verified grub-editenv working for boot switch")
      print("")
      print("Next step: T3 will test rebooting into APP_b")
    '';
  };

in
test
