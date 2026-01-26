# NixOS Integration Test: Cross-Node Pod Communication
# Tests that pods can communicate across nodes using Flannel overlay network
# Validates DNS resolution, service discovery, and pod-to-pod networking
#
# Run with:
#   nix build .#checks.x86_64-linux.k3s-networking
#   nix build .#checks.x86_64-linux.k3s-networking.driverInteractive  # For debugging

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "k3s-cross-node-networking";

  nodes = {
    server = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" "network-test-token";

        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
          "--cluster-cidr=10.42.0.0/16"
          "--service-cidr=10.43.0.0/16"
          "--node-ip=192.168.1.1"
        ];
      };

      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ 6443 10250 2379 2380 ];
          allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.1";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [ k3s kubectl ];
    };

    agent = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "agent";
        serverAddr = "https://192.168.1.1:6443";
        tokenFile = pkgs.writeText "k3s-token" "network-test-token";
        extraFlags = [ "--node-ip=192.168.1.2" ];
      };

      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ 10250 ];
          allowedUDPPorts = [ 8472 ]; # Flannel VXLAN
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.2";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [ k3s ];
    };
  };

  testScript = ''
        import time

        print("=" * 60)
        print("K3s Cross-Node Networking Test")
        print("=" * 60)

        # Start all nodes
        print("\n[1/12] Starting cluster...")
        start_all()
        server.wait_for_unit("multi-user.target")
        agent.wait_for_unit("multi-user.target")
        print("✓ Both nodes booted")

        # Wait for K3s cluster
        print("\n[2/12] Waiting for K3s cluster...")
        server.wait_for_unit("k3s.service")
        agent.wait_for_unit("k3s.service")
        server.wait_for_open_port(6443)
        server.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=120)
        print("✓ K3s cluster ready")

        # Wait for both nodes Ready
        print("\n[3/12] Waiting for nodes to be Ready...")
        server.wait_until_succeeds(
            "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep 2",
            timeout=120
        )
        print("✓ Both nodes are Ready")

        # Verify Flannel is running
        print("\n[4/12] Verifying Flannel CNI...")
        flannel_pods = server.succeed(
            "k3s kubectl get pods -n kube-system -l app=flannel -o jsonpath='{.items[*].metadata.name}'"
        )
        print(f"Flannel pods: {flannel_pods}")
        server.wait_until_succeeds(
            "k3s kubectl get pods -n kube-system -l app=flannel --field-selector=status.phase=Running | grep -q Running",
            timeout=120
        )
        print("✓ Flannel CNI is running")

        # Deploy test pod on server node
        print("\n[5/12] Deploying test pod on server node...")
        server_pod_yaml = """
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-server-pod
      labels:
        app: network-test
        role: server-pod
    spec:
      nodeSelector:
        kubernetes.io/hostname: server
      containers:
      - name: alpine
        image: alpine:latest
        command: ["sh", "-c", "apk add --no-cache curl && sleep 3600"]
    """
        server.succeed(f"cat > /tmp/server-pod.yaml << 'EOF'\n{server_pod_yaml}\nEOF")
        server.succeed("k3s kubectl apply -f /tmp/server-pod.yaml")
        server.wait_until_succeeds(
            "k3s kubectl get pod test-server-pod -o jsonpath='{.status.phase}' | grep Running",
            timeout=120
        )
        print("✓ Server pod is running")

        # Deploy test pod on agent node
        print("\n[6/12] Deploying test pod on agent node...")
        agent_pod_yaml = """
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-agent-pod
      labels:
        app: network-test
        role: agent-pod
    spec:
      nodeSelector:
        kubernetes.io/hostname: agent
      containers:
      - name: alpine
        image: alpine:latest
        command: ["sh", "-c", "apk add --no-cache curl && sleep 3600"]
    """
        server.succeed(f"cat > /tmp/agent-pod.yaml << 'EOF'\n{agent_pod_yaml}\nEOF")
        server.succeed("k3s kubectl apply -f /tmp/agent-pod.yaml")
        server.wait_until_succeeds(
            "k3s kubectl get pod test-agent-pod -o jsonpath='{.status.phase}' | grep Running",
            timeout=120
        )
        print("✓ Agent pod is running")

        # Wait for both pods to have IPs
        print("\n[7/12] Waiting for pod IPs...")
        time.sleep(5)
        server_pod_ip = server.succeed(
            "k3s kubectl get pod test-server-pod -o jsonpath='{.status.podIP}'"
        ).strip()
        agent_pod_ip = server.succeed(
            "k3s kubectl get pod test-agent-pod -o jsonpath='{.status.podIP}'"
        ).strip()
        print(f"Server pod IP: {server_pod_ip}")
        print(f"Agent pod IP: {agent_pod_ip}")
        assert server_pod_ip and agent_pod_ip, "Pod IPs not assigned"
        print("✓ Both pods have IPs")

        # Test pod-to-pod communication (agent -> server)
        print("\n[8/12] Testing pod-to-pod ping (agent -> server)...")
        server.wait_until_succeeds(
            f"k3s kubectl exec test-agent-pod -- ping -c 3 {server_pod_ip}",
            timeout=30
        )
        print(f"✓ Agent pod can ping server pod at {server_pod_ip}")

        # Test pod-to-pod communication (server -> agent)
        print("\n[9/12] Testing pod-to-pod ping (server -> agent)...")
        server.wait_until_succeeds(
            f"k3s kubectl exec test-server-pod -- ping -c 3 {agent_pod_ip}",
            timeout=30
        )
        print(f"✓ Server pod can ping agent pod at {agent_pod_ip}")

        # Create a service for the server pod
        print("\n[10/12] Creating service...")
        service_yaml = """
    apiVersion: v1
    kind: Service
    metadata:
      name: test-service
    spec:
      selector:
        role: server-pod
      ports:
      - port: 80
        targetPort: 80
      type: ClusterIP
    """
        server.succeed(f"cat > /tmp/service.yaml << 'EOF'\n{service_yaml}\nEOF")
        server.succeed("k3s kubectl apply -f /tmp/service.yaml")

        service_ip = server.succeed(
            "k3s kubectl get service test-service -o jsonpath='{.spec.clusterIP}'"
        ).strip()
        print(f"Service IP: {service_ip}")
        print("✓ Service created")

        # Test DNS resolution from agent pod
        print("\n[11/12] Testing DNS resolution...")
        server.wait_until_succeeds(
            "k3s kubectl exec test-agent-pod -- nslookup test-service.default.svc.cluster.local",
            timeout=30
        )
        print("✓ DNS resolution works (test-service.default.svc.cluster.local)")

        # Test DNS for pod hostname
        server.wait_until_succeeds(
            "k3s kubectl exec test-agent-pod -- nslookup kubernetes.default.svc.cluster.local",
            timeout=30
        )
        print("✓ DNS resolution works (kubernetes.default.svc.cluster.local)")

        # Verify CoreDNS is running
        print("\n[12/12] Verifying CoreDNS...")
        coredns_status = server.succeed(
            "k3s kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.phase}'"
        )
        assert "Running" in coredns_status, "CoreDNS not running"
        print("✓ CoreDNS is running")

        # Show full network status
        print("\n" + "=" * 60)
        print("Network Status Summary:")
        print("=" * 60)

        pods_output = server.succeed("k3s kubectl get pods -o wide")
        print("\nPods:")
        print(pods_output)

        services_output = server.succeed("k3s kubectl get services")
        print("\nServices:")
        print(services_output)

        # Clean up
        server.succeed("k3s kubectl delete pod test-server-pod test-agent-pod")
        server.succeed("k3s kubectl delete service test-service")

        print("\n" + "=" * 60)
        print("✓ All networking tests passed!")
        print("=" * 60)
        print("\nValidated:")
        print("  ✓ Flannel VXLAN overlay network")
        print("  ✓ Pod-to-pod communication across nodes")
        print("  ✓ Pod IP assignment and routing")
        print("  ✓ Service creation and ClusterIP allocation")
        print("  ✓ DNS resolution (CoreDNS)")
        print("  ✓ Service discovery via DNS")
  '';
}
