# binfmt_misc Requirements for Cross-Architecture ISAR Builds

**Date**: 2026-02-11
**Related**: Plan 025 (Cross-Architecture Build Environment), Plan 024 (Jetson Kernel 6.12)

## Overview

ISAR cross-compilation for ARM64 targets on x86_64 hosts (or vice versa) requires the Linux kernel's `binfmt_misc` subsystem to execute foreign-architecture binaries during chroot operations. This document covers what binfmt_misc is, why it's needed, how to configure it on each build platform, and what goes wrong when it's missing.

**Key point**: Even with `ISAR_CROSS_COMPILE = "1"` (host cross-toolchain for compilation), QEMU user-mode emulation via binfmt_misc is still required for chroot operations like `dpkg --configure`, postinst scripts, and `ldconfig`.

## Linux Kernel Requirements

### binfmt_misc Module

binfmt_misc is a kernel facility that allows arbitrary binary formats to be recognized and handled by user-space interpreters. It operates through `/proc/sys/fs/binfmt_misc/`, a special filesystem that must be mounted.

**Requirements**:
- Kernel compiled with `CONFIG_BINFMT_MISC=y` or `CONFIG_BINFMT_MISC=m`
- The `binfmt_misc` filesystem mounted at `/proc/sys/fs/binfmt_misc/`
- The `register` file writable (requires root or appropriate capabilities)

**Verification**:
```bash
# Check if binfmt_misc is mounted
ls /proc/sys/fs/binfmt_misc/status 2>/dev/null && echo "mounted" || echo "NOT mounted"

# Check if a specific architecture is registered
cat /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || echo "aarch64 NOT registered"
```

