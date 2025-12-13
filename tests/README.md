# n3x Testing Framework

This directory contains the testing infrastructure for validating the n3x k3s cluster configuration.

## Overview

The testing framework uses NixOS `nixosTest` for automated integration tests. Each test boots real VMs, configures services, and verifies functionality automatically.

**Key Design Decision**: Tests use nixosTest multi-node approach where each "node" IS a k3s cluster node - no nested virtualization required. This works on all platforms (WSL2, Darwin, Cloud).

## Quick Start

```bash
# Run all flake checks (includes formatting and all tests)
nix flake check

# Run a specific k3s test
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
nix build '.#checks.x86_64-linux.k3s-storage' --print-build-logs
nix build '.#checks.x86_64-linux.k3s-network' --print-build-logs
nix build '.#checks.x86_64-linux.k3s-network-constraints' --print-build-logs

# Interactive debugging (opens Python REPL for test control)
nix build '.#checks.x86_64-linux.k3s-cluster-formation.driverInteractive'
./result/bin/nixos-test-driver
```

## Available Tests

### Primary Tests (Phase 4A - nixosTest Multi-Node)

These tests use nixosTest nodes directly as k3s cluster nodes. They work on all platforms.

| Test | Description | Run Command |
|------|-------------|-------------|
| `k3s-cluster-formation` | 2 servers + 1 agent cluster formation, node joining, workload deployment | `nix build '.#checks.x86_64-linux.k3s-cluster-formation'` |
| `k3s-storage` | Storage prerequisites, local-path PVC provisioning, StatefulSet volumes | `nix build '.#checks.x86_64-linux.k3s-storage'` |
| `k3s-network` | CoreDNS, flannel VXLAN, service discovery, pod network connectivity | `nix build '.#checks.x86_64-linux.k3s-network'` |
| `k3s-network-constraints` | Cluster behavior under degraded network (latency, loss, bandwidth limits) | `nix build '.#checks.x86_64-linux.k3s-network-constraints'` |

### Emulation Tests (vsim - Nested Virtualization)

These tests use nested virtualization for complex scenarios. They require native Linux with KVM.

| Test | Description | Run Command |
|------|-------------|-------------|
| `emulation-vm-boots` | Outer VM with libvirtd, OVS, dnsmasq, inner VM definitions | `nix build '.#checks.x86_64-linux.emulation-vm-boots'` |
| `network-resilience` | TC profile infrastructure for network constraint scenarios | `nix build '.#checks.x86_64-linux.network-resilience'` |
| `vsim-k3s-cluster` | Full cluster formation with pre-installed inner VM images | `nix build '.#checks.x86_64-linux.vsim-k3s-cluster'` |

### Validation Checks

| Check | Description | Run Command |
|-------|-------------|-------------|
| `nixpkgs-fmt` | Nix code formatting validation | `nix build '.#checks.x86_64-linux.nixpkgs-fmt'` |
| `build-all` | Validates all configurations build | `nix build '.#checks.x86_64-linux.build-all'` |

## Platform Compatibility

### Platform Support Matrix

| Platform | nixosTest Multi-Node | vsim (Nested Virt) | Notes |
|----------|---------------------|-------------------|-------|
| Native Linux | YES | YES | Full support |
| WSL2 (Windows 11) | YES | NO | Hyper-V limits to 2 nesting levels |
| Darwin (macOS) | YES* | NO | Requires Lima/UTM VM host |
| AWS/Cloud | YES | Varies | Requires KVM-enabled instances |

*Requires running inside a Linux VM (Lima or UTM)

### WSL2 (Windows 11)

WSL2 works with nixosTest multi-node tests out of the box:

```bash
# Verify KVM is available
ls -la /dev/kvm

# Run tests
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
```

**Limitation**: Triple-nested virtualization (vsim tests) does NOT work on WSL2 due to Hyper-V Enlightened VMCS limiting virtualization to 2 levels. See `docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md`.

### Darwin (macOS arm64/x86_64)

macOS requires a Linux VM to run nixosTest. Options:

#### Option 1: Lima (Recommended for arm64)

```bash
# Install Lima
brew install lima

# Create NixOS VM with KVM support
lima create --arch=aarch64 --vm-type=vz nixos.yaml

# Shell into Lima VM
lima

# Inside Lima VM, run tests
cd /path/to/n3x
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
```

Example `nixos.yaml` for Lima:
```yaml
arch: aarch64
vmType: vz
rosetta:
  enabled: true
images:
- location: "https://hydra.nixos.org/build/XXXXX/download/1/nixos-minimal-YY.YY-aarch64-linux.iso"
  arch: aarch64
mounts:
- location: "~"
  writable: true
```

#### Option 2: UTM

