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
    hostName = "n100-3";
    hostId = "1a2b3c03"; # Required for ZFS if used

    # Static IP configuration for management
    interfaces = {
      # Management interface (post-bond)
      bond0 = {
        ipv4.addresses = [{
          address = "10.0.1.13";
          prefixLength = 24;
        }];
      };
    };

    # Default gateway
    defaultGateway = "10.0.1.1";

    # DNS servers
    nameservers = [ "10.0.1.1" "1.1.1.1" ];
  };

  # K3s agent role configuration
  services.k3s = {
    role = "agent";
    serverAddr = "https://10.0.1.11:6443"; # Connect to first server

    # Agent-specific settings
    extraFlags = [
      "--node-ip=10.0.1.13"
      "--node-name=n100-3"
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
          ${pkgs.kubectl}/bin/kubectl label nodes n100-3 node-role.kubernetes.io/worker=true --overwrite
          ${pkgs.kubectl}/bin/kubectl label nodes n100-3 node.longhorn.io/create-default-disk=true --overwrite
          ${pkgs.kubectl}/bin/kubectl label nodes n100-3 hardware.n3x.io/type=n100 --overwrite
        '
      '';
    };
  };

  # Storage configuration for Longhorn
  fileSystems."/var/lib/longhorn" = {
    device = "/dev/disk/by-label/longhorn";
    fsType = "ext4";
    options = [ "defaults" "noatime" ];
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;

    # K3s agent required ports
    allowedTCPPorts = [
      10250 # Kubelet API
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
  ];

  # Enable SSH
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "yes";
    PasswordAuthentication = false;
  };

  # SSH keys for access
  users.users.root.openssh.authorizedKeys.keys = [
    # Add your SSH public keys here
    # "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC..."
  ];

  # System state version
  system.stateVersion = "24.05";
}