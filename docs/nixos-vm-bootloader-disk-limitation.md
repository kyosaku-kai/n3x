# NixOS VM Test Bootloader Disk Size Limitation

**Status**: RESOLVED (nixpkgs fork with `virtualisation.bootDiskAdditionalSpace`)
**Discovered**: 2026-02-01 (Plan 019 Task B2)
**Affects**: NixOS test VMs using `useBootLoader = true` with disk-intensive workloads

## Summary

NixOS test VMs cannot use full bootloader boot (systemd-boot or GRUB via UEFI) when the application requires significant runtime disk space (e.g., k3s, databases, container runtimes). The root filesystem partition is sized at build time to fit only the NixOS closure, with no extra space for runtime data.

## Root Cause

When `virtualisation.useBootLoader = true` is enabled, the disk image creation in `qemu-vm.nix` uses **hardcoded parameters**:

```nix
# nixpkgs/nixos/modules/virtualisation/qemu-vm.nix
diskSize = "auto";        # Size the disk to fit only the NixOS closure
additionalSpace = "0M";   # Provide NO extra space for runtime data
```

The `make-disk-image.nix` function supports both `diskSize` and `additionalSpace` parameters, but the `systemImage` definition ignores the existing `virtualisation.diskSize` option entirely. With 0M additional space, images are ~3GB — just enough for the closure.

At runtime, QEMU creates a COW overlay, so `virtualisation.diskSize = 50GB` only affects the overlay file size — the **partition table** still defines a ~3GB root partition. `boot.growPartition` cannot help because `growpart` sees no additional disk space beyond the partition.

## Symptoms

```
# k3s fails during startup:
write /var/lib/rancher/k3s/server/db/etcd/member/snap/db: no space left on device
```

## Impact on n3x

k3s requires ~5-10GB for etcd, containerd images, and runtime state. The ~3GB partition fills immediately during k3s initialization. NixOS tests use direct kernel boot (`useBootLoader = false`), which bypasses this and respects `diskSize`. ISAR tests are unaffected (image sizing controlled via WKS files).

## Resolution: nixpkgs Fork

n3x uses a nixpkgs fork (`timblaktu/nixpkgs/vm-bootloader-disk-size`) that adds:

```nix
virtualisation.bootDiskAdditionalSpace = mkOption {
  type = types.str;
  default = "512M";
  description = "Additional disk space for bootloader-enabled VMs.";
};
```

This passes through to `make-disk-image.nix`'s existing `additionalSpace` parameter.

**TODO**: Submit upstream PR to nixpkgs, then drop fork.

## Upstream Status

No existing nixpkgs issue or PR directly addresses this. Related:
- **Issue #200810** — VMs hanging with `useBootLoader = true` (different symptom, possibly same cause)
- **Issue #324817** — Meta-issue on unified image builders (long-term, stale)
- **PR #191665** by RaitoBezarius — Major refactor that preserved the hardcoded values

Key maintainers for `qemu-vm.nix`: RaitoBezarius, roberth, edolstra, infinisil. Recent maintainer activity suggests receptiveness to a fix — the change is additive, backward-compatible, and follows established patterns.

## Community Workarounds

- **Post-boot disk expansion**: systemd service to resize partition + filesystem (fragile)
- **Avoid `useBootLoader = true`**: Direct kernel boot works (current n3x approach for NixOS)
- **`emptyDiskImages` + separate mount**: Additional disk for `/var/lib/rancher` (changes architecture)

## References

- **qemu-vm.nix**: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/qemu-vm.nix
- **make-disk-image.nix**: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/make-disk-image.nix
