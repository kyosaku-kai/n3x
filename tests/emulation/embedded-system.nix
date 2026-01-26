# embedded-system.nix
#
# Refactored embedded system emulator using n3x modules and library functions.
# This creates a nested virtualization environment for testing n3x's production
# k3s cluster configurations before bare-metal deployment.
#
# This module imports:
# - mkInnerVM: Generates libvirt VM definitions from n3x host configs
# - mkInnerVMImage: Builds pre-installed qcow2 images for inner VMs
# - mkOVSBridge: Configures OVS switch fabric for VM networking
# - mkTCProfiles: Generates traffic control scripts for network simulation
#
# ARCHITECTURE:
#   Outer VM (this configuration)
#   ├── libvirtd (VM management)
#   ├── openvswitch (ovsbr0 bridge - simulates switch fabric)
#   ├── dnsmasq (DHCP/DNS for inner VMs)
#   └── Inner VMs (n3x production configs - pre-installed NixOS):
#       ├── n100-1 (k3s Server) - 192.168.100.10
#       ├── n100-2 (k3s Server) - 192.168.100.11
#       ├── n100-3 (k3s Agent)  - 192.168.100.12
#       └── jetson-1 (k3s Agent, ARM64) - 192.168.100.20
#
# USAGE:
#   # Build the emulation VM (includes pre-built inner VM images)
#   nix build .#nixosConfigurations.emulator-vm.config.system.build.vm
#
#   # Run the outer VM
#   ./result/bin/run-*-vm
#
#   # Inside outer VM:
#   virsh list --all        # List defined VMs
#   virsh start n100-1      # Start a VM (boots directly to NixOS!)
#   virsh console n100-1    # Console access (Ctrl+] to exit)
#
# PREREQUISITES:
#   - Nested virtualization enabled on host:
#     echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
#
# IMAGE BUILD NOTE:
#   Inner VM images are built at flake evaluation time using mkInnerVMImage.
#   The first build may take a while as it creates full NixOS installations.
#   Subsequent builds use the Nix store cache.
#
# See VSIM-INTEGRATION-PLAN.md for integration roadmap.

{ config, pkgs, lib, modulesPath, inputs ? { }, ... }:

