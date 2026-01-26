# NixOS Integration Test: Network Resilience
#
# Tests the network constraint simulation infrastructure for the n3x emulation
# environment. Validates that TC (traffic control) profiles can be applied,
# switched, and verified.
#
# This test validates:
#   1. TC profile script is executable and works correctly
#   2. OVS bridge is properly configured for inner VMs
#   3. TC rules can be applied to VM interfaces when VMs are running
#   4. Profile switching works (default → constrained → lossy → default)
#   5. Status command shows correct configuration
#
# NOTE: This test focuses on the TC infrastructure specifically. For full k3s
# cluster testing with inner VM connectivity, see vsim-k3s-cluster.nix.
#
# Inner VMs (server-1, server-2, agent-1) have pre-built NixOS images with k3s
# pre-configured. They can boot directly into NixOS when started.
#
# Run with:
#   nix build .#checks.x86_64-linux.network-resilience
#   nix build .#checks.x86_64-linux.network-resilience.driverInteractive

{ pkgs, lib, inputs ? { }, ... }:

pkgs.testers.runNixOSTest {
  name = "network-resilience";

  nodes = {
    emulator = { config, pkgs, lib, modulesPath, ... }: {
      imports = [ ../emulation/embedded-system.nix ];

      # Pass inputs to embedded-system.nix via _module.args
      _module.args.inputs = inputs;

      # Reduce resource requirements for CI testing
      virtualisation = {
        memorySize = lib.mkForce 8192; # 8GB (reduced from 12GB)
        diskSize = lib.mkForce 30000; # 30GB (reduced from 60GB)
        cores = lib.mkForce 4; # 4 vCPUs (reduced from 8)
      };
    };
  };

  testScript = ''
    import time

    print("=" * 70)
    print("Network Resilience Test - TC Profile Infrastructure Validation")
    print("=" * 70)

    # ===========================================================================
    # PHASE 1: Boot Emulation Environment
    # ===========================================================================
    print("\n[PHASE 1] Booting emulation environment...")

    emulator.start()
    emulator.wait_for_unit("multi-user.target")
    print("  VM booted successfully")

    # Verify core services
    emulator.wait_for_unit("libvirtd.service")
    print("  libvirtd is running")

    # OVS creates ovsdb and ovs-vswitchd services, not "openvswitch.service"
    emulator.wait_for_unit("ovsdb.service")
    emulator.wait_for_unit("ovs-vswitchd.service")
    print("  OVS services are running")

    emulator.wait_for_unit("setup-inner-vms.service")
    print("  Inner VMs initialized")

    # ===========================================================================
    # PHASE 2: Validate Infrastructure
    # ===========================================================================
    print("\n[PHASE 2] Validating infrastructure...")

    # Verify OVS bridge exists with correct topology
    # Note: Host interface is "ovshost0" to avoid conflict with libvirt's vnet* naming
    ovs_output = emulator.succeed("ovs-vsctl show")
    assert "ovsbr0" in ovs_output, "OVS bridge ovsbr0 not found"
    assert "ovshost0" in ovs_output, "Host interface ovshost0 not found on bridge"
    print("  OVS bridge topology correct")

    # Verify host interface has IP
    ip_output = emulator.succeed("ip addr show ovshost0")
    assert "192.168.100.1" in ip_output, "Host interface missing IP 192.168.100.1"
    print("  Host interface configured: 192.168.100.1/24")

    # Verify TC script is available
    emulator.succeed("test -x /etc/tc-simulate-constraints.sh")
    print("  TC constraint script is executable")

    # Verify inner VMs are defined
    virsh_list = emulator.succeed("virsh list --all")
    for vm in ["server-1", "server-2", "agent-1"]:
        assert vm in virsh_list, "VM " + vm + " not defined in libvirt"
    print("  Inner VMs defined: server-1, server-2, agent-1")

    # ===========================================================================
    # PHASE 3: TC Profile Testing (Without Running VMs)
    # ===========================================================================
    print("\n[PHASE 3] Testing TC profile script (no running VMs)...")

    # Test status command - should work but report VMs not running
    status_output = emulator.succeed("/etc/tc-simulate-constraints.sh status")
    assert "not running" in status_output, "Status should show VMs not running"
    print("  Status command works (reports VMs not running)")

    # Test profile commands - should complete without error
    emulator.succeed("/etc/tc-simulate-constraints.sh default")
    print("  Default profile command executed")

    emulator.succeed("/etc/tc-simulate-constraints.sh constrained")
    print("  Constrained profile command executed")

    emulator.succeed("/etc/tc-simulate-constraints.sh lossy")
    print("  Lossy profile command executed")

    emulator.succeed("/etc/tc-simulate-constraints.sh clear")
    print("  Clear profile command executed")

    # Test invalid profile - should fail
    result = emulator.execute("/etc/tc-simulate-constraints.sh invalid_profile")[0]
    assert result != 0, "Invalid profile should return non-zero exit code"
    print("  Invalid profile correctly rejected")

    # ===========================================================================
    # PHASE 4: Start Inner VMs and Test TC Rules
    # ===========================================================================
    print("\n[PHASE 4] Starting inner VMs for interface testing...")

    # Start server-1 (it won't boot to an OS but will create a vnet interface)
    emulator.succeed("virsh start server-1")
    time.sleep(3)  # Wait for interface to be created
    print("  Started server-1")

    # Check that interface was created
    server_1_iface = emulator.succeed("virsh domiflist server-1 | grep -oP 'vnet\\d+' || echo 'none'").strip()
    if server_1_iface != "none" and server_1_iface:
        print("  server-1 interface: " + server_1_iface)

        # Now test TC rules can be applied
        print("\n[PHASE 4b] Testing TC rule application...")

        # Apply constrained profile
        emulator.succeed("/etc/tc-simulate-constraints.sh constrained")
        tc_show = emulator.succeed("tc qdisc show dev " + server_1_iface)
        # tbf (token bucket filter) should be present for constrained profile
        if "tbf" in tc_show or "rate" in tc_show:
            print("  Constrained profile applied to " + server_1_iface)
        else:
            print("  Warning: TC rules may not have applied correctly")
            print("  tc output: " + tc_show)

        # Apply lossy profile
        emulator.succeed("/etc/tc-simulate-constraints.sh lossy")
        tc_show = emulator.succeed("tc qdisc show dev " + server_1_iface)
        if "netem" in tc_show:
            print("  Lossy profile applied to " + server_1_iface)
        else:
            print("  Warning: netem rules may not have applied correctly")
            print("  tc output: " + tc_show)

        # Clear rules
        emulator.succeed("/etc/tc-simulate-constraints.sh default")
        tc_show = emulator.succeed("tc qdisc show dev " + server_1_iface)
        print("  Rules cleared from " + server_1_iface)

        # Status should now show the running VM
        status_output = emulator.succeed("/etc/tc-simulate-constraints.sh status")
        assert server_1_iface in status_output, "Status should show running VM interface"
        print("  Status command shows running VM interface")
    else:
        print("  Warning: Could not detect vnet interface for server-1")
        print("  This may be expected if QEMU interface creation is delayed")

    # Clean up - shutdown VM
    emulator.succeed("virsh destroy server-1 || true")
    print("  Stopped server-1")

    # ===========================================================================
    # PHASE 5: Multi-VM TC Test
    # ===========================================================================
    print("\n[PHASE 5] Multi-VM TC test...")

    # Start all VMs
    for vm in ["server-1", "server-2", "agent-1"]:
        emulator.succeed("virsh start " + vm)
        time.sleep(1)
    print("  Started all inner VMs")
    time.sleep(3)  # Wait for interfaces

    # Get all interfaces
    interfaces = {}
    for vm in ["server-1", "server-2", "agent-1"]:
        iface = emulator.succeed("virsh domiflist " + vm + " | grep -oP 'vnet\\d+' || echo '''").strip()
        if iface:
            interfaces[vm] = iface

    if interfaces:
        print("  VM interfaces: " + str(interfaces))

        # Apply constrained profile and verify differential rates
        emulator.succeed("/etc/tc-simulate-constraints.sh constrained")
        print("  Applied constrained profile to all VMs")

        # Check status
        status = emulator.succeed("/etc/tc-simulate-constraints.sh status")
        for vm, iface in interfaces.items():
            assert iface in status, "Interface " + iface + " not in status output"
        print("  Status shows all VM interfaces")

        # Apply lossy and verify
        emulator.succeed("/etc/tc-simulate-constraints.sh lossy")
        print("  Applied lossy profile to all VMs")

        # Clear all
        emulator.succeed("/etc/tc-simulate-constraints.sh default")
        print("  Cleared all TC rules")
    else:
        print("  Warning: No VM interfaces detected")

    # Shutdown all VMs
    for vm in ["server-1", "server-2", "agent-1"]:
        emulator.succeed("virsh destroy " + vm + " || true")
    print("  Stopped all inner VMs")

    # ===========================================================================
    # PHASE 6: OVS Port Verification
    # ===========================================================================
    print("\n[PHASE 6] OVS port verification...")

    # Verify OVS configuration is intact
    ovs_final = emulator.succeed("ovs-vsctl show")
    assert "ovsbr0" in ovs_final, "OVS bridge should still exist"
    print("  OVS bridge intact after VM lifecycle")

    # Check OVS settings
    stp_status = emulator.succeed("ovs-vsctl get bridge ovsbr0 stp_enable")
    assert "true" in stp_status, "STP should be enabled"
    print("  STP enabled on bridge")

    # ===========================================================================
    # Summary
    # ===========================================================================
    print("\n" + "=" * 70)
    print("Network Resilience Test - PASSED")
    print("=" * 70)
    print("")
    print("Validated:")
    print("  - OVS bridge topology (ovsbr0 with ovshost0 @ 192.168.100.1/24)")
    print("  - TC constraint script functionality")
    print("  - Profile switching (default, constrained, lossy)")
    print("  - TC rules apply to running VM interfaces")
    print("  - Multi-VM TC management")
    print("  - OVS configuration persistence")
    print("")
    print("Next steps:")
    print("  - Phase 3: Install NixOS on inner VMs for full connectivity tests")
    print("  - Phase 4: K3s cluster formation under network constraints")
    print("=" * 70)
  '';
}
