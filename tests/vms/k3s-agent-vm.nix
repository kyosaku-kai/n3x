# VM configuration for testing K3s agent (worker) nodes
# Usage: nix build .#nixosConfigurations.vm-k3s-agent.config.system.build.vm
#        ./result/bin/run-vm-k3s-agent-vm

{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    ./default.nix  # Base VM configuration
    ../../modules/common/base.nix
    ../../modules/common/nix-settings.nix
    ../../modules/common/networking.nix
    ../../modules/roles/k3s-agent.nix
    ../../modules/roles/k3s-common.nix
  ];

  # Override hostname for this VM
  networking.hostName = "vm-k3s-agent";

  # Agent nodes can have less resources than servers
  virtualisation = {
    memorySize = 2048;  # 2GB RAM for worker
    cores = 2;
    diskSize = 20480;   # 20GB disk for agent
  };

  # K3s agent-specific test configuration
  services.k3s = {
    enable = true;
    role = "agent";

    # Point to the server VM (adjust IP as needed for your test network)
    serverAddr = "https://192.168.122.10:6443";  # Adjust to your server VM IP

    # Use the same token as server for testing
    tokenFile = pkgs.writeText "k3s-token" "test-token-do-not-use-in-production";

    extraFlags = [
      "--node-label role=worker"
      "--node-label vm=true"
    ];
  };

  # Additional test utilities for agent nodes
  environment.systemPackages = with pkgs; [
    nfs-utils  # For testing NFS storage
    iscsi-initiator-utils  # For testing iSCSI storage
    criu  # For container migration testing
  ];

  # Test script to verify agent is running
  systemd.services.k3s-test-verification = {
    description = "Verify K3s agent is running correctly";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeScript "verify-k3s-agent" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Waiting for K3s agent to be ready..."
        for i in {1..30}; do
          if systemctl is-active k3s.service >/dev/null 2>&1; then
            echo "K3s agent service is active!"

            # Check if containerd is running
            if ${pkgs.k3s}/bin/k3s crictl ps >/dev/null 2>&1; then
              echo "Containerd is responding"
              ${pkgs.k3s}/bin/k3s crictl ps
            fi

            exit 0
          fi
          sleep 5
        done

        echo "K3s agent failed to start properly"
        exit 1
      '';
    };
  };

  # Open ports for K3s agent
  networking.firewall.allowedTCPPorts = [
    10250 # Kubelet metrics
    30000 # NodePort range start
    32767 # NodePort range end (using limited range for testing)
  ];

  networking.firewall.allowedUDPPorts = [
    8472  # Flannel VXLAN
  ];

  # Configure container runtime for testing
  virtualisation.containerd = {
    settings = {
      plugins."io.containerd.grpc.v1.cri" = {
        # Enable container runtime testing features
        enable_selinux = false;
        enable_unprivileged_ports = true;
        enable_unprivileged_icmp = true;
      };
    };
  };
}