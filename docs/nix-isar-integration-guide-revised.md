# Nix and ISAR Integration Guide

> **Note**: This was a pre-implementation design proposal. The actual architecture
> diverged significantly. For accurate documentation, see:
>
> - **[Debian Backend README](../backends/debian/README.md)** — Build architecture, overlays, artifact workflow
> - **[ADR 001: ISAR Artifact Integration](adr/001-isar-artifact-integration-architecture.md)** — Architecture decision
> - **[K3s Image Contract](K3S-IMAGE-CONTRACT.md)** — What images must provide

## What Was Proposed vs What Was Built

| Aspect | Proposed (this doc) | Actual |
|--------|-------------------|--------|
| Artifact model | `fetchurl` from HTTP build server | `requireFile` with local `.wic` files |
| Artifact granularity | Separate rootfs, kernel, initramfs, DTB | Whole `.wic` disk images |
| k3s config | YAML config generation (`nix/k3s/`) | CLI flag generation (`lib/k3s/mk-k3s-flags.nix`) |
| Deployment | Custom SSH scripts (`nix/deploy/`) | nixos-anywhere, NixOS test driver |
| Directory structure | `nix/`, `isar/`, `k8s/` at root | `backends/debian/`, `lib/`, `tests/` |
| Dev shell | `buildFHSUserEnvBubblewrap` | `kas-container` inside Nix devshell |
| Multi-arch | `crossMatrix` in flake.nix | kas machine overlays + QEMU binfmt |

The core insight — treating ISAR artifacts as fixed inputs to Nix — was adopted.
The implementation details diverged because kas overlays proved more natural for
ISAR configuration than Nix-native artifact composition.
