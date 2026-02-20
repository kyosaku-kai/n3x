# ISAR Cross-Compilation Validation: ARM64 on x86_64

**Date**: 2026-02-11
**Branch**: `feature/unified-platform-v2`
**Related**: Plan 024 (Jetson Orin Nano Kernel 6.12 LTS)

## Summary

ISAR builds for ARM64 targets (Jetson Orin Nano) can be cross-compiled on x86_64 hosts with a ~8x speedup over QEMU TCG emulation. This eliminates the need for native ARM64 CI runners (Graviton EC2) as a day-one requirement.

## Background: Why Cross-Compilation Matters

ISAR builds for a different CPU architecture require executing target-architecture binaries during the build process. ISAR supports two approaches:

| Approach | How It Works | When Used |
|----------|-------------|-----------|
| **QEMU TCG emulation** | Every target-arch binary runs through QEMU user-mode translation | `ISAR_CROSS_COMPILE = "0"` |
| **Cross-compilation** | Host-native cross-toolchain compiles code; QEMU only for rootfs package operations (dpkg postinst scripts, etc.) | `ISAR_CROSS_COMPILE = "1"` (ISAR default) |

Cross-compilation uses the host's native `aarch64-linux-gnu-gcc` for all compilation (kernel, modules, packages) and only falls back to QEMU user-mode for operations that must run in the target architecture's chroot (e.g., Debian package post-install scripts, ldconfig).

## The Problem We Solved

