# K3s Bond Failover Test
#
# Tests that bonding active-backup mode correctly fails over when
# the primary interface goes down, and that k3s cluster remains
# operational throughout the failover/failback cycle.
#
# USAGE:
#   nix build '.#checks.x86_64-linux.k3s-bond-failover'
#
# REQUIREMENTS:
#   - Uses bonding-vlans network profile (two NICs bonded)
#   - Primary interface: eth1
#   - Backup interface: eth2
#   - Mode: active-backup with PrimaryReselectPolicy=always
#
# TEST SCENARIOS:
#   1. Verify initial bond state (eth1 active)
#   2. Simulate primary NIC failure (ip link set eth1 down)
#   3. Verify failover to backup (eth2 becomes active)
#   4. Verify k3s API remains accessible
#   5. Restore primary (ip link set eth1 up)
#   6. Verify failback to primary (eth1 becomes active again)
#   7. Verify all nodes still Ready

{ pkgs, lib, inputs ? { }, ... }:

let
  mkK3sClusterTest = import ../lib/mk-k3s-cluster-test.nix;
in
mkK3sClusterTest {
  inherit pkgs lib;
  networkProfile = "bonding-vlans";
  testName = "k3s-bond-failover";

  testScript = ''
    def tlog(msg):
        """Print timestamped log message"""
        import datetime
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    def get_active_slave(node):
        """Extract the currently active slave from bond status"""
        bond_status = node.succeed("cat /proc/net/bonding/bond0")
        for line in bond_status.split("\n"):
            if "Currently Active Slave:" in line:
                return line.split(":")[1].strip()
        return None

    tlog("=" * 70)
    tlog("K3s Bond Failover Test")
    tlog("=" * 70)
    tlog("Network Profile: bonding-vlans (active-backup)")
    tlog("Test Focus: Bond failover and failback during k3s operation")
    tlog("=" * 70)

    # PHASE 1: Boot All Nodes
    tlog("\n[PHASE 1] Booting all nodes...")
    start_all()

    n100_1.wait_for_unit("multi-user.target")
    tlog("  n100-1 booted")
    n100_2.wait_for_unit("multi-user.target")
    tlog("  n100-2 booted")
    n100_3.wait_for_unit("multi-user.target")
    tlog("  n100-3 booted")

    # PHASE 2: Verify Initial Bond Configuration
    tlog("\n[PHASE 2] Verifying initial bond configuration...")

    for node, name in [(n100_1, "n100-1"), (n100_2, "n100-2"), (n100_3, "n100-3")]:
        # Verify bond0 exists
        interfaces = node.succeed("ip -br link show")
        assert "bond0" in interfaces, f"Missing bond0 on {name}"

        # Verify both slaves are up
        bond_status = node.succeed("cat /proc/net/bonding/bond0")
        assert "eth1" in bond_status, f"eth1 not in bond0 on {name}"
        assert "eth2" in bond_status, f"eth2 not in bond0 on {name}"

        # Verify eth1 is initially active (primary)
        active_slave = get_active_slave(node)
        assert active_slave == "eth1", f"Expected eth1 as active slave on {name}, got {active_slave}"
        tlog(f"  {name}: bond0 active with eth1 as primary")

    tlog("  Initial bond configuration verified!")

    # PHASE 3: Wait for K3s Cluster Formation
    tlog("\n[PHASE 3] Waiting for k3s cluster formation...")

    n100_1.wait_for_unit("k3s.service")
    tlog("  n100-1 k3s.service started")

    n100_1.wait_for_open_port(6443)
    tlog("  API server port 6443 open")

    n100_1.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=300)
    tlog("  API server is ready")

    # Give etcd time to stabilize
    import time
    time.sleep(10)

    # Wait for all nodes
    n100_2.wait_for_unit("k3s.service")
    n100_3.wait_for_unit("k3s.service")

    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=300
    )
    tlog("  All 3 nodes Ready")

    nodes_output = n100_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Cluster nodes:\n{nodes_output}")

    # PHASE 4: Pre-Failover Cluster Status
    tlog("\n[PHASE 4] Recording pre-failover cluster status...")

    pre_nodes = n100_1.succeed("k3s kubectl get nodes --no-headers").strip()
    pre_ready_count = len([l for l in pre_nodes.split("\n") if "Ready" in l and "NotReady" not in l])
    tlog(f"  Pre-failover: {pre_ready_count} nodes Ready")

    # PHASE 5: Simulate Primary NIC Failure on n100-1
    tlog("\n[PHASE 5] Simulating eth1 failure on n100-1...")

    # Record active slave before failure
    active_before = get_active_slave(n100_1)
    tlog(f"  Active slave before failure: {active_before}")

    # Bring down primary interface
    n100_1.succeed("ip link set eth1 down")
    tlog("  eth1 brought down")

    # Allow bond to detect failure (miimon=100ms, DownDelaySec=200ms)
    time.sleep(1)

    # PHASE 6: Verify Failover
    tlog("\n[PHASE 6] Verifying failover to eth2...")

    active_after = get_active_slave(n100_1)
    assert active_after == "eth2", f"Expected eth2 as active slave after failure, got {active_after}"
    tlog(f"  Active slave after failure: {active_after} (failover successful!)")

    # Verify bond is still up
    bond_state = n100_1.succeed("ip link show bond0")
    assert "state UP" in bond_state, "bond0 should still be UP after failover"
    tlog("  bond0 state: UP")

    # PHASE 7: Verify K3s Cluster Operational After Failover
    tlog("\n[PHASE 7] Verifying k3s cluster operational after failover...")

    # API should still be accessible
    n100_1.wait_until_succeeds("k3s kubectl get nodes", timeout=60)
    tlog("  k3s API accessible")

    # Give cluster time to process any transient effects
    time.sleep(5)

    # Check node status (may show transient NotReady during network reconfiguration)
    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'n100-1' | grep -w Ready",
        timeout=120
    )
    tlog("  n100-1 still Ready after failover")

    nodes_during = n100_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Nodes during failover:\n{nodes_during}")

    # PHASE 8: Restore Primary Interface
    tlog("\n[PHASE 8] Restoring eth1...")

    n100_1.succeed("ip link set eth1 up")
    tlog("  eth1 brought up")

    # Allow bond to detect recovery and reselect (UpDelaySec=200ms + PrimaryReselectPolicy=always)
    time.sleep(2)

    # PHASE 9: Verify Failback
    tlog("\n[PHASE 9] Verifying failback to eth1...")

    # With PrimaryReselectPolicy=always, bond should switch back to eth1
    active_failback = get_active_slave(n100_1)
    assert active_failback == "eth1", f"Expected eth1 as active slave after failback, got {active_failback}"
    tlog(f"  Active slave after failback: {active_failback} (failback successful!)")

    # Verify eth1 is now MII Status: up
    bond_status = n100_1.succeed("cat /proc/net/bonding/bond0")
    tlog(f"  Bond status after failback:\n{bond_status}")

    # PHASE 10: Final Cluster Verification
    tlog("\n[PHASE 10] Final cluster verification...")

    # Allow cluster to stabilize
    time.sleep(5)

    # Verify all nodes still Ready
    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=120
    )
    tlog("  All 3 nodes Ready after failover/failback cycle")

    final_nodes = n100_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Final cluster nodes:\n{final_nodes}")

    # Verify system pods still running
    n100_1.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep Running",
        timeout=60
    )
    tlog("  CoreDNS still running")

    # Summary
    tlog("\n" + "=" * 70)
    tlog("K3s Bond Failover Test - PASSED")
    tlog("=" * 70)
    tlog("Validated:")
    tlog("  - Initial bond state: eth1 (primary) active")
    tlog("  - Failover: eth1 down -> eth2 became active")
    tlog("  - K3s API accessible during failover")
    tlog("  - Failback: eth1 up -> eth1 became active again")
    tlog("  - All 3 nodes Ready throughout cycle")
    tlog("  - System pods (CoreDNS) still running")
    tlog("=" * 70)
  '';
}
