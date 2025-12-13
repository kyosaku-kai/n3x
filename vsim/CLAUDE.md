# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**vsim** (Virtual Simulator) is a declarative NixOS-based embedded system emulation platform that uses nested virtualization to simulate heterogeneous compute environments. It emulates a physical chassis board with:

- **CHASSIS**: ARM64 (aarch64) Jetson/Nano SOM running k3s Server (control plane)
- **COMPUTE**: x86_64 compute node running k3s Agent
- **STORAGE**: x86_64 storage node running k3s Agent with additional disk

All nodes interconnect through an Open vSwitch bridge emulating a Marvell switch fabric with configurable QoS and traffic control.

## Build and Run Commands

### Building the Emulation Environment

```bash
# Build the outer VM that hosts the nested VMs
nixos-rebuild build-vm -I nixos-config=./embedded-system-emulator.nix

# Run the outer VM
./result/bin/run-*-vm
```

### Inside the Outer VM

```bash
# List all defined VMs
virsh list --all

# Start a VM
virsh start chassis
virsh start compute
virsh start storage

# Start all VMs at once
for vm in chassis compute storage; do virsh start $vm; done

# Access VM console (press Ctrl+] to exit)
virsh console chassis

# Shutdown a VM
virsh shutdown chassis

# Force stop a VM
virsh destroy chassis

# View VM details
virsh dominfo chassis
```

### Network Operations

```bash
# View OVS switch topology
ovs-vsctl show

# Check bridge status
ip link show ovsbr0

# View DHCP leases and DNS entries
systemctl status dnsmasq
journalctl -u dnsmasq

# Test connectivity to VMs
ping -c 3 192.168.100.10  # chassis
ping -c 3 192.168.100.11  # compute
ping -c 3 192.168.100.12  # storage
```

### Traffic Control (Network Simulation)

```bash
# Apply constrained network profile (embedded system limits)
/etc/tc-simulate-constraints.sh constrained

# Apply lossy network profile (resilience testing)
/etc/tc-simulate-constraints.sh lossy

# Remove all constraints (default profile)
/etc/tc-simulate-constraints.sh default

# View current tc configuration
/etc/tc-simulate-constraints.sh status

# Manual tc examples (after VMs are running)
tc qdisc show dev vnet-chassis
tc -s qdisc show dev vnet-compute
```

### Troubleshooting

```bash
# Check if nested virtualization is enabled on host
cat /sys/module/kvm_intel/parameters/nested  # Intel (should be Y or 1)
cat /sys/module/kvm_amd/parameters/nested    # AMD (should be 1)

# Verify services are running
systemctl is-active libvirtd openvswitch setup-inner-vms dnsmasq

# View service logs
journalctl -u libvirtd
journalctl -u openvswitch
journalctl -u setup-inner-vms

# Restart VM setup if VMs don't appear
systemctl restart setup-inner-vms

# Check VM interface assignments
virsh domiflist chassis
virsh domiflist compute
virsh domiflist storage
```

## Architecture

### Nested Virtualization Structure

```
Physical Host (Laptop/Server/Cloud)
└── Outer VM (NixOS Hypervisor Layer)
    ├── libvirtd (VM management)
    ├── openvswitch (ovsbr0 bridge - simulates Marvell switch)
    ├── dnsmasq (DHCP/DNS server)
    ├── systemd-networkd (host network: vnet0 @ 192.168.100.1/24)
    └── Inner VMs:
        ├── chassis (ARM64) - 192.168.100.10
        ├── compute (x86_64) - 192.168.100.11
        └── storage (x86_64) - 192.168.100.12
```

### Key Configuration Sections

**VM Definitions** (lines 46-84):
- Defines the three inner VMs with architecture, resources, and roles
- ARM64 chassis uses QEMU TCG emulation (slower)
- x86_64 nodes use KVM acceleration (fast)

**QoS Profiles** (lines 90-106):
- Network bandwidth limits per VM
- Chassis: 100Mbps (simulates embedded ARM constraints)
- Compute/Storage: 1Gbps

**VM Template Generator** (lines 112-207):
- `mkLibvirtXML` function generates libvirt domain XML
- Handles architecture-specific configuration (ARM64 vs x86_64)
- Applies QoS, resource limits, and firmware settings

**Network Configuration** (lines 249-284):
- Open vSwitch bridge (`ovsbr0`)
- Host interface (`vnet0`)
- DHCP with static IP assignments
- DNS resolution for `.local` domain

## Important Technical Details

### ARM64 Emulation Performance

The chassis VM runs via QEMU TCG emulation, which is **10-20x slower** than native execution:

- Boot time: 5-10 minutes (vs 30-60s native)
- k3s startup: 3-5 minutes (vs 15-30s native)
- Network I/O: 2-5x slower

**Development Strategy**: Use x86_64 VMs for rapid iteration, ARM64 for final validation.

### Resource Control Layers

1. **VM-Level (libvirt)**:
   - CPU: `<cputune>` with shares, period, quota
   - Memory: `<memtune>` with hard/soft limits
   - Network: `<bandwidth>` with inbound/outbound limits

