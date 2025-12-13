# embedded-system-emulator.nix
#
# Declarative NixOS configuration for embedded system emulation platform
#
# This configuration creates a nested virtualization environment that emulates:
#   - CHASSIS: ARM64 Jetson/Nano SOM running k3s Server (Control Plane)
#   - COMPUTE: x86_64 compute node running k3s Agent
#   - STORAGE: x86_64 storage node running k3s Agent with extra disk
#
# All nodes are interconnected through an Open vSwitch bridge that emulates
# a Marvell switch fabric with configurable QoS and traffic shaping.
#
# USAGE:
#   1. Build:  nixos-rebuild build-vm -I nixos-config=./embedded-system-emulator.nix
#   2. Run:    ./result/bin/run-*-vm
#   3. Inside: virsh list --all && virsh start chassis
#
# PREREQUISITES:
#   - Nested virtualization enabled on host:
#     echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf

{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
  ];

  config =
    let
      #############################################################################
      # CONFIGURATION - Adjust these values as needed
      #############################################################################

      network = {
        bridge = "ovsbr0";
        hostInterface = "vnet0";
        hostIP = "192.168.100.1";
        cidr = "/24";
        dhcpStart = "192.168.100.100";
        dhcpEnd = "192.168.100.200";
      };

      # k3s cluster token - REPLACE WITH SECURE VALUE
      # Generate with: openssl rand -hex 32
      k3sToken = "REPLACE_WITH_SECURE_TOKEN_BEFORE_USE";

      #############################################################################
      # VM DEFINITIONS - Embedded System Nodes
      #############################################################################

      vmDefinitions = [
        # CHASSIS: ARM64 Jetson/Nano SOM emulation - k3s Server (Control Plane)
        {
          name = "chassis";
          mac = "52:54:00:12:34:01";
          arch = "aarch64"; # ARM64 emulation via QEMU TCG
          memory = 1024; # 1GB RAM (ARM64 needs more for emulation overhead)
          vcpus = 2;
          ip = "192.168.100.10";
          role = "k3s-server";
          description = "Jetson/Nano SOM - k3s Control Plane";
          cpuModel = "cortex-a57"; # Matches Jetson Nano CPU
        }
        # COMPUTE: x86_64 compute node - k3s Agent
        {
          name = "compute";
          mac = "52:54:00:12:34:02";
          arch = "x86_64"; # Native KVM acceleration
          memory = 512; # 512MB RAM
          vcpus = 1;
          ip = "192.168.100.11";
          role = "k3s-agent";
          description = "Compute Node - k3s Worker";
          cpuModel = "host-passthrough";
        }
        # STORAGE: x86_64 storage node - k3s Agent with extra disk
        {
          name = "storage";
          mac = "52:54:00:12:34:03";
          arch = "x86_64"; # Native KVM acceleration
          memory = 512; # 512MB RAM
          vcpus = 1;
          ip = "192.168.100.12";
          role = "k3s-agent";
          description = "Storage Node - k3s Worker + Persistent Storage";
          cpuModel = "host-passthrough";
          extraDiskSize = 10; # 10GB additional storage disk
        }
      ];

      #############################################################################
      # NETWORK QOS PROFILES - Simulating Hardware Constraints
      #############################################################################

      # Values in kbps for libvirt bandwidth settings
      qosProfiles = {
        # Embedded ARM boards typically have limited network throughput
        chassis = {
          inbound = { average = 100000; peak = 200000; burst = 10240; }; # 100Mbps
          outbound = { average = 100000; peak = 200000; burst = 10240; };
        };
        # x86 nodes get full gigabit
        compute = {
          inbound = { average = 1000000; peak = 2000000; burst = 10240; }; # 1Gbps
          outbound = { average = 1000000; peak = 2000000; burst = 10240; };
        };
        storage = {
          inbound = { average = 1000000; peak = 2000000; burst = 10240; }; # 1Gbps
          outbound = { average = 1000000; peak = 2000000; burst = 10240; };
        };
      };

      #############################################################################
      # VM TEMPLATE GENERATOR - Creates libvirt domain XML
      #############################################################################

      mkLibvirtXML = vm:
        let
          isArm = vm.arch == "aarch64";
          emulator =
            if isArm
            then "${pkgs.qemu}/bin/qemu-system-aarch64"
            else "${pkgs.qemu}/bin/qemu-system-x86_64";
          machineType = if isArm then "virt" else "q35";
          qos = qosProfiles.${vm.name} or qosProfiles.compute;

          # Extra storage disk for storage node
          extraDisk =
            if (vm ? extraDiskSize && vm.extraDiskSize > 0) then ''
              <disk type='file' device='disk'>
                <driver name='qemu' type='qcow2' cache='writeback'/>
                <source file='/var/lib/libvirt/images/${vm.name}-data.qcow2'/>
                <target dev='vdb' bus='virtio'/>
              </disk>
            '' else "";

          # ARM64 requires UEFI firmware (AAVMF)
          firmwareConfig =
            if isArm then ''
              <loader readonly='yes' type='pflash'>${pkgs.OVMF.fd}/AAVMF/QEMU_EFI-pflash.raw</loader>
              <nvram template='${pkgs.OVMF.fd}/AAVMF/vars-template-pflash.raw'>/var/lib/libvirt/qemu/nvram/${vm.name}_VARS.fd</nvram>
            '' else "";
        in
        pkgs.writeText "${vm.name}.xml" ''
          <domain type='${if isArm then "qemu" else "kvm"}'>
            <n>${vm.name}</n>
            <description>${vm.description}</description>
            <memory unit='MiB'>${toString vm.memory}</memory>
            <vcpu placement='static'>${toString vm.vcpus}</vcpu>
        
            <!-- Resource Controls for CPU and Memory -->
            <cputune>
              <shares>${toString (vm.vcpus * 1024)}</shares>
              <!-- Uncomment to add strict CPU limits:
              <period>100000</period>
              <quota>50000</quota>
              -->
            </cputune>
            <memtune>
              <hard_limit unit='MiB'>${toString (vm.memory + 128)}</hard_limit>
              <soft_limit unit='MiB'>${toString vm.memory}</soft_limit>
            </memtune>
        
            <cpu mode='${if isArm then "custom" else "host-passthrough"}'>
              ${if isArm then "<model>${vm.cpuModel}</model>" else ""}
            </cpu>
        
            <os>
              <type arch='${vm.arch}' machine='${machineType}'>hvm</type>
              ${firmwareConfig}
              <boot dev='hd'/>
            </os>
        
            <features>
              <acpi/>
              ${if !isArm then "<apic/>" else ""}
              ${if isArm then "<gic version='3'/>" else ""}
            </features>
        
            <devices>
              <emulator>${emulator}</emulator>
          
              <!-- System Disk -->
              <disk type='file' device='disk'>
                <driver name='qemu' type='qcow2' cache='writeback'/>
                <source file='/var/lib/libvirt/images/${vm.name}.qcow2'/>
                <target dev='vda' bus='virtio'/>
              </disk>
          
              ${extraDisk}
          
              <!-- Network Interface via OVS Bridge with QoS -->
              <interface type='bridge'>
                <source bridge='${network.bridge}'/>
                <virtualport type='openvswitch'/>
                <mac address='${vm.mac}'/>
                <model type='virtio'/>
                <bandwidth>
                  <inbound average='${toString qos.inbound.average}' 
                           peak='${toString qos.inbound.peak}' 
                           burst='${toString qos.inbound.burst}'/>
                  <outbound average='${toString qos.outbound.average}' 
                            peak='${toString qos.outbound.peak}' 
                            burst='${toString qos.outbound.burst}'/>
                </bandwidth>
                <alias name='vnet-${vm.name}'/>
              </interface>
          
              <!-- Console Access -->
              <serial type='pty'><target port='0'/></serial>
              <console type='pty'><target type='serial' port='0'/></console>
              <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
            </devices>
          </domain>
        '';

      # Generate VM definitions with XML
      innerVMs = map (vm: vm // { xml = mkLibvirtXML vm; }) vmDefinitions;

    in
    {

      #############################################################################
      # KERNEL & VIRTUALIZATION
      #############################################################################

      # KVM modules for nested virtualization
      boot.kernelModules = [ "kvm-intel" "kvm-amd" "vhost_net" ];

      # Enable binfmt for running ARM64 binaries on x86_64
      boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

      # Outer VM resources (adjust based on host capabilities)
      virtualisation = {
        memorySize = 8192; # 8GB RAM for outer VM
        diskSize = 50000; # 50GB disk
        qemu.options = [
          "-smp 8" # 8 vCPUs
        ];
      };

      #############################################################################
      # LIBVIRT CONFIGURATION
      #############################################################################

      virtualisation.libvirtd = {
        enable = true;
        qemu = {
          # OVMF firmware is now included by default in newer NixOS
          runAsRoot = true;
          package = pkgs.qemu; # Full QEMU with ARM64 support
        };
      };

      #############################################################################
      # OPEN VSWITCH - MARVELL SWITCH FABRIC EMULATION
      #############################################################################

      # Open vSwitch is enabled implicitly via networking.vswitches configuration
      networking.vswitches.${network.bridge} = {
        interfaces = { };
        extraOvsctlCmds = ''
          -- --may-exist add-port ${network.bridge} ${network.hostInterface} \
          -- set interface ${network.hostInterface} type=internal
        '';
      };

      # Host interface on OVS bridge
      systemd.network = {
        enable = true;
        networks."50-ovs-internal" = {
          matchConfig.Name = network.hostInterface;
          address = [ "${network.hostIP}${network.cidr}" ];
          networkConfig.ConfigureWithoutCarrier = true;
        };
      };

      #############################################################################
      # DNSMASQ - DHCP/DNS FOR CLUSTER NODES
      #############################################################################

      services.dnsmasq = {
        enable = true;
        settings = {
          interface = network.hostInterface;
          bind-interfaces = true;
          dhcp-range = [ "${network.dhcpStart},${network.dhcpEnd},12h" ];
          # Static IP assignments for predictable cluster addressing
          dhcp-host = map (vm: "${vm.mac},${vm.name},${vm.ip}") vmDefinitions;
          # DNS entries for cluster nodes
          address = map (vm: "/${vm.name}.local/${vm.ip}") vmDefinitions;
        };
      };

      #############################################################################
      # INNER VM INITIALIZATION SERVICE
      #############################################################################

      systemd.services.setup-inner-vms = {
        description = "Initialize embedded system node VMs";
        after = [ "libvirtd.service" "openvswitch.service" ];
        wants = [ "libvirtd.service" "openvswitch.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        path = [ pkgs.qemu pkgs.libvirt ];

        script = ''
          set -euo pipefail
          mkdir -p /var/lib/libvirt/images
          mkdir -p /var/lib/libvirt/qemu/nvram

          ${lib.concatMapStrings (vm: ''
            # Create system disk if not exists
            [ -f /var/lib/libvirt/images/${vm.name}.qcow2 ] || \
              qemu-img create -f qcow2 /var/lib/libvirt/images/${vm.name}.qcow2 4G
        
            ${lib.optionalString (vm ? extraDiskSize && vm.extraDiskSize > 0) ''
              # Create extra storage disk
              [ -f /var/lib/libvirt/images/${vm.name}-data.qcow2 ] || \
                qemu-img create -f qcow2 /var/lib/libvirt/images/${vm.name}-data.qcow2 ${toString vm.extraDiskSize}G
            ''}
        
            # Define VM in libvirt
            virsh dominfo ${vm.name} &>/dev/null || virsh define ${vm.xml}
        
            echo "✓ Configured: ${vm.name} (${vm.arch}) - ${vm.description}"
          '') innerVMs}
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
      
          echo "✓ OVS switch fabric configured with STP enabled"
        '';
      };

      #############################################################################
      # PACKAGES & TOOLS
      #############################################################################

      environment.systemPackages = with pkgs; [
        # Virtualization management
        libvirt
        virt-manager
        qemu

        # Networking tools
        openvswitch
        bridge-utils
        iproute2
        tcpdump
        iperf3
        ethtool

        # Kubernetes tools
        k3s
        kubectl
        kubernetes-helm

        # General utilities
        htop
        tmux
        vim
        curl
        wget
        jq
      ];

      #############################################################################
      # TRAFFIC CONTROL SCRIPT
      #############################################################################

      environment.etc."tc-simulate-constraints.sh" = {
        mode = "0755";
        text = ''
          #!/usr/bin/env bash
          #
          # Network Constraint Simulation Script
          #
          # Usage: tc-simulate-constraints.sh [profile]
          #
          # Profiles:
          #   default     - Remove all constraints (full speed)
          #   constrained - Embedded system limits (10-100Mbps + latency)
          #   lossy       - Unreliable network (packet loss + jitter)
          #   custom      - Apply custom tc rules (edit script)
          #
      
          set -euo pipefail
      
          PROFILE=''${1:-default}
      
          # Get active VM interface names
          get_vm_interfaces() {
            virsh domiflist "$1" 2>/dev/null | grep -oP 'vnet\d+' || true
          }
      
          case $PROFILE in
            constrained)
              echo "Applying constrained embedded network profile..."
          
              # Chassis: 10Mbps with 100ms latency (typical embedded ARM)
              IF_CHASSIS=$(get_vm_interfaces chassis)
              [ -n "$IF_CHASSIS" ] && {
                tc qdisc replace dev "$IF_CHASSIS" root tbf rate 10mbit latency 100ms burst 1540
                echo "  chassis ($IF_CHASSIS): 10Mbps, 100ms latency"
              }
          
              # Compute/Storage: 100Mbps with 10ms latency
              for node in compute storage; do
                IF_NODE=$(get_vm_interfaces "$node")
                [ -n "$IF_NODE" ] && {
                  tc qdisc replace dev "$IF_NODE" root tbf rate 100mbit latency 10ms burst 1540
                  echo "  $node ($IF_NODE): 100Mbps, 10ms latency"
                }
              done
              echo "✓ Constrained profile applied"
              ;;
          
            lossy)
              echo "Applying lossy network profile for resilience testing..."
          
              IF_CHASSIS=$(get_vm_interfaces chassis)
              [ -n "$IF_CHASSIS" ] && {
                tc qdisc replace dev "$IF_CHASSIS" root netem loss 2% delay 50ms 20ms distribution normal
                echo "  chassis ($IF_CHASSIS): 2% loss, 50±20ms delay"
              }
          
              for node in compute storage; do
                IF_NODE=$(get_vm_interfaces "$node")
                [ -n "$IF_NODE" ] && {
                  tc qdisc replace dev "$IF_NODE" root netem loss 0.5% delay 20ms 10ms distribution normal
                  echo "  $node ($IF_NODE): 0.5% loss, 20±10ms delay"
                }
              done
              echo "✓ Lossy profile applied"
              ;;
          
            default|clear)
              echo "Removing all network constraints..."
              for node in chassis compute storage; do
                IF_NODE=$(get_vm_interfaces "$node")
                [ -n "$IF_NODE" ] && {
                  tc qdisc del dev "$IF_NODE" root 2>/dev/null || true
                  echo "  $node ($IF_NODE): constraints removed"
                }
              done
              echo "✓ Default profile (no constraints)"
              ;;
          
            status)
              echo "Current tc configuration:"
              for node in chassis compute storage; do
                IF_NODE=$(get_vm_interfaces "$node")
                [ -n "$IF_NODE" ] && {
                  echo "  $node ($IF_NODE):"
                  tc qdisc show dev "$IF_NODE" 2>/dev/null | sed 's/^/    /'
                }
              done
              ;;
          
            *)
              echo "Unknown profile: $PROFILE"
              echo "Available profiles: default, constrained, lossy, status"
              exit 1
              ;;
          esac
        '';
      };

      #############################################################################
      # USER CONFIGURATION
      #############################################################################

      services.getty.autologinUser = "root";
      users.users.root.initialPassword = "demo";
      users.users.root.extraGroups = [ "libvirtd" ];

      #############################################################################
      # WELCOME MESSAGE
      #############################################################################

      environment.etc."motd".text = ''

    ╔════════════════════════════════════════════════════════════════════════╗
    ║           🖥️  Embedded System Emulator Ready  🖥️                       ║
    ╠════════════════════════════════════════════════════════════════════════╣
    ║                                                                        ║
    ║  CLUSTER NODES:                                                        ║
    ║    • chassis  (ARM64) - k3s Server  - 192.168.100.10                   ║
    ║    • compute  (x86)   - k3s Agent   - 192.168.100.11                   ║
    ║    • storage  (x86)   - k3s Agent   - 192.168.100.12                   ║
    ║                                                                        ║
    ║  VM MANAGEMENT:                                                        ║
    ║    virsh list --all              # List all VMs                        ║
    ║    virsh start chassis           # Start a VM                          ║
    ║    virsh console chassis         # Console access (Ctrl+] to exit)     ║
    ║    virsh shutdown chassis        # Graceful shutdown                   ║
    ║                                                                        ║
    ║  NETWORK TOOLS:                                                        ║
    ║    ovs-vsctl show                # View OVS switch topology            ║
    ║    /etc/tc-simulate-constraints.sh constrained  # Apply limits         ║
    ║    /etc/tc-simulate-constraints.sh status       # View current tc      ║
    ║                                                                        ║
    ║  NETWORK: ${network.bridge} @ ${network.hostIP}${network.cidr}                          ║
    ║                                                                        ║
    ║  NOTE: ARM64 chassis VM runs via emulation and will be slower.         ║
    ║        Allow 5-10 minutes for first boot.                              ║
    ║                                                                        ║
    ╚════════════════════════════════════════════════════════════════════════╝

  '';

      system.stateVersion = "24.05";
    };
}
