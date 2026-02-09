# =============================================================================
# Two VM Network Test (ISAR)
# =============================================================================
#
# Layer 2 test: Can two ISAR VMs communicate over VDE?
# This is the ISAR equivalent of tests/nixos/smoke/two-vm-network.nix
#
# This test verifies:
# - Two ISAR VMs can boot in parallel
# - VDE network switch works
# - VMs can be configured with static IPs (from shared profiles)
# - VMs can ping each other
#
# If this test fails, multi-VM ISAR tests will fail.
#
# NETWORK PARITY:
#   Uses shared network profile from lib/network/profiles/simple.nix
#   IPs are sourced from the same profile that NixOS tests use.
#   Only difference: ISAR uses enp0s2, NixOS uses eth1 (same VDE socket)
#
# Usage:
#   nix build '.#checks.x86_64-linux.isar-two-vm-network'
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

  # Import shared network profile - SAME profile used by NixOS tests
  # UNIFIED: Profiles now live in lib/network/ (consumed by BOTH backends)
  networkProfile = import ../../lib/network/profiles/simple.nix { inherit lib; };

  # Create network config helper for ISAR VMs
  mkNetworkConfig = import ../lib/debian/mk-network-config.nix { inherit lib; };
  networkConfig = mkNetworkConfig {
    profile = networkProfile;
    # Map abstract interface names to ISAR's actual interface names
    # QEMU adds: net0 (user, restricted) → enp0s2, then vlan1 (VDE) → enp0s3
    # Base/swupdate images use predictable naming (no net.ifnames=0 boot arg)
    # Server/agent images use eth0/eth1 (net.ifnames=0 in boot overlay)
    interfaceMapping = { cluster = "enp0s3"; };
  };

  test = mkISARTest {
    name = "two-vm-network";

    # Single VLAN for both VMs to communicate
    vlans = [ 1 ];

    machines = {
      vm1 = {
        # Use swupdate image - it includes nixos-test-backdoor service
        image = isarArtifacts.qemuamd64.swupdate.wic;
        memory = 1024;
        cpus = 1;
      };
      vm2 = {
        # Use swupdate image - it includes nixos-test-backdoor service
        image = isarArtifacts.qemuamd64.swupdate.wic;
        memory = 1024;
        cpus = 1;
      };
    };

    testScript =
      let
        # Get IPs from shared profile via networkConfig helper
        vm1IP = networkConfig.getIP "vm1" "cluster";
        vm2IP = networkConfig.getIP "vm2" "cluster";
        clusterIface = networkConfig.getInterface "cluster";
      in
      ''
        import time
        start = time.time()

        ${testScripts.utils.all}

        log_banner("ISAR Two VM Network Test", "swupdate-image", {
            "Layer": "2 (Two-VM Network)",
            "Image": "qemuamd64 swupdate",
            "Purpose": "Verify VDE networking between ISAR VMs",
            "Network Profile": "simple (shared with NixOS tests)"
        })

        # ==========================================================================
        # PHASE 1: Boot both VMs
        # ==========================================================================
        log_section("PHASE 1", "Booting both VMs")
        start_all()

        # Wait for backdoor on both VMs
        vm1.wait_for_unit("nixos-test-backdoor.service")
        tlog("  vm1 backdoor ready")
        vm2.wait_for_unit("nixos-test-backdoor.service")
        tlog("  vm2 backdoor ready")

        # ==========================================================================
        # PHASE 2: Configure network interfaces (using shared profile)
        # ==========================================================================
        log_section("PHASE 2", "Configuring network interfaces from shared profile")

        # IPs sourced from lib/network/profiles/simple.nix (unified location)
        # Same IPs used by NixOS tests, only interface name differs
        VM1_IP = "${vm1IP}"
        VM2_IP = "${vm2IP}"
        CLUSTER_IFACE = "${clusterIface}"

        tlog(f"  Using shared network profile: simple")
        tlog(f"  Cluster interface: {CLUSTER_IFACE} (NixOS uses eth1)")

        # ISAR images need manual IP configuration at runtime
        ${networkConfig.setupCommands "vm1"}
        ${networkConfig.setupCommands "vm2"}

        # Show network interfaces
        vm1_ifaces = vm1.succeed("ip -br addr")
        tlog(f"  vm1 interfaces:\n{vm1_ifaces}")
        vm2_ifaces = vm2.succeed("ip -br addr")
        tlog(f"  vm2 interfaces:\n{vm2_ifaces}")

        # ==========================================================================
        # PHASE 3: Verify IP configuration
        # ==========================================================================
        log_section("PHASE 3", "Verifying IP configuration")

        ${networkConfig.verifyCommands "vm1"}
        ${networkConfig.verifyCommands "vm2"}

        # ==========================================================================
        # PHASE 4: Wait for network to settle
        # ==========================================================================
        log_section("PHASE 4", "Waiting for VDE switch to establish connectivity")

        # VDE switch needs time to learn MAC addresses
        time.sleep(3)

        # ==========================================================================
        # PHASE 5: Test connectivity
        # ==========================================================================
        log_section("PHASE 5", "Testing connectivity")

        # Start simple TCP listeners using socat (known to be available in swupdate images)
        # Using same pattern as swupdate-network-ota.nix
        vm2.succeed("nohup socat TCP-LISTEN:9999,fork,reuseaddr EXEC:'/bin/echo hello' > /tmp/socat.log 2>&1 &")
        vm1.succeed("nohup socat TCP-LISTEN:9998,fork,reuseaddr EXEC:'/bin/echo hello' > /tmp/socat.log 2>&1 &")
        time.sleep(1)

        # Verify listeners are up
        vm1_listen = vm1.execute("ss -tln | grep 9998")
        vm2_listen = vm2.execute("ss -tln | grep 9999")
        tlog(f"  vm1 listening: {vm1_listen[0] == 0}")
        tlog(f"  vm2 listening: {vm2_listen[0] == 0}")

        # Try TCP connectivity with retries (VDE switch may need traffic to learn MACs)
        tlog("  Testing TCP connectivity...")
        for attempt in range(5):
            # Use netcat for connectivity test
            vm1_nc = vm1.execute(f"nc -zv -w 3 {VM2_IP} 9999 2>&1")
            vm2_nc = vm2.execute(f"nc -zv -w 3 {VM1_IP} 9998 2>&1")
            tlog(f"  Attempt {attempt + 1}: vm1->vm2={vm1_nc[0]}, vm2->vm1={vm2_nc[0]}")
            if vm1_nc[0] == 0 and vm2_nc[0] == 0:
                tlog("  Network connectivity established!")
                break
            time.sleep(2)
        else:
            # Debug info before failing
            vm1_arp = vm1.execute("ip neigh show")[1]
            vm2_arp = vm2.execute("ip neigh show")[1]
            tlog(f"  vm1 ARP: {vm1_arp}")
            tlog(f"  vm2 ARP: {vm2_arp}")

        # Final bidirectional verification with nc
        vm1.succeed(f"nc -zv -w 5 {VM2_IP} 9999")
        tlog(f"  vm1 -> vm2 ({VM2_IP}:9999): OK")
        vm2.succeed(f"nc -zv -w 5 {VM1_IP} 9998")
        tlog(f"  vm2 -> vm1 ({VM1_IP}:9998): OK")

        # Cleanup listeners
        vm1.execute("pkill socat")
        vm2.execute("pkill socat")

        elapsed = time.time() - start

        log_summary("ISAR Two VM Network Test", "swupdate-image", [
            f"Both VMs booted successfully",
            f"Static IPs from shared profile ({VM1_IP}, {VM2_IP})",
            f"Interface mapping: cluster -> {CLUSTER_IFACE}",
            "VDE networking verified (same VDE socket as NixOS tests)",
            f"Completed in {elapsed:.1f}s"
        ])
      '';
  };

in
test
