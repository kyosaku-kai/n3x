# n3x + vsim Merge Analysis

**Date**: 2025-12-07
**Author**: Analysis of n3x and vsim projects for consolidation opportunities
**Purpose**: Identify overlap, complementary strengths, and optimal merge strategy

---

## Executive Summary

The **n3x** and **vsim** projects share a common goal: deploying k3s clusters on NixOS with heterogeneous hardware (x86_64 + ARM64). However, they approach this from different angles:

- **n3x**: Production-focused framework for bare-metal deployment with emphasis on modularity, secrets management, storage integration (Longhorn), and real hardware
- **vsim**: Development/testing-focused nested virtualization platform for emulating embedded systems with emphasis on network simulation, resource constraints, and rapid iteration

**Recommendation**: These projects are **highly complementary** and should be merged, with vsim becoming n3x's comprehensive VM testing and development environment, while n3x provides production-grade module implementations.

---

## Project Comparison Matrix

| Aspect | n3x | vsim | Best Approach |
|--------|-----|------|---------------|
| **Primary Goal** | Production k3s on bare metal | Development/testing emulation | Combine both |
| **Target Environment** | Real hardware (N100, Jetson) | Nested VMs (any host) | Both needed |
| **Maturity** | Complete implementation | Functional prototype | n3x more mature |
| **k3s Configuration** | Production-grade with HA, etcd, secrets | Basic, testing-focused | n3x superior |
| **Networking** | Bonding, VLANs, Multus CNI | OVS bridge, QoS, tc simulation | Complementary |
| **Storage** | Longhorn with storage network | Basic disk provisioning | n3x superior |
| **Testing Framework** | NixOS integration tests (`nixosTest`) | Manual VM scripts + libvirt | n3x superior |
| **Secrets Management** | sops-nix with age encryption | Hardcoded/placeholder | n3x superior |
| **Hardware Support** | Modular (N100, Jetson modules) | Hardcoded VM definitions | n3x superior |
| **Architecture Support** | x86_64 + ARM64 via real hardware | x86_64 + ARM64 via QEMU TCG | vsim adds emulation |
| **Deployment Tooling** | nixos-anywhere, disko, deploy-rs | nixos-rebuild build-vm | n3x superior |
| **Resource Constraints** | None (uses real hardware) | Extensive (CPU, RAM, network QoS, tc) | vsim unique value |
| **Network Simulation** | None | OVS QoS, tc profiles, latency/loss | vsim unique value |
| **Documentation** | Comprehensive, production-focused | Detailed technical specs | Both good |

---

## Key Findings

### 1. k3s Deployment: n3x is Definitively Superior

**n3x advantages**:
- Modular role-based configuration (`k3s-server.nix`, `k3s-agent.nix`, `k3s-common.nix`)
- Production-grade flags (etcd tuning, API server limits, scheduler config)
- Proper secrets management via `tokenFile` (never inline secrets)
- Systemd hardening (resource limits, restart policies)
- Automated etcd defragmentation and backup timers
- Comprehensive kernel module loading (`iscsi_tcp`, `dm_crypt`, `overlay`)
- Proper sysctl tuning (`net.ipv4.ip_forward`, `fs.inotify.max_user_watches`)
- Shell aliases and helper functions for operations
- Log rotation configuration

**vsim shortcomings**:
- No k3s configuration at all (VMs have empty disks)
- Documentation shows manual k3s setup after VM deployment
- No secrets management
- No production hardening

**Best approach**: Use n3x's k3s modules entirely, drop vsim's manual approach.

---

### 2. VM Testing: n3x Has Better Framework, vsim Has Better Use Case

**n3x advantages**:
- Uses `pkgs.testers.runNixOSTest` (proper NixOS integration tests)
- Automated test scripts with assertions
- Integrated into `nix flake check` for CI/CD
- Interactive debugging via `.driverInteractive`
- Clean, reproducible test execution

