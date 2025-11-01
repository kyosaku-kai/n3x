# n3x - NixOS K3s Edge Infrastructure Framework

**n3x** is a declarative framework for automated deployment and management of NixOS-based Kubernetes (k3s) clusters with distributed storage (Longhorn). The framework treats the host OS as immutable infrastructure with all application workloads running in containers, providing reproducible deployments across diverse hardware platforms.

## Project Status

**Current Phase**: Documentation and planning. This repository contains comprehensive implementation guides but no actual NixOS configurations yet. Following a documentation-first approach, implementation will begin after thorough planning alignment.

## Hardware Platform Support

n3x is designed as a hardware-agnostic framework that can deploy to any x86_64 or ARM64 system capable of running NixOS. The modular architecture allows adaptation to diverse edge computing devices through hardware-specific NixOS modules.

### Core Requirements
- **Architecture**: x86_64 or ARM64
- **RAM**: Minimum 2GB (4GB+ recommended)
- **Storage**: Minimum 32GB (larger for more Longhorn capacity)
- **Network**: At least one Ethernet interface

### Example Platform Configurations

The framework has been designed to support various hardware platforms. Below are example configurations showing the framework's flexibility:

#### Intel N100 miniPCs (x86_64)
- Budget-friendly edge nodes
- Optional dual NICs for bonding/redundancy
- 16GB RAM, 512GB NVMe typical
- Supports advanced networking features

#### NVIDIA Jetson Orin Nano (ARM64)
- Edge AI/ML workloads with GPU
- Requires jetpack-nixos for CUDA/TensorRT
- Serial console access recommended
- GPU passthrough to containers supported
- See [jetson-orin-nano.md](jetson-orin-nano.md) for comprehensive documentation

#### Raspberry Pi 4/5 (ARM64)
- Low-cost edge deployments
- USB boot or SD card
- Limited to single NIC configurations
- Suitable for lightweight workloads

#### Generic x86_64 Servers
- Standard datacenter hardware
- Multiple NICs and RAID support
- Higher capacity for storage nodes
- Full enterprise feature support

The framework adapts to available hardware capabilities - from simple single-NIC deployments to advanced multi-network configurations.

## Architecture Overview

### Core Design Philosophy

The system follows an immutable infrastructure approach similar to Talos Linux but with operational flexibility for edge deployments:

- **Host OS**: Declaratively configured via NixOS Flakes, minimal footprint
- **Workloads**: All applications run in k3s (lightweight Kubernetes)
- **Provisioning**: Zero-touch bare-metal deployment via `nixos-anywhere` + `disko`
- **Management**: Standard NixOS tools for local/remote deployment (`nixos-rebuild`, `deploy-rs`)
- **Rollback**: Generation-based recovery built into NixOS

### Technology Stack

**Operating System Layer**:
- NixOS with minimal/headless profiles (~500MB footprint)
- Declarative disk partitioning via `disko`
- Secrets management via `sops-nix` or `agenix`
- Automatic garbage collection and store optimization

**Kubernetes Layer**:
- k3s (lightweight Kubernetes distribution)
- Longhorn (distributed block storage)
- Kyverno (policy engine - REQUIRED for Longhorn on NixOS)
- Flexible CNI options (Flannel default, Cilium, Multus for advanced networking)

## Deployment Architecture

### Expected Flake Structure

```
flake.nix              # Main flake
├── modules/
│   ├── common/        # Base configs
│   ├── k3s/           # Kubernetes
│   ├── hardware/      # Platform-specific
│   └── networking/    # Network setup
├── hosts/
│   ├── node1/         # Node configs
│   ├── node2/
│   └── node3/
├── secrets/
│   ├── .sops.yaml     # Encryption
│   └── k3s.yaml       # K3s tokens
└── disko/
    └── standard.nix   # Disk layout
```

### Disk Partitioning Strategy

Example partitioning for a 512GB NVMe device, optimized for immutable infrastructure with Kubernetes workloads:

