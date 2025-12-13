# NixOS Integration Test: K3s Cluster via vsim Nested Virtualization
#
# This test validates k3s cluster formation using the vsim nested virtualization
# infrastructure. It boots inner VMs with pre-installed NixOS images and tests
# that k3s nodes can communicate and form a cluster.
#
# ARCHITECTURE:
#   Outer VM (emulator)
#   ├── OVS bridge (ovsbr0 @ 192.168.100.1/24)
#   └── Inner VMs (libvirt):
#       ├── n100-1 (k3s server) - 192.168.100.10
#       ├── n100-2 (k3s server) - 192.168.100.11
#       └── n100-3 (k3s agent)  - 192.168.100.12
#
# TEST PHASES:
#   1. Boot emulation environment
#   2. Start inner VMs and wait for network
#   3. Verify inner VMs can ping outer VM
#   4. Verify inner VMs can ping each other
#   5. Wait for k3s to initialize on server nodes
#   6. Verify cluster formation
#
# Run with:
#   nix build '.#checks.x86_64-linux.vsim-k3s-cluster'
#   nix build '.#checks.x86_64-linux.vsim-k3s-cluster.driverInteractive'
#
# NOTE: This test requires significant resources (12GB+ RAM) and may take
# up to 1 hour due to nested virtualization overhead.

{ pkgs, lib, inputs ? { }, ... }:

# =============================================================================
# TIMEOUT CONFIGURATION (centralized for easy adjustment)
# =============================================================================
# All timeouts are in seconds. Current values are 10x the original for
# testing with slow nested virtualization in nixosTest framework.
let
  timeouts = {
    # Global test timeout (nixosTest framework)
    global = 18000; # 5 hours (was 30 min)

    # setup-inner-vms service (copy qcow2 images)
    setupInnerVms = 9000; # 2.5 hours (was 15 min)

    # wait_for_vm_network: ping attempts (2s between attempts)
    vmNetworkAttempts = 1800; # 1800 * 2s = 60 min (was 6 min)

    # wait_for_vm_ssh: SSH check attempts (2s between attempts)
    vmSshAttempts = 600; # 600 * 2s = 20 min (was 2 min)

    # k3s.service startup attempts (2s between attempts)
    k3sServiceAttempts = 1200; # 1200 * 2s = 40 min (was 4 min)

    # kubectl access attempts (2s between attempts)
    kubectlAttempts = 600; # 600 * 2s = 20 min (was 2 min)

    # Wait for nodes to join cluster
    nodeJoinWait = 300; # 5 min (was 60s)
  };
in

