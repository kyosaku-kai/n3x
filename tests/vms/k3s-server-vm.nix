# VM configuration for testing K3s server (control plane) nodes
# Usage: nix build .#nixosConfigurations.vm-k3s-server.config.system.build.vm
#        ./result/bin/run-vm-k3s-server-vm

{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    ./default.nix  # Base VM configuration
    ../../modules/common/base.nix
    ../../modules/common/nix-settings.nix
    ../../modules/common/networking.nix
    ../../modules/roles/k3s-server.nix
    ../../modules/roles/k3s-common.nix
  ];

  # Override hostname for this VM
  networking.hostName = "vm-k3s-server";

  # Increase resources for server node
  virtualisation = {
    memorySize = 4096;  # 4GB RAM for control plane
    cores = 2;
    diskSize = 30720;   # 30GB disk for server with etcd
  };

  # K3s server-specific test configuration
  services.k3s = {
    enable = true;
    role = "server";

    # Use SQLite for single-node testing (switch to etcd for HA testing)
    extraFlags = [
      "--write-kubeconfig-mode 0644"
      "--disable traefik"  # We'll deploy our own ingress
      "--disable servicelb" # We'll use MetalLB
      "--cluster-cidr 10.42.0.0/16"
      "--service-cidr 10.43.0.0/16"
    ];

    # For testing, use a static token
    tokenFile = pkgs.writeText "k3s-token" "test-token-do-not-use-in-production";

    # Server-specific settings for testing
    serverAddr = "";  # Empty for first server
    clusterInit = true;  # Initialize new cluster
  };

  # Additional test utilities for server nodes
  environment.systemPackages = with pkgs; [
    etcd  # For inspecting etcd if using HA mode
    sqlite  # For inspecting SQLite database
  ];

  # Test script to verify server is running
  systemd.services.k3s-test-verification = {
    description = "Verify K3s server is running correctly";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeScript "verify-k3s-server" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Waiting for K3s server to be ready..."
        for i in {1..30}; do
          if ${pkgs.k3s}/bin/k3s kubectl get nodes 2>/dev/null; then
            echo "K3s server is ready!"
            ${pkgs.k3s}/bin/k3s kubectl get nodes
            ${pkgs.k3s}/bin/k3s kubectl get pods -A
            exit 0
          fi
          sleep 5
        done

        echo "K3s server failed to start properly"
        exit 1
      '';
    };
  };

  # Open additional ports for K3s server
  networking.firewall.allowedTCPPorts = [
    2379  # etcd client
    2380  # etcd peer
    6443  # K3s API
    10250 # Kubelet metrics
    10251 # kube-scheduler
    10252 # kube-controller-manager
    10257 # kube-controller-manager secure
    10259 # kube-scheduler secure
  ];

  networking.firewall.allowedUDPPorts = [
    8472  # Flannel VXLAN
  ];
}