**vsim advantages**:
- Nested virtualization with libvirt (more realistic than QEMU direct)
- Multi-node cluster running simultaneously
- ARM64 emulation via QEMU TCG (n3x only tests x86_64 VMs)
- Network topology simulation (OVS bridge connecting VMs)
- Resource constraint testing (CPU, RAM, network QoS)

**Best approach**:
1. Keep n3x's `nixosTest` framework as primary testing method
2. Integrate vsim's nested virtualization as an **additional testing mode**
3. Create new test category: `tests/emulation/` for vsim-style libvirt VMs
4. Use vsim for:
   - ARM64 emulation testing (when native ARM64 unavailable)
   - Network constraint/resilience testing
   - Multi-node cluster interaction testing
   - Interactive debugging of cluster issues

---

### 3. Networking: Highly Complementary

**n3x networking strengths**:
- Production network bonding (NIC aggregation)
- VLAN configuration for traffic separation
- Multus CNI for multiple network interfaces
- Storage network isolation for Longhorn
- Real hardware network testing

**vsim networking strengths**:
- Open vSwitch bridge simulation (mimics hardware switches)
- QoS/bandwidth limiting (simulates embedded constraints)
- Traffic control (tc) with profiles:
  - `constrained`: Low bandwidth, high latency
  - `lossy`: Packet loss, jitter
  - `default`: No constraints
- Network latency/delay simulation
- Realistic switch fabric emulation

**Best approach**:
- Keep n3x modules for production networking
- Integrate vsim's OVS + tc setup into test VMs
- Create network testing scenarios:
  - Test Longhorn under network constraints
  - Test k3s resilience with packet loss
  - Test multi-node cluster with latency
  - Validate bonding/failover behavior

---

### 4. Hardware Abstraction: n3x is Superior

**n3x approach** (lines in `/home/tim/src/n3x/flake.nix:51-76`):
```nix
mkSystem = { hostname, system ? systems.n100, modules ? [] }:
  nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs; };
    modules = [
      ./modules/common/base.nix
      ./modules/common/nix-settings.nix
      ./modules/common/networking.nix
      ./hosts/${hostname}/configuration.nix
      disko.nixosModules.disko
      sops-nix.nixosModules.sops
      { networking.hostName = hostname; }
    ] ++ modules;
  };
```

This allows:
- Easy per-host customization (`hosts/${hostname}/`)
- Hardware-specific modules (`modules/hardware/n100.nix`, `jetson-orin-nano.nix`)
- Role composition (`modules/roles/k3s-server.nix`, etc.)

**vsim approach** (lines in `/home/tim/src/n3x/vsim/embedded-system-emulator.nix:51-89`):
```nix
vmDefinitions = [
  { name = "chassis"; mac = "..."; arch = "aarch64"; memory = 1024; ... }
  { name = "compute"; mac = "..."; arch = "x86_64"; memory = 512; ... }
  { name = "storage"; mac = "..."; arch = "x86_64"; memory = 512; ... }
];
```

This is:
- Less modular (hardcoded list)
- Not reusable across configurations
- Difficult to extend with new node types

**Best approach**:
- Use n3x's modular system as the foundation
- Create generator functions for vsim-style nested VMs that consume n3x modules
- Example: `tests/emulation/mkInnerVM.nix` that takes n3x host configs and creates libvirt VMs

---

### 5. Secrets Management: n3x Has It, vsim Doesn't

**n3x implementation**:
- Uses sops-nix for encryption
- Age keys derived from SSH host keys
- Per-host key management
- K3s tokens stored in encrypted files
- Never exposes secrets in Nix store
- Proper `tokenFile` usage throughout

**vsim implementation**:
- Hardcoded placeholder: `k3sToken = "REPLACE_WITH_SECURE_TOKEN_BEFORE_USE";` (line 45)
- No encryption framework
- Not production-ready

**Best approach**: Apply n3x's secrets management to vsim VMs for realistic testing.

---

### 6. Storage: n3x is Production-Ready, vsim is Minimal

**n3x storage stack**:
- Disko for declarative disk partitioning
- Multiple partition layouts (standard, ZFS)
- Longhorn integration with storage network
- Kyverno for PATH patching (NixOS compatibility)
- iSCSI support via `open-iscsi`