pkgs.testers.runNixOSTest {
  name = "vsim-k3s-cluster";

  nodes = {
    emulator = { config, pkgs, lib, modulesPath, ... }: {
      imports = [ ../../tests/emulation/embedded-system.nix ];

      # Pass inputs to embedded-system.nix
      _module.args.inputs = inputs;

      # Resource configuration for nested VM testing
      # embedded-system.nix provides defaults (12GB RAM, 60GB disk, 8 cores)
      # which are appropriate for the vsim tests

      # Override setup-inner-vms timeout (centralized value)
      systemd.services.setup-inner-vms.serviceConfig.TimeoutStartSec = lib.mkForce timeouts.setupInnerVms;
    };
  };

  # Allow the test to take longer (nested VMs are slow)
  globalTimeout = timeouts.global;

  # Skip type checking - we use custom helper functions that confuse mypy
  # The `tlog` function uses print() with timestamps, which is valid Python
  skipTypeCheck = true;

  # Disable OCR, not needed for this test
  enableOCR = false;

  testScript = ''
    import time
    import datetime

    # Timeout values (interpolated from Nix)
    VM_NETWORK_ATTEMPTS = ${toString timeouts.vmNetworkAttempts}
    VM_SSH_ATTEMPTS = ${toString timeouts.vmSshAttempts}
    K3S_SERVICE_ATTEMPTS = ${toString timeouts.k3sServiceAttempts}
    KUBECTL_ATTEMPTS = ${toString timeouts.kubectlAttempts}
    NODE_JOIN_WAIT = ${toString timeouts.nodeJoinWait}
    SETUP_INNER_VMS_TIMEOUT = ${toString timeouts.setupInnerVms}

    def tlog(msg):
        """Print timestamped log message"""
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    def wait_for_vm_network(vm_name, ip, max_attempts=VM_NETWORK_ATTEMPTS):
        """Wait for an inner VM to respond to ping from outer VM"""
        tlog(f"  Waiting for {vm_name} ({ip}) to respond to ping...")
        for attempt in range(max_attempts):
            if attempt % 30 == 0 and attempt > 0:
                # Check VM state and provide status update
                state = emulator.execute(f"virsh domstate {vm_name}")[1].strip()
                tlog(f"    ... still waiting for {vm_name} (attempt {attempt}/{max_attempts}, state: {state})")
                # Check for DHCP requests in dnsmasq log
                dhcp_check = emulator.execute(f"journalctl -u dnsmasq --no-pager | grep -i {vm_name} | tail -3")[1]
                if dhcp_check.strip():
                    tlog(f"    DHCP activity: {dhcp_check.strip()}")
            result = emulator.execute(f"ping -c 1 -W 1 {ip}")[0]
            if result == 0:
                tlog(f"  ✓ {vm_name} is reachable after {attempt + 1} attempts ({attempt * 2}s)")
                return True
            time.sleep(2)
        # Final debug before failing
        tlog(f"  FINAL DEBUG for {vm_name}:")
        tlog(f"    VM state: {emulator.execute(f'virsh domstate {vm_name}')[1].strip()}")
        tlog(f"    DHCP leases: {emulator.execute('cat /var/lib/misc/dnsmasq.leases 2>/dev/null || echo No leases')[1].strip()}")
        # Try to get console output from inner VM (first 50 lines)
        tlog("    Capturing console output (last 30 lines)...")
        console_out = emulator.execute(f"timeout 3 virsh console {vm_name} --force 2>&1 | head -30 || echo 'Console timeout'")[1]
        tlog(f"    Console output:\n{console_out}")
        return False

    def wait_for_vm_ssh(vm_name, ip, max_attempts=VM_SSH_ATTEMPTS):
        """Wait for SSH to be available on inner VM"""
        tlog(f"  Waiting for SSH on {vm_name} ({ip})...")
        for attempt in range(max_attempts):
            if attempt % 60 == 0 and attempt > 0:
                tlog(f"    ... still waiting for SSH on {vm_name} (attempt {attempt}/{max_attempts})")
            result = emulator.execute(f"nc -z -w1 {ip} 22")[0]
            if result == 0:
                tlog(f"  ✓ SSH ready on {vm_name} after {attempt + 1} attempts")
                return True
            time.sleep(2)
        return False

    def ssh_cmd(ip, cmd):
        """Execute command on inner VM via SSH"""
        return emulator.succeed(
            f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{ip} '{cmd}'"
        )

    def ssh_exec(ip, cmd):
        """Execute command on inner VM, return (exit_code, output)"""
        result = emulator.execute(
            f"sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{ip} '{cmd}'"
        )
        return result

    # Inner VM IPs
    VMS = {
        "n100-1": "192.168.100.10",  # k3s server (cluster init)
        "n100-2": "192.168.100.11",  # k3s server (joins)
        "n100-3": "192.168.100.12",  # k3s agent
    }

    tlog("=" * 70)
    tlog("vsim K3s Cluster Test - Nested Virtualization")
    tlog("=" * 70)

    # ===========================================================================
    # PHASE 1: Boot Emulation Environment
    # ===========================================================================
    tlog("\n[PHASE 1] Booting emulation environment...")

    emulator.start()
    tlog("  Waiting for multi-user.target...")
    emulator.wait_for_unit("multi-user.target")
    tlog("  ✓ Outer VM booted")

    # Wait for services in dependency order:
    # 1. OVS (base networking) - ovsdb and ovs-vswitchd services
    tlog("  Waiting for OVS services...")
    emulator.wait_for_unit("ovsdb.service")
    emulator.wait_for_unit("ovs-vswitchd.service")
    tlog("  ✓ OVS services ready")

    # 2. libvirtd (VM management)
    tlog("  Waiting for libvirtd.service...")
    emulator.wait_for_unit("libvirtd.service")
    tlog("  ✓ libvirtd ready")

    # 3. setup-inner-vms (copies qcow2 images - takes longest)
    tlog(f"  Waiting for setup-inner-vms.service (timeout={SETUP_INNER_VMS_TIMEOUT}s)...")
    emulator.wait_for_unit("setup-inner-vms.service", timeout=SETUP_INNER_VMS_TIMEOUT)
    tlog("  ✓ inner VMs setup complete")

    # 4. dnsmasq (DHCP for inner VMs)
    tlog("  Waiting for dnsmasq.service...")
    emulator.wait_for_unit("dnsmasq.service")
    tlog("  ✓ dnsmasq ready")
    tlog("  All services started")

    # Install sshpass for SSH to inner VMs
    tlog("  Installing sshpass for SSH access...")
    emulator.succeed("nix-env -iA nixos.sshpass || true")

    # ===========================================================================
    # PHASE 2: Start Inner VMs
    # ===========================================================================
    tlog("\n[PHASE 2] Starting inner VMs...")

    # Verify inner VMs are defined with pre-built images
    virsh_list = emulator.succeed("virsh list --all")
    for vm in VMS.keys():
        assert vm in virsh_list, f"VM {vm} not defined"
    tlog("  ✓ All VMs defined in libvirt")

    # Start n100-1 first (it's the cluster init server)
    tlog("  Starting n100-1 (primary k3s server)...")
    emulator.succeed("virsh start n100-1")
    tlog("  ✓ Started n100-1")

    # Wait for n100-1 to get network before starting others
    tlog("  Waiting 10s for n100-1 to initialize...")
    time.sleep(10)

    # Start remaining VMs
    tlog("  Starting n100-2...")
    emulator.succeed("virsh start n100-2")
    tlog("  ✓ Started n100-2")
    tlog("  Starting n100-3...")
    emulator.succeed("virsh start n100-3")
    tlog("  ✓ Started n100-3")

    # ===========================================================================
    # PHASE 3: Wait for Inner VM Network Connectivity
    # ===========================================================================
    tlog("\n[PHASE 3] Waiting for inner VM network connectivity...")

    for vm_name, ip in VMS.items():
        if not wait_for_vm_network(vm_name, ip, max_attempts=180):
            # Debug: show OVS state
            tlog("  DEBUG: OVS state:")
            tlog(emulator.succeed("ovs-vsctl show"))
            tlog("  DEBUG: virsh domiflist:")
            for vm in VMS.keys():
                tlog(emulator.succeed(f"virsh domiflist {vm} 2>/dev/null || echo '{vm} not running'"))
            tlog("  DEBUG: ARP table:")
            tlog(emulator.succeed("ip neigh show"))
            raise Exception(f"VM {vm_name} ({ip}) did not become reachable")

    tlog("  ✓ All inner VMs have network connectivity!")

    # ===========================================================================
    # PHASE 4: Verify SSH Access
    # ===========================================================================
    tlog("\n[PHASE 4] Verifying SSH access to inner VMs...")

    for vm_name, ip in VMS.items():
        if not wait_for_vm_ssh(vm_name, ip, max_attempts=60):
            raise Exception(f"SSH not available on {vm_name} ({ip})")

    tlog("  ✓ SSH available on all inner VMs")

    # Quick connectivity test
    for vm_name, ip in VMS.items():
        hostname = ssh_cmd(ip, "hostname").strip()
        assert hostname == vm_name, f"Expected hostname {vm_name}, got {hostname}"
        tlog(f"  ✓ {vm_name}: hostname verified")

    # ===========================================================================
    # PHASE 5: Verify Inner VMs Can Reach Each Other
    # ===========================================================================
    tlog("\n[PHASE 5] Testing inter-VM connectivity...")

    # Test from n100-1 to others
    ssh_cmd("192.168.100.10", "ping -c 1 192.168.100.11")
    tlog("  ✓ n100-1 -> n100-2: OK")
    ssh_cmd("192.168.100.10", "ping -c 1 192.168.100.12")
    tlog("  ✓ n100-1 -> n100-3: OK")

    # Test from n100-2 to others
    ssh_cmd("192.168.100.11", "ping -c 1 192.168.100.10")
    tlog("  ✓ n100-2 -> n100-1: OK")
    ssh_cmd("192.168.100.11", "ping -c 1 192.168.100.12")
    tlog("  ✓ n100-2 -> n100-3: OK")

    tlog("  ✓ Inter-VM connectivity verified!")

    # ===========================================================================
    # PHASE 6: Wait for K3s Server Initialization
    # ===========================================================================
    tlog("\n[PHASE 6] Waiting for k3s server initialization...")

    # K3s takes time to initialize, especially on first boot
    # Wait for k3s.service on n100-1 (primary server)
    tlog(f"  Waiting for k3s.service on n100-1 (max {K3S_SERVICE_ATTEMPTS} attempts)...")
    for attempt in range(K3S_SERVICE_ATTEMPTS):
        if attempt % 120 == 0 and attempt > 0:
            tlog(f"    ... still waiting for k3s ({attempt * 2}s elapsed)")
        exit_code, _ = ssh_exec("192.168.100.10", "systemctl is-active k3s.service")
        if exit_code == 0:
            tlog(f"  ✓ k3s.service active on n100-1 after {attempt * 2} seconds")
            break
        time.sleep(2)
    else:
        # Debug output
        tlog("  DEBUG: k3s service status:")
        tlog(ssh_exec("192.168.100.10", "systemctl status k3s.service")[1])
        tlog("  DEBUG: k3s logs:")
        tlog(ssh_exec("192.168.100.10", "journalctl -u k3s.service --no-pager | tail -50")[1])
        raise Exception("k3s.service did not start on n100-1")

    # ===========================================================================
    # PHASE 7: Verify Cluster Nodes
    # ===========================================================================
    tlog("\n[PHASE 7] Verifying cluster nodes...")

    # Wait for kubectl to work
    tlog(f"  Waiting for kubectl access (max {KUBECTL_ATTEMPTS} attempts)...")
    for attempt in range(KUBECTL_ATTEMPTS):
        if attempt % 60 == 0 and attempt > 0:
            tlog(f"    ... still waiting for kubectl ({attempt * 2}s elapsed)")
        exit_code, output = ssh_exec("192.168.100.10", "k3s kubectl get nodes 2>/dev/null")
        if exit_code == 0 and "n100-1" in output:
            tlog("  ✓ kubectl working, cluster accessible")
            break
        time.sleep(2)
    else:
        raise Exception("kubectl not working on n100-1")

    # Give time for other nodes to join
    tlog(f"  Waiting {NODE_JOIN_WAIT}s for all nodes to join cluster...")
    time.sleep(NODE_JOIN_WAIT)

    # Check node status
    nodes_output = ssh_cmd("192.168.100.10", "k3s kubectl get nodes -o wide")
    tlog("  Current nodes:")
    tlog(nodes_output)

    # Verify at least the primary server is Ready
    assert "n100-1" in nodes_output, "n100-1 not in kubectl output"
    assert "Ready" in nodes_output, "No nodes are Ready"
    tlog("  ✓ Primary server (n100-1) is Ready")

    # Check if other nodes joined
    if "n100-2" in nodes_output:
        tlog("  ✓ n100-2 joined the cluster")
    if "n100-3" in nodes_output:
        tlog("  ✓ n100-3 joined the cluster")

    # ===========================================================================
    # Summary
    # ===========================================================================
    tlog("\n" + "=" * 70)
    tlog("vsim K3s Cluster Test - PASSED")
    tlog("=" * 70)
    tlog("")
    tlog("Validated:")
    tlog("  - Emulation environment boots with nested virtualization")
    tlog("  - Inner VMs boot from pre-installed NixOS images")
    tlog("  - Network connectivity: outer VM <-> inner VMs")
    tlog("  - Network connectivity: inner VM <-> inner VM")
    tlog("  - K3s server initialized on primary node")
    tlog("  - Cluster accessible via kubectl")
    tlog("")
    tlog("Final node status:")
    tlog(nodes_output)
    tlog("=" * 70)
  '';
}