let
  #############################################################################
  # LIBRARY IMPORTS
  #############################################################################

  # Import mkInnerVM generator
  # Note: This function creates libvirt VM definitions from n3x host configs
  # It handles architecture detection, QoS profiles, and extra disks
  mkInnerVM = import ./lib/mkInnerVM.nix {
    inherit pkgs lib inputs;
  };

  # Import mkInnerVMImage generator
  # Note: This function builds pre-installed qcow2 disk images from n3x host configs
  # Images are built at nix evaluation time and stored in the Nix store
  mkInnerVMImage = import ./lib/mkInnerVMImage.nix {
    inherit pkgs lib inputs;
    baseDir = ./.; # Path to tests/emulation directory
  };

  #############################################################################
  # INNER VM DISK IMAGES (Pre-built NixOS installations)
  #############################################################################
  #
  # These images contain full NixOS installations with k3s pre-configured.
  # Building these images takes time on first run, but results are cached.
  #
  # NOTE: ARM64 images (jetson-1) require binfmt emulation on the build host.
  # The outer VM has boot.binfmt.emulatedSystems = [ "aarch64-linux" ] enabled.

  innerVMImages = {
    # x86_64 VMs - built natively
    n100-1 = mkInnerVMImage {
      hostname = "n100-1";
      diskSize = 8192; # 8GB
    };
    n100-2 = mkInnerVMImage {
      hostname = "n100-2";
      diskSize = 8192;
    };
    n100-3 = mkInnerVMImage {
      hostname = "n100-3";
      diskSize = 8192;
    };
    # ARM64 VM - built via binfmt emulation (SLOW)
    # Disabled by default - uncomment to enable ARM64 image building
    # jetson-1 = mkInnerVMImage {
    #   hostname = "jetson-1";
    #   diskSize = 8192;
    #   arch = "aarch64";
    # };
  };

  # Import OVS bridge configuration
  mkOVSBridge = import ./lib/mkOVSBridge.nix {
    inherit config lib pkgs;
  };

  # Import traffic control profiles
  mkTCProfiles = import ./lib/mkTCProfiles.nix {
    inherit pkgs;
  };

  #############################################################################
  # NETWORK CONFIGURATION
  #############################################################################

  network = {
    bridge = "ovsbr0";
    # Use "ovshost0" to avoid conflict with libvirt's vnet0/vnet1/etc. naming
    hostInterface = "ovshost0";
    hostIP = "192.168.100.1";
    cidr = "/24";
    dhcpStart = "192.168.100.100";
    dhcpEnd = "192.168.100.200";
  };

  #############################################################################
  # INNER VM DEFINITIONS - Using n3x Host Configurations
  #############################################################################
  #
  # These VMs use actual n3x host configurations from hosts/
  # This ensures we're testing the same code that will be deployed to hardware.
  #
  # Each VM now references a pre-built qcow2 image from innerVMImages.
  # The setup-inner-vms service copies these images to /var/lib/libvirt/images/
  # on first boot, so VMs boot directly into NixOS without installation.

  innerVMs = [
    # n100-1: Primary k3s server (control plane leader)
    (mkInnerVM {
      hostname = "n100-1";
      mac = "52:54:00:12:34:01";
      ip = "192.168.100.10";
      memory = 4096; # 4GB for k3s server
      vcpus = 2;
      qosProfile = "default"; # Full gigabit speed
      diskImagePath = innerVMImages.n100-1.imagePath;
    })

    # n100-2: Secondary k3s server (HA control plane)
    (mkInnerVM {
      hostname = "n100-2";
      mac = "52:54:00:12:34:02";
      ip = "192.168.100.11";
      memory = 4096;
      vcpus = 2;
      qosProfile = "default";
      diskImagePath = innerVMImages.n100-2.imagePath;
    })

    # n100-3: k3s agent with extra storage disk (Longhorn)
    (mkInnerVM {
      hostname = "n100-3";
      mac = "52:54:00:12:34:03";
      ip = "192.168.100.12";
      memory = 2048; # 2GB for agent
      vcpus = 2;
      extraDiskSize = 10; # 10GB for Longhorn storage testing
      qosProfile = "default";
      diskImagePath = innerVMImages.n100-3.imagePath;
    })

    # jetson-1: ARM64 k3s agent via QEMU TCG emulation
    # NOTE: TCG emulation is SLOW (~10-20x slower than native).
    # Use only for cross-architecture validation, not performance testing.
    # NOTE: ARM64 image building is slow. diskImagePath is null until enabled.
    (mkInnerVM {
      hostname = "jetson-1";
      mac = "52:54:00:12:34:10";
      ip = "192.168.100.20";
      memory = 2048; # 2GB RAM
      vcpus = 2;
      arch = "aarch64"; # Forces QEMU TCG emulation
      qosProfile = "constrained"; # Simulate embedded ARM limits
      # diskImagePath = innerVMImages.jetson-1.imagePath; # Enable when ARM64 images are built
    })
  ];

  #############################################################################
  # OVS BRIDGE CONFIGURATION
  #############################################################################

  ovsConfig = mkOVSBridge {
    bridgeName = network.bridge;
    hostInterface = network.hostInterface;
    hostIP = network.hostIP;
    cidr = network.cidr;
  };

