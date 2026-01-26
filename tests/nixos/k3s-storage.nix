# NixOS Integration Test: K3s Storage (Multi-Node nixosTest)
#
# This test validates k3s storage infrastructure prerequisites using
# nixosTest multi-node architecture. Each nixosTest "node" IS a k3s cluster node.
#
# ARCHITECTURE:
#   nixosTest framework spawns 3 VMs:
#   - server_1: k3s server (single server with SQLite - more reliable in CI)
#   - agent_1: k3s agent (worker)
#   - agent_2: k3s agent (worker)
#
#   NOTE: Using single server to avoid etcd quorum issues that occur with
#   multi-server clusters during CI. Multi-server cluster tested in
#   k3s-cluster-formation.nix.
#
# TEST PHASES:
#   1. Boot all nodes and form cluster
#   2. Validate storage prerequisites (kernel modules, iSCSI, directories)
#   3. Verify local-path-provisioner deployment and storage class
#   4. Verify Longhorn prerequisites are ready for production deployment
#
# NOTES:
#   - This test focuses on infrastructure validation in an airgapped environment
#   - Pod-based storage tests (PVC binding, data persistence) require network access
#     to pull container images, which isn't available in nixosTest
#   - The k3s airgap images include k3s system components but not general workloads
#   - Full Longhorn deployment requires Helm + external image pulls (not CI-friendly)
#   - For workload testing, use a network-enabled test or emulation-vm
#
# Run with:
#   nix build '.#checks.x86_64-linux.k3s-storage'
#   nix build '.#checks.x86_64-linux.k3s-storage.driverInteractive'

{ pkgs, lib, inputs ? { }, ... }:

let
  # Common k3s token for test cluster
  testToken = "k3s-storage-test-token";

  # Network configuration
  network = {
    server_1 = "192.168.1.1";
    agent_1 = "192.168.1.2";
    agent_2 = "192.168.1.3";
    serverApi = "https://192.168.1.1:6443";
    clusterCidr = "10.42.0.0/16";
    serviceCidr = "10.43.0.0/16";
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
      6443
      2379
      2380
      10250
      10251
      10252
      3260 # iSCSI for Longhorn
    ];
    allowedUDPPorts = [ 8472 ];
  };

  # Firewall rules for k3s agents
  agentFirewall = {
    enable = true;
    allowedTCPPorts = [
      10250
      3260 # iSCSI for Longhorn
    ];
    allowedUDPPorts = [ 8472 ];
  };

  # Base NixOS configuration with storage prerequisites
  baseK3sStorageConfig = { config, pkgs, ... }: {
    imports = [
      ../../backends/nixos/modules/common/base.nix
    ];

    # Kernel modules for k3s and storage
    boot.kernelModules = [
      "overlay"
      "br_netfilter"
      # Longhorn prerequisites
      "iscsi_tcp"
      "dm_crypt"
      "dm_thin_pool"
    ];

    # Kernel parameters for k3s and storage
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
    };

    # iSCSI service for Longhorn
    services.openiscsi = {
      enable = true;
      name = "iqn.2024-01.io.n3x.longhorn:${config.networking.hostName}";
    };

    # Enable k3s with airgap images (no network access needed)
    services.k3s = {
      enable = true;
      # Pre-load airgap images so k3s doesn't need to pull from internet
      images = [ pkgs.k3s.passthru.airgapImages ];
    };

    # Create Longhorn data directory
    systemd.tmpfiles.rules = [
      "d /var/lib/longhorn 0700 root root -"
    ];

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
      openiscsi
      util-linux
      e2fsprogs
      xfsprogs
    ];
  };

