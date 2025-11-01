# NVIDIA Jetson Orin Nano NixOS Support

This document provides comprehensive information about running NixOS on NVIDIA Jetson Orin Nano hardware with full GPU functionality, k3s support, and kernel management through the jetpack-nixos project.

## Overview

**NixOS on Jetson Orin Nano is production-ready** through the jetpack-nixos project by Anduril Industries. This mature, actively maintained solution packages the complete Linux for Tegra (L4T) ecosystem as NixOS modules, enabling:

- Declarative configuration of Jetson hardware
- Full CUDA/CuDNN/TensorRT support
- Hardware acceleration and container GPU passthrough
- K3s deployment with GPU-enabled workloads
- Reproducible edge AI infrastructure

## The jetpack-nixos Project

### Core Solution

The **jetpack-nixos** repository (github.com/anduril/jetpack-nixos) represents the definitive solution for running NixOS on modern Jetson hardware:

- Maintained by Anduril Industries with professional-grade documentation
- Supports JetPack 5 and 6, including Orin Nano Super variant
- 293 GitHub stars, 98 forks, active development through 2025
- Used in production defense technology systems

### Supported Hardware

**Actively Supported:**
- Jetson Orin Nano (including Super variant)
- Jetson Orin NX
- Jetson Orin AGX (including Industrial)
- Jetson Xavier AGX
- Jetson Xavier NX

**Not Supported:**
- Original Jetson Nano (deprecated in JetPack 5+)
- Jetson TX2/TX1 (obsolete)

## L4T Kernel and Tegra Patch Management

### Kernel Architecture

jetpack-nixos **packages NVIDIA's pre-patched kernel sources** rather than attempting to patch mainline:

- **JetPack 5**: Linux 5.10 with Tegra patches (L4T R35.x)
- **JetPack 6**: Linux 5.15 with Tegra patches (L4T R36.x)
- Sources from OpenEmbedded for Tegra (OE4T) for cleaner organization
- Both standard and real-time kernel variants available

### GPU Driver Integration

The nvgpu driver and related components are handled through:

- Building nvgpu from source as out-of-tree module
- Packaging all L4T components as Nix derivations:
  - Platform firmware and UEFI bootloader (EDK2-based)
  - ARM Trusted Firmware
  - CUDA/CuDNN/TensorRT libraries
  - V4L2 multimedia stack
  - Vulkan/EGL/GBM graphics APIs

### Bring Your Own Kernel (BYOK)

JetPack 6+ supports using newer mainline kernels:

- Experimental support for kernel 6.1, 6.6, even 6.12 via OE4T
- Requires nvidia-kernel-oot modules
- Community reports 146+ patches needed for full Tegra support
- UEFI-based boot enables standard NixOS workflows

### Version Coupling

**Critical**: JetPack firmware versions must exactly match kernel/rootfs versions:
- JetPack 5 firmware cannot run JetPack 6 kernels
- Updates must upgrade firmware and rootfs simultaneously
- NixOS generations track component sets atomically

## K3s Deployment on Jetson

### Configuration

K3s runs natively on ARM64 with full GPU passthrough support:

```nix
{
  # Jetson GPU support
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nano";
    carrierBoard = "devkit";
    majorVersion = 6;
  };
  hardware.graphics.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  # K3s configuration
  boot.kernelModules = [ "overlay" "br_netfilter" "iscsi_tcp" ];
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.ipv4.ip_forward" = 1;
  };

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--write-kubeconfig-mode 644";
  };

  networking.firewall.allowedTCPPorts = [ 6443 ];
}
```

### GPU Access in Containers

The nvidia-container-toolkit enables GPU passthrough:

- Uses Container Device Interface (CDI) format
- Access GPUs with device specification `nvidia.com/gpu=all`
- Deploy NVIDIA device plugin for Kubernetes
- Request GPU resources: `resources.limits.nvidia.com/gpu: 1`
- CUDA compute capability automatically set to 8.7 for Orin

### Performance Considerations

**Critical for k3s deployments:**
- Use external SSD/NVMe storage, NOT eMMC or SD cards
- K3s generates significant write activity
- Mount `/var/lib/rancher/k3s` on fast storage
- Configure 4-8GB swap for pod-heavy workloads
- Use ARM64-specific or multi-arch container images
- NVIDIA GPU Cloud (NGC) provides optimized L4T containers

## Installation Process

### Prerequisites

- x86_64 host machine (NVIDIA flashing tools are x86_64-only)
- USB cable for recovery mode connection
- Serial console access (micro-USB) - **ESSENTIAL**
- NVMe or USB storage for OS installation

### Step 1: Flash UEFI Firmware

```bash
# Build firmware package
nix build github:anduril/jetpack-nixos#flash-orin-nano-devkit

# Put Jetson in recovery mode (hold recovery button during power-on)
# Run flash script
sudo ./result/flash.sh
```

