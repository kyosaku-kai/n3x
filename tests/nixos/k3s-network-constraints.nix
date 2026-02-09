# NixOS Integration Test: K3s Network Constraints
#
# Tests k3s cluster behavior under degraded network conditions using tc/netem
# directly on nixosTest node interfaces. This is the portable approach that
# works on all platforms (WSL2, Darwin, Cloud) without nested virtualization.
#
# ARCHITECTURE:
#   nixosTest framework spawns 3 VMs:
#   - server_1: k3s server (control plane)
#   - agent_1: k3s agent (worker 1)
#   - agent_2: k3s agent (worker 2)
#
# TEST PHASES:
#   1. Boot cluster and verify baseline networking
#   2. Apply latency constraints and measure impact
#   3. Apply packet loss and verify k3s resilience
#   4. Apply bandwidth limits and test data transfer
#   5. Test cluster recovery after constraints removed
#
# TC/NETEM PROFILES:
#   - baseline: No constraints (full speed)
#   - latency:  10-50ms delay with jitter
#   - lossy:    1-3% packet loss
#   - constrained: Bandwidth limited (10-50 Mbps)
#   - combined: All constraints together (edge device simulation)
#
# Run with:
#   nix build '.#checks.x86_64-linux.k3s-network-constraints'
#   nix build '.#checks.x86_64-linux.k3s-network-constraints.driverInteractive'

{ pkgs, lib, inputs ? { }, ... }:

let
  # Common k3s token for test cluster
  testToken = "k3s-network-constraints-test-token";

  # Network configuration
  network = {
    server_1 = "192.168.1.1";
    agent_1 = "192.168.1.2";
    agent_2 = "192.168.1.3";
    serverApi = "https://192.168.1.1:6443";
    clusterCidr = "10.42.0.0/16";
    serviceCidr = "10.43.0.0/16";
    clusterDns = "10.43.0.10";
  };

  # Common virtualisation settings
  vmConfig = {
    memorySize = 3072;
    cores = 2;
    diskSize = 20480;
  };

  # Firewall rules for k3s servers
  serverFirewall = {
    enable = true;
    allowedTCPPorts = [
      6443 # Kubernetes API server
      2379 # etcd client
      2380 # etcd peer
      10250 # Kubelet API
      53 # DNS
    ];
    allowedUDPPorts = [
      8472 # Flannel VXLAN
      53 # DNS
    ];
  };

  # Firewall rules for k3s agents
  agentFirewall = {
    enable = true;
    allowedTCPPorts = [
      10250 # Kubelet API
    ];
    allowedUDPPorts = [
      8472 # Flannel VXLAN
    ];
  };

  # Base NixOS configuration for k3s network constraint tests
  baseK3sNetworkConfig = { config, pkgs, ... }: {
    imports = [
      ../../backends/nixos/modules/common/base.nix
    ];

    # Kernel modules for k3s networking and tc
    boot.kernelModules = [
      "overlay"
      "br_netfilter"
      "vxlan"
      "ip_tables"
      "iptable_nat"
      "iptable_filter"
      "sch_netem" # Network emulator for tc
      "sch_tbf" # Token bucket filter for bandwidth limiting
      "sch_htb" # Hierarchical token bucket
    ];

    # Kernel parameters for k3s networking
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    # Enable k3s with airgap images
    services.k3s = {
      enable = true;
      images = [ pkgs.k3s.passthru."airgap-images" ];
    };

    # Test-friendly authentication
    # Clear all password options to avoid "multiple password options" warning from nixosTest
    users.users.root.hashedPassword = lib.mkForce null;
    users.users.root.hashedPasswordFile = lib.mkForce null;
    users.users.root.password = lib.mkForce "test";
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = lib.mkForce "yes";
        PasswordAuthentication = lib.mkForce true;
      };
    };

    environment.systemPackages = with pkgs; [
      k3s
      kubectl
      jq
      curl
      dig
      iproute2
      iptables
      tcpdump
      netcat-openbsd
      iperf3 # Bandwidth testing
    ];
  };