The initial Jetson Orin Nano machine configuration (`kas/machine/jetson-orin-nano.yml`) had `ISAR_CROSS_COMPILE = "0"`, which forced full QEMU TCG emulation. This caused the kernel build to take **>2 hours 49 minutes** before being killed (it still hadn't finished). The fix was trivial: remove the override so ISAR's default cross-compilation takes effect.

**Commit**: `f3011b8` — `perf(isar): enable cross-compilation for Jetson ARM64 builds`

## Validation Results (2026-02-11)

### Build Timing

| Phase | TCG Emulation (old) | Cross-Compilation (new) |
|-------|--------------------:|------------------------:|
| Kernel `do_dpkg_build` | >2h 49m (KILLED) | **21m 53s** |
| Full image build (with sstate) | N/A (never completed) | **30m 32s** |

The cross-compiled kernel build is at least **8x faster** than TCG emulation (and likely more — TCG was killed before completing).

### Build Environment

- **Host**: WSL2 NixOS (x86_64), 20 vCPUs, 27.4 GB RAM
- **Cross-toolchain**: `aarch64-linux-gnu-gcc` via Debian's `crossbuild-essential-arm64`
- **binfmt_misc**: QEMU user-mode registered for aarch64 (flags: POCF)
- **Container**: kas-isar:5.1 via podman

### Cross-Compile Evidence

From the build log (`log.do_dpkg_build`):
```
# CROSS_COMPILE=aarch64-linux-gnu-
# CROSS_COMPILE_COMPAT=
```

### Config Fragment Validation

The Tegra234 kernel config fragment was successfully merged:
```
+ ./scripts/kconfig/merge_config.sh -O build-full/ build-full/.config debian/fragments/tegra234-enable.cfg debian/isar/version.cfg
Merging debian/fragments/tegra234-enable.cfg
```

### Image Contents

| Component | Value |
|-----------|-------|
| Kernel package | `linux-image-tegra` 6.12.69+r0 |
| Kernel version string | `6.12.69-tegra` |
| vmlinux size | 40 MB (vs 37 MB stock Debian arm64) |
| nvidia-l4t-core | 36.4.4 |
| nvidia-l4t-tools | 36.4.4 |
| Image format | tar.gz (for L4T flash) |
| Rootfs size | 209 MB compressed |

## CI Architecture Impact: Graviton Not Required at Launch

This validation has a significant cost implication for CI runner deployment (Plan 023).

### Original Plan

Deploy both x86_64 (c6i.2xlarge) and Graviton/ARM64 (c7g.2xlarge) EC2 runners:
- x86_64: ~$493/mo (instance + EBS)
- Graviton: ~$444/mo (instance + EBS)
- **Total: ~$937/mo**

### Revised Recommendation

**Start with x86_64 only.** A single x86_64 runner can build both x86_64 and ARM64 ISAR images via cross-compilation:

- x86_64 native builds: Full speed
- ARM64 cross-compiled builds: ~30 minutes (validated)
- ARM64 with warm sstate cache: Expected significantly faster (only changed recipes rebuild)
- **Cost: ~$493/mo** (47% savings vs both runners)

### When Graviton Becomes Needed

Add a Graviton runner when:
1. ARM64 build volume justifies native-speed builds (multiple daily builds)
2. Cross-compilation proves insufficient for specific recipes (rare — ISAR handles most cases)
3. Native ARM64 testing is required (hardware-in-the-loop, not just image building)

The Graviton host configuration (`infra/nixos-runner/hosts/ec2-graviton.nix`) is already implemented and can be deployed anytime via `pulumi up`.

## binfmt_misc: Build Environment Requirement

Cross-compilation still requires QEMU user-mode for target-architecture chroot operations. This is a **kernel-level** requirement (`/proc/sys/fs/binfmt_misc/`).

### How binfmt_misc Is Needed

Even with `ISAR_CROSS_COMPILE = "1"`, some build steps run inside an ARM64 chroot:
- Debian package postinst/preinst scripts
- `ldconfig` for shared library cache
- `dpkg --configure` for package configuration

These steps execute ARM64 binaries, which requires the kernel's binfmt_misc to intercept them and route to QEMU.

### Platform-Specific Solutions

| Build Environment | binfmt Status | Solution |
|-------------------|---------------|----------|
| NixOS (bare metal or WSL) | Configurable via NixOS options | `boot.binfmt.emulatedSystems = ["aarch64-linux"]` |
| NixOS-WSL (distributed to team) | Same as above | WSL kernel config + NixOS binfmt module |
| Docker Desktop (macOS/Windows) | Pre-configured | Docker Desktop's Linux VM includes binfmt for common archs |
| Podman on macOS (Apple Silicon) | Via podman machine | `podman machine` Linux VM needs binfmt for x86_64 |
| Generic Linux | Manual registration | `update-binfmts` package or manual `/proc/sys/fs/binfmt_misc/register` |
| EC2 NixOS runners | NixOS module | Already configured in `infra/nixos-runner/` |

### Current Registration (WSL2 NixOS)

```bash
# Static QEMU binary (no dynamic library dependencies)
QEMU_STATIC=$(nix build --no-link --print-out-paths 'nixpkgs#pkgsStatic.qemu-user')/bin/qemu-aarch64

# Register with F (fix binary), P (preserve argv[0]), C (credentials) flags
sudo sh -c "echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${QEMU_STATIC}:FPC' > /proc/sys/fs/binfmt_misc/register"
```

**F flag is critical**: Without it, the QEMU binary path is resolved at exec time, which fails inside containers where the host path doesn't exist. The F flag resolves the binary at registration time and passes the file descriptor.

## Key Takeaway

**Do not disable cross-compilation for ISAR ARM64 builds.** The `ISAR_CROSS_COMPILE` variable defaults to `"1"` for good reason. Overriding it to `"0"` causes catastrophic build time regressions (~8x+ slower). If a specific recipe fails under cross-compilation, fix the recipe rather than disabling cross-compilation globally.

## References

- `backends/debian/kas/machine/jetson-orin-nano.yml` — Machine config (includes kernel overlay)
- `backends/debian/kas/kernel/tegra-6.12.yml` — Kernel selection overlay (`KERNEL_NAME = "tegra"`)
- `backends/debian/meta-n3x/recipes-kernel/linux/linux-tegra_6.12.69.bb` — Kernel recipe
- `backends/debian/meta-n3x/recipes-kernel/linux/files/tegra234-enable.cfg` — Kernel config fragment
- `backends/debian/BSP-GUIDE.md` — BSP development guide (kernel and cross-build sections)
- `infra/nixos-runner/hosts/ec2-graviton.nix` — Graviton config (ready but not needed at launch)
- `docs/jetson-orin-nano-kernel6-analysis-revised.md` — Full kernel porting analysis
