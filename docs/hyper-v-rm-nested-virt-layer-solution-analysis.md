This is a great problem to think through carefully. Your intuition about eliminating L2 is sound, but let's analyze the full picture.

## Understanding Your Current Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ L0: Windows 11 (Hyper-V hypervisor active for WSL2)                │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ L1: WSL2 VM (Microsoft Linux kernel) running NixOS userspace    │ │
│ │ ┌─────────────────────────────────────────────────────────────┐ │ │
│ │ │ L2: QEMU/KVM VM (NixOS) ← OVS lives here                    │ │ │
│ │ │ ┌──────────┐ ┌──────────┐ ┌──────────┐                      │ │ │
│ │ │ │ L3: VM   │ │ L3: VM   │ │ L3: VM   │  ← k3s nodes         │ │ │
│ │ │ │ (NixOS)  │ │ (NixOS)  │ │ (NixOS)  │  ← containers here   │ │ │
│ │ │ └──────────┘ └──────────┘ └──────────┘                      │ │ │
│ │ └─────────────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

Your L3 VMs are struggling because they're three virtualization layers deep, and the memory translation overhead alone is catastrophic—let alone the compounding VM exit latency for any privileged operation.

## Analyzing Your Isolation Rationale

You mentioned wanting isolation from L1. Let's decompose what "isolation" might mean here:

| Isolation Goal | Does L2 Help? | Alternative |
|----------------|---------------|-------------|
| Network isolation from L1 | Yes | OVS + network namespaces at L1 |
| Filesystem/state isolation | Yes | Dedicated directories, tmpfs, or btrfs subvolumes |
| Reproducible "clean room" | Yes | NixOS flake describing entire environment |
| Resource isolation (CPU/mem) | Yes | cgroups at L1 |
| Kernel isolation (different kernel) | Yes | **This is the one that actually requires a VM** |

The critical question: **Do you need a different kernel than what WSL2 provides?**

If yes (for example, you need specific kernel modules, a particular kernel version, or custom kernel config), then some VM layer is necessary. If no, you may be able to flatten further.

## Proposed Refactored Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ L0: Windows 11                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ L1: WSL2 NixOS                                                  │ │
│ │                                                                 │ │
│ │   ┌─────────────────────────────────────────────────────────┐   │ │
│ │   │              Open vSwitch (OVS)                         │   │ │
│ │   │   br-k3s (OVS bridge with QoS, VLAN trunk, etc.)       │   │ │
│ │   └──────┬─────────────┬─────────────┬─────────────┬────────┘   │ │
│ │          │ tap0        │ tap1        │ tap2        │            │ │
│ │   ┌──────┴─────┐ ┌─────┴──────┐ ┌────┴───────┐ ┌───┴────────┐   │ │
│ │   │ L2: VM     │ │ L2: VM     │ │ L2: VM     │ │ L2: VM     │   │ │
│ │   │ k3s server │ │ k3s agent  │ │ k3s agent  │ │ k3s agent  │   │ │
│ │   │ (NixOS)    │ │ (NixOS)    │ │ (NixOS)    │ │ (NixOS)    │   │ │
│ │   │            │ │            │ │            │ │            │   │ │
│ │   │ containerd │ │ containerd │ │ containerd │ │ containerd │   │ │
│ │   └────────────┘ └────────────┘ └────────────┘ └────────────┘   │ │
│ └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

This eliminates one full virtualization layer. Your k3s nodes are now L2 instead of L3.

## Feasibility Analysis

### 1. OVS in WSL2

**Challenge**: The WSL2 kernel is maintained by Microsoft and may not include OVS kernel modules (`openvswitch.ko`).

**Options**:
- **Build a custom WSL2 kernel** with OVS support. Microsoft documents this process, and NixOS can manage the kernel build declaratively.
- **Use OVS userspace datapath** (`ovs-vswitchd` with `--dpdk` or netdev datapath). Slower than kernel datapath but avoids kernel module issues.
- **Check if the kernel already has it**: Run `modprobe openvswitch` in your current WSL2 NixOS—it might already be there.

### 2. Container Runtimes in L2 VMs

**This should work fine.** Containers don't nest virtualization; they use:
- Namespaces (pid, net, mnt, uts, ipc, user, cgroup)
- cgroups v2 for resource limits
- seccomp for syscall filtering
- OverlayFS for layered filesystems

Your L2 NixOS VMs need proper kernel configuration. Key NixOS options:

```nix
{
  boot.kernelParams = [ "cgroup_no_v1=all" ];  # Force cgroups v2 unified hierarchy
  
  # These are typically defaults, but be explicit
  boot.kernelModules = [ "overlay" "br_netfilter" ];
  
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };
  
  virtualisation.containerd.enable = true;
  
  # k3s handles most of this, but ensuring the foundations are there
  services.k3s = {
    enable = true;
    role = "server";  # or "agent"
    # ...
  };
}
```

### 3. Performance Expectations

| Operation | L3 (current) | L2 (proposed) |
|-----------|-------------|---------------|
| Container startup | Very slow / broken | Seconds |
| Network latency (pod-to-pod) | Extreme | ~1-2ms overhead |
| Memory overhead per VM | 3x translation walks | 2x translation walks |
| CPU-bound container workload | 30-50% overhead | 10-20% overhead |

