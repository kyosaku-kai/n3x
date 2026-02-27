# Emulation Testing Framework

A NixOS-based nested virtualization platform for interactive debugging and exploration of n3x k3s cluster configurations. It runs production n3x configs as libvirt VMs inside a hypervisor VM, connected by an OVS switch fabric with traffic control.

> **This is NOT the primary test infrastructure.** Automated CI/CD testing uses `nixosTest` multi-node — see [tests/README.md](../README.md). The emulation framework is for interactive debugging on native Linux only.

## Platform Requirements

This framework requires nested virtualization (VMs inside VMs). It works on:

- **Native Linux** (bare metal or cloud VMs with nested virt enabled)

It does **not** work on WSL2 (Hyper-V caps nesting at 2 levels), Docker Desktop, or macOS Apple Silicon. See [docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md](../../docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md) for details.

Verify nested virtualization before use:

```bash
cat /sys/module/kvm_intel/parameters/nested  # Intel: Y or 1
cat /sys/module/kvm_amd/parameters/nested    # AMD: 1
```

## Directory Structure

```
tests/emulation/
├── README.md               # This file
├── embedded-system.nix     # Main emulator: VM topology, outer VM services
└── lib/
    ├── inner-vm-base.nix   # Base NixOS module for inner VMs (virtio, serial, auth)
    ├── mkInnerVM.nix       # n3x host configs → libvirt domain XML
    ├── mkInnerVMImage.nix  # n3x host configs → bootable qcow2 images
    ├── mkOVSBridge.nix     # OVS switch fabric + systemd-networkd host interface
    └── mkTCProfiles.nix    # Traffic control constraint profiles (tc/netem)
```

## Build and Run

```bash
# Build the emulation VM (includes pre-built inner VM images)
nix build '.#packages.x86_64-linux.emulation-vm'

# Interactive mode (foreground, serial console on stdio)
./result/bin/run-nixos-vm

# Background mode (daemon, connect via socat)
nix run '.#emulation-vm-bg'
socat -,raw,echo=0 unix-connect:$XDG_RUNTIME_DIR/n3x-emulation/serial.sock

# Stop background VM
echo 'quit' | socat - unix-connect:$XDG_RUNTIME_DIR/n3x-emulation/monitor.sock
```

System requirements: CPU with nested virt (VT-x/AMD-V), 16GB+ RAM, 60GB+ disk.

## Inside the Outer VM

```bash
# List and start inner VMs
virsh list --all
for vm in n100-1 n100-2 n100-3; do virsh start "$vm"; done

# Console access (Ctrl+] to exit)
virsh console n100-1

# OVS switch topology
ovs-vsctl show

# Traffic control constraint profiles
/etc/tc-simulate-constraints.sh constrained   # Embedded system limits
/etc/tc-simulate-constraints.sh lossy          # Packet loss + jitter
/etc/tc-simulate-constraints.sh status         # Show current config
/etc/tc-simulate-constraints.sh default        # Remove all constraints
```

Inner VMs boot directly to NixOS with pre-built disk images. Login: `root` / `test`.

## Architecture

```
Physical Host (bare metal / cloud VM with nested virt)
└── Outer VM (NixOS Hypervisor — 12GB RAM, 8 vCPU)
    ├── libvirtd          VM lifecycle management
    ├── openvswitch       ovsbr0 bridge (simulated switch fabric)
    │   └── vnet0         Host management interface (192.168.100.1/24)
    ├── dnsmasq           DHCP/DNS for inner VMs
    ├── tc                Traffic shaping on VM tap interfaces
    └── Inner VMs
        ├── n100-1  x86_64  k3s Server  192.168.100.10  4GB/2vCPU  [KVM]
        ├── n100-2  x86_64  k3s Server  192.168.100.11  4GB/2vCPU  [KVM]
        ├── n100-3  x86_64  k3s Agent   192.168.100.12  2GB/2vCPU  [KVM]
        └── jetson-1 arm64  k3s Agent   192.168.100.20  2GB/2vCPU  [TCG]
```

The ARM64 `jetson-1` VM uses QEMU TCG (software emulation), which is 10-20x slower than native. Use it for cross-architecture validation only.

## Traffic Control Profiles

| Profile | Effect |
|---------|--------|
| `default` | No constraints (full speed) |
| `constrained` | 10-100 Mbps bandwidth limits + latency |
| `lossy` | Packet loss + jitter for resilience testing |

Profiles apply tc/netem rules to inner VM tap interfaces. VMs also have libvirt QoS bandwidth limits configured in their domain XML.

## Flake Outputs

```bash
nix build '.#packages.x86_64-linux.emulation-vm'          # VM package
nix run '.#emulation-vm'                                    # Interactive run
nix run '.#emulation-vm-bg'                                 # Background run
nix build '.#checks.x86_64-linux.emulation-vm-boots'       # Automated boot check
nix build '.#nixosConfigurations.emulator-vm.config.system.build.vm'  # Raw VM build
```

## References

- [tests/README.md](../README.md) — Primary test infrastructure (nixosTest multi-node)
- [embedded-system.nix](embedded-system.nix) — Header comments describe full architecture and usage
- [docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md](../../docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md) — Why WSL2 doesn't work