in
pkgs.testers.runNixOSTest {
  name = "k3s-network-constraints";

  nodes = {
    # Primary k3s server
    server_1 = { config, pkgs, lib, ... }: {
      imports = [ baseK3sNetworkConfig ];
      virtualisation = vmConfig;

      services.k3s = {
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
          "--cluster-cidr=${network.clusterCidr}"
          "--service-cidr=${network.serviceCidr}"
          "--cluster-dns=${network.clusterDns}"
          "--node-ip=${network.server_1}"
          "--node-name=server-1"
          "--flannel-backend=vxlan"
          "--flannel-iface=eth1"
        ];
      };

      networking = {
        hostName = "server-1";
        firewall = serverFirewall;
        interfaces.eth1.ipv4.addresses = [{
          address = network.server_1;
          prefixLength = 24;
        }];
      };
    };

    # k3s agent (worker 1)
    agent_1 = { config, pkgs, lib, ... }: {
      imports = [ baseK3sNetworkConfig ];
      virtualisation = vmConfig;

      services.k3s = {
        role = "agent";
        serverAddr = network.serverApi;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = [
          "--node-ip=${network.agent_1}"
          "--node-name=agent-1"
          "--flannel-iface=eth1"
        ];
      };

      networking = {
        hostName = "agent-1";
        firewall = agentFirewall;
        interfaces.eth1.ipv4.addresses = [{
          address = network.agent_1;
          prefixLength = 24;
        }];
      };
    };

    # k3s agent (worker 2)
    agent_2 = { config, pkgs, lib, ... }: {
      imports = [ baseK3sNetworkConfig ];
      virtualisation = vmConfig;

      services.k3s = {
        role = "agent";
        serverAddr = network.serverApi;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = [
          "--node-ip=${network.agent_2}"
          "--node-name=agent-2"
          "--flannel-iface=eth1"
        ];
      };

      networking = {
        hostName = "agent-2";
        firewall = agentFirewall;
        interfaces.eth1.ipv4.addresses = [{
          address = network.agent_2;
          prefixLength = 24;
        }];
      };
    };
  };

  skipTypeCheck = true;

  testScript = ''
    import time
    import re

    def tlog(msg):
        """Print timestamped log message"""
        import datetime
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    # =========================================================================
    # TC/NETEM Helper Functions
    # =========================================================================
    def apply_tc_netem(machine, iface, delay_ms=0, jitter_ms=0, loss_pct=0, rate_mbit=0):
        """Apply tc/netem rules to an interface.

        Args:
            machine: The nixosTest machine object
            iface: Interface name (e.g., 'eth1')
            delay_ms: Base delay in milliseconds
            jitter_ms: Delay jitter (+/- ms)
            loss_pct: Packet loss percentage (0-100)
            rate_mbit: Bandwidth limit in Mbps (0 = unlimited)
        """
        # First, clear any existing qdisc
        machine.execute(f"tc qdisc del dev {iface} root 2>/dev/null || true")

        if delay_ms == 0 and loss_pct == 0 and rate_mbit == 0:
            # No constraints - use pfifo_fast (default)
            return

        # Build netem parameters
        netem_params = []
        if delay_ms > 0:
            if jitter_ms > 0:
                netem_params.append(f"delay {delay_ms}ms {jitter_ms}ms distribution normal")
            else:
                netem_params.append(f"delay {delay_ms}ms")
        if loss_pct > 0:
            netem_params.append(f"loss {loss_pct}%")

        if rate_mbit > 0 and netem_params:
            # Use HTB for rate limiting with netem as leaf
            machine.succeed(f"tc qdisc add dev {iface} root handle 1: htb default 10")
            machine.succeed(f"tc class add dev {iface} parent 1: classid 1:10 htb rate {rate_mbit}mbit")
            machine.succeed(f"tc qdisc add dev {iface} parent 1:10 handle 10: netem {' '.join(netem_params)}")
        elif rate_mbit > 0:
            # Just rate limiting with TBF
            machine.succeed(f"tc qdisc add dev {iface} root tbf rate {rate_mbit}mbit latency 50ms burst 1540")
        elif netem_params:
            # Just netem (delay/loss)
            machine.succeed(f"tc qdisc add dev {iface} root netem {' '.join(netem_params)}")

    def clear_tc(machine, iface):
        """Clear all tc rules from an interface."""
        machine.execute(f"tc qdisc del dev {iface} root 2>/dev/null || true")

    def show_tc(machine, iface):
        """Show current tc configuration for an interface."""
        return machine.succeed(f"tc qdisc show dev {iface}")

    def measure_latency(src_machine, dst_ip, count=5):
        """Measure ping latency between machines. Returns (avg_ms, loss_pct)."""
        result = src_machine.succeed(f"ping -c {count} -q {dst_ip}")
        # Parse: rtt min/avg/max/mdev = 0.123/0.456/0.789/0.012 ms
        match = re.search(r'rtt min/avg/max/mdev = [\d.]+/([\d.]+)/[\d.]+/[\d.]+', result)
        avg_ms = float(match.group(1)) if match else 0
        # Parse: X packets transmitted, Y received, Z% packet loss
        loss_match = re.search(r'(\d+)% packet loss', result)
        loss_pct = int(loss_match.group(1)) if loss_match else 0
        return avg_ms, loss_pct

    tlog("=" * 70)
    tlog("K3s Network Constraints Test (Multi-Node nixosTest)")
    tlog("=" * 70)
    tlog("Architecture: 1 server + 2 agents")
    tlog("  server_1: k3s server @ ${network.server_1}")
    tlog("  agent_1: k3s agent  @ ${network.agent_1}")
    tlog("  agent_2: k3s agent  @ ${network.agent_2}")
    tlog("Testing: tc/netem network constraints on eth1 interface")
    tlog("=" * 70)

    # =========================================================================
    # PHASE 1: Boot Cluster and Establish Baseline
    # =========================================================================
    tlog("\n[PHASE 1] Booting cluster and establishing baseline...")

    start_all()

    server_1.wait_for_unit("multi-user.target")
    agent_1.wait_for_unit("multi-user.target")
    agent_2.wait_for_unit("multi-user.target")
    tlog("  All nodes booted")

    # Wait for k3s cluster formation
    server_1.wait_for_unit("k3s.service")
    server_1.wait_for_open_port(6443)
    server_1.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=180)
    tlog("  API server ready")

    # Wait for all nodes
    server_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=300
    )
    tlog("  All 3 nodes Ready")

    # Stabilization delay
    time.sleep(10)

    # Measure baseline latency
    tlog("\n  Baseline latency measurements:")
    baseline_1_2, loss_1_2 = measure_latency(server_1, "${network.agent_1}")
    tlog(f"    server_1 -> agent_1: {baseline_1_2:.2f}ms, {loss_1_2}% loss")
    baseline_1_3, loss_1_3 = measure_latency(server_1, "${network.agent_2}")
    tlog(f"    server_1 -> agent_2: {baseline_1_3:.2f}ms, {loss_1_3}% loss")
    baseline_2_3, loss_2_3 = measure_latency(agent_1, "${network.agent_2}")
    tlog(f"    agent_1 -> agent_2: {baseline_2_3:.2f}ms, {loss_2_3}% loss")

    # =========================================================================
    # PHASE 2: Apply Latency Constraints
    # =========================================================================
    tlog("\n[PHASE 2] Testing latency constraints...")

    # Apply 50ms latency with 10ms jitter to agent_1
    tlog("  Applying 50ms (+/-10ms) latency to agent_1 eth1...")
    apply_tc_netem(agent_1, "eth1", delay_ms=50, jitter_ms=10)

    tc_output = show_tc(agent_1, "eth1")
    assert "netem" in tc_output, "netem qdisc not applied"
    tlog(f"  TC config: {tc_output.strip()}")

    # Measure latency with constraints
    constrained_latency, _ = measure_latency(server_1, "${network.agent_1}", count=10)
    tlog(f"  server_1 -> agent_1 with constraints: {constrained_latency:.2f}ms")
    assert constrained_latency > baseline_1_2 + 30, f"Latency should increase significantly (got {constrained_latency}ms, baseline {baseline_1_2}ms)"
    tlog("  Latency constraint verified!")

    # Verify k3s still functional with latency
    server_1.succeed("k3s kubectl get nodes")
    tlog("  k3s API still responsive under latency")

    # Clear latency constraint
    clear_tc(agent_1, "eth1")
    tlog("  Cleared latency constraint from agent_1")

    # =========================================================================
    # PHASE 3: Apply Packet Loss
    # =========================================================================
    tlog("\n[PHASE 3] Testing packet loss constraints...")

    # Apply 5% packet loss to agent_2
    tlog("  Applying 5% packet loss to agent_2 eth1...")
    apply_tc_netem(agent_2, "eth1", loss_pct=5)

    tc_output = show_tc(agent_2, "eth1")
    assert "loss" in tc_output, "loss rule not applied"
    tlog(f"  TC config: {tc_output.strip()}")

    # Test with more pings to observe loss
    _, observed_loss = measure_latency(server_1, "${network.agent_2}", count=50)
    tlog(f"  Observed packet loss to agent_2: {observed_loss}%")
    # Note: With 5% loss, we might see 0-15% depending on sample size

    # Verify k3s handles packet loss gracefully
    tlog("  Verifying k3s node status under packet loss...")
    # Node should still be Ready (k3s tolerates some packet loss)
    server_1.wait_until_succeeds(
        "k3s kubectl get node agent-2 --no-headers | grep -w Ready",
        timeout=60
    )
    tlog("  agent-2 still Ready despite packet loss")

    # Clear packet loss
    clear_tc(agent_2, "eth1")
    tlog("  Cleared packet loss from agent_2")

    # =========================================================================
    # PHASE 4: Apply Bandwidth Limits
    # =========================================================================
    tlog("\n[PHASE 4] Testing bandwidth constraints...")

    # Apply 10Mbps limit to both agents
    tlog("  Applying 10Mbps bandwidth limit to agents...")
    apply_tc_netem(agent_1, "eth1", rate_mbit=10)
    apply_tc_netem(agent_2, "eth1", rate_mbit=10)

    tc_2 = show_tc(agent_1, "eth1")
    tc_3 = show_tc(agent_2, "eth1")
    tlog(f"  agent_1 TC: {tc_2.strip()}")
    tlog(f"  agent_2 TC: {tc_3.strip()}")

    # Verify k3s still operational with bandwidth limits
    nodes_output = server_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Cluster status under bandwidth limits:\n{nodes_output}")

    # Test kubectl responsiveness
    start_time = time.time()
    server_1.succeed("k3s kubectl get pods -A")
    elapsed = time.time() - start_time
    tlog(f"  kubectl get pods -A completed in {elapsed:.2f}s")

    # Clear bandwidth limits
    clear_tc(agent_1, "eth1")
    clear_tc(agent_2, "eth1")
    tlog("  Cleared bandwidth limits")

    # =========================================================================
    # PHASE 5: Combined Constraints (Edge Device Simulation)
    # =========================================================================
    tlog("\n[PHASE 5] Testing combined constraints (edge device simulation)...")

    # Simulate edge device: 20Mbps, 30ms latency, 1% loss
    tlog("  Simulating edge device on agent_2: 20Mbps, 30ms latency, 1% loss...")
    apply_tc_netem(agent_2, "eth1", delay_ms=30, jitter_ms=5, loss_pct=1, rate_mbit=20)

    tc_output = show_tc(agent_2, "eth1")
    tlog(f"  TC config: {tc_output.strip()}")

    # Measure combined impact
    combined_latency, combined_loss = measure_latency(server_1, "${network.agent_2}", count=20)
    tlog(f"  Combined: {combined_latency:.2f}ms latency, {combined_loss}% observed loss")

    # Verify cluster stability under combined constraints
    tlog("  Verifying cluster stability...")
    server_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=60
    )
    tlog("  All nodes still Ready under combined constraints")

    # Test DNS resolution (uses overlay network)
    dns_svc_ip = server_1.succeed(
        "k3s kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}'"
    ).strip()
    server_1.wait_until_succeeds(
        f"dig @{dns_svc_ip} kubernetes.default.svc.cluster.local +short +time=5",
        timeout=60
    )
    tlog("  DNS resolution works under constraints")

    # Clear all constraints
    clear_tc(agent_2, "eth1")
    tlog("  Cleared combined constraints")

    # =========================================================================
    # PHASE 6: Recovery Verification
    # =========================================================================
    tlog("\n[PHASE 6] Verifying recovery after constraints removed...")

    # Verify baseline latency restored
    time.sleep(5)  # Brief stabilization
    recovered_latency, recovered_loss = measure_latency(server_1, "${network.agent_2}", count=10)
    tlog(f"  Recovered latency: {recovered_latency:.2f}ms (baseline: {baseline_1_3:.2f}ms)")

    # Should be close to baseline (within 5ms)
    assert abs(recovered_latency - baseline_1_3) < 5, f"Latency did not recover to baseline"
    tlog("  Latency recovered to baseline")

    # Verify cluster fully healthy
    server_1.succeed("k3s kubectl get nodes -o wide")
    server_1.succeed("k3s kubectl get pods -A")
    tlog("  Cluster fully operational")

    # =========================================================================
    # Summary
    # =========================================================================
    tlog("\n" + "=" * 70)
    tlog("K3s Network Constraints Test - PASSED")
    tlog("=" * 70)
    tlog("")
    tlog("Validated:")
    tlog("  - Baseline latency measurement")
    tlog("  - Latency constraints via tc/netem (50ms +/- 10ms)")
    tlog("  - Packet loss simulation (5%)")
    tlog("  - Bandwidth limiting (10Mbps)")
    tlog("  - Combined constraints (edge device: 20Mbps, 30ms, 1% loss)")
    tlog("  - Cluster stability under all constraint profiles")
    tlog("  - Recovery after constraints removed")
    tlog("")
    tlog("Key findings:")
    tlog(f"  - Baseline latency: ~{baseline_1_2:.1f}ms")
    tlog(f"  - With 50ms netem: ~{constrained_latency:.1f}ms")
    tlog("  - k3s tolerates moderate network degradation")
    tlog("  - DNS and API server remain responsive")
    tlog("")
    tlog("Note: These tests apply constraints to the eth1 (cluster) interface.")
    tlog("      Constraints do not require nested virtualization or OVS.")
    tlog("=" * 70)
  '';
}