- `/boot`: 1GB (EFI system partition)
- `/`: 4GB (root partition - minimal base system only, ~500MB used)
- `/nix`: 30GB (Nix store - supports ~20-30 generations + build artifacts)
- `/var`: 10GB (system logs, k3s state, container runtime data)
- `/tmp`: 4GB (temporary files, build workspace - can use tmpfs)
- `swap`: 16GB (matches RAM for hibernation support)
- `/var/lib/longhorn`: ~447GB (Kubernetes persistent storage)

**Rationale**: With the host OS treated as immutable infrastructure:
- **Root (`/`)**: 4GB for minimal base system (~450-500MB), isolated from volatile data
- **Nix store (`/nix`)**: 30GB supports 20-30 generations + build artifacts
- **Variable data (`/var`)**: 10GB dedicated for:
  - System logs (`/var/log`) - prevents log growth from affecting root
  - k3s etcd state and containerd data
  - System state that persists across reboots
- **Temporary (`/tmp`)**: 4GB separate partition or tmpfs mount:
  - Isolates temporary build files and caches
  - Can be mounted as tmpfs for RAM-based performance (optional)
  - Automatically cleaned on reboot if using tmpfs
- **Swap**: 16GB for hibernation and memory pressure handling
- **Storage**: ~87% of disk dedicated to Kubernetes workloads via Longhorn

This partitioning scheme prevents common failures where logs or temporary files exhaust root filesystem space, while maintaining operational flexibility and maximizing storage for workloads.

**Implementation with disko**:
```nix
# disko/standard.nix
{
  disk.nvme0n1 = {
    device = "/dev/nvme0n1";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        root = {
          size = "4G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };
        nix = {
          size = "30G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/nix";
            mountOptions = [ "noatime" ];
          };
        };
        var = {
          size = "10G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var";
            mountOptions = [ "noatime" "nodiratime" ];
          };
        };
        tmp = {
          size = "4G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/tmp";
            mountOptions = [ "noatime" "nodev" "nosuid" "noexec" ];
          };
        };
        swap = {
          size = "16G";
          content = {
            type = "swap";
            randomEncryption = true;
          };
        };
        longhorn = {
          size = "100%";  # Use remaining space
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var/lib/longhorn";
            mountOptions = [ "noatime" "nodiratime" "discard" ];
          };
        };
      };
    };
  };
}
```

**Alternative tmpfs configuration** (for `/tmp` in RAM):
```nix
# In your NixOS configuration
fileSystems."/tmp" = {
  device = "tmpfs";
  fsType = "tmpfs";
  options = [ "size=4G" "mode=1777" "nodev" "nosuid" "noexec" ];
};
```

## Critical Implementation Patterns

### 1. Longhorn on NixOS Requires Kyverno

**Problem**: Longhorn expects FHS paths (`/usr/bin/env`) but NixOS uses `/nix/store/*` paths.

**Solution**: Deploy Kyverno ClusterPolicy to inject correct PATH into longhorn-system pods:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-path-to-longhorn
spec:
  rules:
    - name: add-path
      match:
        resources:
          kinds: [Pod]
          namespaces: [longhorn-system]
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                env:
                  - name: PATH
                    value: "/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
```

**Deployment Order**: Kyverno → Longhorn → workloads

### 2. Secrets Management Best Practices

**NEVER** use inline secrets in NixOS configurations:

```nix
# ❌ WRONG - exposes secret in Nix store
services.k3s.token = "my-secret-token";

