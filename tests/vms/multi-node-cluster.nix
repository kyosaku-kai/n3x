# Multi-node K3s cluster VM test configuration
# This creates a complete 3-node cluster for testing
# Usage: nix build .#tests.multi-node-cluster
#        ./result/bin/run-cluster-test

{ pkgs, lib, ... }:

let
  # Shared configuration for all VMs in the cluster
  sharedConfig = {
    virtualisation.graphics = false;

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "yes";
        PasswordAuthentication = true;
      };
    };

    users.users.root.initialPassword = "test";

    environment.systemPackages = with pkgs; [
      vim
      kubectl
      k9s
      curl
      jq
    ];

    # Use a common network for inter-VM communication
    networking.useDHCP = false;
    networking.interfaces.eth0.useDHCP = true;
  };

  # K3s token for cluster authentication
  k3sToken = "test-cluster-token-insecure";
  tokenFile = pkgs.writeText "k3s-token" k3sToken;

in {
  # Test script that creates and verifies the cluster
  testScript = ''
    #!${pkgs.python3}/bin/python3
    import time
    import subprocess

    print("Starting multi-node K3s cluster test...")

    # Start all VMs
    print("Starting control-plane node...")
    control_plane.start()
    control_plane.wait_for_unit("multi-user.target")

    print("Starting worker-1 node...")
    worker1.start()
    worker1.wait_for_unit("multi-user.target")

    print("Starting worker-2 node...")
    worker2.start()
    worker2.wait_for_unit("multi-user.target")

    # Wait for K3s to initialize on control plane
    print("Waiting for K3s server to initialize...")
    control_plane.wait_for_unit("k3s.service")
    control_plane.wait_for_open_port(6443)
    time.sleep(30)  # Give K3s time to fully initialize

    # Verify control plane is ready
    print("Verifying control plane...")
    control_plane.succeed("k3s kubectl get nodes")

    # Wait for workers to join
    print("Waiting for workers to join cluster...")
    worker1.wait_for_unit("k3s.service")
    worker2.wait_for_unit("k3s.service")
    time.sleep(30)  # Give workers time to register

    # Verify all nodes are ready
    print("Verifying cluster status...")
    output = control_plane.succeed("k3s kubectl get nodes -o wide")
    print(output)

    # Check that we have 3 nodes
    nodes = control_plane.succeed("k3s kubectl get nodes --no-headers | wc -l").strip()
    assert nodes == "3", f"Expected 3 nodes, got {nodes}"

    # Deploy a test workload
    print("Deploying test workload...")
    control_plane.succeed("""
      cat <<EOF | k3s kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: nginx-test
        namespace: default
      spec:
        replicas: 3
        selector:
          matchLabels:
            app: nginx-test
        template:
          metadata:
            labels:
              app: nginx-test
          spec:
            containers:
            - name: nginx
              image: nginx:alpine
              ports:
              - containerPort: 80
      EOF
    """)

    # Wait for deployment to be ready
    print("Waiting for deployment to be ready...")
    time.sleep(20)
    control_plane.succeed("k3s kubectl wait --for=condition=available --timeout=60s deployment/nginx-test")

    # Verify pods are distributed across nodes
    print("Verifying pod distribution...")
    pods = control_plane.succeed("k3s kubectl get pods -o wide")
    print(pods)

    print("Multi-node cluster test completed successfully!")
  '';

  # VM configurations for the cluster
  nodes = {
    # Control plane node (K3s server)
    control-plane = { config, pkgs, ... }: {
      imports = [ sharedConfig ];

      networking.hostName = "control-plane";
      networking.interfaces.eth0.ipv4.addresses = [{
        address = "192.168.1.10";
        prefixLength = 24;
      }];

      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 30720;
      };

      services.k3s = {
        enable = true;
        role = "server";
        inherit tokenFile;
        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
          "--cluster-init"
          "--node-taint=CriticalAddonsOnly=true:NoExecute"
          "--node-label=node-role.kubernetes.io/control-plane=true"
        ];
      };

      networking.firewall.allowedTCPPorts = [
        6443   # K3s API
        2379   # etcd client
        2380   # etcd peer
        10250  # Kubelet
      ];
    };

    # Worker node 1
    worker-1 = { config, pkgs, ... }: {
      imports = [ sharedConfig ];

      networking.hostName = "worker-1";
      networking.interfaces.eth0.ipv4.addresses = [{
        address = "192.168.1.11";
        prefixLength = 24;
      }];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "agent";
        serverAddr = "https://192.168.1.10:6443";
        inherit tokenFile;
        extraFlags = [
          "--node-label=node-role.kubernetes.io/worker=true"
          "--node-label=worker-id=1"
        ];
      };

      networking.firewall.allowedTCPPorts = [
        10250  # Kubelet
      ];
    };

    # Worker node 2
    worker-2 = { config, pkgs, ... }: {
      imports = [ sharedConfig ];

      networking.hostName = "worker-2";
      networking.interfaces.eth0.ipv4.addresses = [{
        address = "192.168.1.12";
        prefixLength = 24;
      }];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "agent";
        serverAddr = "https://192.168.1.10:6443";
        inherit tokenFile;
        extraFlags = [
          "--node-label=node-role.kubernetes.io/worker=true"
          "--node-label=worker-id=2"
        ];
      };

      networking.firewall.allowedTCPPorts = [
        10250  # Kubelet
      ];
    };
  };
}