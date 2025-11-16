{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    # Hardware configuration
    ./hardware-configuration.nix

    # Disko disk configuration
    ../../disko/n100-standard.nix
  ];

  # Node-specific network configuration
  networking = {
    hostName = "n100-1";
    hostId = "1a2b3c01"; # Required for ZFS if used

    # Static IP configuration for management
    interfaces = {
      # Management interface (post-bond)
      bond0 = {
        ipv4.addresses = [{
          address = "10.0.1.11";
          prefixLength = 24;
        }];
      };
    };

    # Default gateway
    defaultGateway = {
      address = "10.0.1.1";
      interface = "bond0";
    };

    # DNS servers
    nameservers = [ "10.0.1.1" "1.1.1.1" ];
  };

  # K3s server role configuration
  services.k3s = {
    role = "server";
    serverAddr = ""; # This is the first server
    clusterInit = true; # Initialize the cluster

    # Server-specific settings
    extraFlags = [
      "--node-ip=10.0.1.11"
      "--cluster-cidr=10.42.0.0/16"
      "--service-cidr=10.43.0.0/16"
      "--flannel-backend=wireguard-native"
      "--disable=traefik"
      "--disable=servicelb"
      "--disable=local-storage"
      "--node-name=n100-1"
      "--tls-san=10.0.1.11"
      "--tls-san=n100-1.local"
    ];
  };

  # Node labels and taints
  systemd.services.k3s-node-labels = {
    description = "Apply K3s node labels and taints";
    after = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = ''
        ${pkgs.bash}/bin/bash -c '
          until ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; do
            sleep 5
          done
          ${pkgs.kubectl}/bin/kubectl label nodes n100-1 node-role.kubernetes.io/control-plane=true --overwrite
          ${pkgs.kubectl}/bin/kubectl label nodes n100-1 node.longhorn.io/create-default-disk=true --overwrite
          ${pkgs.kubectl}/bin/kubectl label nodes n100-1 hardware.n3x.io/type=n100 --overwrite
        '
      '';
    };
  };

  # Note: Longhorn storage filesystem is managed by disko configuration
  # See disko/n100-standard.nix for /var/lib/longhorn partition definition

  # Firewall configuration
  networking.firewall = {
    enable = true;

    # K3s required ports
    allowedTCPPorts = [
      6443  # Kubernetes API server
      2379  # etcd client requests
      2380  # etcd peer communication
      10250 # Kubelet API
      10251 # kube-scheduler
      10252 # kube-controller-manager
      10256 # kube-proxy
    ];

    # Flannel VXLAN
    allowedUDPPorts = [
      8472  # Flannel VXLAN
      51820 # WireGuard (if using flannel-backend=wireguard-native)
      51821 # WireGuard (additional)
    ];

    # Allow all traffic from cluster network
    extraCommands = ''
      iptables -A INPUT -s 10.42.0.0/16 -j ACCEPT
      iptables -A INPUT -s 10.43.0.0/16 -j ACCEPT
      iptables -A INPUT -s 10.0.1.0/24 -j ACCEPT
    '';
  };

  # System packages specific to this host
  environment.systemPackages = with pkgs; [
    kubectl
    k9s
    helm
  ];

  # Note: SSH is configured in modules/common/base.nix
  # Base module enables SSH with prohibit-password (key-based root login only)

  # SSH keys for access
  users.users.root.openssh.authorizedKeys.keys = [
    # Add your SSH public keys here
    # "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC..."
  ];

  # System state version
  system.stateVersion = "24.05";
}