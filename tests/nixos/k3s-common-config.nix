# NixOS Integration Test: K3s Common Configuration
# Tests that the k3s-common module correctly configures kernel modules, sysctls,
# services, and other foundational settings required for K3s
#
# Run with:
#   nix build .#checks.x86_64-linux.k3s-common-config
#   nix build .#checks.x86_64-linux.k3s-common-config.driverInteractive  # For debugging

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "k3s-common-config";

  nodes = {
    node = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 10240;
      };

      # Enable k3s to trigger all common configuration
      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" "test-token";
      };
    };
  };

  testScript = ''
    import time

    print("=" * 60)
    print("K3s Common Configuration Test")
    print("=" * 60)

    # Start the VM
    print("\n[1/10] Starting VM...")
    node.start()
    node.wait_for_unit("multi-user.target")
    print("✓ VM booted successfully")

    # Test kernel modules
    print("\n[2/10] Verifying kernel modules...")

    required_modules = [
        "overlay",
        "br_netfilter",
        "bonding",
        "xt_conntrack",
        "xt_MASQUERADE",
        "dm_thin_pool",
        "iscsi_tcp",
    ]

    for module in required_modules:
        result = node.succeed(f"lsmod | grep -w {module} || modprobe {module} && lsmod | grep -w {module}")
        print(f"  ✓ {module} is available")

    print("✓ All required kernel modules are available")

    # Test sysctl parameters
    print("\n[3/10] Verifying sysctl parameters...")

    sysctls = {
        "net.ipv4.ip_forward": "1",
        "net.bridge.bridge-nf-call-iptables": "1",
        "net.bridge.bridge-nf-call-ip6tables": "1",
        "fs.inotify.max_user_watches": "524288",
        "fs.inotify.max_user_instances": "8192",
    }

    for key, expected_value in sysctls.items():
        actual_value = node.succeed(f"sysctl -n {key}").strip()
        assert actual_value == expected_value, f"sysctl {key}: expected {expected_value}, got {actual_value}"
        print(f"  ✓ {key} = {actual_value}")

    print("✓ All sysctl parameters are correctly set")

    # Test required directories
    print("\n[4/10] Verifying required directories...")

    required_dirs = [
        "/var/lib/k3s",
        "/etc/rancher/k3s",
        "/var/lib/containerd",
        "/var/lib/containers",
    ]

    for dir_path in required_dirs:
        node.succeed(f"test -d {dir_path}")
        print(f"  ✓ {dir_path} exists")

    print("✓ All required directories exist")

    # Test directory permissions
    print("\n[5/10] Verifying directory permissions...")

    k3s_perms = node.succeed("stat -c '%a' /var/lib/k3s").strip()
    assert k3s_perms == "755", f"Expected /var/lib/k3s to have 755, got {k3s_perms}"
    print(f"  ✓ /var/lib/k3s has correct permissions (755)")

    rancher_perms = node.succeed("stat -c '%a' /etc/rancher/k3s").strip()
    assert rancher_perms == "755", f"Expected /etc/rancher/k3s to have 755, got {rancher_perms}"
    print(f"  ✓ /etc/rancher/k3s has correct permissions (755)")

    print("✓ Directory permissions are correct")

    # Test iSCSI service
    print("\n[6/10] Verifying iSCSI service...")
    node.wait_for_unit("iscsid.service")

    iscsi_status = node.succeed("systemctl is-active iscsid.service").strip()
    assert iscsi_status == "active", f"Expected iscsid to be active, got {iscsi_status}"
    print("  ✓ iscsid.service is active")

    # Verify iSCSI initiator name
    initiator_name = node.succeed("cat /etc/iscsi/initiatorname.iscsi")
    print(f"  ✓ iSCSI initiator name: {initiator_name.strip()}")

    print("✓ iSCSI service is properly configured")

    # Test rpcbind service (required for NFS)
    print("\n[7/10] Verifying rpcbind service...")
    node.wait_for_unit("rpcbind.service")

    rpcbind_status = node.succeed("systemctl is-active rpcbind.service").strip()
    assert rpcbind_status == "active", f"Expected rpcbind to be active, got {rpcbind_status}"
    print("  ✓ rpcbind.service is active")

    print("✓ rpcbind service is running")

    # Test environment variables
    print("\n[8/10] Verifying environment variables...")

    # Check KUBECONFIG is set
    kubeconfig = node.succeed("echo $KUBECONFIG").strip()
    assert kubeconfig == "/etc/rancher/k3s/k3s.yaml", f"Expected KUBECONFIG=/etc/rancher/k3s/k3s.yaml, got {kubeconfig}"
    print(f"  ✓ KUBECONFIG = {kubeconfig}")

    # Verify PATH includes required directories
    path = node.succeed("echo $PATH").strip()
    assert "/run/wrappers/bin" in path, "PATH missing /run/wrappers/bin"
    assert "/run/current-system/sw/bin" in path, "PATH missing /run/current-system/sw/bin"
    print(f"  ✓ PATH is correctly configured")

    print("✓ Environment variables are set")

    # Test required system packages
    print("\n[9/10] Verifying required system packages...")

    required_packages = [
        "k3s",
        "kubectl",
        "helm",
        "jq",
        "yq",
    ]

    for package in required_packages:
        node.succeed(f"which {package}")
        version = node.succeed(f"{package} version 2>&1 || {package} --version 2>&1 || echo 'installed'").strip()
        print(f"  ✓ {package} is installed")

    print("✓ All required packages are available")

    # Test systemd configuration
    print("\n[10/10] Verifying systemd configuration...")

    # Check systemd limits
    nofile_limit = node.succeed("systemctl show -p DefaultLimitNOFILE").strip()
    print(f"  ✓ DefaultLimitNOFILE: {nofile_limit}")

    # Verify k3s slice exists
    node.succeed("systemctl status k3s.slice || systemctl list-units --type=slice | grep k3s")
    print("  ✓ k3s.slice is configured")

    # Test container registry configuration
    if node.succeed("test -f /etc/rancher/k3s/registries.yaml && echo exists || echo missing").strip() == "exists":
        registries = node.succeed("cat /etc/rancher/k3s/registries.yaml")
        assert "docker.io" in registries, "registries.yaml missing docker.io"
        print("  ✓ Container registries configured")

    # Test helper script
    node.succeed("test -f /etc/k3s-helpers.sh")
    node.succeed("test -x /etc/k3s-helpers.sh")
    print("  ✓ k3s-helpers.sh exists and is executable")

    print("✓ systemd and helper scripts are configured")

    # Verify k3s can start with this configuration
    print("\nBonus: Verifying K3s starts with common config...")
    node.wait_for_unit("k3s.service")
    node.wait_for_open_port(6443)
    print("✓ K3s service started successfully with common config")

    print("\n" + "=" * 60)
    print("✓ All k3s-common configuration tests passed!")
    print("=" * 60)
  '';
}