**vsim storage**:
- Basic qcow2 disk creation
- Optional extra disk for storage node (line 127-133)
- No partition management
- No distributed storage

**Best approach**: Use n3x's storage modules in vsim test VMs to validate Longhorn deployment.

---

### 7. Testing Philosophy: Different but Complementary

**n3x testing approach** (automated):
```python
# From tests/integration/single-server.nix
server.start()
server.wait_for_unit("k3s.service")
server.wait_for_open_port(6443)
server.wait_until_succeeds("k3s kubectl get nodes | grep server")
server.succeed("k3s kubectl create deployment nginx-test --image=nginx:alpine")
```

Benefits:
- Fully automated
- CI/CD friendly
- Fast (direct QEMU, no libvirt overhead)
- Reproducible

Limitations:
- Single-node focus (multi-node requires complex network setup)
- No ARM64 emulation (only x86_64 tests)
- No resource constraint testing
- Limited network topology simulation

**vsim testing approach** (interactive):
```bash
virsh start chassis
virsh start compute
virsh start storage
virsh console chassis  # Manual interaction
/etc/tc-simulate-constraints.sh constrained
```

Benefits:
- Realistic multi-node cluster
- ARM64 emulation via QEMU TCG
- Network constraint simulation
- Interactive debugging
- Nested virtualization (closer to real hardware)

Limitations:
- Manual, not automated
- Slow (especially ARM64 TCG emulation: 10-20x slower)
- Not CI/CD friendly
- Requires nested virtualization support

**Best approach**: Use both!
- **Automated CI/CD**: n3x's `nixosTest` for fast validation
- **Manual exploration**: vsim for complex scenarios, ARM64 testing, network resilience
- **Integration**: Create automated tests that spawn vsim environments for specific scenarios

---

## Merge Strategy

### Phase 1: Consolidation (Recommended Approach)

#### 1.1 Directory Structure
```
n3x/
├── flake.nix                    # Main flake (unchanged)
├── modules/
│   ├── common/                  # From n3x (unchanged)
│   ├── hardware/                # From n3x (unchanged)
│   ├── roles/                   # From n3x (unchanged)
│   ├── network/                 # From n3x (unchanged)
│   ├── kubernetes/              # From n3x (unchanged)
│   └── security/                # From n3x (unchanged)
├── hosts/                       # From n3x (unchanged)
├── tests/
│   ├── integration/             # From n3x (nixosTest framework)
│   │   ├── single-server.nix
│   │   ├── agent-join.nix       # TODO
│   │   ├── multi-node.nix       # TODO
│   │   └── longhorn.nix         # TODO
│   ├── emulation/               # NEW: From vsim (nested virtualization)
│   │   ├── README.md            # Adapted from vsim/CLAUDE.md
│   │   ├── lib/
│   │   │   ├── mkInnerVM.nix    # Generator for libvirt VMs using n3x modules
│   │   │   ├── mkOVSBridge.nix  # OVS bridge configuration
│   │   │   └── mkTCProfiles.nix # Traffic control profiles
│   │   ├── embedded-system.nix  # Adapted from vsim/embedded-system-emulator.nix
│   │   └── network-resilience.nix # New test scenarios
│   ├── vms/                     # From n3x (QEMU direct VMs)
│   │   ├── default.nix
│   │   ├── k3s-server-vm.nix
│   │   ├── k3s-agent-vm.nix
│   │   └── multi-node-cluster.nix
│   ├── run-vm-tests.sh          # From n3x
│   └── README.md                # From n3x
├── docs/                        # From n3x
├── secrets/                     # From n3x
├── disko/                       # From n3x
├── manifests/                   # From n3x
└── scripts/                     # From n3x
```

#### 1.2 Integration Steps

