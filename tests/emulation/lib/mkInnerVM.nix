# mkInnerVM.nix - Generator function: n3x configs → libvirt VMs
#
# This function takes an n3x host configuration and converts it into a libvirt
# VM definition suitable for nested virtualization testing in the vsim emulation
# environment.
#
# USAGE EXAMPLE:
#
#   mkInnerVM = import ./tests/emulation/lib/mkInnerVM.nix {
#     inherit pkgs lib inputs;
#   };
#
#   server1 = mkInnerVM {
#     hostname = "n100-1";           # Uses hosts/n100-1/configuration.nix
#     mac = "52:54:00:12:34:01";     # MAC for DHCP
#     ip = "192.168.100.10";         # Static IP
#     memory = 4096;                 # 4GB RAM
#     vcpus = 2;                     # 2 vCPUs
#     qosProfile = "default";        # Network QoS profile
#   };
#
#   agent1 = mkInnerVM {
#     hostname = "jetson-1";         # Uses hosts/jetson-1/configuration.nix
#     mac = "52:54:00:12:34:02";
#     ip = "192.168.100.11";
#     arch = "aarch64";              # ARM64 emulation via QEMU TCG
#     memory = 2048;
#     vcpus = 2;
#     extraDiskSize = 10;            # Add 10GB extra disk for storage testing
#     qosProfile = "constrained";    # Simulate embedded system limits
#   };
#
# PARAMETERS:
#   hostname        - Which n3x host config to use (e.g., "n100-1", "jetson-1")
#   mac             - MAC address for DHCP assignment
#   ip              - Static IP address
#   memory          - RAM in MB (default: 2048)
#   vcpus           - vCPU count (default: 2)
#   arch            - "x86_64" (KVM) or "aarch64" (TCG) (default: auto-detect from hostname)
#   extraDiskSize   - Additional disk in GB (default: 0 = none)
#   qosProfile      - Network QoS profile name (default: "default")
#   diskImagePath   - Optional: Path to pre-built qcow2 image (Nix store path)
#                     If provided, setup script will copy this instead of creating empty disk
#
# RETURNS: Attribute set with:
#   hostname        - Original hostname
#   mac, ip, memory, vcpus, arch - Original parameters
#   xml             - Path to libvirt domain XML file
#   description     - Human-readable description
#   diskImagePath   - Path to pre-built image (if provided) for setup script
#
# IMPLEMENTATION NOTES:
#   - Imports n3x host configuration from hosts/${hostname}/configuration.nix
#   - Generates libvirt XML adapted from vsim's mkLibvirtXML template
#   - Handles architecture-specific configuration (ARM64 vs x86_64)
#   - ARM64 uses QEMU TCG emulation (slow), x86_64 uses KVM (fast)
#   - QoS profiles are applied via libvirt <bandwidth> settings
#   - Extra disks are provisioned for storage node testing
#   - Pre-built disk images can be provided via diskImagePath parameter

{ pkgs, lib, inputs, ... }:

{ hostname
, mac
, ip
, memory ? 2048
, vcpus ? 2
, arch ? (if lib.hasPrefix "jetson" hostname then "aarch64" else "x86_64")
, extraDiskSize ? 0
, qosProfile ? "default"
, diskImagePath ? null  # Optional: Nix store path to pre-built qcow2 image
}:

let
  # Detect node role from hostname
  role =
    if lib.hasInfix "n100-1" hostname then "k3s-server"
    else if lib.hasInfix "n100-2" hostname then "k3s-server"
    else "k3s-agent";

  # Generate human-readable description
  description =
    if lib.hasPrefix "n100" hostname then
      "N100 miniPC - ${role}"
    else if lib.hasPrefix "jetson" hostname then
      "Jetson Orin Nano - ${role}"
    else
      "${hostname} - ${role}";

  # QoS profile definitions (bandwidth in kbps for libvirt)
  qosProfiles = {
    # Default: Full gigabit speed, minimal constraints
    default = {
      inbound = { average = 1000000; peak = 2000000; burst = 10240; }; # 1Gbps
      outbound = { average = 1000000; peak = 2000000; burst = 10240; };
    };

    # Constrained: Simulates embedded system network limits
    constrained = {
      inbound = { average = 100000; peak = 200000; burst = 10240; }; # 100Mbps
      outbound = { average = 100000; peak = 200000; burst = 10240; };
    };

    # Lossy: For network resilience testing (bandwidth only - loss/latency via tc)
    lossy = {
      inbound = { average = 50000; peak = 100000; burst = 5120; }; # 50Mbps
      outbound = { average = 50000; peak = 100000; burst = 5120; };
    };
  };

  qos = qosProfiles.${qosProfile} or qosProfiles.default;

  # Architecture-specific configuration
  isArm = arch == "aarch64";
  emulator =
    if isArm
    then "${pkgs.qemu}/bin/qemu-system-aarch64"
    else "${pkgs.qemu}/bin/qemu-system-x86_64";
  # Use pc (i440fx) for x86_64 with BIOS boot; q35 defaults to UEFI which requires GPT
  # Our disk images use legacy MBR partitioning with GRUB BIOS boot
  machineType = if isArm then "virt" else "pc";

  # Extra storage disk configuration
  extraDisk =
    if extraDiskSize > 0 then ''
      <disk type='file' device='disk'>
        <driver name='qemu' type='qcow2' cache='writeback'/>
        <source file='/var/lib/libvirt/images/${hostname}-data.qcow2'/>
        <target dev='vdb' bus='virtio'/>
      </disk>
    '' else "";

  # ARM64 requires UEFI firmware (EDK2 for aarch64, bundled with QEMU)
  # Note: edk2-aarch64-code.fd is read-only code, nvram is created per-VM for persistent EFI variables
  firmwareConfig =
    if isArm then ''
      <loader readonly='yes' type='pflash'>${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd</loader>
      <nvram>/var/lib/libvirt/qemu/nvram/${hostname}_VARS.fd</nvram>
    '' else "";

  # Generate libvirt domain XML
  # NOTE: ARM64 VMs use type='qemu' for TCG emulation (cross-architecture)
  # x86_64 VMs use type='kvm' for hardware acceleration (nested virt works!)
  # See ~/src/nested-virt-poc for proof that nested KVM works in nixosTest VMs
  mkLibvirtXML = pkgs.writeText "${hostname}.xml" ''
    <domain type='${if isArm then "qemu" else "kvm"}'>
      <name>${hostname}</name>
      <description>${description}</description>
      <memory unit='MiB'>${toString memory}</memory>
      <vcpu placement='static'>${toString vcpus}</vcpu>

      <!-- Resource Controls for CPU and Memory -->
      <cputune>
        <shares>${toString (vcpus * 1024)}</shares>
        <!-- Uncomment to add strict CPU limits:
        <period>100000</period>
        <quota>50000</quota>
        -->
      </cputune>
      <memtune>
        <hard_limit unit='MiB'>${toString (memory + 128)}</hard_limit>
        <soft_limit unit='MiB'>${toString memory}</soft_limit>
      </memtune>

      <!-- CPU configuration: KVM uses host-passthrough, TCG needs explicit model -->
      ${if isArm then ''
      <cpu mode='custom' match='exact'>
        <model fallback='allow'>cortex-a57</model>
      </cpu>'' else ''
      <cpu mode='host-passthrough'>
      </cpu>''}

      <os>
        <type arch='${arch}' machine='${machineType}'>hvm</type>
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
          <source file='/var/lib/libvirt/images/${hostname}.qcow2'/>
          <target dev='vda' bus='virtio'/>
        </disk>

        ${extraDisk}

        <!-- Network Interface via OVS Bridge with QoS -->
        <interface type='bridge'>
          <source bridge='ovsbr0'/>
          <virtualport type='openvswitch'/>
          <mac address='${mac}'/>
          <model type='virtio'/>
          <bandwidth>
            <inbound average='${toString qos.inbound.average}'
                     peak='${toString qos.inbound.peak}'
                     burst='${toString qos.inbound.burst}'/>
            <outbound average='${toString qos.outbound.average}'
                      peak='${toString qos.outbound.peak}'
                      burst='${toString qos.outbound.burst}'/>
          </bandwidth>
          <alias name='vnet-${hostname}'/>
        </interface>

        <!-- Console Access -->
        <serial type='pty'><target port='0'/></serial>
        <console type='pty'><target type='serial' port='0'/></console>
        <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
      </devices>
    </domain>
  '';

  # NOTE: Building full NixOS systems from n3x host configs is deferred to
  # a future enhancement. For now, VMs get empty disks and can be installed
  # manually using nixos-anywhere or the standard NixOS installer.
  #
  # To enable this in the future, uncomment and fix the following:
  #
  # nixosSystem = inputs.nixpkgs.lib.nixosSystem {
  #   system = arch + "-linux";
  #   specialArgs = { inherit inputs; };
  #   modules = [
  #     ../../hosts/${hostname}/configuration.nix
  #     {
  #       nixpkgs.hostPlatform = arch + "-linux";
  #       services.qemu-guest-agent.enable = true;
  #       services.getty.autologinUser = lib.mkDefault "root";
  #       users.users.root.initialPassword = lib.mkDefault "test";
  #       networking.useDHCP = lib.mkDefault true;
  #     }
  #   ];
  # };

in
{
  # Pass through original parameters
  inherit hostname mac ip memory vcpus arch extraDiskSize qosProfile;

  # Pre-built disk image path (null if not provided)
  inherit diskImagePath;

  # Add computed values
  inherit description role;

  # Libvirt domain XML
  xml = mkLibvirtXML;

  # Helper metadata for debugging
  meta = {
    qosProfile = qos;
    isArm = isArm;
    emulator = emulator;
    machineType = machineType;
    hasPrebuiltImage = diskImagePath != null;
  };
}