# ✅ CORRECT - references file outside Nix store
services.k3s.tokenFile = config.sops.secrets.k3s_token.path;
```

### 3. Multi-Node Configuration with Generator Functions

Reduce duplication across nodes using generator patterns:

```nix
mkSystem = { systemType, serverType, roles, hmRoles }: {
  imports = [
    ./modules/common
    ./modules/hardware/${systemType}
  ] ++ (map (role: ./modules/roles/${role}) roles);

  networking.hostName = # derived from args
  services.k3s.role = serverType;
};
```

### 4. Network Configuration Patterns

The framework supports various networking configurations based on hardware capabilities:
- Single NIC with single IP (simplest deployment)
- Multiple IPs on single interface (traffic separation)
- Bonded NICs for redundancy (see hardware examples)
- Advanced CNI configurations with Multus (see hardware examples)

### 5. Minimal NixOS Configuration

Achieving ~450MB footprint while maintaining operational flexibility:

```nix
{
  imports = [
    "${modulesPath}/profiles/minimal.nix"
    "${modulesPath}/profiles/headless.nix"
  ];

  # Disable unnecessary features
  documentation.enable = false;
  environment.defaultPackages = [];
  programs.command-not-found.enable = false;

  # Optimize Nix store
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Limit boot generations
  boot.loader.systemd-boot.configurationLimit = 10;
}
```

## Example Hardware Configurations

These examples demonstrate hardware-specific configurations. The framework supports many platforms through modular hardware configurations.

### Intel N100 miniPCs

These miniPCs often include dual NICs enabling advanced networking configurations.

**Required kernel modules** (for Longhorn):
```nix
boot.kernelModules = [ "iscsi_tcp" "dm_crypt" "overlay" ];
```

**Dual-NIC Bonding with Traffic Separation** (optional):
```nix
systemd.network = {
  enable = true;
  networks."10-bond0" = {
    matchConfig.Name = "bond0";
    address = [
      "192.168.10.10/24"  # k3s cluster network
      "192.168.20.10/24"  # Longhorn storage network (with Multus CNI)
    ];
  };
  netdevs."10-bond0" = {
    bondConfig = {
      Mode = "balance-alb";  # No switch config required
      TransmitHashPolicy = "layer3+4";
    };
  };
};

services.k3s.extraFlags = [
  "--node-ip=192.168.10.10"
  "--flannel-iface=bond0"
];
```

**Performance optimizations**:
```nix
# I/O Scheduler
services.udev.extraRules = ''
  ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
'';

# Filesystem options
fileSystems."/var/lib/longhorn".options = [ "noatime" "nodiratime" "discard" ];

# CPU power management
boot.kernelParams = [ "intel_idle.max_cstate=1" ];

# Memory tuning
boot.kernel.sysctl = {
  "vm.swappiness" = 10;
  "vm.vfs_cache_pressure" = 50;
};
```

### NVIDIA Jetson Orin Nano

For comprehensive Jetson Orin Nano documentation including kernel management, L4T patches, and GPU functionality, see [jetson-orin-nano.md](jetson-orin-nano.md).

**Basic jetpack-nixos configuration**:
```nix
{
  imports = [
    (builtins.fetchTarball "https://github.com/anduril/jetpack-nixos/archive/master.tar.gz"
      + "/modules/default.nix")
  ];

  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nano";
    carrierBoard = "devkit";
    majorVersion = 6;
  };

  hardware.graphics.enable = true;
  hardware.nvidia-container-toolkit.enable = true;
}
```

**Critical notes**:
- Serial console via micro-USB is essential (HDMI console doesn't work)
- Use firmware version 35.2.1 (35.3.1 has USB boot issues)
- Requires flashing UEFI firmware first, then standard NixOS installation
- K3s with GPU support is fully feasible - see comprehensive documentation

## Deployment Tools and Workflow

### Key Tools

1. **nixos-anywhere**: Automated bare-metal provisioning via SSH
   - Deploys NixOS to any Linux system in 2-5 minutes per node
   - Uses kexec to boot installer environment without reboot
   - Integrates with disko for declarative partitioning

2. **deploy-rs**: Multi-node deployment tool
   - Manages remote deployments from single flake
   - Supports rollback on failure
   - Integrates with NixOS activation scripts

3. **disko**: Declarative disk partitioning
   - Defines partition layout in Nix
   - Automatic formatting during nixos-anywhere deployment
   - Supports complex layouts with LUKS, LVM, etc.

4. **sops-nix**: Secrets management
   - Encrypts secrets with age or GPG
   - Integrates with NixOS module system
   - Supports per-host key management

### Deployment Sequence

**Preparation Phase**:
1. Create git repository with flake structure
2. Generate age keys from SSH host keys: `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
3. Configure `.sops.yaml` with encryption rules
4. Encrypt k3s token: `sops secrets/k3s.yaml`
5. Test configurations in VMs

**Initial Deployment**:
1. Boot nodes via network (iPXE) or USB installer
2. Deploy first node: `nixos-anywhere --flake .#node1 root@192.168.10.11`
3. Verify boot and SSH access
4. Deploy remaining nodes: `deploy-rs .#node2 .#node3` or use nixos-rebuild