**Step 1**: Create `tests/emulation/lib/mkInnerVM.nix`
```nix
# Generator function that creates libvirt VM XML from n3x host configs
{ pkgs, lib, ... }:

{ hostname        # Which n3x host config to use
, mac             # MAC address for DHCP
, ip              # Static IP assignment
, memory ? 2048   # RAM in MB
, vcpus ? 2       # vCPU count
, arch ? "x86_64" # "x86_64" or "aarch64"
, extraDiskSize ? 0 # Additional disk in GB
, qosProfile ? "default" # "default", "constrained", or "lossy"
}:

let
  # Import the n3x host configuration
  hostConfig = import ../../hosts/${hostname}/configuration.nix;

  # Build NixOS system for this VM
  system = nixpkgs.lib.nixosSystem {
    inherit arch;
    modules = [ hostConfig ];
  };

  # Generate libvirt XML (adapted from vsim's mkLibvirtXML)
  # ... implementation ...
in {
  inherit hostname mac ip memory vcpus arch;
  xml = mkLibvirtXML { /* ... */ };
  system = system;
}
```

**Step 2**: Adapt `vsim/embedded-system-emulator.nix` to use n3x modules
```nix
# tests/emulation/embedded-system.nix
{ config, pkgs, lib, modulesPath, ... }:

let
  # Import the VM generator
  mkInnerVM = import ./lib/mkInnerVM.nix { inherit pkgs lib; };

  # Define VMs using n3x host configurations
  innerVMs = [
    (mkInnerVM {
      hostname = "n100-1";  # Use n3x's n100-1 config
      mac = "52:54:00:12:34:01";
      ip = "192.168.100.10";
      memory = 4096;
      vcpus = 2;
      qosProfile = "constrained";
    })
    (mkInnerVM {
      hostname = "n100-2";  # Use n3x's n100-2 config
      mac = "52:54:00:12:34:02";
      ip = "192.168.100.11";
      memory = 2048;
      vcpus = 2;
    })
    (mkInnerVM {
      hostname = "n100-3";  # Use n3x's n100-3 config (storage node)
      mac = "52:54:00:12:34:03";
      ip = "192.168.100.12";
      memory = 2048;
      vcpus = 2;
      extraDiskSize = 10;
    })
  ];

  # Keep vsim's OVS bridge, dnsmasq, tc setup
  # ... (from vsim's configuration) ...
in {
  # Outer VM configuration (from vsim)
  # Inner VMs now use n3x's production modules
  # ...
}
```

**Step 3**: Create automated emulation tests
```nix
# tests/integration/emulation-cluster.nix
{ pkgs, lib, ... }:

# This test spawns the nested emulation environment and validates it
pkgs.testers.runNixOSTest {
  name = "emulation-cluster";

  nodes = {
    emulator = { config, pkgs, modulesPath, ... }: {
      imports = [ ../emulation/embedded-system.nix ];
    };
  };

  testScript = ''
    emulator.start()
    emulator.wait_for_unit("setup-inner-vms.service")

    # Start VMs
    emulator.succeed("virsh start chassis")
    emulator.succeed("virsh start compute")
    emulator.succeed("virsh start storage")

    # Wait for cluster to form
    emulator.wait_until_succeeds("ping -c 1 192.168.100.10", timeout=300)

    # Verify k3s cluster (once VMs have booted and k3s started)
    # ... additional assertions ...
  '';
}
```

**Step 4**: Update `flake.nix` to expose emulation tests
```nix
# In outputs.checks
checks.${systems.n100} = {
  # Existing tests
  k3s-single-server = pkgs.callPackage ./tests/integration/single-server.nix { };

  # NEW: Emulation tests
  emulation-cluster = pkgs.callPackage ./tests/integration/emulation-cluster.nix { };

  # NEW: Network resilience test
  network-resilience = pkgs.callPackage ./tests/emulation/network-resilience.nix { };
};

# In outputs.packages (for interactive use)
packages.${systems.n100} = {
  # Existing packages
  iso = ...;
  vm = ...;

  # NEW: Emulation environment
  emulation-vm = (import ./tests/emulation/embedded-system.nix {
    inherit pkgs lib modulesPath;
  }).config.system.build.vm;
};
```

#### 1.3 Documentation Updates

