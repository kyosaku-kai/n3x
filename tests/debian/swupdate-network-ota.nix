# =============================================================================
# SWUpdate Network OTA Test
# =============================================================================
#
# Tests network-based OTA where one VM serves updates to another:
# 1. Boot two VMs on same VLAN (update_server and target)
# 2. Server VM: Start HTTP server hosting .swu bundle
# 3. Target VM: Fetch and apply update via network
# 4. Verify update applied successfully
#
# This validates the complete network-based OTA workflow that would be used
# in production deployments.
#
# Usage:
#   nix build '.#test-swupdate-network-ota'
#   # Or run interactively:
#   nix build '.#test-swupdate-network-ota.driver'
#   ./result/bin/run-test-interactive
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/debian/debian-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/debian/mk-debian-test.nix { inherit pkgs lib; };

  test = mkISARTest {
    name = "swupdate-network-ota";

    # Single VLAN for both VMs to communicate
    vlans = [ 1 ];

    machines = {
      # Update server - serves the .swu bundle over HTTP
      update_server = {
        image = isarArtifacts.qemuamd64.swupdate.wic;
        memory = 1024;
        cpus = 1;
      };
      # Target device - applies the OTA update
      target = {
        image = isarArtifacts.qemuamd64.swupdate.wic;
        memory = 2048;
        cpus = 2;
      };
    };

    # Longer timeout for network operations
    globalTimeout = 600;

    testScript = ''
      import time

      HTTP_PORT = 8080
      UPDATE_DIR = "/srv/updates"
      BUNDLE_NAME = "network-ota-test.swu"

      def setup_network(machine, ip_addr, interface="enp0s3"):
          """Configure network interface with static IP
          QEMU adds: net0 (user, restricted) → enp0s2, then vlan1 (VDE) → enp0s3
          Base/swupdate images use predictable naming (no net.ifnames=0 boot arg)"""
          machine.succeed(f"ip link set {interface} up")
          machine.succeed(f"ip addr add {ip_addr}/24 dev {interface}")
          print(f"Configured {interface} with {ip_addr}")

      def create_test_bundle(machine, bundle_path, key_dir):
          """Create a signed test .swu bundle on the machine"""
          # Generate RSA key and X.509 certificate for CMS signing
          # Debian swupdate uses CONFIG_SIGALG_CMS (PKCS#7)
          machine.succeed(
              f"set -e && "
              f"mkdir -p {key_dir} && "
              f"cd {key_dir} && "
              "openssl genrsa -out priv.pem 2048 && "
              "openssl req -new -x509 -key priv.pem -out cert.pem -days 1 "
              "-subj '/CN=SWUpdate Test/O=n3x/C=US'"
          )
          print(f"Generated RSA key and X.509 certificate for CMS signing in {key_dir}")

          machine.succeed(
              f"set -e && "
              f"mkdir -p {UPDATE_DIR} && "
              "dd if=/dev/zero of=/tmp/rootfs.ext4 bs=1M count=50 && "
              "mkfs.ext4 -F -L APP_b /tmp/rootfs.ext4 &&"
              "mkdir -p /tmp/rootfs_mnt && "
              "mount /tmp/rootfs.ext4 /tmp/rootfs_mnt && "
              "echo 'Network OTA Test Bundle' > /tmp/rootfs_mnt/network-ota-marker.txt && "
              "date >> /tmp/rootfs_mnt/network-ota-marker.txt && "
              "hostname >> /tmp/rootfs_mnt/network-ota-marker.txt && "
              "mkdir -p /tmp/rootfs_mnt/{etc,bin,lib,usr,var} && "
              "echo 'NAME=n3x-network-ota' > /tmp/rootfs_mnt/etc/os-release && "
              "echo 'VERSION=network-test-1.0' >> /tmp/rootfs_mnt/etc/os-release && "
              "umount /tmp/rootfs_mnt && "
              "ROOTFS_SHA256=$(sha256sum /tmp/rootfs.ext4 | cut -d' ' -f1) && "
              "echo \"Rootfs SHA256: $ROOTFS_SHA256\" && "
              "printf '%s\\n' "
              "'software = {' "
              "'  version = \"network-ota-test-1.0.0\";' "
              "'  hardware-compatibility = [ \"1.0\" ];' "
              "'  images: (' "
              "'    {' "
              "'      filename = \"rootfs.ext4\";' "
              "'      type = \"raw\";' "
              "'      device = \"/dev/disk/by-label/APP_b\";' "
              "'      sha256 = \"'\"$ROOTFS_SHA256\"'\";' "
              "'    }' "
              "'  );' "
              "'};' > /tmp/sw-description && "
              f"openssl cms -sign -in /tmp/sw-description -out /tmp/sw-description.sig -signer {key_dir}/cert.pem -inkey {key_dir}/priv.pem -outform DER -nosmimecap -binary && "
              "cd /tmp && "
              "(echo sw-description; echo sw-description.sig; echo rootfs.ext4) | cpio -o -H crc > " + bundle_path + " && "
              "rm -f /tmp/rootfs.ext4 /tmp/sw-description /tmp/sw-description.sig && "
              "echo \"Signed bundle created: $(ls -la " + bundle_path + ")\""
          )

      # ==========================================================================
      # PHASE 1: Boot both VMs and establish network
      # ==========================================================================
      print("\n" + "=" * 70)
      print("PHASE 1: Boot VMs and Establish Network")
      print("=" * 70)

      # Wait for both VMs to boot
      update_server.wait_for_unit("nixos-test-backdoor.service")
      target.wait_for_unit("nixos-test-backdoor.service")
      print("Both VMs booted successfully")

      # Configure network interfaces manually since ISAR images don't auto-configure
      # Using static IPs on the 192.168.1.x subnet
      SERVER_IP = "192.168.1.1"
      TARGET_IP = "192.168.1.2"

      print("\n--- Configuring Network ---")
      setup_network(update_server, SERVER_IP)
      setup_network(target, TARGET_IP)

      # Show network interfaces on both machines
      print("\n--- Update Server Network ---")
      server_ifaces = update_server.succeed("ip -br addr")
      print(server_ifaces)

      print("\n--- Target Network ---")
      target_ifaces = target.succeed("ip -br addr")
      print(target_ifaces)

      server_ip = SERVER_IP
      target_ip = TARGET_IP
      print(f"\nUpdate server IP: {server_ip}")
      print(f"Target IP: {target_ip}")

      # Verify network connectivity between VMs
      print("\n--- Network Connectivity Test ---")

      # VDE switch needs time to establish forwarding between VMs
      # Give the virtio-net devices time to initialize and the VDE switch to see them
      print("Waiting for VDE switch to establish connectivity...")
      time.sleep(3)

      # Use ping to trigger ARP resolution and verify Layer 3 connectivity
      # Ping multiple times to give ARP time to populate
      print("Testing ping connectivity (may take a few attempts)...")

      # Try ping from both sides with retries - VDE switch may need traffic to learn MACs
      for attempt in range(5):
          server_ping = update_server.execute(f"ping -c 2 -W 2 {target_ip} 2>&1")
          target_ping = target.execute(f"ping -c 2 -W 2 {server_ip} 2>&1")
          print(f"Attempt {attempt + 1}:")
          print(f"  Server->Target: exit={server_ping[0]}")
          print(f"  Target->Server: exit={target_ping[0]}")
          if server_ping[0] == 0 and target_ping[0] == 0:
              print("Network connectivity established!")
              break
          time.sleep(2)
      else:
          # Final debug before continuing (don't fail yet - let HTTP test fail with details)
          print("Warning: Ping connectivity not verified, continuing anyway...")

      # Show ARP tables for debugging
      print("\nARP tables:")
      server_arp = update_server.execute("ip neigh show")
      print(f"Server ARP: {server_arp}")
      target_arp = target.execute("ip neigh show")
      print(f"Target ARP: {target_arp}")

      print("Network setup complete - proceeding with HTTP setup")

      # ==========================================================================
      # PHASE 2: Set up update server with HTTP service
      # ==========================================================================
      print("\n" + "=" * 70)
      print("PHASE 2: Set Up Update Server")
      print("=" * 70)

      # Create the signed .swu bundle on the update server
      bundle_path = f"{UPDATE_DIR}/{BUNDLE_NAME}"
      key_dir = f"{UPDATE_DIR}/keys"
      print(f"Creating signed test bundle at {bundle_path}...")
      create_test_bundle(update_server, bundle_path, key_dir)

      # Also serve the certificate for signature verification
      update_server.succeed(f"cp {key_dir}/cert.pem {UPDATE_DIR}/cert.pem")
      print(f"Certificate available at {UPDATE_DIR}/cert.pem")

      # Verify bundle was created
      bundle_info = update_server.succeed(f"ls -la {bundle_path}")
      print(f"Bundle created: {bundle_info}")

      # Start a simple HTTP file server using socat
      # socat properly handles bidirectional TCP communication
      print(f"\nStarting socat HTTP server on port {HTTP_PORT}...")

      # Create an HTTP handler script that socat will exec for each connection
      # Note: Using separate commands to avoid complex escaping issues
      update_server.succeed(f"mkdir -p /tmp")
      update_server.succeed(
          "cat > /tmp/http-handler.sh << 'HTTPEOF'\n"
          "#!/bin/bash\n"
          f"WEBROOT={UPDATE_DIR}\n"
          "read -r REQUEST_LINE\n"
          "FILE=$(echo \"$REQUEST_LINE\" | awk '{print $2}' | sed 's|^/||')\n"
          "FILEPATH=\"$WEBROOT/$FILE\"\n"
          "while IFS= read -r line; do\n"
          "    line=$(echo \"$line\" | tr -d '\\r')\n"
          "    [ -z \"$line\" ] && break\n"
          "done\n"
          "if [ -n \"$FILE\" ] && [ -f \"$FILEPATH\" ]; then\n"
          "    SIZE=$(stat -c%s \"$FILEPATH\")\n"
          "    printf 'HTTP/1.0 200 OK\\r\\n'\n"
          "    printf 'Content-Type: application/octet-stream\\r\\n'\n"
          "    printf 'Content-Length: %d\\r\\n' \"$SIZE\"\n"
          "    printf '\\r\\n'\n"
          "    cat \"$FILEPATH\"\n"
          "else\n"
          "    printf 'HTTP/1.0 404 Not Found\\r\\n\\r\\n'\n"
          "fi\n"
          "HTTPEOF"
      )
      update_server.succeed("chmod +x /tmp/http-handler.sh")

      # Start socat to listen on port and fork handler for each connection
      update_server.succeed(
          f"nohup socat TCP-LISTEN:{HTTP_PORT},fork,reuseaddr EXEC:/tmp/http-handler.sh > /tmp/http-server.log 2>&1 &"
      )

      # Give server a moment to start
      import time
      time.sleep(1)

      # Wait for HTTP server to be ready - check if socat is listening
      for i in range(30):
          result = update_server.execute(f"ss -tln | grep -q ':{HTTP_PORT} '")
          if result[0] == 0:
              break
          time.sleep(0.5)
      else:
          # Debug: show what's happening
          ss_out = update_server.execute("ss -tln")
          print(f"ss -tln output: {ss_out}")
          ps_out = update_server.execute("ps aux | grep -E 'socat|http'")
          print(f"socat/http processes: {ps_out}")
          log_out = update_server.execute("cat /tmp/http-server.log 2>/dev/null || echo 'no log'")
          print(f"http server log: {log_out}")
          raise Exception(f"HTTP server did not start on port {HTTP_PORT}")
      print(f"HTTP server running on port {HTTP_PORT}")

      # ==========================================================================
      # PHASE 3: Target downloads and applies update
      # ==========================================================================
      print("\n" + "=" * 70)
      print("PHASE 3: Target Downloads and Applies Update")
      print("=" * 70)

      bundle_url = f"http://{server_ip}:{HTTP_PORT}/{BUNDLE_NAME}"
      print(f"Bundle URL: {bundle_url}")

      # Debug: verify network connectivity with ping first
      print("\n--- Network connectivity debug ---")

      # First, verify network devices exist and show full details
      print("Target network devices:")
      target_devs = target.execute("ip link show")
      print(f"  ip link: {target_devs}")

      print("Server network devices:")
      server_devs = update_server.execute("ip link show")
      print(f"  ip link: {server_devs}")

      # Check if interface has correct MAC (set by mkISARVMScript)
      # The MACs are generated from machine name hash
      print("Verifying VLAN connectivity via arping (layer 2 test):")
      arping_result = target.execute(f"arping -c 3 -I enp0s2 {server_ip} 2>&1 || echo 'arping failed (may not be installed)'")
      print(f"  arping result: {arping_result}")

      ping_result = target.execute(f"ping -c 3 -W 2 {server_ip} 2>&1 || echo 'ping failed'")

      # Debug: check ARP and routes
      arp_result = target.execute("ip neigh show")
      print(f"ARP table: {arp_result}")
      route_result = target.execute("ip route show")
      print(f"Routes: {route_result}")

      # Test TCP connectivity with nc before curl
      print("\n--- Testing TCP connectivity to HTTP port ---")
      nc_result = target.execute(f"nc -zv -w 5 {server_ip} {HTTP_PORT} 2>&1 || echo 'nc failed'")
      print(f"Netcat result: {nc_result}")

      # Test HTTP connectivity from target to server with retry and verbose output
      print("\n--- Testing HTTP connectivity ---")
      for attempt in range(5):
          result = target.execute(f"curl -v --connect-timeout 10 -I {bundle_url} 2>&1")
          print(f"Curl attempt {attempt + 1}: exit={result[0]}")
          if result[0] == 0:
              print("HTTP HEAD request successful")
              break
          print(f"Output: {result[1][:500]}")
          time.sleep(2)
      else:
          # Final debug before failing
          server_ss = update_server.execute("ss -tlnp")
          print(f"Server listening sockets: {server_ss}")
          server_log = update_server.execute("cat /tmp/http-server.log 2>/dev/null || echo 'no log'")
          print(f"HTTP server log: {server_log}")
          raise Exception("HTTP connectivity test failed after 5 attempts")

      # Download the bundle and certificate
      print("\n--- Downloading bundle and certificate ---")
      cert_url = f"http://{server_ip}:{HTTP_PORT}/cert.pem"
      target.succeed(f"curl -o /tmp/update.swu {bundle_url}")
      target.succeed(f"curl -o /tmp/cert.pem {cert_url}")
      download_info = target.succeed("ls -la /tmp/update.swu /tmp/cert.pem")
      print(f"Downloaded files: {download_info}")

      # Verify the target's current partition state
      print("\n--- Target current partition state ---")
      current_root = target.succeed("findmnt -n -o SOURCE /").strip()
      print(f"Current root: {current_root}")
      blkid_out = target.succeed("blkid")
      print(f"Block devices:\n{blkid_out}")

      # Set up /etc/hwrevision for hardware compatibility check
      target.succeed("echo 'qemu-amd64 1.0' > /etc/hwrevision")
      print("Created /etc/hwrevision with 'qemu-amd64 1.0'")

      # Create grubenv at the default location SWUpdate expects
      target.succeed(
          "mkdir -p /boot/grub && "
          "grub-editenv /boot/grub/grubenv create && "
          "grub-editenv /boot/grub/grubenv set rootfs_slot=a"
      )
      print("Created /boot/grub/grubenv for SWUpdate GRUB handler")

      # Apply the update using SWUpdate with certificate for signature verification
      print("\n--- Applying signed update with SWUpdate ---")
      apply_result = target.succeed(
          "swupdate -v -k /tmp/cert.pem -i /tmp/update.swu 2>&1 || { "
          "echo 'SWUpdate failed with exit code $?'; "
          "cat /var/log/swupdate.log 2>/dev/null || true; "
          "exit 1; }"
      )
      print(f"SWUpdate output:\n{apply_result}")

      # ==========================================================================
      # PHASE 4: Verify update was applied
      # ==========================================================================
      print("\n" + "=" * 70)
      print("PHASE 4: Verify Update Applied")
      print("=" * 70)

      # Mount APP_b and check for our marker file
      verify_result = target.succeed(
          "set -e && "
          "mkdir -p /mnt/app_b && "
          "mount /dev/disk/by-label/APP_b /mnt/app_b && "
          "echo 'APP_b contents:' && "
          "ls -la /mnt/app_b/ && "
          "if [ -f /mnt/app_b/network-ota-marker.txt ]; then "
          "  echo 'SUCCESS: Found network-ota-marker.txt'; "
          "  cat /mnt/app_b/network-ota-marker.txt; "
          "else "
          "  echo 'ERROR: network-ota-marker.txt not found'; "
          "  exit 1; "
          "fi && "
          "if [ -f /mnt/app_b/etc/os-release ]; then "
          "  echo 'OS release:'; "
          "  cat /mnt/app_b/etc/os-release; "
          "fi && "
          "umount /mnt/app_b"
      )
      print(verify_result)

      # ==========================================================================
      # PHASE 5: Cleanup and summary
      # ==========================================================================
      print("\n" + "=" * 70)
      print("PHASE 5: Cleanup and Summary")
      print("=" * 70)

      # Stop HTTP server (socat-based) - use execute to avoid race condition with cleanup
      update_server.execute("pkill -f 'socat TCP-LISTEN'")
      print("HTTP server stopped")

      # Summary
      print("\n" + "=" * 70)
      print("TEST SUMMARY")
      print("=" * 70)
      print("")
      print("Network OTA Test Results:")
      print(f"  [PASS] Update server booted at {server_ip}")
      print(f"  [PASS] Target device booted at {target_ip}")
      print("  [PASS] VLAN networking configured between VMs")
      print("  [PASS] Generated RSA key and X.509 certificate for bundle signing")
      print(f"  [PASS] HTTP server serving signed bundle on port {HTTP_PORT}")
      print("  [PASS] Target downloaded bundle and certificate over network")
      print("  [PASS] SWUpdate verified signature and applied update to APP_b")
      print("  [PASS] Marker file present in updated partition")
      print("")
      print("This test validates:")
      print("  - Multi-VM network setup with VLAN")
      print("  - RSA signature generation and verification")
      print("  - HTTP-based signed bundle distribution")
      print("  - Network-based SWUpdate workflow with signature verification")
      print("  - End-to-end secure OTA update mechanism")
      print("")
      print("NETWORK OTA TEST: PASSED")
    '';
  };

in
test
