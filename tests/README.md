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
| `k3s-bond-failover` | Bond active-backup failover/failback while k3s remains operational | `nix build '.#checks.x86_64-linux.k3s-bond-failover'` |
| `k3s-vlan-negative` | Validates VLAN misconfiguration causes expected failures | `nix build '.#checks.x86_64-linux.k3s-vlan-negative'` |

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

### ARM64/aarch64 Validation (Jetson)

Build validation tests for Jetson (aarch64-linux) configurations. These ensure ARM64 configs build correctly without runtime testing.

| Check | Description | Run Command |
|-------|-------------|-------------|
| `jetson-1-build` | Builds jetson-1 NixOS system derivation | `nix build '.#checks.aarch64-linux.jetson-1-build'` |
| `jetson-2-build` | Builds jetson-2 NixOS system derivation | `nix build '.#checks.aarch64-linux.jetson-2-build'` |

**NOTE**: Building these checks requires an aarch64 builder:
- Native aarch64 hardware (Jetson, ARM server, Apple Silicon Mac with Lima)
- Remote aarch64 builder (see [Nix Remote Builders](https://nixos.wiki/wiki/Distributed_build))
- binfmt-misc emulation (very slow, not recommended for full builds)

```bash
# On x86_64 with configured aarch64 remote builder:
nix build '.#checks.aarch64-linux.jetson-1-build' --builders 'ssh://aarch64-builder'

# Verify config evaluates without building (no builder required):
nix eval '.#nixosConfigurations.jetson-1.config.system.build.toplevel' --no-build
```

## Network Profiles

The test framework supports multiple network configurations via **parameterized test builders**. This allows testing different network topologies without code duplication.

### Available Profiles

Located in `tests/lib/network-profiles/`:

| Profile | Description | Use Case | VLANs | Bonding |
|---------|-------------|----------|-------|---------|
| **simple** | Single flat network via eth1 | Baseline testing, CI/CD quick validation | No | No |
| **vlans** | 802.1Q VLAN tagging on eth1 trunk | VLAN validation before hardware deployment | Yes (100, 200) | No |
| **bonding-vlans** | Bonding + VLAN tagging | Full production parity testing | Yes (100, 200) | Yes |

### Network Profile Tests

Tests using parameterized builder (`tests/lib/mk-k3s-cluster-test.nix`):

```bash
# Simple profile (baseline)
nix build '.#checks.x86_64-linux.k3s-cluster-simple'

# VLAN tagging (production parity)
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'

# Bonding + VLANs (complete production simulation)
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'
```

### VLAN Configuration Details

The **vlans** and **bonding-vlans** profiles configure:

- **VLAN 200** (Cluster Network)
  - IP range: 192.168.200.0/24
  - Used by: k3s API, flannel VXLAN, cluster communication
  - Interface: `eth1.200` (vlans) or `bond0.200` (bonding-vlans)

- **VLAN 100** (Storage Network)
  - IP range: 192.168.100.0/24
  - Used by: Longhorn, iSCSI, storage replication
  - Interface: `eth1.100` (vlans) or `bond0.100` (bonding-vlans)

### Adding Custom Network Profiles

Create a new profile in `tests/lib/network-profiles/custom.nix`:

```nix
{ lib }:
{
  nodeIPs = { n100-1 = "..."; n100-2 = "..."; n100-3 = "..."; };
  serverApi = "https://...";
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  nodeConfig = nodeName: { config, pkgs, lib, ... }: {
    # Network configuration for each node
    networking.interfaces.eth1.ipv4.addresses = [ ... ];
  };

  k3sExtraFlags = nodeName: [
    "--node-ip=..."
    "--flannel-iface=eth1"
  ];
}
```

Then add to `flake.nix`:

```nix
k3s-cluster-custom = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
  inherit pkgs lib;
  networkProfile = "custom";
};
```

### Why Parameterized Tests?

**Benefits**:
- **No code duplication** - Test logic defined once, network configs separate
- **Easy extension** - Add new profiles without touching test code
- **Production parity** - VLAN tests match future hardware deployment
- **Maintainability** - Changes to test logic apply to all profiles

**Nix-Idiomatic Pattern**:
Uses module system composition instead of branching or code duplication.

### Specialized Tests

#### Bond Failover Test (`k3s-bond-failover`)

Tests that bonding active-backup mode correctly handles NIC failures while k3s remains operational.

**Test Scenarios**:
1. Verify initial bond state (eth1 as primary/active)
2. Simulate primary NIC failure (`ip link set eth1 down`)
3. Verify automatic failover to backup (eth2 becomes active)
4. Verify k3s API remains accessible during failover
5. Restore primary NIC (`ip link set eth1 up`)
6. Verify failback to primary (eth1 becomes active again with `PrimaryReselectPolicy=always`)
7. Verify all 3 nodes remain Ready throughout the cycle

**Configuration**:
- Uses `bonding-vlans` network profile
- Bond mode: `active-backup`
- miimon: 100ms, UpDelaySec/DownDelaySec: 200ms

```bash
nix build '.#checks.x86_64-linux.k3s-bond-failover'
```

#### VLAN Negative Test (`k3s-vlan-negative`)

Validates that VLAN misconfigurations cause expected failures. This is a "negative test" - it proves assertions work by expecting failure.

**Scenario**:
- n100-1: VLAN 200 (correct)
- n100-2: VLAN 201 (wrong)
- n100-3: VLAN 202 (wrong)

All nodes use the same IP range (192.168.200.x) but different VLAN tags.

**Expected Behavior**:
1. All nodes boot successfully
2. n100-1 initializes k3s and becomes Ready
3. n100-2 and n100-3 fail to join cluster (connection refused/timeout)
4. Test passes by verifying cluster formation fails as expected

**nixosTest Limitation Note**: In nixosTest's virtual network, VLAN tags are applied but may not enforce true L2 isolation (no switch enforcement). The test documents this and validates configuration correctness rather than traffic isolation.

```bash
nix build '.#checks.x86_64-linux.k3s-vlan-negative'
```

### Profile-Specific Assertions

The parameterized test builder (`mk-k3s-cluster-test.nix`) includes profile-aware assertions that verify network configuration correctness.

#### PHASE 2: Interface and IP Assertions

| Profile | Verified Interfaces | Verified IPs |
|---------|---------------------|--------------|
| `simple` | `eth1` | `192.168.1.x` |
| `vlans` | `eth1.200`, `eth1.100` | `192.168.200.x`, `192.168.100.x` |
| `bonding-vlans` | `bond0`, `bond0.200`, `bond0.100` | `192.168.200.x`, `192.168.100.x` |

#### PHASE 2.5: VLAN Tag Verification

For `vlans` and `bonding-vlans` profiles:
- Verifies `ip -d link show` contains `vlan id 200` for cluster VLAN
- Verifies `ip -d link show` contains `vlan id 100` for storage VLAN

#### PHASE 2.6: Storage Network Validation

For `vlans` and `bonding-vlans` profiles:
- Verifies each node has correct storage IP (192.168.100.1-3)
- Tests ping connectivity from each node to all other nodes on storage network

#### PHASE 2.7: Cross-VLAN Isolation Check

For `vlans` and `bonding-vlans` profiles (best-effort in nixosTest):
1. **ARP table inspection** - Verifies ARP entries learned on correct interfaces
2. **Routing table verification** - Asserts cluster network routes via `.200` interface, storage via `.100`
3. **IP cross-contamination check** - Verifies cluster VLAN has no storage IPs and vice versa

**Note**: True L2 isolation testing requires OVS emulation or physical hardware.

### Test Coverage Matrix

| Validation | simple | vlans | bonding-vlans | bond-failover | vlan-negative |
|------------|--------|-------|---------------|---------------|---------------|
| Interface exists | ✓ | ✓ | ✓ | ✓ | ✓ |
| IP assignment | ✓ | ✓ | ✓ | ✓ | ✓ |
| VLAN ID verification | - | ✓ | ✓ | ✓ | ✓ |
| Storage network ping | - | ✓ | ✓ | ✓ | - |
| Routing table segregation | - | ✓ | ✓ | ✓ | - |
| IP cross-contamination | - | ✓ | ✓ | ✓ | - |
| K3s cluster formation | ✓ | ✓ | ✓ | ✓ | partial |
| Bond failover/failback | - | - | - | ✓ | - |
| VLAN misconfiguration detection | - | - | - | - | ✓ |

## Platform Compatibility

### Platform Support Matrix

| Platform | nixosTest Multi-Node | vsim (Nested Virt) | aarch64 Build | Notes |
|----------|---------------------|-------------------|---------------|-------|
| Native Linux (x86_64) | YES | YES | Requires builder | Full support |
| Native Linux (aarch64) | YES | YES | YES | ARM servers, Jetson |
| WSL2 (Windows 11) | YES | NO | Requires builder | Hyper-V limits to 2 nesting levels |
| Darwin (macOS arm64) | YES* | NO | YES (native) | Requires Lima/UTM VM host |
| Darwin (macOS x86_64) | YES* | NO | Requires builder | Requires Lima/UTM VM host |
| AWS/Cloud | YES | Varies | Graviton instances | Requires KVM-enabled instances |

*Requires running inside a Linux VM (Lima or UTM)

#### aarch64 Builder Options

To build ARM64 (Jetson) configurations from x86_64 hosts:

1. **Remote aarch64 builder** (recommended for CI/CD):
   ```bash
   # Configure in /etc/nix/machines or nix.conf
   # Example: ssh://builder@aarch64-host x86_64-linux,aarch64-linux
   nix build '.#checks.aarch64-linux.jetson-1-build'
   ```

2. **Apple Silicon Mac with Lima** (cross-compile):
   ```bash
   # Lima runs native aarch64-linux, can serve as builder
   lima nix build '.#checks.aarch64-linux.jetson-1-build'
   ```

3. **AWS Graviton instance**:
   ```bash
   # Launch aarch64 NixOS AMI on Graviton
   # Run builds natively
   ```

4. **binfmt-misc emulation** (very slow, last resort):
   ```bash
   # Enable binfmt in NixOS configuration
   boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
   # Warning: Full system builds may take hours
   ```

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
├── integration/               # nixosTest integration tests
│   ├── k3s-cluster-formation.nix   # Primary cluster test
│   ├── k3s-storage.nix             # Storage infrastructure
│   ├── k3s-network.nix             # Network validation
│   ├── k3s-network-constraints.nix # Network degradation
│   ├── k3s-bond-failover.nix       # Bond failover/failback test
│   ├── k3s-vlan-negative.nix       # VLAN misconfiguration test
│   ├── network-resilience.nix      # TC infrastructure (vsim)
│   └── vsim-k3s-cluster.nix        # Full vsim cluster
├── lib/                       # Test library functions
│   ├── mk-k3s-cluster-test.nix     # Parameterized test builder
│   └── network-profiles/           # Network profile definitions
│       ├── simple.nix              # Single flat network
│       ├── vlans.nix               # 802.1Q VLAN tagging
│       ├── bonding-vlans.nix       # Bonding + VLANs
│       └── vlans-broken.nix        # Intentionally broken (negative test)
├── emulation/                 # vsim nested virtualization environment
│   ├── embedded-system.nix         # Outer VM configuration
│   └── lib/                        # Helper functions
├── vms/                       # Manual VM configurations
│   ├── k3s-server-vm.nix
│   └── k3s-agent-vm.nix
├── run-vm-tests.sh            # Manual test runner script
└── README.md                  # This file
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

### Bond Failover Test Failures

If `k3s-bond-failover` fails:

1. **"Expected eth1 as active slave"** - Check bond configuration:
   ```bash
   # In test driver
   n100_1.succeed("cat /proc/net/bonding/bond0")
   ```
   Verify `eth1` is listed as primary and active-backup mode is enabled.

2. **"Failover to eth2 did not occur"** - Check miimon timing:
   ```bash
   n100_1.succeed("cat /proc/net/bonding/bond0 | grep -i mii")
   ```
   The `DownDelaySec` (200ms) may need adjustment for slower systems.

3. **"k3s API inaccessible after failover"** - Cluster may need more time to stabilize. Check etcd health:
   ```bash
   n100_1.succeed("k3s kubectl get endpoints kubernetes")
   ```

### VLAN Negative Test Behavior

The `k3s-vlan-negative` test may pass even when nodes appear to communicate. This is expected in nixosTest:

- **nixosTest shares a virtual network bridge** - VLANs are tagged but not isolated at L2
- The test verifies configuration correctness (VLAN IDs are applied)
- For true isolation testing, use OVS emulation or physical hardware

### Profile-Specific Assertion Failures

If PHASE 2.x assertions fail:

1. **Missing interface** (e.g., "Missing eth1.200"):
   ```bash
   # Check systemd-networkd status
   n100_1.succeed("networkctl status")
   n100_1.succeed("journalctl -u systemd-networkd -n 50")
   ```

2. **Missing IP** (e.g., "Missing 192.168.200.x"):
   ```bash
   # Check if DHCP or static config applied
   n100_1.succeed("ip addr show")
   n100_1.succeed("networkctl status eth1.200")
   ```

3. **Routing table mismatch**:
   ```bash
   n100_1.succeed("ip route show")
   # Expected: 192.168.200.0/24 dev eth1.200 (or bond0.200)
   ```

### etcd Election Timing

K3s HA clusters use etcd which requires leader election. Timing variance is normal:

- Cluster formation typically takes 60-120 seconds
- Tests have generous timeouts (300s for node ready)
- If tests timeout, check etcd logs:
  ```bash
  n100_1.succeed("journalctl -u k3s -n 100 | grep -i etcd")
  ```

### Test Caching Behavior

`nix build` uses caching. Tests that previously passed may not re-execute:

| Indicator | Cached (not run) | Actually ran |
|-----------|------------------|--------------|
| Duration | 6-10 seconds | 2-15 minutes |
| VM boot logs | None | `systemd[1]: Initializing...` |
| Test commands | None | `must succeed:`, `wait_for` |

To force test re-execution:
```bash
# Force rebuild (ignores cache)
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild
```

## Additional Resources

- [NixOS Testing Library](https://nixos.wiki/wiki/NixOS_Testing_library)
- [nix.dev Integration Testing](https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines.html)
- [Hyper-V Nested Virtualization Analysis](../docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md)
- [n3x Main README](../README.md)