**Update n3x/README.md**:
- Add section on emulation testing
- Explain when to use `nixosTest` vs emulation environment
- Link to vsim documentation for network simulation features

**Create tests/emulation/README.md**:
- Adapt from vsim/CLAUDE.md and vsim/embedded-system-emulator.md
- Explain nested virtualization setup
- Document network constraint profiles
- Provide examples of emulation use cases

**Update tests/README.md**:
- Add emulation testing category
- Explain test hierarchy: unit (nixosTest) → integration (nixosTest multi-node) → emulation (libvirt nested)

---

### Phase 2: Feature Integration

#### 2.1 Network Simulation Module

Create `modules/testing/network-simulation.nix`:
```nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.testing.networkSimulation;
in {
  options.testing.networkSimulation = {
    enable = mkEnableOption "network constraint simulation for testing";

    profile = mkOption {
      type = types.enum [ "default" "constrained" "lossy" "custom" ];
      default = "default";
      description = "Network constraint profile to apply";
    };

    customTc = mkOption {
      type = types.lines;
      default = "";
      description = "Custom tc commands for network shaping";
    };
  };

  config = mkIf cfg.enable {
    # Install tc profiles script (from vsim)
    environment.etc."tc-simulate-constraints.sh" = {
      source = ../tests/emulation/lib/tc-profiles.sh;
      mode = "0755";
    };

    # Apply profile at boot
    systemd.services.network-simulation = {
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        /etc/tc-simulate-constraints.sh ${cfg.profile}
      '';
    };
  };
}
```

#### 2.2 ARM64 Emulation Testing

Create automated tests that run ARM64 nodes via QEMU TCG:
```nix
# tests/emulation/arm64-cluster.nix
# Tests k3s cluster with ARM64 server + x86_64 agents
# This validates cross-architecture deployment scenarios
```

#### 2.3 Resilience Testing Suite

Create `tests/emulation/resilience/`:
```
resilience/
├── network-partition.nix  # Test cluster behavior with network split
├── high-latency.nix       # Test under high latency (satellite link simulation)
├── packet-loss.nix        # Test with 1-5% packet loss
├── bandwidth-limited.nix  # Test with 10Mbps constraints
└── combined-stress.nix    # All constraints simultaneously
```

---

## Specific Technical Recommendations

### 1. k3s Configuration
- **Use**: n3x modules entirely (`modules/roles/k3s-*.nix`)
- **Action**: Apply these to vsim VMs instead of empty disks
- **Benefit**: VMs boot with production k3s config, ready for testing

### 2. Secrets in Emulation
- **Use**: n3x's sops-nix framework
- **Action**: Create test-specific encrypted secrets in `tests/emulation/secrets/`
- **Benefit**: Tests validate secrets management workflow

### 3. Disk Partitioning
- **Use**: n3x's disko configurations
- **Action**: Apply to vsim VM disk images during creation
- **Benefit**: Tests validate disk layouts before bare-metal deployment

### 4. Network Simulation
- **Use**: vsim's OVS + tc setup
- **Action**: Make it optional via module (`testing.networkSimulation.enable`)
- **Benefit**: Realistic network testing without impacting production configs

### 5. Testing Workflow
```bash
# Fast automated validation (CI/CD)
nix flake check

# Interactive multi-node testing
nix build .#packages.x86_64-linux.emulation-vm
./result/bin/run-*-vm

# Inside emulation VM:
virsh start chassis compute storage
/etc/tc-simulate-constraints.sh lossy
kubectl get nodes  # Test cluster under constraints
```

### 6. ARM64 Strategy
- **Development**: Use vsim's QEMU TCG emulation
- **CI/CD**: Use native ARM64 runners (GitHub Actions: `runs-on: ubuntu-latest-arm`)
- **Production**: Deploy to real ARM64 hardware (Jetson)

---

## Migration Checklist

### Files to Move from vsim to n3x