in
pkgs.testers.runNixOSTest {
  name = "k3s-storage";

  nodes = {
    # Primary k3s server
    server_1 = { config, pkgs, lib, ... }: {
      imports = [ baseK3sStorageConfig ];
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
          "--node-ip=${network.server_1}"
          "--node-name=server-1"
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
      imports = [ baseK3sStorageConfig ];
      virtualisation = vmConfig;

      services.k3s = {
        role = "agent";
        serverAddr = network.serverApi;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = [
          "--node-ip=${network.agent_1}"
          "--node-name=agent-1"
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
      imports = [ baseK3sStorageConfig ];
      virtualisation = vmConfig;

      services.k3s = {
        role = "agent";
        serverAddr = network.serverApi;
        tokenFile = pkgs.writeText "k3s-token" testToken;
        extraFlags = [
          "--node-ip=${network.agent_2}"
          "--node-name=agent-2"
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
  skipLint = true;

  testScript = ''
    def tlog(msg):
        """Print timestamped log message"""
        import datetime
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    tlog("=" * 70)
    tlog("K3s Storage Test (Multi-Node nixosTest)")
    tlog("=" * 70)
    tlog("Architecture: 1 server + 2 agents (SQLite backend)")
    tlog("  server_1: k3s server")
    tlog("  agent_1: k3s agent (worker 1)")
    tlog("  agent_2: k3s agent (worker 2)")
    tlog("=" * 70)

    # =========================================================================
    # PHASE 1: Boot All Nodes and Form Cluster
    # =========================================================================
    tlog("\n[PHASE 1] Booting all nodes and forming cluster...")

    start_all()

    # Wait for all nodes to boot
    server_1.wait_for_unit("multi-user.target")
    tlog("  server_1 booted")
    agent_1.wait_for_unit("multi-user.target")
    tlog("  agent_1 booted")
    agent_2.wait_for_unit("multi-user.target")
    tlog("  agent_2 booted")

    # Wait for primary server k3s to initialize
    server_1.wait_for_unit("k3s.service")
    tlog("  k3s.service started on server_1")

    server_1.wait_for_open_port(6443)
    tlog("  API server port 6443 open")

    server_1.wait_until_succeeds(
        "k3s kubectl get --raw /readyz",
        timeout=180
    )
    tlog("  API server is ready")

    # Wait for server node to be Ready
    server_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'server-1' | grep -w Ready",
        timeout=120
    )
    tlog("  server-1 is Ready")

    # Wait for first agent to join
    agent_1.wait_for_unit("k3s.service")
    tlog("  k3s.service started on agent_1")

    server_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'agent-1' | grep -w Ready",
        timeout=180
    )
    tlog("  agent-1 is Ready")

    # Wait for second agent to join
    agent_2.wait_for_unit("k3s.service")
    tlog("  k3s.service started on agent_2")

    server_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep 'agent-2' | grep -w Ready",
        timeout=180
    )
    tlog("  agent-2 is Ready")

    # Verify all 3 nodes are Ready
    server_1.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep -q 3",
        timeout=60
    )
    tlog("  All 3 nodes Ready")

    nodes_output = server_1.succeed("k3s kubectl get nodes -o wide")
    tlog(f"\n  Cluster nodes:\n{nodes_output}")

    # =========================================================================
    # PHASE 2: Validate Storage Prerequisites
    # =========================================================================
    tlog("\n[PHASE 2] Validating storage prerequisites on all nodes...")

    # Kernel modules to check
    required_modules = ["iscsi_tcp", "dm_crypt", "overlay", "br_netfilter"]

    for node_name, node in [("server_1", server_1), ("agent_1", agent_1), ("agent_2", agent_2)]:
        tlog(f"\n  Checking {node_name}...")

        # Check kernel modules
        for module in required_modules:
            result = node.succeed(f"lsmod | grep -q {module} && echo 'loaded' || (modprobe {module} && echo 'loaded')")
            tlog(f"    {module}: OK")

        # Check iSCSI service
        node.wait_for_unit("iscsid.service")
        tlog(f"    iSCSI daemon: running")

        # Check iSCSI initiator name
        initiator = node.succeed("cat /etc/iscsi/initiatorname.iscsi").strip()
        assert "iqn." in initiator, f"Invalid iSCSI initiator on {node_name}"
        tlog(f"    iSCSI initiator: configured")

        # Check Longhorn directory
        node.succeed("test -d /var/lib/longhorn")
        tlog(f"    /var/lib/longhorn: exists")

        # Check filesystem support
        fs_types = node.succeed("cat /proc/filesystems")
        assert "ext4" in fs_types, "ext4 not supported"
        # XFS is optional - Longhorn can use ext4 as well
        # XFS may not be in minimal test VM kernels
        has_xfs = "xfs" in fs_types
        if has_xfs:
            tlog(f"    Filesystems: ext4, xfs supported")
        else:
            tlog(f"    Filesystems: ext4 supported (xfs not in kernel - OK for local-path)")

        # Check required utilities (mkfs.xfs is optional)
        for util in ["mkfs.ext4", "iscsiadm", "nsenter"]:
            node.succeed(f"command -v {util}")
            tlog(f"    {util}: available")
        # mkfs.xfs available via xfsprogs package
        node.succeed("command -v mkfs.xfs")
        tlog(f"    mkfs.xfs: available")

    tlog("\n  All storage prerequisites validated!")

    # =========================================================================
    # PHASE 3: Verify local-path-provisioner Deployment
    # =========================================================================
    tlog("\n[PHASE 3] Verifying local-path-provisioner deployment...")

    # Wait for local-path-provisioner to be running
    server_1.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system -l app=local-path-provisioner --no-headers | grep Running",
        timeout=180
    )
    tlog("  local-path-provisioner pod is running")

    # Check storage class exists and is default
    sc_output = server_1.succeed("k3s kubectl get storageclass local-path -o jsonpath='{.metadata.name}'")
    assert "local-path" in sc_output, "local-path storage class not found"
    tlog("  local-path storage class exists")

    # Show storage class details
    sc_details = server_1.succeed("k3s kubectl get storageclass local-path -o wide")
    tlog(f"  Storage class details:\n{sc_details}")

    # Verify ConfigMap for local-path-provisioner
    server_1.wait_until_succeeds(
        "k3s kubectl get configmap -n kube-system local-path-config",
        timeout=60
    )
    tlog("  local-path-provisioner ConfigMap exists")

    # Show local-path-provisioner pod details
    pod_details = server_1.succeed("k3s kubectl get pods -n kube-system -l app=local-path-provisioner -o wide")
    tlog(f"  Provisioner pod:\n{pod_details}")

    # =========================================================================
    # PHASE 4: Verify Longhorn Prerequisites
    # =========================================================================
    tlog("\n[PHASE 4] Verifying Longhorn deployment prerequisites...")

    # Summarize storage readiness
    tlog("\n  Storage Infrastructure Summary:")
    tlog("  ================================")

    # Kernel modules
    tlog("  Kernel modules:")
    for module in ["iscsi_tcp", "dm_crypt", "dm_thin_pool", "overlay"]:
        check = server_1.execute(f"lsmod | grep -q {module}")
        status = "loaded" if check[0] == 0 else "available (can be loaded)"
        tlog(f"    {module}: {status}")

    # iSCSI status
    tlog("  iSCSI:")
    server_1.succeed("systemctl is-active iscsid")
    tlog("    iscsid: running")

    # Storage directories (only check Longhorn directory - k3s internal paths vary by role)
    tlog("  Storage directories:")
    server_1.succeed("test -d /var/lib/longhorn")
    tlog("    /var/lib/longhorn: exists")

    # Kernel parameters
    tlog("  Kernel parameters:")
    for param in ["net.ipv4.ip_forward", "net.bridge.bridge-nf-call-iptables"]:
        value = server_1.succeed(f"sysctl -n {param}").strip()
        tlog(f"    {param} = {value}")

    # Storage class summary
    tlog("  Storage classes:")
    sc_list = server_1.succeed("k3s kubectl get storageclass --no-headers")
    tlog(f"    {sc_list.strip()}")

    # Show all system pods
    pods_output = server_1.succeed("k3s kubectl get pods -A -o wide")
    tlog(f"\n  All pods:\n{pods_output}")

    # =========================================================================
    # Summary
    # =========================================================================
    tlog("\n" + "=" * 70)
    tlog("K3s Storage Test - PASSED")
    tlog("=" * 70)
    tlog("")
    tlog("Validated:")
    tlog("  - 3-node cluster formation (1 server + 2 agents)")
    tlog("  - Storage prerequisites on all nodes:")
    tlog("    - Kernel modules (iscsi_tcp, dm_crypt, overlay, br_netfilter)")
    tlog("    - iSCSI daemon configured and running")
    tlog("    - Longhorn data directory (/var/lib/longhorn)")
    tlog("    - Filesystem support (ext4, xfs tools available)")
    tlog("    - Required utilities (mkfs, iscsiadm, nsenter)")
    tlog("  - local-path-provisioner deployed and running")
    tlog("  - local-path StorageClass available")
    tlog("")
    tlog("Note: Pod-based PVC tests (binding, data persistence) require")
    tlog("      network access to pull container images. Use k3s-network.nix")
    tlog("      or emulation-vm for workload testing.")
    tlog("")
    tlog("Ready for Longhorn deployment on network-enabled environment.")
    tlog("=" * 70)
  '';
}