2. **Traffic Control (tc)**:
   - Applied to VM tap interfaces (vnet-chassis, vnet-compute, vnet-storage)
   - Simulates bandwidth limits, latency, packet loss, jitter
   - Profiles: default, constrained, lossy

3. **Kubernetes-Level (k3s)**:
   - Pod resource requests and limits
   - Applied after k3s is installed and configured

### Critical Configuration Values

**Network** (lines 29-36):
- Bridge: `ovsbr0`
- Host IP: `192.168.100.1/24`
- DHCP range: `192.168.100.100-192.168.100.200`
- Static IPs: .10 (chassis), .11 (compute), .12 (storage)

**k3s Token** (line 40):
- **MUST be replaced** with secure value before k3s deployment
- Generate with: `openssl rand -hex 32`

**Outer VM Resources** (lines 225-229):
- 8GB RAM (hosts all 3 inner VMs + services)
- 8 vCPUs
- 50GB disk

## Modification Guidelines

### Adding a New VM Node

1. Add entry to `vmDefinitions` array (lines 46-84)
2. Define QoS profile in `qosProfiles` (lines 90-106)
3. VM will be automatically:
   - Created by `setup-inner-vms` service
   - Assigned static IP via dnsmasq
   - Connected to ovsbr0 bridge
   - Given DNS name `{vm.name}.local`

### Adjusting Resource Limits

**VM Memory/CPU**: Modify VM definition (lines 46-84)
```nix
memory = 2048;  # MB
vcpus = 4;
```

**Network Bandwidth**: Modify QoS profile (lines 90-106)
```nix
inbound = { average = 500000; peak = 1000000; burst = 10240; };  # 500Mbps
```

**Outer VM Resources**: Modify virtualisation block (lines 225-229)
```nix
virtualisation = {
  memorySize = 16384;  # 16GB
  cores = 16;
  diskSize = 100000;   # 100GB
};
```

### Customizing Traffic Control Profiles

Edit `/etc/tc-simulate-constraints.sh` generation (lines 370-466):
- Add new profile case in script
- Use `tbf` for bandwidth limits
- Use `netem` for delay/loss/jitter

## Testing and Validation

### Prerequisites on Physical Host

```bash
# Enable nested virtualization (required)
# Intel:
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel

# AMD:
echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
sudo modprobe -r kvm_amd && sudo modprobe kvm_amd
```

### Verification Checklist

Inside outer VM:

1. **Services running**:
   ```bash
   systemctl is-active libvirtd openvswitch setup-inner-vms dnsmasq
   # All should show: active
   ```

2. **VMs defined**:
   ```bash
   virsh list --all
   # Should show chassis, compute, storage as "shut off"
   ```

3. **OVS bridge configured**:
   ```bash
   ovs-vsctl show
   # Should show Bridge ovsbr0 with port vnet0
   ```

4. **After starting VMs**:
   ```bash
   ping -c 3 192.168.100.10  # chassis
   # Should receive responses (may take 5-10 min for ARM64 to boot)
   ```

## Known Issues and Workarounds

1. **NixOS 25.x Configuration Changes**: The configuration has been updated for NixOS 25.x compatibility:
   - `services.openvswitch.enable` removed - OVS is now enabled implicitly via `networking.vswitches.*`
   - `virtualisation.libvirtd.qemu.ovmf.*` options removed - OVMF firmware now included by default
   - `virtualisation.cores` replaced with `virtualisation.qemu.options = ["-smp 8"]` for CPU configuration
   - Module structure now requires explicit `imports = ["${modulesPath}/virtualisation/qemu-vm.nix"]`

2. **ARM64 VM extremely slow**: Expected behavior. TCG emulation is inherently slow. Consider:
   - Testing on native ARM64 hardware (Apple Silicon, Graviton, Raspberry Pi)
   - Using x86_64-only configuration for development
   - Increasing outer VM CPU allocation

3. **VMs not appearing in `virsh list`**: Restart setup service:
   ```bash
   systemctl restart setup-inner-vms
   ```

4. **No DHCP leases**: Check dnsmasq and network:
   ```bash
   systemctl status dnsmasq
   ip addr show vnet0  # Should have 192.168.100.1/24
   ```

5. **tc rules not working**: Ensure VMs are running first (interfaces created dynamically)
   ```bash
   virsh domiflist chassis  # Check interface name
   tc qdisc show dev vnet-chassis
   ```

## Next Steps After Initial Setup

This configuration provides the infrastructure layer. To complete the embedded system emulation:

1. **Install NixOS on Inner VMs**:
   - Attach NixOS ISO to VMs
   - Boot and install minimal system
   - Configure static networking

2. **Deploy k3s Cluster**:
   - Configure k3s server on chassis
   - Join agents from compute and storage
   - Verify cluster formation

3. **Add Storage Layer**:
   - Format storage node's extra disk (/dev/vdb)
   - Deploy Longhorn or local-path-provisioner
   - Test PVC provisioning

## Related Documentation

- **Full Architecture**: See `embedded-system-emulator.md` for detailed system design
- **NixOS Manual**: https://nixos.org/manual/nixos/stable/
- **libvirt Domains**: https://libvirt.org/formatdomain.html
- **Open vSwitch**: https://docs.openvswitch.org/
- **k3s Documentation**: https://docs.k3s.io/
