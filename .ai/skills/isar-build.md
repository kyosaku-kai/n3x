# ISAR Build Skill

This skill provides standardized procedures for ISAR/BitBake builds in the n3x project.

## Automated Build and Registration

The preferred way to build images and register them in the nix store:

```bash
# Build ALL variants, hash, register, update lib/isar/artifact-hashes.nix
nix run '.#isar-build-all'

# Build one variant
nix run '.#isar-build-all' -- --variant server-simple-server-1

# Build all variants for one machine
nix run '.#isar-build-all' -- --machine qemuamd64

# List all variants
nix run '.#isar-build-all' -- --list

# After building, stage and verify
git add lib/isar/artifact-hashes.nix
nix flake check --no-build

# Run all ISAR tests
nix build '.#checks.x86_64-linux.isar-all' -L
```

The build matrix is defined in `lib/isar/build-matrix.nix`. The only mutable state is `lib/isar/artifact-hashes.nix`.

## Pre-Flight Checklist

**ALWAYS run these checks before starting any ISAR build:**

```bash
# 1. Check for orphaned build processes
pgrep -a podman 2>/dev/null | grep -v "podman$" || echo "No podman builds"
pgrep -a bitbake 2>/dev/null || echo "No bitbake"
pgrep -a kas 2>/dev/null | grep -v "kas$" || echo "No kas"

# 2. Check for orphaned containers
sudo podman ps -a 2>/dev/null | grep -v "^CONTAINER" || echo "No containers"

# 3. Verify WSL mounts (if on WSL)
ls /mnt/c/Windows 2>/dev/null && echo "✓ /mnt/c mounted" || echo "✗ /mnt/c NOT mounted - run: nix run '.#wsl-remount'"

# 4. Verify shared cache exists
ls ~/.cache/yocto/downloads ~/.cache/yocto/sstate 2>/dev/null && echo "✓ Cache ready" || echo "✗ Cache missing - will be created on first build"
```

## Build Procedure

### Standard Build Commands

```bash
# Enter ISAR shell
nix develop .#debian

# Navigate to backend
cd backends/debian

# Build image (combine overlays with colons)
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/network/simple.yml
```

### Build Specific Recipes (Debugging)

```bash
# Build single package
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake systemd-networkd-config"

# Clean and rebuild
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake -c cleanall systemd-networkd-config"
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake systemd-networkd-config"

# Force rebuild ignoring sstate
kas-build kas/base.yml:kas/machine/qemu-amd64.yml --cmd "bitbake -c cleansstate systemd-networkd-config"
```

### Container Image Version

The build requires `kas-isar` image (not plain `kas`):

```bash
# Verify/pull correct image
podman pull ghcr.io/siemens/kas/kas-isar:5.1

# If using wrong image, export correct one (use KAS_CONTAINER_IMAGE for full path)
export KAS_CONTAINER_IMAGE="ghcr.io/siemens/kas/kas-isar:5.1"
```

## Process Termination Protocol

**CRITICAL: Never use SIGKILL (-9) without trying graceful termination first!**

The `kas-build` wrapper has trap handlers that remount WSL filesystems. SIGKILL bypasses these handlers.

### Signal Priority (in order):

1. **SIGTERM (15)** - Preferred. Allows cleanup.
   ```bash
   kill -TERM <pid>
   sleep 5
   ```

2. **SIGINT (2)** - Ctrl+C equivalent
   ```bash
   kill -INT <pid>
   sleep 3
   ```

3. **SIGQUIT (3)** - Core dump, still trappable
   ```bash
   kill -QUIT <pid>
   sleep 3
   ```

4. **SIGKILL (9)** - **LAST RESORT ONLY**
   ```bash
   # Only if process is truly stuck
   kill -9 <pid>
   # Then immediately recover mounts:
   nix run '.#wsl-remount'
   ```

### Finding Build Process PIDs

```bash
# Find kas-build wrapper
pgrep -f kas-build

# Find bitbake inside container
sudo podman exec -it $(sudo podman ps -q) pgrep bitbake
```

## Recovery Procedures

### Mount Recovery (after SIGKILL)

```bash
# Try automatic remount
nix run '.#wsl-remount'

# Verify
ls /mnt/c/Windows

# If still broken, from PowerShell:
wsl --shutdown
# Then restart WSL
```

### Container Cleanup

