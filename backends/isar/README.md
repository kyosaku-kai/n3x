# ISAR Backend for n3x

This directory contains the ISAR (Integration System for Automated Root filesystem generation) backend for the n3x K3s cluster platform.

## Build Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        n3x ISAR Build Architecture                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Layer 5: BitBake Recipe Artifacts                                    │   │
│  │   • .deb packages installed to target rootfs                         │   │
│  │   • .wic images ready for deployment or testing                      │   │
│  │   • Network configs in /etc/systemd/network/                         │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                              ▲                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Layer 4: BitBake/ISAR Build System                                   │   │
│  │   • Parses recipes from meta-isar-k3s/                               │   │
│  │   • Shared cache: ~/.cache/yocto/{downloads,sstate}                  │   │
│  │   • Task execution: fetch → unpack → build → package → image         │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                              ▲                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Layer 3: kas-container (Podman)                                      │   │
│  │   • Image: ghcr.io/siemens/kas/kas-isar:5.1                          │   │
│  │   • Provides: bitbake, ISAR, sbuild/schroot, bubblewrap              │   │
│  │   • Privileged mode for rootfs operations                            │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                              ▲                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Layer 2: kas-build Wrapper (WSL-specific)                            │   │
│  │   • Defined in: flake.nix (nix develop .#isar)                       │   │
│  │   • WSL workaround: unmounts /mnt/c during build (sgdisk sync bug)   │   │
│  │   • Remounts with proper permissions on exit                         │   │
│  │   • CRITICAL: Never SIGKILL - use SIGTERM for cleanup                │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                              ▲                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Layer 1: Nix Development Shell                                       │   │
│  │   • Command: nix develop .#isar                                      │   │
│  │   • Provides: kas, podman, kas-build wrapper                         │   │
│  │   • Sets: KAS_CONTAINER_IMAGE_NAME, KAS_CONTAINER_ENGINE             │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                              ▲                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Layer 0: Host Environment (WSL2)                                     │   │
│  │   • 9p mounts: /mnt/c, /mnt/d (Windows drives)                       │   │
│  │   • Hyper-V: 2-level virtualization limit (no L3 VMs)                │   │
│  │   • Nested KVM works for nixosTest, not for nested containers        │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
backends/isar/
├── kas/                              # KAS configuration overlays
│   ├── base.yml                      # Base configuration (shared cache, container settings)
│   ├── machine/                      # Machine-specific overlays
│   │   ├── qemu-amd64.yml           # QEMU x86_64 (testing)
│   │   └── jetson-orin-nano.yml     # Jetson Orin Nano (hardware)
│   ├── image/                        # Image recipe overlays
│   │   ├── k3s-server.yml           # K3s server image
│   │   └── k3s-agent.yml            # K3s agent image
│   └── network/                      # Network profile overlays
│       ├── simple.yml               # Flat network (default)
│       ├── vlans.yml                # VLAN tagging
│       └── bonding-vlans.yml        # Bonding + VLANs
├── meta-isar-k3s/                    # BitBake layer
│   ├── conf/layer.conf              # Layer configuration
│   ├── recipes-core/                # Core image recipes
│   │   └── images/                  # Image definitions
│   └── recipes-support/             # Support package recipes
│       ├── systemd-networkd-config/ # Network configuration (from Nix)
│       └── k3s/                     # K3s binary and service
├── build/                            # Build output (gitignored)
│   ├── tmp/deploy/images/           # Final images
│   ├── tmp/work/                    # Recipe workdirs
│   └── downloads/                   # Downloaded sources (link to cache)
└── README.md                         # This file
```

## Quick Start

### Prerequisites

1. **Podman** - Container engine (recommended over Docker for rootless support)
2. **KVM** - Kernel virtualization for qemu-amd64 testing
3. **WSL2** (if on Windows) - With nested virtualization enabled

### Build Commands

```bash
# Enter the ISAR development shell
nix develop .#isar

# Build a K3s server image for QEMU (testing)
cd backends/isar
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/network/simple.yml

# Build for Jetson Orin Nano (hardware)
kas-build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/image/k3s-server.yml:kas/network/vlans.yml

# Build a specific package only (for debugging)
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake systemd-networkd-config"
```

### Network Profiles

Network configurations are generated from Nix profiles to ensure parity with NixOS:

| Profile | Description | K3s Interface | Storage Interface |
|---------|-------------|---------------|-------------------|
| `simple` | Single flat network | eth1 (192.168.1.x/24) | Same |
| `vlans` | 802.1Q VLAN tagging | eth1.200 (192.168.200.x/24) | eth1.100 (192.168.100.x/24) |
| `bonding-vlans` | Bond + VLANs | bond0.200 | bond0.100 |

To regenerate network configs after modifying `lib/network/profiles/*.nix`:

```bash
nix run '.#generate-networkd-configs'
```

## WSL2 Considerations

### The sgdisk sync() Bug

When building WIC images, `sgdisk` calls `sync()` which hangs on WSL2's 9p filesystem mounts. The `kas-build` wrapper handles this by:

1. Unmounting `/mnt/c` (and other Windows drives) before build
2. Running the build in the container
3. Remounting with proper permissions on exit

**CRITICAL**: Never use `kill -9` on a running `kas-build` process! This prevents the cleanup handler from remounting filesystems. Instead:

```bash
# Preferred: graceful termination
kill -TERM <pid>
sleep 5

# If still running
kill -INT <pid>
sleep 3

# Last resort only (breaks mounts!)
kill -9 <pid>

# Recovery after SIGKILL
nix run '.#wsl-remount'
# Or from PowerShell: wsl --shutdown
```

### Shared Cache Configuration

Build artifacts are cached at the user level to persist across projects:

```yaml
# In kas/base.yml
local_conf_header:
  shared-cache: |
    DL_DIR = "${HOME}/.cache/yocto/downloads"
    SSTATE_DIR = "${HOME}/.cache/yocto/sstate"
```

Verify cache is working:
```bash
ls -la ~/.cache/yocto/
# Should show downloads/ and sstate/ directories
```

## Troubleshooting

### Check for Orphaned Processes

```bash
# Check for running containers
sudo podman ps -a

# Check for build processes
pgrep -a bitbake
pgrep -a kas

# Clean up orphaned containers
sudo podman rm -f $(sudo podman ps -aq)
```

### Recipe Debugging

```bash
# Enter ISAR shell to debug
nix develop .#isar
cd backends/isar

# Clean and rebuild a specific recipe
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake -c cleanall systemd-networkd-config"
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake systemd-networkd-config"

# Check package contents
dpkg-deb -c build/tmp/work/*/systemd-networkd-config/*/systemd-networkd-config_*.deb
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `bwrap: not found` | Wrong container image | Use `kas-isar:5.1`, not `kas:latest` |
| Build hangs at 96% | sgdisk sync() on 9p | Use `kas-build` wrapper (unmounts /mnt/c) |
| `/mnt/c` empty after build | SIGKILL killed wrapper | Run `nix run '.#wsl-remount'` |
| `sysconfdir` undefined | ISAR vs OE difference | Already fixed - ensure latest recipe |
| sstate not reused | Wrong cache path | Check `~/.cache/yocto/` exists |

## Integration with Nix

The ISAR backend integrates with the main n3x flake:

- **Network configs**: Generated from `lib/network/profiles/*.nix`
- **Test images**: Consumed by `nix/isar-artifacts.nix` for nixosTest
- **Flash scripts**: Use `lib.mkJetsonFlashScript` for hardware deployment

See `lib/network/README.md` for the unified network abstraction design.
