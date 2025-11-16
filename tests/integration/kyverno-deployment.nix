# NixOS Integration Test: Kyverno Deployment and Policy Validation
# Tests that Kyverno can be deployed and PATH patching policies work
# This is CRITICAL for Longhorn on NixOS
#
# Run with:
#   nix build .#checks.x86_64-linux.kyverno-deployment
#   nix build .#checks.x86_64-linux.kyverno-deployment.driverInteractive  # For debugging

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "kyverno-deployment";

  nodes = {
    server = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../modules/common/base.nix
        ../../modules/common/nix-settings.nix
        ../../modules/common/networking.nix
        ../../modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 6144;  # 6GB - Kyverno needs more resources
        cores = 4;
        diskSize = 30720;
      };

      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" "kyverno-test-token";

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
        allowedTCPPorts = [ 6443 10250 2379 2380 9443 ]; # 9443 for Kyverno webhook
        allowedUDPPorts = [ 8472 ];
      };

      environment.systemPackages = with pkgs; [
        k3s
        kubectl
        kubernetes-helm
        curl
        jq
      ];
    };
  };

  testScript = ''
    import time

    print("=" * 60)
    print("Kyverno Deployment and Policy Validation Test")
    print("=" * 60)

    # Start the server
    print("\n[1/14] Starting K3s server...")
    server.start()
    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("k3s.service")
    server.wait_for_open_port(6443)
    server.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=120)
    print("✓ K3s server is ready")

    # Wait for server node Ready
    print("\n[2/14] Waiting for node to be Ready...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready",
        timeout=120
    )
    print("✓ Node is Ready")

    # Create Kyverno namespace
    print("\n[3/14] Creating Kyverno namespace...")
    server.succeed("k3s kubectl create namespace kyverno")
    print("✓ Kyverno namespace created")

    # Install Kyverno using Helm
    print("\n[4/14] Installing Kyverno via Helm...")
    print("Adding Kyverno Helm repository...")
    server.succeed("helm repo add kyverno https://kyverno.github.io/kyverno/")
    server.succeed("helm repo update")

    print("Installing Kyverno...")
    install_result = server.succeed(
        """
        helm install kyverno kyverno/kyverno \\
          --namespace kyverno \\
          --set replicaCount=1 \\
          --set webhooksCleanup.enabled=false \\
          --set admissionController.replicas=1 \\
          --set backgroundController.replicas=1 \\
          --set cleanupController.replicas=1 \\
          --set reportsController.replicas=1 \\
          --wait --timeout=300s
        """,
        timeout=330
    )
    print("✓ Kyverno Helm chart installed")

    # Wait for Kyverno pods to be running
    print("\n[5/14] Waiting for Kyverno pods...")
    server.wait_until_succeeds(
        "k3s kubectl get pods -n kyverno -l app.kubernetes.io/instance=kyverno --field-selector=status.phase=Running | grep -q Running",
        timeout=180
    )

    # Verify all Kyverno components
    kyverno_pods = server.succeed(
        "k3s kubectl get pods -n kyverno -l app.kubernetes.io/instance=kyverno"
    )
    print("\nKyverno pods:")
    print(kyverno_pods)
    print("✓ Kyverno pods are running")

    # Wait for Kyverno webhook to be ready
    print("\n[6/14] Waiting for Kyverno webhook...")
    server.wait_until_succeeds(
        "k3s kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg",
        timeout=60
    )
    print("✓ Kyverno webhooks are configured")

    # Create the PATH patching policy for Longhorn
    print("\n[7/14] Creating Longhorn PATH patching policy...")
    path_policy = """
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-path-to-longhorn
  annotations:
    policies.kyverno.io/title: Add PATH to Longhorn System Pods
    policies.kyverno.io/category: NixOS Compatibility
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: |
      This policy adds the NixOS PATH environment variable to all pods
      in the longhorn-system namespace for NixOS compatibility.
spec:
  background: false
  rules:
    - name: add-nixos-path
      match:
        any:
        - resources:
            kinds:
            - Pod
            namespaces:
            - longhorn-system
      mutate:
        patchStrategicMerge:
          spec:
            containers:
            - (name): "*"
              env:
              - name: PATH
                value: "/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
"""
    server.succeed(f"cat > /tmp/path-policy.yaml << 'EOF'\n{path_policy}\nEOF")
    server.succeed("k3s kubectl apply -f /tmp/path-policy.yaml")
    print("✓ PATH patching policy created")

    # Wait for policy to be ready
    print("\n[8/14] Waiting for policy to be ready...")
    server.wait_until_succeeds(
        "k3s kubectl get clusterpolicy add-path-to-longhorn -o jsonpath='{.status.ready}' | grep -i true",
        timeout=60
    )
    print("✓ Policy is ready")

    # Create longhorn-system namespace
    print("\n[9/14] Creating longhorn-system namespace...")
    server.succeed("k3s kubectl create namespace longhorn-system")
    print("✓ longhorn-system namespace created")

    # Create a test pod to verify PATH patching
    print("\n[10/14] Creating test pod to verify PATH mutation...")
    test_pod = """
apiVersion: v1
kind: Pod
metadata:
  name: path-test-pod
  namespace: longhorn-system
spec:
  containers:
  - name: alpine
    image: alpine:latest
    command: ["sh", "-c", "env | grep PATH && sleep 3600"]
"""
    server.succeed(f"cat > /tmp/test-pod.yaml << 'EOF'\n{test_pod}\nEOF")
    server.succeed("k3s kubectl apply -f /tmp/test-pod.yaml")

    # Wait for pod to be running
    server.wait_until_succeeds(
        "k3s kubectl get pod path-test-pod -n longhorn-system -o jsonpath='{.status.phase}' | grep Running",
        timeout=120
    )
    print("✓ Test pod is running")

    # Verify PATH was mutated by Kyverno
    print("\n[11/14] Verifying PATH mutation by Kyverno...")
    pod_env = server.succeed(
        "k3s kubectl exec path-test-pod -n longhorn-system -- env | grep '^PATH='"
    )
    print(f"Pod PATH: {pod_env.strip()}")

    assert "/nix/var/nix/profiles/default/bin" in pod_env, "NixOS PATH not added by Kyverno"
    assert "/run/current-system/sw/bin" in pod_env, "NixOS system PATH not added"
    print("✓ PATH was successfully mutated by Kyverno policy")

    # Verify the pod spec was actually modified
    print("\n[12/14] Verifying pod spec modification...")
    pod_spec = server.succeed(
        "k3s kubectl get pod path-test-pod -n longhorn-system -o jsonpath='{.spec.containers[0].env[?(@.name==\"PATH\")].value}'"
    )
    print(f"Pod spec PATH: {pod_spec.strip()}")
    assert "/nix" in pod_spec, "Pod spec was not modified"
    print("✓ Pod spec contains mutated PATH")

    # Check Kyverno policy reports
    print("\n[13/14] Checking Kyverno policy reports...")
    time.sleep(5)  # Give time for reports to generate

    try:
        reports = server.succeed(
            "k3s kubectl get policyreport -n longhorn-system -o yaml"
        )
        print("Policy reports:")
        print(reports[:500])  # Print first 500 chars
    except:
        print("⚠ Policy reports not yet generated (this is okay)")

    # Verify Kyverno metrics endpoint
    print("\n[14/14] Verifying Kyverno metrics...")
    server.wait_until_succeeds(
        "k3s kubectl get svc -n kyverno | grep kyverno-svc-metrics",
        timeout=30
    )
    print("✓ Kyverno metrics service exists")

    # Show final status
    print("\n" + "=" * 60)
    print("Kyverno Status Summary:")
    print("=" * 60)

    all_policies = server.succeed("k3s kubectl get clusterpolicy")
    print("\nCluster Policies:")
    print(all_policies)

    kyverno_status = server.succeed("k3s kubectl get all -n kyverno")
    print("\nKyverno Resources:")
    print(kyverno_status)

    # Clean up
    server.succeed("k3s kubectl delete pod path-test-pod -n longhorn-system")
    server.succeed("k3s kubectl delete namespace longhorn-system")

    print("\n" + "=" * 60)
    print("✓ All Kyverno tests passed!")
    print("=" * 60)
    print("\nValidated:")
    print("  ✓ Kyverno Helm installation")
    print("  ✓ Kyverno admission controller running")
    print("  ✓ Kyverno webhooks configured")
    print("  ✓ ClusterPolicy creation and readiness")
    print("  ✓ PATH mutation for longhorn-system namespace")
    print("  ✓ Pod spec modification by Kyverno")
    print("  ✓ NixOS compatibility layer working")
    print("\nSystem is ready for Longhorn deployment!")
  '';
}