```bash
# List all containers
sudo podman ps -a

# Remove specific container
sudo podman rm -f <container_id>

# Remove all containers
sudo podman rm -f $(sudo podman ps -aq)

# If containers won't delete, check for volume mounts
sudo podman volume ls
sudo podman volume prune
```

### Build Directory Cleanup

```bash
cd backends/debian

# Remove schroot overlay leftovers (requires root due to chroot)
sudo rm -rf build/tmp/schroot-overlay/*/upper/tmp/*.wic/

# Reset bitbake state (rarely needed)
rm -rf build/tmp/stamps/
rm -rf build/cache/

# Full clean (loses all cached work - avoid if possible)
# rm -rf build/
```

## Monitoring Builds

### Check Progress

```bash
# Watch build logs
tail -f backends/debian/build/tmp/log/cooker/*/console-latest.log

# Check for output images
ls -la backends/debian/build/tmp/deploy/images/

# Watch package builds
ls backends/debian/build/tmp/work/*/
```

### Expected Build Times

| Build Type | Time (incremental) | Time (clean) |
|------------|-------------------|--------------|
| Single recipe | 1-3 min | 2-5 min |
| Full image | 5-10 min | 20-40 min |
| Jetson image | 10-15 min | 30-60 min |

Note: ISAR/Debian builds are faster than Yocto because they use pre-built .deb packages.

## Common Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `bwrap: not found` | Wrong container image | Use `kas-isar:5.1` not `kas:latest` |
| Build hangs at ~96% | sgdisk sync() on 9p | Ensure using `kas-build` wrapper |
| `/mnt/c` empty | SIGKILL broke mounts | Run `nix run '.#wsl-remount'` |
| `Permission denied` | Root-owned files | Use `sudo` for cleanup |
| sstate not reused | Changed recipe | Expected - sstate checksums recipe |
| `dpkg error` | Corrupted schroot | Clean schroot: `sudo rm -rf build/tmp/schroot-*/` |

## Stale Sstate Troubleshooting

**CRITICAL: NEVER use `rm -rf` on sstate cache directories. Always use BitBake's built-in commands.**

BitBake tracks recipe changes via checksums and rebuilds what's necessary. Manual cache deletion:
- Wastes time (forces unnecessary rebuilds)
- Can leave the cache in an inconsistent state
- Bypasses BitBake's dependency tracking

### When to Invalidate Sstate

Use `bitbake -c cleansstate` when:
- Build fails with "file not found" errors for files that should be generated
- Recipe changes aren't being picked up after code modifications
- Build output doesn't reflect recent changes to recipes

### Invalidating Recipe Sstate (Proper Method)

```bash
# Enter ISAR shell first
nix develop .#debian
cd backends/debian

# For package recipes (e.g., systemd-networkd-config)
kas-container shell kas/base.yml:kas/machine/qemu-amd64.yml -c \
  "bitbake -c cleansstate systemd-networkd-config"

# For image recipes (e.g., n3x-image-server)
# Note: Use the FULL kas config including overlays that define the image
kas-container shell kas/base.yml:kas/machine/qemu-amd64.yml:kas/test-k3s-overlay.yml:kas/network/simple.yml -c \
  "bitbake -c cleansstate n3x-image-server"

# Then rebuild normally
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/test-k3s-overlay.yml:kas/network/simple.yml
```

### BitBake Clean Task Hierarchy

| Task | Effect | When to Use |
|------|--------|-------------|
| `cleanall` | Removes build dir + downloads + sstate | Almost never - too aggressive |
| `cleansstate` | Removes sstate cache entries only | **Preferred** - forces rebuild from cached downloads |
| `clean` | Removes build directory only | Rarely needed |

### Example: Missing File Errors

If build fails with errors like:
```
FileNotFoundError: [Errno 2] No such file or directory: '.../debian-configscript.sh'
```

This typically means stale sstate is serving fetch/unpack results. Fix:

```bash
# Invalidate the specific image recipe's sstate
kas-container shell <full-kas-config> -c "bitbake -c cleansstate <image-recipe>"

# Rebuild
kas-build <full-kas-config>
```

## Integration with Claude Sessions

When working on ISAR builds across Claude sessions:

1. **Before starting**: Run pre-flight checklist
2. **During build**: Monitor logs, don't just wait
3. **If interrupted**: Document build state in plan file
4. **Before ending session**: Ensure no orphaned processes
5. **Next session**: Check for stale containers/processes before new builds
