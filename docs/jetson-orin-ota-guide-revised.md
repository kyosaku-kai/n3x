# Jetson Orin Nano OTA-Ready Setup: ISAR + SWUpdate + Nix Tooling

## Document Overview

**Revised**: 2026-01-22
**Original Source**: `file:///C:/Users/blackt1/Downloads/jetson-orin-ota-nix-guide.md`
**Integration Target**: `isar-k3s` project

This document describes building an OTA-capable system for Jetson Orin Nano using:
- **ISAR**: Debian-based embedded Linux image builder (already established in this project)
- **SWUpdate**: Production-ready OTA framework with official ISAR support via `isar-cip-core`
- **Nix**: Host development environment (already configured in `flake.nix`)
- **jetpack-nixos**: NVIDIA BSP tooling for initial device flashing

---

## Corrections to Original Document

### 1. jetpack-nixos Flash Script Naming

**Original claim**: Use `nix build github:anduril/jetpack-nixos#flash-orin-nano-devkit`

**Corrected**: The package exists and is named correctly. Verified via:
```bash
nix flake show github:anduril/jetpack-nixos 2>&1 | grep orin-nano
# Output includes:
#   flash-orin-nano-devkit: package 'initrd-flash-orin-nano-devkit-cross'
#   flash-orin-nano-devkit-jp5: package 'initrd-flash-orin-nano-devkit-jp5-cross'
```

**JetPack versions**:
- `flash-orin-nano-devkit` = JetPack 6 (L4T 36.x, current)
- `flash-orin-nano-devkit-jp5` = JetPack 5 (L4T 35.x, legacy)

### 2. ISAR qemuarm64 vs Native Jetson Machine

**Original approach**: Build with `MACHINE = "qemuarm64"` then manually integrate with L4T BSP

**Better approach for this project**: We already have `kas/machine/jetson-orin-nano.yml` which defines a proper machine configuration. The ISAR build should target this directly, not qemuarm64.

The existing machine config:
```yaml
machine: jetson-orin-nano
distro: debian-trixie
target: mc:jetson-orin-nano-trixie:isar-image-base
```

### 3. SWUpdate Integration Path

**Original claim**: isar-cip-core provides complete SWUpdate recipes

**Clarified**: isar-cip-core does provide SWUpdate integration, but it requires:
1. Adding isar-cip-core as a kas layer
2. Using `kas/opt/swupdate.yml` overlay to enable SWUpdate
3. Configuring bootloader (EFI Boot Guard) separately

The kas overlay sets:
```bitbake
CIP_IMAGE_OPTIONS:append = " recipes-core/images/swupdate.inc"
OVERRIDES .= ":swupdate"
WKS_FILE ?= "${MACHINE}-${SWUPDATE_BOOTLOADER}.wks.in"
ABROOTFS_PART_UUID_A ?= "fedcba98-7654-3210-cafe-5e0710000001"
ABROOTFS_PART_UUID_B ?= "fedcba98-7654-3210-cafe-5e0710000002"
```

### 4. EFI Boot Guard vs NVIDIA nv_boot_control

**Original assumption**: Use EFI Boot Guard for A/B switching

**Reality for Jetson**: NVIDIA uses `nv_boot_control` and `nvbootctrl` for slot management, not EFI Boot Guard. The UEFI Capsule Update mechanism handles firmware updates. For Jetson platforms:

- **Bootloader A/B**: Managed by NVIDIA's `nvbootctrl` utility
- **Rootfs A/B**: Can use `nvbootctrl -t rootfs` or standard partition labels
- **SWUpdate integration**: Needs custom bootloader handler for `nvbootctrl`

### 5. flake.nix Integration

**Original**: Proposed separate flake.nix for Jetson development

**Better**: Extend existing `flake.nix` in this project. Current flake already has:
- `kas` for ISAR builds
- `podman` for container runtime
- `qemu` for testing

Missing for Jetson OTA work:
- jetpack-nixos input (for flash tools)
- Additional packages for SWUpdate build/packaging

---

## Architecture: Revised for This Project

