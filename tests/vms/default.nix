# VM Testing Configuration for n3x
# This module provides VM configurations for testing the n3x cluster setup
# Usage: nixos-rebuild build-vm --flake .#vm-test-server

{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
  ];

  # VM-specific configuration
  virtualisation = {
    # Memory allocation for the VM
    memorySize = lib.mkDefault 4096; # 4GB RAM for testing k3s

    # Disk size for the VM
    diskSize = lib.mkDefault 20480; # 20GB disk

    # Enable graphics for debugging (disable for headless)
    graphics = lib.mkDefault false;

    # CPU cores
    cores = lib.mkDefault 2;

    # Use UEFI boot like real hardware
    useEFIBoot = true;

    # Enable nested virtualization for container workloads
    qemu.options = [
      "-cpu host,+vmx" # Intel VT-x
      "-enable-kvm"
    ];

    # Network configuration for VM
    # Creates a bridge interface for VM networking
    qemu.networkingOptions = [
      "-netdev user,id=net0,hostfwd=tcp::6443-:6443,hostfwd=tcp::10250-:10250"
      "-device virtio-net-pci,netdev=net0"
    ];

    # Shared directories between host and VM
    # Using default nix-store sharing configuration from qemu-vm.nix

    # Forward ports from the VM to the host
    forwardPorts = [
      { from = "host"; host.port = 6443; guest.port = 6443; } # K3s API
      { from = "host"; host.port = 10250; guest.port = 10250; } # Kubelet API
      { from = "host"; host.port = 8080; guest.port = 80; } # HTTP
      { from = "host"; host.port = 8443; guest.port = 443; } # HTTPS
    ];
  };

  # Basic networking setup for VM
  networking = {
    hostName = lib.mkDefault "vm-test";
    useDHCP = false;
    interfaces.eth0.useDHCP = true;

    # Firewall configuration for testing
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # SSH
        6443 # K3s API
        10250 # Kubelet
        80 # HTTP
        443 # HTTPS
        2379 # etcd client
        2380 # etcd peer
      ];
    };
  };

  # Enable SSH for remote access to VM
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
      PasswordAuthentication = lib.mkForce true;
    };
  };

  # Set a default root password for testing (insecure, for testing only)
  users.users.root = {
    initialPassword = "test";
  };

  # Console configuration for debugging
  console = {
    earlySetup = true;
    keyMap = "us";
  };

  # Enable serial console for debugging
  boot.kernelParams = [ "console=ttyS0,115200" ];

  # System packages useful for testing
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tmux
    kubectl
    k9s
    tcpdump
    netcat
    dig
    jq
  ];

  # Faster boot for testing
  boot.loader.timeout = 1;

  # Disable documentation to save space in VM
  documentation = {
    enable = false;
    nixos.enable = false;
    man.enable = false;
    doc.enable = false;
  };

  system.stateVersion = "24.05";
}