The difference between 2 and 3 levels of nesting is often the difference between "slow but functional" and "non-functional."

## Network Topology Detail

Here's how OVS would connect your k3s nodes at L1:

```
L1 (WSL2 NixOS)
┌────────────────────────────────────────────────────────────────────────────┐
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        OVS Bridge: br-k3s                            │  │
│  │                                                                      │  │
│  │   Port: tap0        Port: tap1        Port: tap2        Port: mgmt   │  │
│  │   tag: 100          tag: 100          tag: 100          trunk: all   │  │
│  │   QoS: policy-a     QoS: policy-a     QoS: policy-b                  │  │
│  └───────┬─────────────────┬─────────────────┬─────────────────┬────────┘  │
│          │                 │                 │                 │           │
│          │                 │                 │                 │           │
│  ┌───────┴───────┐ ┌───────┴───────┐ ┌───────┴───────┐        │           │
│  │    QEMU VM    │ │    QEMU VM    │ │    QEMU VM    │        │           │
│  │   k3s-node-1  │ │   k3s-node-2  │ │   k3s-node-3  │    (to host/NAT)  │
│  │               │ │               │ │               │                    │
│  │  eth0: tap0   │ │  eth0: tap1   │ │  eth0: tap2   │                    │
│  │  10.0.100.11  │ │  10.0.100.12  │ │  10.0.100.13  │                    │
│  └───────────────┘ └───────────────┘ └───────────────┘                    │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

You can apply OVS features at L1:
- **QoS**: `ovs-vsctl set port tap0 qos=@newqos -- ... `
- **VLANs**: `ovs-vsctl set port tap0 tag=100`
- **Mirroring**: `ovs-vsctl -- set bridge br-k3s mirrors=@m -- ...`
- **OpenFlow rules**: Full SDN programmability

## Concerns and Mitigations

### Concern 1: "I wanted isolation from my L1 dev environment"

**Mitigation**: Use NixOS properly.

```nix
# Define your entire k3s lab as a self-contained flake
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  
  outputs = { self, nixpkgs }: {
    # VMs are defined declaratively, completely isolated from your
    # main NixOS configuration
    nixosConfigurations.k3s-node = nixpkgs.lib.nixosSystem {
      # ...
    };
    
    # Script to bring up the entire lab
    packages.x86_64-linux.lab-up = /* derivation that starts all VMs + OVS */;
    packages.x86_64-linux.lab-down = /* clean teardown */;
  };
}
```

Your lab becomes a reproducible, isolated artifact. Run `nix run .#lab-up`, do your work, run `nix run .#lab-down`. No pollution of your L1 environment.

### Concern 2: "What if I need features the WSL2 kernel doesn't have?"

**Mitigation**: Build a custom WSL2 kernel.

```nix
# In your NixOS flake
packages.x86_64-linux.wsl-kernel = pkgs.linuxPackages_6_6.kernel.override {
  structuredExtraConfig = with lib.kernel; {
    OPENVSWITCH = module;
    # ... other needed options
  };
};
```

Then point WSL2 to use this kernel via `.wslconfig`.

### Concern 3: "Is L2 still too deep for containers?"

**No.** Here's why:

```
Container in L2 VM execution path:
─────────────────────────────────
Container process
    ↓ (syscall)
L2 Guest kernel (NixOS in QEMU)
    ↓ (VM exit for privileged ops OR direct execution for most syscalls)
L1 Guest kernel (WSL2 kernel)
    ↓ (VM exit)
L0 Hypervisor (Hyper-V)
    ↓
Hardware

Containers add NO virtualization layer. They use:
- Namespaces: kernel data structure manipulation, not VM exits
- cgroups: kernel accounting, not VM exits  
- seccomp: syscall filtering, handled in kernel
- overlayfs: VFS layer, standard file operations
```

Container operations are fundamentally different from VM operations. A container in an L2 VM is **not** equivalent to an L3 VM.

## Recommendations

1. **Do the refactor.** Eliminate L2 and run k3s VMs directly from L1 with OVS at L1.

2. **Test OVS kernel support first:**
   ```bash
   modprobe openvswitch
   lsmod | grep openvswitch
   ```
   If it fails, plan for custom kernel or userspace datapath.

3. **Allocate adequate resources to L2 VMs.** k3s server nodes want at least 2 vCPUs and 2GB RAM; agents can be lighter.

4. **Use virtio networking** for your tap devices. The performance difference vs emulated NICs is substantial:
   ```nix
   virtualisation.qemu.networkInterfaces = [{
     type = "tap";
     id = "tap0";
     driver = "virtio-net-pci";
   }];
   ```

5. **Consider macvtap** as an alternative to OVS tap devices if you hit issues—though OVS gives you far more control.

This refactoring should give you a functional, performant k3s lab with full OVS capabilities. The L2 VMs will have working container runtimes because containers are kernel features, not virtualization—cgroups v2 and namespaces will work fine in a properly configured guest kernel.
