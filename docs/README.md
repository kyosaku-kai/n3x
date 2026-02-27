# n3x Documentation

Quick navigation to all project documentation. See also the [top-level README](../README.md) for project overview.

## Onboarding
- [Getting Started](GETTING-STARTED.md) — Choose your entry level (packages, BSP, tests, platform)
- [Build System Presentation Guide](BUILD-SYSTEM-PRESENTATION-GUIDE.md) — Visual overview for stakeholders

## Architecture & Design
- [System Architecture Diagram](diagrams/n3x-architecture.drawio.svg) ([description](diagrams/n3x-architecture.md))
- [Debian Backend Diagram](diagrams/n3x-debian-backend.drawio.svg) — kas overlay composition, build stack, artifact flow
- [NixOS Backend Diagram](diagrams/n3x-nixos-backend.drawio.svg) — module composition, deployment paths, flake inputs
- [CI Pipeline Diagram](diagrams/ci-pipeline.drawio.svg) — pipeline stages, runner infrastructure, cache topology
- [Build Caching Diagram](diagrams/build-caching.drawio.svg)
- [Build System Presentation](diagrams/n3x-build-system-presentation.drawio.svg)

### Architecture Decision Records
- [ADR 001: ISAR Artifact Integration](adr/001-isar-artifact-integration-architecture.md)
- [Nix Binary Cache Architecture](nix-binary-cache-architecture-decision.md)
- [ISAR Extraction Design](ISAR-EXTRACTION-DESIGN.md) — Superseded; see [extraction manifest](n3x-extraction-manifest.md)

## Build System
- [Application Packages](../backends/debian/packages/README.md) — Debian package development interface
- [Debian Backend](../backends/debian/README.md) — Build architecture, overlays, quick start
- [NixOS Backend](../backends/nixos/README.md) — Host configurations, modules, deployment
- [BSP Development Guide](../backends/debian/BSP-GUIDE.md) — Board support packages
- [Nix + ISAR Integration](nix-isar-integration-guide-revised.md) — Historical proposal (see Debian Backend README for current)
- [Debian Package Governance](debian-package-governance-best-practices.md)
- [K3s Image Contract](K3S-IMAGE-CONTRACT.md) — What images must provide
- [Cross-Compilation Validation](isar-cross-compilation-validation.md)
- [binfmt Requirements](binfmt-requirements.md) — Cross-arch QEMU user-mode setup

## Testing
- [Test Framework](../tests/README.md) — Test catalog, layers, commands
- [Test Coverage Matrix](../tests/TEST-COVERAGE.md)
- [Test Library](../tests/lib/README.md) — Test builder internals
- [Network Schema](../tests/lib/NETWORK-SCHEMA.md) — Network profile data format
- [Emulation Utilities](../tests/emulation/README.md)
- [VLAN Testing Guide](VLAN-TESTING-GUIDE.md) — VLAN test infrastructure
- [DHCP Test Infrastructure](DHCP-TEST-INFRASTRUCTURE.md)
- [Debian L4 Test Architecture](ISAR-L4-TEST-ARCHITECTURE.md) — Multi-node cluster tests
- [SWUpdate Testing](swupdate-testing.md)

## Infrastructure & CI
- [Infrastructure Overview](../infra/README.md) — AWS provisioning + NixOS runner configs
- [AWS Runner Provisioning (Pulumi)](../infra/pulumi/README.md)
- [NixOS Runner Configuration](../infra/nixos-runner/README.md)
- [CI Privileged Build Requirements](isar-ci-privileged-build-requirements.md)
- [Air-Gapped Source Audit](oss-air-gapped-source-audit.md)

## Hardware & Deployment
- [Jetson Orin Nano Kernel Analysis](jetson-orin-nano-kernel6-analysis-revised.md)
- [Jetson Orin Nano Overview](jetson-orin-nano.md) — Platform and kernel overview
- [Jetson OTA Guide](jetson-orin-ota-guide-revised.md)
- [Deployment Checklist](PHASE-9-DEPLOYMENT-CHECKLIST.md)

## Shared Libraries
- [K3s Flag Generation](../lib/k3s/README.md)
- [Network Config Generation](../lib/network/README.md)

## Secrets & Security
- [SOPS/age Secrets Setup](SECRETS-SETUP.md)
- [Secrets Reference](../secrets/README.md)

## Kubernetes
- [Manifests Reference](../manifests/README.md)

## Platform Notes
- [Hyper-V Nested Virtualization](platform-notes-hyper-v-nested-virtualization.md) — Two-level nesting limit, architecture decision
- [NixOS VM Bootloader Disk Limitation](nixos-vm-bootloader-disk-limitation.md) — Upstream gap + nixpkgs fork resolution

## Extraction & Migration
- [n3x Extraction Manifest](n3x-extraction-manifest.md) — Tracks file extraction to downstream repo

## Reference & WIP
- [Mikrotik Setup Notes](wip-L1.0-mikrotik-setup.md) (WIP)
- [Infrastructure Survey](wip-L1.1-infrastructure-survey.md) (WIP)

## Archive
- [ISAR Interface Design Diagram](diagrams/archive/n3x-isar-interface-design.drawio.svg) — Historical
- [Sparse Checkout Workflow Diagram](diagrams/archive/n3x-sparse-checkout-workflow.drawio.svg) — Historical
- [Flow Notes](archive/n3x-flow-notes.md) — Debugging session notes