- [x] `vsim/embedded-system-emulator.nix` → `tests/emulation/embedded-system.nix` (adapted)
- [x] `vsim/embedded-system-emulator.md` → `tests/emulation/README.md` (adapted)
- [x] vsim's tc script → `tests/emulation/lib/tc-profiles.sh`
- [x] vsim's libvirt XML generation → `tests/emulation/lib/mkInnerVM.nix` (refactored)
- [x] vsim's OVS setup → `tests/emulation/lib/mkOVSBridge.nix` (extracted)

### Files to Keep from n3x (No Changes Needed)

- [x] All `modules/*` (production-grade)
- [x] All `hosts/*` (host configurations)
- [x] All `secrets/*` (encrypted secrets)
- [x] All `disko/*` (disk layouts)
- [x] `tests/integration/*` (nixosTest framework)
- [x] `tests/vms/*` (QEMU direct VMs)
- [x] `flake.nix` (minimal changes needed)

### Files to Deprecate from vsim

- [ ] `vsim/CLAUDE.md` (content merged into n3x docs)
- [ ] `vsim/embedded-system-emulator.nix` (becomes `tests/emulation/embedded-system.nix`)
- [ ] Standalone vsim flake (integrated into n3x)

### New Files to Create

- [ ] `tests/emulation/lib/mkInnerVM.nix` (VM generator using n3x configs)
- [ ] `tests/emulation/lib/mkOVSBridge.nix` (OVS bridge module)
- [ ] `tests/emulation/lib/mkTCProfiles.nix` (Traffic control profiles)
- [ ] `tests/emulation/README.md` (Emulation testing guide)
- [ ] `tests/integration/emulation-cluster.nix` (Automated emulation test)
- [ ] `modules/testing/network-simulation.nix` (Optional network constraints)
- [ ] `tests/emulation/resilience/*.nix` (Resilience test suite)

---

## Timeline Estimate

### Quick Win (1-2 days)
- Move vsim into `tests/emulation/` directory
- Update documentation to reference both testing approaches
- Create basic integration (manual use only)

### Full Integration (1 week)
- Implement `mkInnerVM.nix` generator
- Refactor embedded-system.nix to use n3x modules
- Create automated emulation tests
- Update flake.nix with new outputs
- Comprehensive documentation

### Production-Ready (2 weeks)
- Full resilience test suite
- CI/CD integration (where feasible)
- ARM64 emulation testing
- Performance benchmarking
- Migration guide for existing vsim users

---

## Risks and Mitigations

### Risk 1: ARM64 Emulation Too Slow for CI/CD
**Mitigation**:
- Use emulation tests only for manual validation
- Use native ARM64 GitHub runners when available
- Focus automated tests on x86_64 (fastest)

### Risk 2: Nested Virtualization Not Available on All Hosts
**Mitigation**:
- Make emulation tests optional (`nix build .#emulation-vm` vs `nix flake check`)
- Document nested virt requirements clearly
- Provide cloud VM images with nested virt pre-enabled

### Risk 3: Complexity Increase for New Users
**Mitigation**:
- Clear documentation hierarchy (simple → advanced)
- Separate quick-start guide (nixosTest only)
- Advanced guide for emulation testing
- Examples for common scenarios

---

## Conclusion

The n3x and vsim projects are **highly synergistic**:

1. **n3x provides**: Production-grade k3s modules, secrets management, storage integration, modular architecture, bare-metal deployment tooling

2. **vsim provides**: Nested virtualization testing, network simulation, resource constraints, ARM64 emulation, interactive debugging environment

3. **Together they enable**:
   - **Fast automated testing** (nixosTest) for CI/CD
   - **Realistic emulation** (libvirt nested VMs) for complex scenarios
   - **Network resilience validation** (tc profiles) before production deployment
   - **ARM64 development** (QEMU TCG) without physical ARM hardware
   - **Gradual deployment validation**: nixosTest → emulation → bare-metal

**Recommended Action**: Merge vsim into n3x as `tests/emulation/`, refactor to use n3x modules, maintain both testing approaches for different use cases.

This creates a **comprehensive k3s-on-NixOS framework** spanning development, testing, and production deployment.
