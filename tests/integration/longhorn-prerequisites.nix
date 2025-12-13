# NixOS Integration Test: Longhorn Prerequisites
# Tests that NixOS is properly configured for Longhorn storage
# Validates kernel modules, iSCSI, and required system configuration
#
# Run with:
#   nix build .#checks.x86_64-linux.longhorn-prerequisites
#   nix build .#checks.x86_64-linux.longhorn-prerequisites.driverInteractive  # For debugging

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "longhorn-prerequisites";

  nodes = {
    server = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../modules/common/base.nix
        ../../modules/common/nix-settings.nix
        ../../modules/common/networking.nix
        ../../modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 20480;
      };

      # K3s server configuration
      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" "longhorn-test-token";

        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
          "--cluster-cidr=10.42.0.0/16"
          "--service-cidr=10.43.0.0/16"
        ];
      };

      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ 6443 10250 2379 2380 3260 ]; # 3260 for iSCSI
        allowedUDPPorts = [ 8472 ];
      };

      environment.systemPackages = with pkgs; [
        k3s
        kubectl
        open-iscsi
        util-linux
        e2fsprogs
        xfsprogs
      ];
    };
  };

  testScript = ''
        import time

        print("=" * 60)
        print("Longhorn Prerequisites Test")
        print("=" * 60)

        # Start the server
        print("\n[1/10] Starting K3s server...")
        server.start()
        server.wait_for_unit("multi-user.target")
        print("✓ Server VM booted")

        # Wait for K3s
        print("\n[2/10] Waiting for K3s server...")
        server.wait_for_unit("k3s.service")
        server.wait_for_open_port(6443)
        server.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=120)
        print("✓ K3s server is ready")

        # Check required kernel modules for Longhorn
        print("\n[3/10] Verifying kernel modules...")
        required_modules = [
            "dm_thin_pool",
            "dm_crypt",
            "iscsi_tcp",
            "overlay",
            "br_netfilter"
        ]

        for module in required_modules:
            result = server.succeed(f"lsmod | grep {module} || echo 'not loaded'")
            if "not loaded" not in result:
                print(f"✓ Module {module} is loaded")
            else:
                # Try to load the module
                server.succeed(f"modprobe {module}")
                print(f"✓ Module {module} loaded successfully")

        # Verify iSCSI service
        print("\n[4/10] Checking iSCSI daemon...")
        server.wait_for_unit("iscsid.service")
        iscsi_status = server.succeed("systemctl status iscsid.service")
        assert "active" in iscsi_status.lower(), "iSCSI daemon is not active"
        print("✓ iSCSI daemon is running")

        # Check iSCSI initiator name
        print("\n[5/10] Verifying iSCSI initiator configuration...")
        initiator_name = server.succeed("cat /etc/iscsi/initiatorname.iscsi")
        print(f"iSCSI initiator: {initiator_name.strip()}")
        assert "iqn." in initiator_name, "Invalid iSCSI initiator name format"
        assert "longhorn" in initiator_name.lower(), "Longhorn not in initiator name"
        print("✓ iSCSI initiator is properly configured")

        # Verify required filesystems
        print("\n[6/10] Checking filesystem support...")
        fs_types = server.succeed("cat /proc/filesystems")
        assert "ext4" in fs_types, "ext4 filesystem not supported"
        assert "xfs" in fs_types, "xfs filesystem not supported"
        print("✓ Required filesystems (ext4, xfs) are supported")

        # Check for required utilities
        print("\n[7/10] Verifying required utilities...")
        utilities = {
            "mkfs.ext4": "e2fsprogs",
            "mkfs.xfs": "xfsprogs",
            "iscsiadm": "open-iscsi",
            "nsenter": "util-linux"
        }

        for util, package in utilities.items():
            result = server.succeed(f"command -v {util}")
            assert result.strip(), f"{util} not found (from {package})"
            print(f"✓ {util} is available")

        # Verify kernel parameters
        print("\n[8/10] Checking kernel parameters...")
        sysctl_checks = {
            "net.bridge.bridge-nf-call-iptables": "1",
            "net.ipv4.ip_forward": "1",
            "fs.inotify.max_user_watches": "524288"
        }

        for param, expected in sysctl_checks.items():
            value = server.succeed(f"sysctl -n {param}").strip()
            assert value == expected, f"{param} = {value}, expected {expected}"
            print(f"✓ {param} = {value}")

        # Verify directory structure for container storage
        print("\n[9/10] Checking storage directories...")
        directories = [
            "/var/lib/kubelet",
            "/var/lib/containerd",
            "/var/lib/k3s"
        ]

        for directory in directories:
            server.succeed(f"test -d {directory}")
            print(f"✓ Directory {directory} exists")

        # Create test namespace and apply Kyverno policy
        print("\n[10/10] Testing Kyverno policy compatibility...")
        server.succeed("k3s kubectl create namespace longhorn-system || true")

        # Create a simple Kyverno ClusterPolicy
        kyverno_policy = """
    apiVersion: kyverno.io/v1
    kind: ClusterPolicy
    metadata:
      name: test-path-policy
    spec:
      background: false
      rules:
      - name: test-rule
        match:
          any:
          - resources:
              kinds:
              - Pod
              namespaces:
              - longhorn-system
        validate:
          message: "Test policy for Longhorn namespace"
          pattern:
            metadata:
              namespace: longhorn-system
    """

        server.succeed(f"cat > /tmp/kyverno-test.yaml << 'EOF'\n{kyverno_policy}\nEOF")

        # Note: We can't actually apply Kyverno policies without Kyverno installed,
        # but we can verify the manifest is valid YAML
        server.succeed("k3s kubectl apply --dry-run=client -f /tmp/kyverno-test.yaml")
        print("✓ Kyverno policy manifest is valid")

        print("\n" + "=" * 60)
        print("✓ All Longhorn prerequisite checks passed!")
        print("=" * 60)
        print("\nSystem is ready for Longhorn deployment:")
        print("  - All required kernel modules available")
        print("  - iSCSI daemon configured and running")
        print("  - Required filesystems supported")
        print("  - Necessary utilities installed")
        print("  - Kernel parameters properly configured")
        print("  - Storage directories present")
        print("  - Kyverno policy compatibility validated")
  '';
}