1. Download NixOS ARM64 ISO from hydra.nixos.org
2. Create new VM in UTM with virtualization enabled
3. Install NixOS, enable nix flakes
4. Clone n3x and run tests

#### Cross-Compilation Note

For arm64 Macs testing x86_64 configurations:
- Native arm64 tests work directly
- x86_64 tests require Rosetta 2 or cross-compilation setup
- Consider using `aarch64-linux` checks when available

### AWS/Cloud

For cloud CI/CD, use instances with KVM support:

#### AWS
- Use `.metal` instances (e.g., `c5.metal`, `m5.metal`) for bare-metal KVM
- Or use Nitro instances with `/dev/kvm` access (e.g., `c5.xlarge` with nested virt enabled)

#### NixOS AMI Setup

```bash
# Launch NixOS AMI (community AMIs available)
# Or build custom AMI with:
nix build '.#packages.x86_64-linux.amazon-image'

# After launch, ensure KVM module is loaded
sudo modprobe kvm_intel  # or kvm_amd
ls -la /dev/kvm
```

#### Self-Hosted GitLab Runner on NixOS

```nix
# configuration.nix for GitLab runner
{ config, pkgs, ... }:
{
  # Enable KVM
  boot.kernelModules = [ "kvm-intel" ];  # or kvm-amd

  # GitLab runner
  services.gitlab-runner = {
    enable = true;
    services.default = {
      registrationConfigFile = "/etc/gitlab-runner/token";
      executor = "shell";
      tagList = [ "kvm" "nix" ];
    };
  };

  # Nix configuration
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
  };

  # User permissions for KVM
  users.users.gitlab-runner.extraGroups = [ "kvm" ];
}
```

## CI/CD Integration

### GitLab CI

The repository includes `.gitlab-ci.yml` with:
- Validation stage: flake check, formatting
- Test stage: individual k3s tests (cluster-formation, storage, network, constraints)
- Integration stage: emulation tests, full test suite

Runner requirements:
- Nix with flakes enabled
- `/dev/kvm` access
- Tag: `kvm`

### GitHub Actions

```yaml
name: n3x Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v24
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - name: Run k3s cluster formation test
        run: nix build '.#checks.x86_64-linux.k3s-cluster-formation' --print-build-logs
```

Note: GitHub-hosted runners may not have KVM. Use self-hosted runners for full test suite.

## Directory Structure

```
tests/
├── integration/           # nixosTest integration tests
│   ├── k3s-cluster-formation.nix   # Primary cluster test
│   ├── k3s-storage.nix             # Storage infrastructure
│   ├── k3s-network.nix             # Network validation
│   ├── k3s-network-constraints.nix # Network degradation
│   ├── network-resilience.nix      # TC infrastructure (vsim)
│   └── vsim-k3s-cluster.nix        # Full vsim cluster
├── emulation/             # vsim nested virtualization environment
│   ├── embedded-system.nix         # Outer VM configuration
│   └── lib/                        # Helper functions
├── vms/                   # Manual VM configurations
│   ├── k3s-server-vm.nix
│   └── k3s-agent-vm.nix
├── run-vm-tests.sh        # Manual test runner script
└── README.md              # This file
```

## Interactive Debugging

For debugging test failures:

```bash
# Build interactive test driver
nix build '.#checks.x86_64-linux.k3s-cluster-formation.driverInteractive'
./result/bin/nixos-test-driver

# In Python REPL:
>>> start_all()
>>> server1.wait_for_unit("k3s")
>>> server1.succeed("kubectl get nodes")
>>> server1.shell_interact()  # Drop into shell
```

## Troubleshooting

### KVM Not Available

```bash
# Check if KVM module is loaded
lsmod | grep kvm

# Load KVM module
sudo modprobe kvm_intel  # Intel
sudo modprobe kvm_amd    # AMD

# Check permissions
ls -la /dev/kvm
# Add user to kvm group if needed
sudo usermod -aG kvm $USER
```

### Test Timeouts

Tests have default timeouts. For slow systems:

```bash
# Increase test timeout
NIX_TEST_TIMEOUT=3600 nix build '.#checks.x86_64-linux.k3s-cluster-formation'
```

### Out of Memory

Reduce parallel builds or increase VM memory:

```bash
# Build with less parallelism
nix build '.#checks.x86_64-linux.k3s-storage' --max-jobs 1
```

### WSL2 Nested Virtualization Failure

vsim tests (emulation-vm-boots, network-resilience) will fail on WSL2. Use nixosTest multi-node tests instead.

## Additional Resources

- [NixOS Testing Library](https://nixos.wiki/wiki/NixOS_Testing_library)
- [nix.dev Integration Testing](https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines.html)
- [Hyper-V Nested Virtualization Analysis](../docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md)
- [n3x Main README](../README.md)