Most modern Linux kernels (including WSL2's Microsoft kernel) ship with `CONFIG_BINFMT_MISC=y`.

### /proc Filesystem

binfmt_misc lives under `/proc/sys/fs/binfmt_misc/`. This is always available on systems with procfs mounted (all standard Linux installations). On WSL2, `/proc` is managed by the WSL init system and is always present.

## QEMU User-Mode Binary Requirements

### Static Linking is Mandatory

The QEMU binary used for binfmt_misc **must be statically linked**. This is required by the `F` (fix-binary) flag, which opens the interpreter at registration time and passes the file descriptor to the kernel. A dynamically linked binary would fail inside containers/chroots because its shared libraries (from the host) aren't available in the container's filesystem namespace.

**Verification**:
```bash
# Must show "statically linked"
file $(which qemu-aarch64) 2>/dev/null || file $(which qemu-aarch64-static) 2>/dev/null
```

**NixOS source**: `nixpkgs#pkgsStatic.qemu-user` provides statically-linked QEMU user-mode binaries built with musl libc.

**Debian/Ubuntu source**: `qemu-user-static` package provides `/usr/bin/qemu-aarch64-static`.

### Current Binary (NixOS-WSL)

```
/nix/store/...-qemu-user-static-x86_64-unknown-linux-musl-10.2.0/bin/qemu-aarch64
ELF 64-bit LSB executable, x86-64, statically linked
```

## Registration Format

### Wire Format

Registration is done by writing a colon-delimited string to `/proc/sys/fs/binfmt_misc/register`:

```
:name:type:offset:magic:mask:interpreter:flags
```

| Field | Description |
|-------|-------------|
| `name` | Identifier (appears as filename under `/proc/sys/fs/binfmt_misc/`) |
| `type` | `M` for magic number matching, `E` for extension matching |
| `offset` | Byte offset in file to start matching (usually `0`) |
| `magic` | Hex bytes to match (ELF header + architecture identifier) |
| `mask` | Hex bitmask applied before comparison (allows wildcard bytes) |
| `interpreter` | Absolute path to the QEMU binary |
| `flags` | Registration flags (see below) |

### Magic Bytes for ARM64 (aarch64)

The magic bytes identify an ELF binary for a specific architecture:

```
magic: 7f454c460201010000000000000000000200b700
mask:  ffffffffffffff00fffffffffffffffffeffffff
```

Breakdown:
- `7f454c46` — ELF magic number (`\x7fELF`)
- `02` — 64-bit (ELFCLASS64)
- `01` — Little-endian (ELFDATA2LSB)
- `01` — ELF version 1
- `00` — OS/ABI (masked out — any value accepted)
- `0000000000000000` — Padding (masked out)
- `0200` — ET_EXEC or ET_DYN (mask `fe` accepts both)
- `b700` — Architecture: EM_AARCH64 (0x00B7)

### Magic Bytes for x86_64 (needed on ARM hosts)

```
magic: 7f454c4602010100000000000000000002003e00
mask:  ffffffffffffff00fffffffffffffffffeffffff
```

The only difference: `3e00` = EM_X86_64 (0x003E) instead of `b700` = EM_AARCH64.

## Registration Flags

### F — Fix Binary (CRITICAL for Container Builds)

The `F` flag tells the kernel to open the interpreter binary at **registration time** and cache the file descriptor. Without it, the kernel resolves the interpreter path at **execution time**.

**Why F is critical for ISAR**: ISAR builds run inside containers (kas-container via podman/docker). Containers have their own filesystem namespace. Without `F`:
1. Container executes an ARM64 binary
2. Kernel looks up interpreter at `/nix/store/.../qemu-aarch64`
3. That path doesn't exist inside the container's mount namespace
4. Result: `No such file or directory`

With `F`:
1. Kernel already has an open file descriptor to the interpreter (from registration)
2. Container executes an ARM64 binary
3. Kernel uses the cached fd — no path resolution needed
4. QEMU runs correctly, regardless of container's filesystem

**Kernel requirement**: Linux >= 4.8 (all current targets meet this).

When `F` is set, the kernel also implicitly enables `O` (open-binary), which passes an open fd of the target binary to the interpreter. This is why `/proc/sys/fs/binfmt_misc/qemu-aarch64` shows flags `POCF` even when only `FPC` was specified during registration.

### P — Preserve argv[0]

Preserves the original `argv[0]` of the executed binary. Without `P`, the interpreter receives:
```
argv[0] = /path/to/qemu-aarch64
argv[1] = /path/to/binary
```

With `P`, the interpreter receives the original binary name as an additional argument, allowing QEMU to properly report the program name to the guest binary. This is generally recommended for QEMU user-mode.

### C — Credentials

Controls which binary's credentials (uid/gid, capabilities) are used for permission checks:
- **Without C**: Permissions based on the **interpreter** (QEMU binary)
- **With C**: Permissions based on the **target binary** being executed

This matters for setuid binaries inside chroots (e.g., `sudo`, `su`). For ISAR builds, `C` ensures that package postinst scripts that expect specific permissions work correctly.

### Recommended Flags for ISAR

Use `FPC` (or `FCP` — order doesn't matter):
```
:qemu-aarch64:M::...:<interpreter>:FPC
```

## Complete Registration Command

### x86_64 Host → ARM64 Target (most common)

```bash
# Get static QEMU binary path from nixpkgs
QEMU_STATIC=$(nix build --no-link --print-out-paths 'nixpkgs#pkgsStatic.qemu-user')/bin/qemu-aarch64

# Register with the kernel
sudo sh -c "echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${QEMU_STATIC}:FPC' > /proc/sys/fs/binfmt_misc/register"
```

### ARM64 Host → x86_64 Target (Apple Silicon → AMD V3000)

```bash
QEMU_STATIC=$(nix build --no-link --print-out-paths 'nixpkgs#pkgsStatic.qemu-user')/bin/qemu-x86_64

sudo sh -c "echo ':qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:${QEMU_STATIC}:FPC' > /proc/sys/fs/binfmt_misc/register"
```

## Failure Modes

### binfmt_misc Not Registered

**Symptom**: Build fails when ISAR attempts to run target-architecture binaries inside the chroot.

**Typical error messages**:
```
chroot: failed to run command '/bin/bash': Exec format error
```
```
dpkg: error processing package <name> (--configure):
 installed <name> package post-installation script subprocess returned error exit status 1
```
```
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

The root cause is `ENOEXEC` (errno 8) — the kernel doesn't know how to execute an ARM64 ELF binary on an x86_64 host.

**Where it fails in the ISAR build**: During `do_rootfs` (specifically `apt-get install` inside the target chroot), when dpkg runs postinst scripts for installed packages. The `debootstrap` phase may also fail if it needs to execute target-architecture binaries.

### F Flag Missing (Interpreter Not Found in Container)

**Symptom**: binfmt is registered on the host but builds fail inside containers.

```
/usr/bin/qemu-aarch64-static: No such file or directory
```

or simply:

```
Exec format error
```

This happens because without `F`, the kernel tries to resolve the interpreter path inside the container's mount namespace where the host's Nix store (or `/usr/bin`) isn't mounted.

**Fix**: Re-register with the `F` flag, or ensure the QEMU binary is bind-mounted into the container.

### binfmt_misc Not Mounted

**Symptom**: Registration command fails.

```
bash: /proc/sys/fs/binfmt_misc/register: No such file or directory
```

**Fix**:
```bash
sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
```

On NixOS, this is handled automatically by the binfmt module. On other systems, ensure the `binfmt_misc` filesystem is in `/etc/fstab` or mounted by a systemd unit.

### Registration Lost After Reboot

binfmt_misc registrations are not persistent by default — they live only in kernel memory. After reboot (or `wsl --shutdown` on WSL2), registrations must be re-applied.

**Solutions by platform**:
- **NixOS**: `boot.binfmt.emulatedSystems` creates a systemd service that re-registers on boot
- **Debian/Ubuntu**: `binfmt-support` package with persistent `/var/lib/binfmts/` entries
- **Manual**: Add registration to a boot script or systemd oneshot unit

## Platform-Specific Configuration

### NixOS (Bare Metal or EC2)

NixOS has built-in binfmt support. Add to your NixOS configuration:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

This handles everything:
- Installs static QEMU binaries from `pkgsStatic.qemu-user`
- Mounts `binfmt_misc` filesystem
- Registers all relevant binary formats with `FPC` flags
- Creates a systemd service for persistent registration across reboots

**Verification after applying config**:
```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
# Should show: enabled, interpreter path, flags: POCF
```

### NixOS-WSL (Windows Teammates)

WSL2 uses the Microsoft kernel, but binfmt_misc is compiled in (`CONFIG_BINFMT_MISC=y`). The standard NixOS `boot.binfmt.emulatedSystems` option works on NixOS-WSL — `systemd-binfmt.service` starts at boot and registers correctly.

**NixOS configuration** (in nixcfg WSL module):
```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
boot.binfmt.preferStaticEmulators = true;
boot.binfmt.registrations.aarch64-linux.matchCredentials = true;
```

This produces a registration with flags `POCF` (all required flags), using a statically-linked QEMU from `pkgsStatic.qemu-user`.

**Validated** (2026-02-12): `systemd-binfmt.service` runs at WSL boot, registration survives session restarts. No manual registration needed.

**Fallback (manual, per-session)** — only needed if NixOS module is not yet applied:
```bash
QEMU_STATIC=$(nix build --no-link --print-out-paths 'nixpkgs#pkgsStatic.qemu-user')/bin/qemu-aarch64
sudo sh -c "echo ':qemu-aarch64:M::...:${QEMU_STATIC}:FPC' > /proc/sys/fs/binfmt_misc/register"
```

### Docker Desktop (macOS / Windows)

Docker Desktop runs a LinuxKit-based VM that includes `binfmt-fixup`, which pre-registers QEMU emulators for common architectures (aarch64, arm, riscv64, s390x, ppc64le, mips64le, mips64).

**This typically works out of the box** for kas-container builds via Docker Desktop. No additional configuration should be needed.

**Verification**:
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
# Or check directly:
docker run --rm alpine ls /proc/sys/fs/binfmt_misc/
```

**Caveat**: Docker Desktop's binfmt registrations may not use the `F` flag. If kas-container builds fail with "Exec format error" despite registrations being present, reset with:
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

### Podman on macOS (Apple Silicon)

Podman on macOS runs a Fedora CoreOS VM via `podman machine`. This VM may or may not have binfmt pre-configured for x86_64 emulation.

**For ARM64 Mac building x86_64 targets (AMD V3000)**:
- The podman machine VM needs `qemu-x86_64` registered via binfmt_misc
- Fedora CoreOS may include `qemu-user-static` and `binfmt-support` packages

**Verification**:
```bash
podman machine ssh cat /proc/sys/fs/binfmt_misc/qemu-x86_64
```

**If not configured**: See Plan 025 Task 3 for validation and setup steps.

### Generic Linux (Ubuntu, Fedora, etc.)

Install QEMU user-mode static and the binfmt support package:

```bash
# Debian/Ubuntu
sudo apt-get install qemu-user-static binfmt-support

# Fedora
sudo dnf install qemu-user-static
```

These packages register binfmt entries automatically and persist across reboots.

**Note**: Some distributions register without the `F` flag. Check and re-register if needed for container builds:
```bash
# Check current flags
cat /proc/sys/fs/binfmt_misc/qemu-aarch64 | head -3

# If flags don't include F, re-register
sudo sh -c 'echo -1 > /proc/sys/fs/binfmt_misc/qemu-aarch64'  # Remove old
# Then register with F flag (see Complete Registration Command above)
```

## Build Environment Matrix

| Environment | Host Arch | Cross Target | binfmt Needed | How Provisioned |
|-------------|-----------|-------------|---------------|-----------------|
| NixOS-WSL (Tim) | x86_64 | aarch64 | `qemu-aarch64` | NixOS module (Plan 025 T2) |
| NixOS-WSL (team) | x86_64 | aarch64 | `qemu-aarch64` | NixOS module (distributed) |
| macOS Docker (team) | aarch64 | x86_64 | `qemu-x86_64` | Docker Desktop built-in |
| macOS Podman (team) | aarch64 | x86_64 | `qemu-x86_64` | Needs validation (Plan 025 T3) |
| EC2 x86_64 runner | x86_64 | aarch64 | `qemu-aarch64` | NixOS runner config |

## References

- [Linux kernel binfmt_misc documentation](https://docs.kernel.org/admin-guide/binfmt-misc.html)
- [multiarch/qemu-user-static](https://github.com/multiarch/qemu-user-static) — Docker image for resetting binfmt registrations
- [kas Issue #19](https://github.com/siemens/kas/issues/19) — kas-container binfmt path mismatch
- [Debian Bug #868030](https://bugs.debian.org/868030) — Request for F flag in qemu-user-static binfmt entries
- `docs/isar-cross-compilation-validation.md` — Cross-compilation validation results
- `.claude/user-plans/025-cross-arch-build-environment.md` — Full plan with remaining tasks