```
                    DEVELOPMENT HOST (NixOS/WSL2)
    ┌─────────────────────────────────────────────────────────┐
    │  nix develop (flake.nix)                                │
    │  ├── kas-container → ISAR build system                  │
    │  ├── qemu → Testing (existing test framework)           │
    │  └── jetpack-nixos flash tools → Initial flashing       │
    │                                                         │
    │  Build Outputs:                                         │
    │  ├── isar/build/.../isar-k3s-image-*.wic (base image)   │
    │  └── isar/build/.../isar-k3s-image-*.swu (OTA package)  │
    └─────────────────────────────────────────────────────────┘
                              │
              USB Recovery Mode (initial flash only)
                              │
                              ▼
    ┌─────────────────────────────────────────────────────────┐
    │              JETSON ORIN NANO TARGET                     │
    │                                                          │
    │  QSPI Flash (Bootloader)      NVMe/SD (Rootfs)          │
    │  ├── MB1/MB2 (A/B)            ├── APP (Slot A)          │
    │  └── UEFI (A/B)               └── APP_b (Slot B)        │
    │                                                          │
    │  Running System:                                         │
    │  ├── Debian Trixie (ISAR-built)                         │
    │  ├── SWUpdate daemon                                     │
    │  ├── nvbootctrl (slot management)                        │
    │  └── Suricatta (hawkBit client)                          │
    │                                                          │
    │  OTA Updates via Network ──────────────────────────────▶ │
    └─────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌─────────────────────────────────────────────────────────┐
    │                    hawkBit Server                        │
    │            (Fleet Management, optional)                  │
    └─────────────────────────────────────────────────────────┘
```

---

## Phase 1: Extend Project Flake for Jetson OTA

### Current flake.nix (already exists)

The existing `flake.nix` provides ISAR/kas tooling. To add Jetson flash support:

```nix
# Proposed additions to flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # ADD: jetpack-nixos for NVIDIA flash tools
    jetpack-nixos = {
      url = "github:anduril/jetpack-nixos";
      # Don't follow nixpkgs - jetpack-nixos pins specific versions
    };
  };

  outputs = { self, nixpkgs, flake-utils, jetpack-nixos }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;  # Required for NVIDIA components
        };
      in {
        devShells.default = pkgs.mkShell {
          name = "isar-k3s";

          buildInputs = with pkgs; [
            # Existing ISAR/kas tooling
            kas
            podman
            qemu
            gnumake
            git
            python3
            jq
            yq-go
            tree

            # ADD: SWUpdate packaging tools
            openssl
            zstd
            cpio
            dosfstools
            e2fsprogs

            # ADD: USB flash tools
            usbutils  # lsusb for recovery mode detection
          ];

          shellHook = ''
            export KAS_CONTAINER_ENGINE=podman

            echo "isar-k3s Isar Development Environment"
            echo ""
            echo "ISAR Build:"
            echo "  kas-container --isar build kas/base.yml:kas/machine/jetson-orin-nano.yml"
            echo ""
            echo "Jetson Flash (after building flash script):"
            echo "  nix build github:anduril/jetpack-nixos#flash-orin-nano-devkit"
            echo "  sudo ./result/bin/flash-orin-nano-devkit"
          '';
        };

        # Expose flash scripts as packages
        packages = {
          flash-orin-nano = jetpack-nixos.packages.${system}.flash-orin-nano-devkit or
            pkgs.writeShellScriptBin "flash-orin-nano-devkit" ''
              echo "Building flash script..."
              nix build github:anduril/jetpack-nixos#flash-orin-nano-devkit -o ./flash-script
              echo "Flash script built. Run: sudo ./flash-script/bin/flash-orin-nano-devkit"
            '';
        };
      }
    );
}
```

---

## Phase 2: Add isar-cip-core for SWUpdate

### Clone and Configure isar-cip-core

```bash
cd /home/tim/src/isar-k3s

# Clone isar-cip-core as a submodule or layer
git submodule add https://gitlab.com/cip-project/cip-core/isar-cip-core.git isar/isar-cip-core

# Alternative: Add as kas remote repo in isar-k3s.yml
```

### Create kas overlay for SWUpdate: `kas/opt/swupdate.yml`

```yaml
# kas/opt/swupdate.yml
# Enable SWUpdate OTA framework
# Usage: kas-container --isar build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/opt/swupdate.yml

header:
  version: 14
  includes:
    # Include isar-cip-core SWUpdate configuration
    - repo: isar-cip-core
      file: kas/opt/swupdate.yml

repos:
  isar-cip-core:
    url: https://gitlab.com/cip-project/cip-core/isar-cip-core.git
    branch: master
    layers:
      recipes-bsp:
      recipes-core:
      recipes-support:

local_conf_header:
  swupdate-jetson: |
    # Jetson-specific SWUpdate configuration

    # Hardware compatibility string
    SWUPDATE_HW_COMPATIBILITY = "jetson-orin-nano-8gb"

    # Use nvbootctrl for slot management (not EFI Boot Guard)
    SWUPDATE_BOOTLOADER = "nvbootctrl"

    # A/B rootfs partition labels
    ABROOTFS_PART_UUID_A = "fedcba98-7654-3210-cafe-5e0710000001"
    ABROOTFS_PART_UUID_B = "fedcba98-7654-3210-cafe-5e0710000002"

    # Include SWUpdate and dependencies in image
    IMAGE_INSTALL:append = " \
        swupdate \
        swupdate-www \
        libubootenv-bin \
        "
```