in
{
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
  ];

  config = lib.mkMerge [
    # Apply OVS bridge configuration from mkOVSBridge
    ovsConfig

    {
      #############################################################################
      # KERNEL & VIRTUALIZATION
      #############################################################################

      # KVM modules for nested virtualization
      boot.kernelModules = [ "kvm-intel" "kvm-amd" "vhost_net" ];

      # Disable binfmt by default - ARM64 emulation adds boot overhead
      # Enable if you need to build/test Jetson (ARM64) configurations
      # boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

      # Outer VM resources (adjust based on host capabilities)
      virtualisation = {
        memorySize = 12288; # 12GB RAM for outer VM (hosts 3 inner VMs)
        diskSize = 60000; # 60GB disk
        cores = 8; # 8 vCPUs
        # NOTE: graphics and serial console settings are left to defaults.
        # When used interactively: set graphics=false via command line if needed
        # When used in NixOS tests: the test framework handles serial/backdoor setup
        # Avoid setting -serial here as it conflicts with test driver's serial setup
      };

      # Fast shutdown timeouts for testing environment
      # NOTE: Using systemd.extraConfig instead of systemd.settings.Manager because
      # systemd.settings was introduced in nixpkgs ~24.05+, and n3x's current nixpkgs
      # revision doesn't have this option.
      # TODO: Convert to systemd.settings.Manager.DefaultTimeoutStopSec = "10s"
      #       when nixpkgs is updated.
      # ERROR being worked around: "The option `systemd.settings' does not exist"
      systemd.extraConfig = "DefaultTimeoutStopSec=10s";

      #############################################################################
      # LIBVIRT CONFIGURATION
      #############################################################################

      virtualisation.libvirtd = {
        enable = true;
        # Fast shutdown: destroy VMs immediately instead of suspending
        onShutdown = "shutdown";
        shutdownTimeout = 5; # 5 seconds max wait for VM shutdown
        parallelShutdown = 4; # Shutdown all VMs in parallel
        qemu = {
          runAsRoot = true;
          package = pkgs.qemu; # Full QEMU with ARM64 support
        };
      };

      #############################################################################
      # DNSMASQ - DHCP/DNS FOR INNER VMS
      #############################################################################

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = network.hostInterface;
          bind-interfaces = true;
          dhcp-range = [ "${network.dhcpStart},${network.dhcpEnd},12h" ];
          # Static IP assignments from innerVMs definitions
          dhcp-host = map (vm: "${vm.mac},${vm.hostname},${vm.ip}") innerVMs;
          # DNS entries for cluster nodes
          address = map (vm: "/${vm.hostname}.local/${vm.ip}") innerVMs;
        };
      };

      #############################################################################
      # INNER VM INITIALIZATION SERVICE
      #############################################################################

      systemd.services.setup-inner-vms = {
        description = "Initialize inner VMs using n3x configurations";
        after = [ "libvirtd.service" "openvswitch.service" ];
        wants = [ "libvirtd.service" "openvswitch.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Large qcow2 images take time to copy in a VM - allow up to 15 minutes
          TimeoutStartSec = 900;
        };
        path = [ pkgs.qemu pkgs.libvirt pkgs.coreutils ];

        script = ''
          set -euo pipefail
          mkdir -p /var/lib/libvirt/images
          mkdir -p /var/lib/libvirt/qemu/nvram

          ${lib.concatMapStrings (vm: ''
            # Setup system disk for ${vm.hostname}
            if [ ! -f /var/lib/libvirt/images/${vm.hostname}.qcow2 ]; then
              ${if vm.diskImagePath != null then ''
              # Copy pre-built NixOS image from Nix store
              echo "Copying pre-built image for ${vm.hostname}..."
              cp ${vm.diskImagePath} /var/lib/libvirt/images/${vm.hostname}.qcow2
              chmod 644 /var/lib/libvirt/images/${vm.hostname}.qcow2
              echo "  -> Pre-installed NixOS image ready"
              '' else ''
              # No pre-built image - create empty disk
              echo "Creating empty disk for ${vm.hostname} (no pre-built image)..."
              qemu-img create -f qcow2 /var/lib/libvirt/images/${vm.hostname}.qcow2 8G
              echo "  -> Empty disk created (requires manual NixOS installation)"
              ''}
            else
              echo "Disk for ${vm.hostname} already exists, skipping..."
            fi

            ${lib.optionalString (vm.extraDiskSize > 0) ''
              # Create extra storage disk for Longhorn/data
              [ -f /var/lib/libvirt/images/${vm.hostname}-data.qcow2 ] || \
                qemu-img create -f qcow2 /var/lib/libvirt/images/${vm.hostname}-data.qcow2 ${toString vm.extraDiskSize}G
            ''}

            ${lib.optionalString vm.meta.isArm ''
              # Create NVRAM file for ARM64 UEFI (64MB, matching EDK2 requirements)
              [ -f /var/lib/libvirt/qemu/nvram/${vm.hostname}_VARS.fd ] || \
                qemu-img create -f raw /var/lib/libvirt/qemu/nvram/${vm.hostname}_VARS.fd 64M
            ''}

            # Define VM in libvirt
            virsh dominfo ${vm.hostname} &>/dev/null || virsh define ${vm.xml}

            echo "Configured: ${vm.hostname} (${vm.arch}) - ${vm.description}"
          '') innerVMs}

          echo ""
          echo "All inner VMs configured. Use 'virsh list --all' to see them."
          echo ""
          echo "VMs with pre-built images boot directly to NixOS."
          echo "VMs with empty disks require manual installation."
        '';
      };

      #############################################################################
      # NETWORK SIMULATION SETUP
      #############################################################################

      systemd.services.setup-network-simulation = {
        description = "Configure network simulation parameters";
        after = [ "openvswitch.service" "setup-inner-vms.service" ];
        wants = [ "openvswitch.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        path = [ pkgs.iproute2 pkgs.openvswitch ];

        script = ''
          # Wait for OVS to be ready
          sleep 2

          # Configure OVS for switch simulation
          ovs-vsctl set bridge ${network.bridge} \
            stp_enable=true \
            other_config:forward-bpdu=true \
            fail_mode=standalone

          echo "OVS switch fabric configured with STP enabled"
        '';
      };

      #############################################################################
      # TRAFFIC CONTROL SCRIPT
      #############################################################################

      # Use mkTCProfiles to generate the constraint simulation script
      environment.etc."tc-simulate-constraints.sh" = mkTCProfiles;

      #############################################################################
      # PACKAGES & TOOLS (minimal set for headless hypervisor)
      #############################################################################

      environment.systemPackages = with pkgs; [
        # Virtualization management (virsh CLI only, no GUI)
        libvirt

        # Networking tools (essential for OVS and debugging)
        openvswitch
        iproute2

        # Minimal utilities
        tmux # For managing multiple consoles
        vim
        jq
      ];

      # Disable unnecessary services for faster boot
      services.udisks2.enable = false;
      xdg.portal.enable = false;
      documentation.enable = false;
      documentation.nixos.enable = false;

      # Prevent dhcpcd from interfering with OVS internal interfaces
      # The ovshost0 interface is managed by systemd-networkd with static IP
      # dhcpcd would otherwise override with IPv4LL (169.254.x.x)
      networking.dhcpcd.denyInterfaces = [ "ovshost0" "ovsbr0" "ovs-system" "vnet*" ];

      #############################################################################
      # USER CONFIGURATION
      #############################################################################

      services.getty.autologinUser = "root";
      users.users.root.initialPassword = "test";
      users.users.root.extraGroups = [ "libvirtd" ];

      #############################################################################
      # WELCOME MESSAGE
      #############################################################################

      environment.etc."motd".text = ''

  ================================================================================
            n3x Emulation Environment (Headless Mode)
  ================================================================================

  CLUSTER NODES:
    * n100-1 (x86_64)  - k3s Server - 192.168.100.10  [${if (builtins.elemAt innerVMs 0).diskImagePath != null then "READY" else "empty"}]
    * n100-2 (x86_64)  - k3s Server - 192.168.100.11  [${if (builtins.elemAt innerVMs 1).diskImagePath != null then "READY" else "empty"}]
    * n100-3 (x86_64)  - k3s Agent  - 192.168.100.12  [${if (builtins.elemAt innerVMs 2).diskImagePath != null then "READY" else "empty"}]
    * jetson-1 (arm64) - k3s Agent  - 192.168.100.20  [${if (builtins.elemAt innerVMs 3).diskImagePath != null then "READY" else "empty"}]

  COMMANDS:
    virsh list --all              # List VMs
    virsh start n100-1            # Start VM
    virsh console n100-1          # Attach console (Ctrl+] to detach)
    virsh destroy n100-1          # Force stop VM
    ovs-vsctl show                # View network topology

  QUICK START:
    virsh start n100-1 && virsh console n100-1
    # Login: root / test

  NETWORK: ${network.bridge} @ ${network.hostIP}${network.cidr}
  SHUTDOWN: Type 'poweroff' (fast shutdown configured)

  ================================================================================

      '';

      system.stateVersion = "24.05";
    }
  ];
}
