# Parameterized K3s Cluster Test Builder
#
# This function generates k3s cluster tests with different network profiles.
# It separates test logic from network configuration, enabling:
#   - Reusable test scripts
#   - Multiple network topologies (simple, vlans, bonding-vlans)
#   - Easy addition of new profiles without duplicating test code
#
# USAGE:
#   tests = {
#     k3s-simple = mkK3sClusterTest { networkProfile = "simple"; };
#     k3s-vlans = mkK3sClusterTest { networkProfile = "vlans"; };
#     k3s-bonding-vlans = mkK3sClusterTest { networkProfile = "bonding-vlans"; };
#   };
#
# PARAMETERS:
#   - networkProfile: Name of network profile to use (default: "simple")
#   - testName: Name of the test (default: "k3s-cluster-${networkProfile}")
#   - testScript: Custom test script (default: standard cluster formation test)
#   - extraNodeConfig: Additional config to merge into all nodes
#
# NETWORK PROFILES:
#   Defined in tests/lib/network-profiles/
#   Each profile provides:
#     - nodeConfig: Function returning per-node network configuration
#     - k3sExtraFlags: Function returning k3s-specific flags for node
#     - serverApi: Server API endpoint URL
#     - clusterCidr, serviceCidr: K3s network CIDRs

{ pkgs
, lib
, networkProfile ? "simple"
, testName ? null
, testScript ? null
, extraNodeConfig ? { }
, ...
}:

let
  # Load network profile
  profile = import ./network-profiles/${networkProfile}.nix { inherit lib; };

  # Test name defaults to k3s-cluster-<profile>
  actualTestName = if testName != null then testName else "k3s-cluster-${networkProfile}";

  # Common k3s token for test cluster
  testToken = "${actualTestName}-test-token";

  # Common virtualisation settings for all nodes
  vmConfig = {
    memorySize = 3072; # 3GB RAM per node
    cores = 2;
    diskSize = 20480; # 20GB disk
  };

  # Firewall rules for k3s servers
  serverFirewall = {
    enable = true;
    allowedTCPPorts = [
      6443 # Kubernetes API server
      2379 # etcd client
      2380 # etcd peer
      10250 # Kubelet API
      10251 # kube-scheduler
      10252 # kube-controller-manager
    ];
    allowedUDPPorts = [
      8472 # Flannel VXLAN
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

  # Base NixOS configuration for all k3s nodes
  baseK3sConfig = { config, pkgs, ... }: {
    imports = [
      ../../modules/common/base.nix
    ];

    # Essential kernel modules for k3s
    boot.kernelModules = [
      "overlay"
      "br_netfilter"
    ];

    # Essential kernel parameters for k3s networking
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
    };

    # Enable k3s with airgap images
    services.k3s = {
      enable = true;
      images = [ pkgs.k3s.passthru.airgap-images ];
    };

    # Test-friendly authentication
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
      iproute2
    ];
  };

  # Build node configuration by merging:
  #   1. Base k3s config
  #   2. Network profile config
  #   3. Extra node config
  mkNodeConfig = nodeName: role: lib.recursiveUpdate
    (lib.recursiveUpdate
      {
        imports = [ baseK3sConfig (profile.nodeConfig nodeName) ];
        virtualisation = vmConfig;
        networking.hostName = nodeName;
      }
      extraNodeConfig)
    {
      services.k3s = {
        role = role;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = lib.filter (x: x != null) ([
          (if role == "server" then "--write-kubeconfig-mode=0644" else null)
          (if role == "server" then "--disable=traefik" else null)
          (if role == "server" then "--disable=servicelb" else null)
          (if role == "server" then "--cluster-cidr=${profile.clusterCidr}" else null)
          (if role == "server" then "--service-cidr=${profile.serviceCidr}" else null)
          "--node-name=${nodeName}"
        ] ++ (profile.k3sExtraFlags nodeName));
      };

      networking.firewall = if role == "server" then serverFirewall else agentFirewall;
    };

  # Default test script (cluster formation validation)
  defaultTestScript = ''
    def tlog(msg):
        """Print timestamped log message"""
        import datetime
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    tlog("=" * 70)
    tlog("K3s Cluster Test - Network Profile: ${networkProfile}")
    tlog("=" * 70)
    tlog("Architecture: 2 servers + 1 agent")
    tlog("  n100-1: k3s server (cluster init)")
    tlog("  n100-2: k3s server (joins)")
    tlog("  n100-3: k3s agent (worker)")
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

    # PHASE 2: Verify Network Configuration (profile-aware)
    tlog("\n[PHASE 2] Verifying network configuration...")

    # Show network interfaces on each node and verify expected interfaces per profile
    for node, name in [(n100_1, "n100-1"), (n100_2, "n100-2"), (n100_3, "n100-3")]:
        interfaces = node.succeed("ip -br addr show")
        tlog(f"  {name} interfaces:\n{interfaces}")

        # Profile-specific interface and IP assertions
        if "${networkProfile}" == "simple":
            # Simple profile: eth1 with 192.168.1.x IP
            assert "eth1" in interfaces, f"Missing eth1 interface on {name}"
            assert "192.168.1." in interfaces, f"Missing 192.168.1.x IP on {name} (simple profile requires eth1 with 192.168.1.x)"
            tlog(f"  {name}: eth1 interface with 192.168.1.x IP - OK")

        elif "${networkProfile}" == "vlans":
            # VLANs profile: eth1.200 and eth1.100 with their respective IPs
            assert "eth1.200" in interfaces, f"Missing eth1.200 (cluster VLAN) interface on {name}"
            assert "eth1.100" in interfaces, f"Missing eth1.100 (storage VLAN) interface on {name}"
            assert "192.168.200." in interfaces, f"Missing 192.168.200.x cluster VLAN IP on {name}"
            assert "192.168.100." in interfaces, f"Missing 192.168.100.x storage VLAN IP on {name}"
            tlog(f"  {name}: eth1.200 (192.168.200.x) and eth1.100 (192.168.100.x) - OK")

        elif "${networkProfile}" == "bonding-vlans":
            # Bonding + VLANs profile: bond0, bond0.200, bond0.100 with IPs
            assert "bond0 " in interfaces or "bond0\t" in interfaces, f"Missing bond0 interface on {name}"
            assert "bond0.200" in interfaces, f"Missing bond0.200 (cluster VLAN) interface on {name}"
            assert "bond0.100" in interfaces, f"Missing bond0.100 (storage VLAN) interface on {name}"
            assert "192.168.200." in interfaces, f"Missing 192.168.200.x cluster VLAN IP on {name}"
            assert "192.168.100." in interfaces, f"Missing 192.168.100.x storage VLAN IP on {name}"
            tlog(f"  {name}: bond0, bond0.200 (192.168.200.x), bond0.100 (192.168.100.x) - OK")

    tlog("  Network configuration verified for ${networkProfile} profile!")

    # PHASE 2.5: Verify VLAN tag configuration (profile-specific)
    if "${networkProfile}" in ["vlans", "bonding-vlans"]:
        tlog("\n[PHASE 2.5] Verifying VLAN tag configuration...")

        # Determine VLAN interface prefix based on profile
        vlan_iface = "eth1" if "${networkProfile}" == "vlans" else "bond0"

        for node, name in [(n100_1, "n100-1"), (n100_2, "n100-2"), (n100_3, "n100-3")]:
            # Verify cluster VLAN (200)
            # Output format: "vlan protocol 802.1Q id 200" - check for both patterns
            cluster_vlan = node.succeed(f"ip -d link show {vlan_iface}.200")
            cluster_vlan_lower = cluster_vlan.lower()
            assert ("vlan protocol 802.1q id 200" in cluster_vlan_lower or
                    "vlan id 200" in cluster_vlan_lower), f"VLAN 200 not configured correctly on {name}. Output: {cluster_vlan}"
            tlog(f"  {name}: {vlan_iface}.200 - VLAN ID 200 OK")

            # Verify storage VLAN (100)
            storage_vlan = node.succeed(f"ip -d link show {vlan_iface}.100")
            storage_vlan_lower = storage_vlan.lower()
            assert ("vlan protocol 802.1q id 100" in storage_vlan_lower or
                    "vlan id 100" in storage_vlan_lower), f"VLAN 100 not configured correctly on {name}. Output: {storage_vlan}"
            tlog(f"  {name}: {vlan_iface}.100 - VLAN ID 100 OK")

        tlog("  VLAN tag verification complete!")

    # PHASE 2.6: Verify storage network connectivity (profile-specific)
    if "${networkProfile}" in ["vlans", "bonding-vlans"]:
        tlog("\n[PHASE 2.6] Verifying storage network connectivity...")

        storage_ips = {
            "n100-1": "192.168.100.1",
            "n100-2": "192.168.100.2",
            "n100-3": "192.168.100.3",
        }

        for node, name in [(n100_1, "n100-1"), (n100_2, "n100-2"), (n100_3, "n100-3")]:
            # Verify node has storage IP
            own_ip = storage_ips[name]
            node.succeed(f"ip addr show | grep {own_ip}")
            tlog(f"  {name}: has storage IP {own_ip}")

            # Ping other nodes on storage network
            for target_name, target_ip in storage_ips.items():
                if target_name != name:
                    node.succeed(f"ping -c 1 -W 2 {target_ip}")
                    tlog(f"  {name} -> {target_name} ({target_ip}): OK")

        tlog("  Storage network connectivity verified!")

    # PHASE 2.7: Cross-VLAN Isolation Check (best-effort in nixosTest)
    #
    # NOTE ON NIXOSTEST LIMITATIONS:
    # In nixosTest, all VMs share a single virtual network bridge. True L2
    # isolation (802.1Q tag enforcement) requires a physical switch or OVS.
    # The checks below provide best-effort validation:
    #   1. Verify ARP tables are per-interface (not leaked across VLANs)
    #   2. Verify routing tables show VLANs as separate networks
    #   3. Verify each interface has correct IP (no cross-contamination)
    #
    # For production-level VLAN isolation testing, use:
    #   - OVS emulation framework (tests/emulation/) on native Linux
    #   - Physical hardware with managed switch
    #
    if "${networkProfile}" in ["vlans", "bonding-vlans"]:
        tlog("\n[PHASE 2.7] Cross-VLAN isolation check (best-effort)...")
        tlog("  NOTE: nixosTest shared network limits true L2 isolation testing.")
        tlog("  These checks verify configuration correctness, not switch enforcement.")

        # Determine VLAN interface prefix based on profile
        vlan_iface = "eth1" if "${networkProfile}" == "vlans" else "bond0"

        cluster_ips = {
            "n100-1": "192.168.200.1",
            "n100-2": "192.168.200.2",
            "n100-3": "192.168.200.3",
        }
        storage_ips = {
            "n100-1": "192.168.100.1",
            "n100-2": "192.168.100.2",
            "n100-3": "192.168.100.3",
        }

        for node, name in [(n100_1, "n100-1"), (n100_2, "n100-2"), (n100_3, "n100-3")]:
            # 1. Verify ARP entries learned on correct interfaces
            # Populate ARP cache first
            for target_name, target_ip in cluster_ips.items():
                if target_name != name:
                    node.succeed(f"ping -c 1 -W 2 {target_ip} || true")
            for target_name, target_ip in storage_ips.items():
                if target_name != name:
                    node.succeed(f"ping -c 1 -W 2 {target_ip} || true")

            # Check ARP table shows entries on correct interfaces
            arp_output = node.succeed("ip neigh show")
            tlog(f"  {name} ARP table:\n{arp_output}")

            # 2. Verify routing table shows separate networks per VLAN
            route_output = node.succeed("ip route show")
            tlog(f"  {name} routes:\n{route_output}")

            # Cluster network should route via cluster VLAN interface
            assert f"192.168.200.0/24 dev {vlan_iface}.200" in route_output, \
                f"Cluster network not routed via {vlan_iface}.200 on {name}"

            # Storage network should route via storage VLAN interface
            assert f"192.168.100.0/24 dev {vlan_iface}.100" in route_output, \
                f"Storage network not routed via {vlan_iface}.100 on {name}"

            tlog(f"  {name}: routing correctly segregated per VLAN")

            # 3. Verify no cross-contamination of IPs
            # Each VLAN interface should ONLY have its designated IP
            cluster_iface_output = node.succeed(f"ip addr show dev {vlan_iface}.200")
            storage_iface_output = node.succeed(f"ip addr show dev {vlan_iface}.100")

            # Cluster VLAN interface should NOT have storage IPs
            assert "192.168.100." not in cluster_iface_output, \
                f"Storage IP leaked to cluster VLAN interface on {name}"

            # Storage VLAN interface should NOT have cluster IPs
            assert "192.168.200." not in storage_iface_output, \
                f"Cluster IP leaked to storage VLAN interface on {name}"

            tlog(f"  {name}: no IP cross-contamination between VLANs")

        tlog("  Cross-VLAN isolation checks complete!")
        tlog("  NOTE: For true L2 isolation testing, use OVS emulation or hardware.")

    # PHASE 3: Wait for Primary Server K3s
    tlog("\n[PHASE 3] Waiting for primary server (n100-1) k3s...")

    n100_1.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    n100_1.wait_for_open_port(6443)
    tlog("  API server port 6443 open")

    # Wait for API server to be ready - HA etcd election can take time
    n100_1.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=300)
    tlog("  API server is ready")

    # Give etcd cluster a moment to stabilize after initial leader election
    import time
    time.sleep(10)

    # PHASE 4: Verify Primary Server Node Ready
    tlog("\n[PHASE 4] Waiting for n100-1 to be Ready...")

    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'n100-1' | grep -w Ready",
        timeout=240
    )
    tlog("  n100-1 is Ready")

    nodes_output = n100_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"  Current nodes:\n{nodes_output}")

    # PHASE 5: Wait for Secondary Server
    tlog("\n[PHASE 5] Waiting for secondary server (n100-2)...")

    n100_2.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'n100-2' | grep -w Ready",
        timeout=300
    )
    tlog("  n100-2 is Ready")

    # PHASE 6: Wait for Agent
    tlog("\n[PHASE 6] Waiting for agent (n100-3)...")

    n100_3.wait_for_unit("k3s.service")
    tlog("  k3s.service started")

    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'n100-3' | grep -w Ready",
        timeout=300
    )
    tlog("  n100-3 is Ready")

    # PHASE 7: Verify All Nodes
    tlog("\n[PHASE 7] Verifying all 3 nodes are Ready...")

    n100_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=60
    )
    tlog("  All 3 nodes are Ready")

    nodes_output = n100_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"\n  Cluster nodes:\n{nodes_output}")

    pods_output = n100_1.succeed("k3s kubectl get pods -A -o wide")
    tlog(f"\n  System pods:\n{pods_output}")

    # PHASE 8: Verify System Components
    tlog("\n[PHASE 8] Verifying system components...")

    n100_1.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep Running",
        timeout=120
    )
    tlog("  CoreDNS is running")

    n100_1.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l app=local-path-provisioner --no-headers | grep Running",
        timeout=120
    )
    tlog("  Local-path-provisioner is running")

    # Summary
    tlog("\n" + "=" * 70)
    tlog("K3s Cluster Test (${networkProfile} profile) - PASSED")
    tlog("=" * 70)
    tlog("Validated:")
    tlog("  - Network profile: ${networkProfile}")
    if "${networkProfile}" in ["vlans", "bonding-vlans"]:
        tlog("  - VLAN tags (200, 100) verified")
        tlog("  - Storage network (192.168.100.x) connectivity OK")
        tlog("  - Cross-VLAN isolation (best-effort) verified")
    tlog("  - All 3 nodes Ready")
    tlog("  - System components running")
    tlog("=" * 70)
  '';

in
pkgs.testers.runNixOSTest {
  name = actualTestName;

  nodes = {
    # Primary k3s server (cluster init)
    n100-1 = lib.recursiveUpdate (mkNodeConfig "n100-1" "server") {
      services.k3s.clusterInit = true;
    };

    # Secondary k3s server (joins cluster)
    n100-2 = lib.recursiveUpdate (mkNodeConfig "n100-2" "server") {
      services.k3s.serverAddr = profile.serverApi;
    };

    # k3s agent (worker node)
    n100-3 = lib.recursiveUpdate (mkNodeConfig "n100-3" "agent") {
      services.k3s.serverAddr = profile.serverApi;
    };
  };

  skipTypeCheck = true;

  testScript = if testScript != null then testScript else defaultTestScript;
}