---

## Phase 3: Build ISAR Image for Jetson

### Build Base Image

```bash
cd /home/tim/src/isar-k3s
nix develop

cd isar/

# Build WITHOUT SWUpdate first (validate base image)
kas-container --isar build kas/base.yml:kas/machine/jetson-orin-nano.yml

# Build WITH SWUpdate (for OTA capability)
kas-container --isar build kas/base.yml:kas/machine/jetson-orin-nano.yml:kas/opt/swupdate.yml
```

**Note**: On WSL2, use the workaround script to avoid sgdisk hang:
```bash
./scripts/wsl-safe-build.sh kas/base.yml:kas/machine/jetson-orin-nano.yml
```

### Output Files

After successful build:
```
isar/build/tmp/deploy/images/jetson-orin-nano/
├── isar-k3s-image-*-debian-trixie-arm64.tar.gz  # Rootfs tarball
├── isar-k3s-image-*-debian-trixie-arm64.wic     # Disk image
└── isar-k3s-image-*-debian-trixie-arm64.swu     # OTA update package (if swupdate.yml used)
```

---

## Phase 4: Integrate ISAR Rootfs with L4T BSP

### Download L4T BSP

```bash
cd /home/tim/src/isar-k3s

# Download JetPack 6 / L4T R36.4.3
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Jetson_Linux_R36.4.3_aarch64.tbz2

# Extract
tar xf Jetson_Linux_R36.4.3_aarch64.tbz2
```

### Replace L4T Sample Rootfs with ISAR Image

```bash
cd Linux_for_Tegra

# Remove default sample rootfs
sudo rm -rf rootfs/*

# Extract ISAR rootfs
sudo tar -xf ../isar/build/tmp/deploy/images/jetson-orin-nano/isar-k3s-image-*-debian-trixie-arm64.tar.gz -C rootfs/

# Apply NVIDIA proprietary binaries (drivers, firmware)
sudo ./apply_binaries.sh

# Create default user
sudo ./tools/l4t_create_default_user.sh \
    -u nvidia \
    -p nvidia123 \
    -n jetson-orin-nano \
    --accept-license
```

### Alternative: jetpack-nixos with Custom Rootfs

jetpack-nixos creates NixOS rootfs by default. For ISAR rootfs:

1. Build ISAR image
2. Use L4T tools directly (as above)
3. Or modify jetpack-nixos configuration to use external rootfs

---

## Phase 5: Initial Flash (USB Recovery Mode Required)

### Enter Recovery Mode

1. Connect USB-C between host and Jetson
2. Connect FC-REC to GND jumper (on devkit carrier board)
3. Apply power
4. Verify recovery mode:
   ```bash
   lsusb | grep -i nvidia
   # Should show: "0955:7023 NVIDIA Corp. APX"
   ```

### Flash with A/B Rootfs

```bash
cd Linux_for_Tegra

# Flash with A/B partition layout to NVMe
sudo ROOTFS_AB=1 ROOTFS_RETRY_COUNT_MAX=3 \
    ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    -c ./tools/kernel_flash/flash_l4t_t234_nvme_rootfs_ab.xml \
    --showlogs \
    --network usb0 \
    jetson-orin-nano-devkit external
```

**Parameters**:
- `ROOTFS_AB=1`: Create dual rootfs partitions (APP and APP_b)
- `ROOTFS_RETRY_COUNT_MAX=3`: Auto-rollback after 3 boot failures
- `--external-device nvme0n1p1`: Flash to NVMe (use `mmcblk0p1` for SD)

---

## Phase 6: SWUpdate Configuration on Target

### Verify Installation After First Boot

```bash
# SSH to Jetson
ssh nvidia@<jetson-ip>

# Check L4T version
cat /etc/nv_tegra_release
# Expected: # R36 (release), REVISION: 4.3, ...

# Check boot slots
sudo nvbootctrl dump-slots-info
sudo nvbootctrl -t rootfs dump-slots-info

# Verify SWUpdate
swupdate --version
```

### Configure SWUpdate for nvbootctrl

Create `/etc/swupdate.cfg`:

```config
globals: {
    verbose = true;
    loglevel = 5;

    # Use custom handler for nvbootctrl
    bootloader = "nvbootctrl";

    hardware-compatibility = true;
};

# For hawkBit integration (optional)
suricatta: {
    tenant = "default";
    id = "${DEVICE_ID}";
    url = "https://hawkbit.example.com:8443";
    polldelay = 300;
};
```

### Create nvbootctrl Handler for SWUpdate

Create `/usr/lib/swupdate/handlers/nvbootctrl-handler.sh`:

```bash
#!/bin/bash
# SWUpdate handler for NVIDIA nvbootctrl slot management
set -e

ACTION=$1  # "get" or "set"
SLOT=$2    # "A" or "B" (for set)

case "$ACTION" in
    get)
        # Get current active slot
        CURRENT=$(nvbootctrl -t rootfs get-current-slot 2>/dev/null)
        echo "$CURRENT"
        ;;
    set)
        # Set next boot slot
        if [ "$SLOT" = "A" ]; then
            nvbootctrl -t rootfs set-active-boot-slot 0
        elif [ "$SLOT" = "B" ]; then
            nvbootctrl -t rootfs set-active-boot-slot 1
        fi
        ;;
    confirm)
        # Mark current boot successful
        nvbootctrl -t rootfs mark-boot-successful
        ;;
esac
```

---

## Phase 7: Create SWUpdate Packages

### sw-description for Jetson A/B Updates

```config
software = {
    version = "1.0.0";
    hardware-compatibility: ["jetson-orin-nano-8gb"];

    jetson: {
        # Update inactive rootfs slot
        rootfs: {
            images: ({
                filename = "rootfs.ext4.zst";
                device = "/dev/disk/by-partlabel/APP_b";  # or APP based on current
                type = "raw";
                compressed = "zstd";
                sha256 = "@rootfs.ext4.zst.sha256";
            });
            scripts: ({
                filename = "post-update.sh";
                type = "shellscript";
            });
        };
    };
};
```

### Build .swu Package

```bash
cd /home/tim/src/isar-k3s
mkdir -p swu-build && cd swu-build

# Create ext4 from ISAR rootfs
truncate -s 4G rootfs.ext4
mkfs.ext4 -L APP_b rootfs.ext4

mkdir -p mnt
sudo mount rootfs.ext4 mnt
sudo tar -xf ../isar/build/tmp/deploy/images/jetson-orin-nano/isar-k3s-image-*-debian-trixie-arm64.tar.gz -C mnt/
sudo umount mnt

# Compress
zstd -19 rootfs.ext4 -o rootfs.ext4.zst

# Calculate checksum
sha256sum rootfs.ext4.zst | cut -d' ' -f1 > rootfs.ext4.zst.sha256

# Package (sw-description MUST be first)
echo -e "sw-description\nrootfs.ext4.zst\npost-update.sh" | \
    cpio -ov -H crc > isar-k3s-update-1.0.0.swu
```

---

## Hardware Constraints Reference

| Constraint | Details | Mitigation |
|------------|---------|------------|
| No internal eMMC | Orin Nano stores bootloader in QSPI only; rootfs on NVMe/SD | Plan for external storage |
| Initial flash requires USB | Cannot bypass recovery mode for first flash | Physical access for provisioning |
| Factory firmware compatibility | May need staged upgrade (JP5 → JP6) | Check `nvbootctrl --version` |
| A/B rootfs disabled by default | Must use `ROOTFS_AB=1` during flash | Include in flash command |
| x86_64 host required for flash | NVIDIA tools are x86_64-only | Flash from x86 machine |

---

## Integration with Existing Project Test Framework

The existing NixOS test driver framework (`isar/nix/tests/`) can be adapted for Jetson testing:

1. **QEMU emulation** (`kas/machine/qemu-arm64-orin.yml`): Already configured for Cortex-A78 emulation
2. **Real hardware tests**: Require physical Jetson + serial/SSH access
3. **SWUpdate validation**: Test update workflow in QEMU before real hardware

See `isar/.research/CRITICAL-DECISION-SUMMARY.md` for test framework architecture.

---

## References

- [jetpack-nixos](https://github.com/anduril/jetpack-nixos) - NVIDIA BSP tooling for Nix
- [isar-cip-core](https://gitlab.com/cip-project/cip-core/isar-cip-core) - ISAR SWUpdate integration
- [SWUpdate Documentation](https://sbabic.github.io/swupdate/)
- [NVIDIA L4T Documentation](https://docs.nvidia.com/jetson/l4t/index.html)
- [hawkBit](https://www.eclipse.org/hawkbit/) - OTA fleet management
