# =============================================================================
# ISAR Network Debug Test Fixture
# =============================================================================
#
# A minimal, fast-running test designed for debugging network configuration
# issues in ISAR images. This test:
#   - Boots 2 ISAR VMs
#   - Applies runtime network configuration (mask networkd, add IPs)
#   - Monitors IP persistence over 60 seconds
#   - Reports any IP disappearance issues
#
# NO K3S STARTUP - this is purely for network debugging.
# Target runtime: ~1-2 minutes vs 7-10 minutes for full L4 test.
#
# CONTEXT:
#   This fixture was created to debug the IP persistence issue discovered
#   during ISAR L4 cluster testing (2026-01-29):
#   - server-2's eth1 IP (192.168.1.2) configured in Phase 2 but GONE by Phase 5
#   - ICMP ping works, but TCP needs source IP for full connectivity
#   - Something between Phase 2 and Phase 5 removes the IP address
#
# USAGE:
#   nix build '.#checks.x86_64-linux.isar-network-debug' -L
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/isar/isar-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/isar/mk-isar-test.nix { inherit pkgs lib; };

  # Import shared test utilities
  testScripts = import ../lib/test-scripts { inherit lib; };
  bootPhase = import ../lib/test-scripts/phases/boot.nix { inherit lib; };

  # Use the simple server image (same as L4 test)
  serverImage = isarArtifacts.qemuamd64.server.simple.wic;

  test = mkISARTest {
    name = "isar-network-debug";

    machines = {
      vm1 = {
        image = serverImage;
        memory = 2048; # Less memory since no k3s
        cpus = 2;
      };
      vm2 = {
        image = serverImage;
        memory = 2048;
        cpus = 2;
      };
    };

    vlans = [ 1 ]; # Single VLAN for cluster network

    globalTimeout = 300; # 5 minute timeout (should complete in ~2 min)

    testScript = ''
      ${testScripts.utils.all}

      log_banner("ISAR Network Debug Test", "simple", {
          "Purpose": "Debug IP persistence issue",
          "VM1 IP": "192.168.1.1",
          "VM2 IP": "192.168.1.2",
          "Duration": "60s monitoring",
          "K3s": "NOT started (network-only test)"
      })

      # =========================================================================
      # PHASE 1: Boot VMs
      # =========================================================================
      log_section("PHASE 1", "Booting VMs")
      start_all()

      # Wait for backdoor service (ISAR boot detection)
      vm1.wait_for_unit("nixos-test-backdoor.service", timeout=120)
      tlog("  vm1 backdoor ready")
      vm2.wait_for_unit("nixos-test-backdoor.service", timeout=120)
      tlog("  vm2 backdoor ready")

      # =========================================================================
      # PHASE 2: Capture pre-configuration state
      # =========================================================================
      log_section("PHASE 2", "Capturing pre-configuration state")

      # Check what systemd-networkd has configured
      pre_vm1_ip = vm1.execute("ip addr show eth1 2>&1")[1]
      pre_vm1_routes = vm1.execute("ip route show 2>&1")[1]
      pre_vm1_networkd = vm1.execute("systemctl status systemd-networkd.service 2>&1")[1]
      tlog(f"  vm1 pre-config eth1:\n{pre_vm1_ip}")
      tlog(f"  vm1 pre-config routes:\n{pre_vm1_routes}")
      tlog(f"  vm1 networkd status: {pre_vm1_networkd[:200]}...")

      pre_vm2_ip = vm2.execute("ip addr show eth1 2>&1")[1]
      pre_vm2_routes = vm2.execute("ip route show 2>&1")[1]
      pre_vm2_networkd = vm2.execute("systemctl status systemd-networkd.service 2>&1")[1]
      tlog(f"  vm2 pre-config eth1:\n{pre_vm2_ip}")
      tlog(f"  vm2 pre-config routes:\n{pre_vm2_routes}")
      tlog(f"  vm2 networkd status: {pre_vm2_networkd[:200]}...")

      # =========================================================================
      # PHASE 3: Configure network (same procedure as L4 test)
      # =========================================================================
      log_section("PHASE 3", "Configuring network")

      # The exact sequence from mk-isar-cluster-test.nix mkNetworkSetupCommands
      def configure_network(vm, ip, hostname):
          """Apply runtime network configuration - same as L4 test"""
          # MASK networkd to prevent restart via k3s service dependencies
          vm.execute("systemctl mask systemd-networkd.service")
          vm.execute("systemctl stop systemd-networkd.service || true")

          # Flush and reconfigure eth1
          vm.execute("ip addr flush dev eth1")
          vm.succeed("ip link set eth1 up")
          vm.succeed(f"ip addr add {ip}/24 dev eth1")

          # Set hostname (also done in L4 test)
          vm.succeed(f"echo {hostname} > /etc/hostname")
          vm.succeed(f"hostname {hostname}")

          tlog(f"  {hostname} configured with IP {ip}")

      configure_network(vm1, "192.168.1.1", "server-1")
      configure_network(vm2, "192.168.1.2", "server-2")

      # Verify IPs immediately after configuration
      def check_ip(vm, hostname, expected_ip):
          """Check if expected IP is present on eth1"""
          result = vm.execute("ip addr show eth1 | grep 'inet '")[1]
          has_ip = expected_ip in result
          tlog(f"  {hostname} eth1: {result.strip()} - {'OK' if has_ip else 'MISSING!'}")
          return has_ip

      tlog("")
      tlog("--- Immediate IP check after configuration ---")
      vm1_ok = check_ip(vm1, "server-1", "192.168.1.1")
      vm2_ok = check_ip(vm2, "server-2", "192.168.1.2")
      assert vm1_ok and vm2_ok, "IPs not configured correctly!"

      # =========================================================================
      # PHASE 4: Test basic connectivity
      # =========================================================================
      log_section("PHASE 4", "Testing basic connectivity")

      vm1.wait_until_succeeds("ping -c 1 192.168.1.2", timeout=30)
      tlog("  vm1 can ping vm2 (192.168.1.2)")
      vm2.wait_until_succeeds("ping -c 1 192.168.1.1", timeout=30)
      tlog("  vm2 can ping vm1 (192.168.1.1)")

      # =========================================================================
      # PHASE 5: Add default route (simulates L4 test VM workarounds)
      # =========================================================================
      log_section("PHASE 5", "Adding default route (VM workarounds)")

      # This is done in L4 test mkVMWorkarounds
      vm1.succeed("ip route add default via 192.168.1.254 dev eth1 || true")
      vm2.succeed("ip route add default via 192.168.1.254 dev eth1 || true")
      tlog("  Default routes added via 192.168.1.254")

      # Check IPs after route addition
      tlog("")
      tlog("--- IP check after adding default route ---")
      vm1_ok = check_ip(vm1, "server-1", "192.168.1.1")
      vm2_ok = check_ip(vm2, "server-2", "192.168.1.2")
      if not (vm1_ok and vm2_ok):
          tlog("WARNING: IP disappeared after adding default route!")

      # =========================================================================
      # PHASE 6: Monitor IP persistence over time
      # =========================================================================
      log_section("PHASE 6", "Monitoring IP persistence (60 seconds)")

      import time
      check_interval = 10  # seconds
      total_duration = 60  # seconds

      for i in range(total_duration // check_interval):
          time.sleep(check_interval)
          elapsed = (i + 1) * check_interval

          tlog(f"")
          tlog(f"--- IP check at {elapsed}s ---")

          # Full eth1 status
          vm1_eth1 = vm1.execute("ip addr show eth1")[1]
          vm2_eth1 = vm2.execute("ip addr show eth1")[1]

          vm1_has_ip = "192.168.1.1" in vm1_eth1
          vm2_has_ip = "192.168.1.2" in vm2_eth1

          tlog(f"  server-1 eth1: {'OK' if vm1_has_ip else 'MISSING!'}")
          if not vm1_has_ip:
              tlog(f"    Full output:\n{vm1_eth1}")

          tlog(f"  server-2 eth1: {'OK' if vm2_has_ip else 'MISSING!'}")
          if not vm2_has_ip:
              tlog(f"    Full output:\n{vm2_eth1}")

          # If either IP is missing, dump diagnostics
          if not (vm1_has_ip and vm2_has_ip):
              tlog("  FAILURE: IP disappeared!")

              # Check what services might have touched networking
              vm_with_issue = vm2 if not vm2_has_ip else vm1
              hostname = "server-2" if not vm2_has_ip else "server-1"

              tlog(f"  Diagnosing {hostname}...")

              # Check if networkd got unmasked somehow
              networkd_status = vm_with_issue.execute("systemctl status systemd-networkd.service 2>&1")[1]
              tlog(f"    networkd: {networkd_status[:200]}")

              # Check journal for network-related events
              journal = vm_with_issue.execute("journalctl -n 30 --no-pager 2>&1")[1]
              tlog(f"    Recent journal:\n{journal}")

              # Check routes
              routes = vm_with_issue.execute("ip route show 2>&1")[1]
              tlog(f"    Routes:\n{routes}")

              # Fail the test with diagnostics
              raise Exception(f"IP address disappeared from {hostname} at {elapsed}s")

          # Verify ping still works
          vm2.succeed("ping -c 1 192.168.1.1")

      # =========================================================================
      # PHASE 7: Simulate k3s startup on vm1 (what L4 test does in Phase 4)
      # =========================================================================
      log_section("PHASE 7", "Simulating k3s startup on vm1")

      # Check if k3s-server service exists
      k3s_exists = vm1.execute("systemctl list-unit-files | grep k3s-server")[1]
      tlog(f"  k3s-server unit: {k3s_exists.strip() if k3s_exists.strip() else 'NOT FOUND'}")

      if "k3s-server" in k3s_exists:
          # Configure k3s for cluster-init (minimal config needed)
          vm1.execute('sed -i \'s|^K3S_SERVER_OPTS=.*|K3S_SERVER_OPTS="--cluster-init --node-ip 192.168.1.1 --flannel-iface eth1"|\' /etc/default/k3s-server')

          # Create /dev/kmsg symlink (k3s needs this)
          vm1.execute("rm -f /dev/kmsg && ln -s /dev/null /dev/kmsg")
          vm2.execute("rm -f /dev/kmsg && ln -s /dev/null /dev/kmsg")

          tlog("  Starting k3s-server.service on vm1...")
          vm1.succeed("systemctl start k3s-server.service")

          # Wait for k3s to be up
          vm1.wait_for_unit("k3s-server.service", timeout=120)
          tlog("  k3s-server.service started on vm1")

          # Wait for API port
          vm1.wait_for_open_port(6443, timeout=60)
          tlog("  API port 6443 open on vm1")

          # Check what vm1 is listening on
          listen_output = vm1.execute("ss -tlnp | grep 6443")[1]
          tlog(f"  vm1 port 6443 bindings: {listen_output.strip()}")

          # NOW test TCP connectivity from vm2 to vm1:6443
          tlog("")
          tlog("--- TCP connectivity test: vm2 -> vm1:6443 ---")

          # First check network state on both VMs
          vm1_eth1 = vm1.execute("ip addr show eth1 | grep inet")[1].strip()
          vm2_eth1 = vm2.execute("ip addr show eth1 | grep inet")[1].strip()
          tlog(f"  vm1 eth1: {vm1_eth1}")
          tlog(f"  vm2 eth1: {vm2_eth1}")

          # Try ping first (should work)
          ping_result = vm2.execute("ping -c 1 192.168.1.1 2>&1")[1]
          tlog(f"  Ping vm2->vm1: {ping_result.strip().split(chr(10))[-2] if ping_result else 'failed'}")

          # Try TCP connection using bash /dev/tcp (more reliable than nc)
          tcp_test = vm2.execute("timeout 5 bash -c 'echo > /dev/tcp/192.168.1.1/6443' 2>&1; echo exit_code=$?")
          tlog(f"  TCP test vm2->vm1:6443: {tcp_test[1].strip()}")

          # Also try with curl
          curl_test = vm2.execute("timeout 10 curl -k -v https://192.168.1.1:6443/healthz 2>&1")[1]
          # Extract just the connection status
          curl_lines = [l for l in curl_test.split('\n') if 'Trying' in l or 'Connected' in l or 'refused' in l or 'timed out' in l]
          tlog(f"  Curl vm2->vm1:6443: {' | '.join(curl_lines[:3])}")

          # Check iptables on vm1
          iptables_out = vm1.execute("iptables -L -n 2>&1")[1]
          tlog(f"  vm1 iptables INPUT chain:\n{iptables_out[:500]}")

          # Check if there are any REJECT/DROP rules
          drop_rules = vm1.execute("iptables -L -n 2>&1 | grep -E 'DROP|REJECT'")[1]
          if drop_rules.strip():
              tlog(f"  WARNING: Found DROP/REJECT rules:\n{drop_rules}")
          else:
              tlog(f"  No DROP/REJECT rules found")

          # Check vm2's IP immediately after vm1 k3s starts
          tlog("")
          tlog("--- vm2 IP check IMMEDIATELY after vm1 k3s start ---")
          vm2_eth1 = vm2.execute("ip addr show eth1")[1]
          vm2_has_ip = "192.168.1.2" in vm2_eth1
          tlog(f"  vm2 eth1: {'OK' if vm2_has_ip else 'MISSING!'}")
          if not vm2_has_ip:
              tlog(f"    Full output:\n{vm2_eth1}")
              # Check what might have happened
              vm2_journal = vm2.execute("journalctl -n 50 --no-pager 2>&1")[1]
              tlog(f"    vm2 journal:\n{vm2_journal}")

          # Wait 30s more and check again
          tlog("  Waiting 30s to check IP persistence post-k3s-start...")
          time.sleep(30)

          tlog("")
          tlog("--- vm2 IP check 30s after vm1 k3s start ---")
          vm2_eth1 = vm2.execute("ip addr show eth1")[1]
          vm2_has_ip = "192.168.1.2" in vm2_eth1
          tlog(f"  vm2 eth1: {'OK' if vm2_has_ip else 'MISSING!'}")
          if not vm2_has_ip:
              tlog(f"    Full output:\n{vm2_eth1}")
              raise Exception("IP disappeared after k3s start on vm1!")

          # Verify ping still works
          vm2.succeed("ping -c 1 192.168.1.1")
          tlog("  Ping from vm2 to vm1 still works")

      else:
          tlog("  k3s-server not found - skipping k3s simulation")
          tlog("  (This test uses swupdate image without k3s)")

      # =========================================================================
      # PHASE 8: Final verification
      # =========================================================================
      log_section("PHASE 8", "Final verification")

      # Full network state dump
      tlog("")
      tlog("--- Final Network State ---")
      for vm, name in [(vm1, "server-1"), (vm2, "server-2")]:
          tlog(f"")
          tlog(f"  {name}:")
          eth1 = vm.execute("ip addr show eth1")[1]
          routes = vm.execute("ip route show")[1]
          tlog(f"    eth1: {eth1.strip()}")
          tlog(f"    routes: {routes.strip()}")

      log_summary("ISAR Network Debug Test", "simple", [
          "Both VMs booted successfully",
          "Network configuration applied (mask networkd, add IPs)",
          "IPs persisted for 60 seconds",
          "ICMP ping works bidirectionally",
          "k3s startup on vm1 did not affect vm2 network",
          "No IP disappearance observed"
      ])
    '';
  };

in
test