**Kubernetes Setup**:
1. Install Multus CNI for network separation
2. Deploy Kyverno and apply PATH patching policy
3. Install Longhorn via Helm with storage network config
4. Verify pod scheduling and PVC creation
5. Deploy workloads via manifests or GitOps

**Ongoing Management**:
- Updates: `nix flake update` → `nixos-rebuild` or `deploy-rs`
- Configuration changes: Edit `.nix` files → deploy via preferred method
- Rollback: Boot into previous NixOS generation
- Monitoring: Deploy Prometheus/Grafana via k3s manifests

## Common Commands Reference

### Deployment Commands
```bash
# Deploy single node
nixos-anywhere --flake .#node1 root@192.168.10.11

# Deploy to multiple nodes (various methods)
# Using deploy-rs:
deploy-rs .#node1 .#node2 .#node3

# Using nixos-rebuild remotely:
nixos-rebuild switch --flake .#node2 --target-host root@192.168.10.12

# Deploy all nodes in parallel with GNU parallel:
parallel nixos-rebuild switch --flake .#{} --target-host root@{} ::: node1:192.168.10.11 node2:192.168.10.12 node3:192.168.10.13
```

### Development Commands
```bash
# Validate flake structure
nix flake check

# Update dependencies
nix flake update

# Build configuration without deploying
nix build .#nixosConfigurations.node1.config.system.build.toplevel

# Test in VM
nixos-rebuild build-vm --flake .#node1
```

### Secrets Management
```bash
# Edit encrypted secrets
sops secrets/k3s.yaml

# Convert SSH host key to age public key
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub

# Generate new sops key
age-keygen -o ~/.config/sops/age/keys.txt
```

## Proven Reference Implementations

The following community projects provide working examples directly applicable to this deployment:

- **[niki-on-github/nixos-k3s](https://github.com/niki-on-github/nixos-k3s)**: Production-ready GitOps deployment with single-command provisioning from bare metal. Includes Flux, Cilium CNI, sops-nix, and self-hosted Gitea.

- **[rorosen/k3s-nix](https://github.com/rorosen/k3s-nix)**: Clean multi-node examples with interactive testing, sops-nix secrets, and automated manifest deployment. Includes Prometheus, Grafana, and Helm charts in pure Nix.

- **[Skasselbard/NixOS-K3s-Cluster](https://github.com/Skasselbard/NixOS-K3s-Cluster)**: CSV-driven cluster provisioning demonstrating declarative host definitions and automated deployment patterns.

- **[anduril/jetpack-nixos](https://github.com/anduril/jetpack-nixos)**: Jetson Orin Nano NixOS support with full GPU functionality, CUDA/TensorRT integration, and container GPU passthrough.

## Key Design Decisions

### Why NixOS Instead of Talos Linux?

While Talos provides an 80MB footprint and API-only management, NixOS offers:
- SSH access for edge device troubleshooting
- Declarative configuration with version control
- Generation-based rollback without re-imaging
- Existing ecosystem and tooling
- Flexibility for edge-specific requirements

### Why K3s Instead of Full Kubernetes?

- Single binary deployment (~50MB)
- Built-in storage, load balancer, ingress controller
- Lower resource requirements (512MB RAM minimum)
- Embedded etcd for simplified HA
- Production-grade with CNCF certification

### Why Longhorn for Storage?

- Cloud-native distributed block storage
- Built-in backup/restore and disaster recovery
- Incremental snapshots and replica management
- Works well with k3s's embedded architecture
- Active development and community support

## Important Notes

- This project follows a **documentation-first** approach
- All workloads should run in k3s, not on the host OS
- The host OS is treated as immutable infrastructure
- Always test configurations in VMs before bare metal deployment
- Serial console access is critical for Jetson hardware troubleshooting

## Next Steps

Once documentation alignment is achieved, implementation will focus on:

1. Creating the flake structure with multi-node configurations
2. Setting up disko partitioning layouts for N100 hardware
3. Configuring sops-nix with proper key management
4. Testing deployments in VMs with various scenarios
5. Deploying to physical hardware with incremental validation
6. Documenting specific configurations and lessons learned