### Step 2: Create Installation Media

```bash
# For JetPack 6
nix build github:anduril/jetpack-nixos#iso_minimal

# For JetPack 5
nix build github:anduril/jetpack-nixos#iso_minimal_jp5

# Write to USB drive
dd if=result/iso/*.iso of=/dev/sdX bs=1M status=progress
```

### Step 3: Install NixOS

Boot from USB and perform standard NixOS installation with jetpack-nixos modules.

### Using Flakes

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    jetpack.url = "github:anduril/jetpack-nixos/master";
  };

  outputs = { self, nixpkgs, jetpack }: {
    nixosConfigurations.orin-nano = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        jetpack.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

## Known Limitations and Workarounds

### Critical Issues

**HDMI/DisplayPort Console Output**
- **Problem**: Linux console doesn't work on external monitors
- **Workaround**: Use serial UART console via micro-USB
- Desktop environments work after boot (LightDM recommended)
- GDM fails due to rootless X11 issues

**USB Boot Failures**
- **Problem**: Firmware 35.3.1 doesn't detect USB devices
- **Solution**: Use firmware version 35.2.1

**NFS Flashing Reliability**
- **Problem**: Intermittent "no such file" errors during flash
- **Workaround**: Retry multiple times, restart NFS service

### Desktop Environment Issues

- GNOME has memory manager initialization failures
- LightDM with i3 confirmed working
- Wayland works on Orin (Weston, Sway tested)
- X11 requires running as root once before normal use

### Boot Configuration

**Xavier AGX Specific:**
- UEFI variables stored on eMMC, not QSPI flash
- Cannot modify boot order from Linux
- Manual UEFI menu configuration required

## Minimal NixOS for Embedded Deployment

### Basic Minimization

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
  services.udisks2.enable = false;

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

### Advanced Patterns

**Impermanence with tmpfs root:**
- Keep only `/boot` and `/nix` persistent
- Reduces storage wear on embedded flash
- Ensures clean state on each boot
- Ideal for edge computing reliability

**MicrOS Project:**
- "Microscopic NixOS" for embedded systems
- Reduces systemd dependencies
- `lib.microsSystem` alternative to `lib.nixosSystem`

## Community and Support

### Primary Resources

- **GitHub**: github.com/anduril/jetpack-nixos (code, issues, documentation)
- **NixOS Discourse**: Primary discussion forum
- **Matrix Chat**: #users:nixos.org for real-time support
- **Discord**: discord.gg/RbvHtGa (unofficial but active)

### Key Contributors

- **Daniel Fullmer** (Anduril): Primary maintainer
- **elliotberman**: JetPack 7 development
- **colemickens**: UEFI patches
- Multiple academic institutions (TUM Technical University)

### Additional Resources

- NVIDIA Developer Forums (hardware-specific issues)
- eLinux.org wiki (L4T patch collections)
- OpenEmbedded for Tegra (kernel development)
- Community gists for specific flashing scenarios

## Production Readiness Assessment

### Strengths

- **Mature Project**: 2+ years active development
- **Professional Maintenance**: Anduril Industries backing
- **Production Usage**: Deployed in defense systems
- **Comprehensive Support**: All major L4T components
- **Active Community**: Regular updates, responsive issue tracking

### Considerations

- **Kernel Lag**: 2-4 years behind mainline (security implications)
- **Console Access**: Serial console essential for troubleshooting
- **Flashing Complexity**: Multi-step process requires technical expertise
- **Desktop Limitations**: Headless deployments recommended

### Recommended Use Cases

**Ideal for:**
- Fleet deployments requiring reproducibility
- Edge AI/ML inference workloads
- Robotics and industrial automation
- Research requiring exact reproducibility
- Organizations with existing NixOS expertise

**Consider Ubuntu for:**
- Quick prototyping
- Teams new to NixOS or Jetson
- Projects requiring reliable graphical output
- Maximum NVIDIA community support

## Validation Approach for K3s

While no documented k3s+NixOS+Jetson deployments exist, all components are proven independently:

1. **Verify NixOS Boot**: Confirm basic system with GPU (`nvidia-smi`)
2. **Test CUDA**: Run basic CUDA samples
3. **Container GPU**: Verify Docker/Podman GPU passthrough
4. **Enable K3s**: Deploy single-node cluster
5. **GPU Scheduling**: Install NVIDIA device plugin
6. **Deploy Workload**: Test GPU-enabled pods

## Future Outlook

- NVIDIA improving mainline kernel support gradually
- Community OE4T development for newer kernels
- JetPack 7 support in development
- Potential for official k3s integration documentation
- Growing adoption in edge computing deployments

The combination of NixOS's declarative infrastructure with Jetson's edge AI capabilities provides unique operational advantages that justify the implementation complexity for appropriate use cases.