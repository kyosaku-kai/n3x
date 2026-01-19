# CLAUDE.md - Project Memory and Rules

This file provides project-specific rules and task tracking for Claude Code when working with the n3x repository.

## Critical Rules

### Git Commit Practices

1. **ALWAYS commit relevant changes after making them** - This is a high priority rule. Stage and commit changes that are part of the long-term solution immediately after completing work.

2. **NEVER include AI/Claude attributions in commits**:
   - Do NOT add "Co-Authored-By: Claude" or "Generated with Claude"
   - Do NOT mention Anthropic, AI, or Claude in commit messages
   - Keep commit messages professional and attribution-free
   - Focus on describing WHAT changed and WHY, not who/what created it

3. **Do NOT commit temporary files** - Never stage or commit files created for temporary or short-term purposes.

### Shell Command Practices

4. **ALWAYS single-quote Nix derivation references** - When running `nix build`, `nix flake check`, or similar commands with derivation paths like `.#thing`, ALWAYS use single quotes: `nix build '.#thing'`. This prevents shell globbing issues in zsh and other shells.

## Project Status and Next Tasks

### Current Status
- **Phase**: Phase 6 ✅ VALIDATED (VLAN Infrastructure), Phase 7 Optional (CI Validation)
- **Repository State**: All 3 VLAN network profile tests passing on WSL2/Hyper-V
- **Branch**: `simint` (key commits: `080eeb3` HA fix, `f4dc6cc` bonding fix, `8e70f85` VLAN profiles)
- **Implementation**: ✅ Complete - 3 network profiles with parameterized test builder
- **Runtime Testing**: ✅ VALIDATED (2026-01-17)
  - `k3s-cluster-simple` - PASSED (flat network baseline)
  - `k3s-cluster-vlans` - PASSED (VLAN 200/100 tagging, nodes show 192.168.200.x IPs)
  - `k3s-cluster-bonding-vlans` - PASSED (bond0 + VLAN tagging)
- **Next Action**: Phase 8 (Secrets Preparation) or Phase 7 (CI) based on priority

### Completed Implementation Tasks

All core implementation tasks have been completed:

1. **Flake Structure Creation** ✅
   - Initialized flake.nix with proper inputs (nixpkgs, disko, sops-nix, nixos-anywhere, jetpack-nixos)
   - Created modular structure under modules/ directory
   - Set up hosts/ directory for per-node configurations (5 hosts: 3 N100, 2 Jetson)

2. **Hardware Modules** ✅
   - Created N100-specific hardware module with optimizations
   - Created Jetson Orin Nano module using jetpack-nixos
   - Configured kernel parameters and performance tuning

3. **Network Configuration** ✅
   - Implemented dual-IP bonding module
   - Configured Multus CNI NetworkAttachmentDefinition
   - Set up VLAN support for traffic separation
   - Created storage network configuration for k3s and Longhorn

4. **K3s Setup** ✅
   - Created server and agent role modules with secure variants
   - Configured token management with sops-nix
   - Implemented Kyverno PATH patching for Longhorn
   - Created common k3s configuration module

5. **Storage Configuration** ✅
   - Implemented disko partition layouts (standard and ZFS options)
   - Configured Longhorn module with storage network
   - Created k3s-storage integration module
   - Ready for PVC creation and replica management testing

6. **Secrets Management** ✅
   - Configured sops-nix integration
   - Created secrets module with age key support
   - Set up encryption for K3s tokens
   - Documented secrets workflow

7. **Testing Framework** ✅
   - Created comprehensive VM testing configurations
   - Configured test VMs for server, agent, and multi-node clusters
   - Implemented NixOS integration tests using `nixosTest` framework
   - Added automated test runner script for manual testing
   - Integrated tests into `checks` output for CI/CD
   - Documented testing procedures

### Remaining Tasks

#### Emulation Infrastructure Validation ✅ (Completed 2025-12-09)

**Validated**:
- [x] `nix flake check` passes (warnings are acceptable)
- [x] `nix build .#packages.x86_64-linux.emulation-vm` succeeds
- [x] Emulation VM boots with all services (libvirtd, ovs-vswitchd, ovsdb, dnsmasq)
- [x] Inner VMs defined in libvirt (n100-1, n100-2, n100-3)
- [x] OVS bridge topology correct (ovsbr0 with vnet0 @ 192.168.100.1/24)
- [x] tc constraint script functional (`/etc/tc-simulate-constraints.sh`)
- [x] Nested virtualization working in WSL2

---

### vsim Expansion Roadmap (Current Focus)

The emulation infrastructure is operational. Next steps expand testing capabilities:

#### Phase 1: Network Resilience Testing ✅ (Completed 2025-12-09)

**Goal**: Create automated tests for network constraint scenarios.

**Completed**:
- [x] Updated `mkTCProfiles.nix` to use correct VM names (n100-1, n100-2, n100-3)
- [x] Created `tests/integration/network-resilience.nix` nixosTest
- [x] Test validates OVS bridge topology and host interface configuration
- [x] Test validates TC profile script execution (default, constrained, lossy)
- [x] Test validates VM interface detection when VMs are started
- [x] Test validates TC rule application to running VM interfaces
- [x] Test validates multi-VM TC management
- [x] Added `network-resilience` to flake checks output

**Note**: Full inter-VM connectivity testing requires Phase 3 (Inner VM Installation).
The current test validates the TC infrastructure works correctly.

**Run test**:
```bash
nix build .#checks.x86_64-linux.network-resilience
```

#### Phase 2: ARM64 Emulation (Jetson Testing) ✅ (Completed 2025-12-09)

**Goal**: Add Jetson Orin Nano (aarch64) to inner VMs via QEMU TCG.

**Completed**:
- [x] Added jetson-1 VM definition to `tests/emulation/embedded-system.nix`
- [x] Fixed `mkInnerVM.nix` to use correct UEFI firmware path (`${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd`)
- [x] Added NVRAM initialization for ARM64 VMs in setup-inner-vms service
- [x] Updated `mkTCProfiles.nix` with jetson-1 traffic control rules
- [x] Updated MOTD and documentation with ARM64 VM information
- [x] Verified flake check passes with ARM64 configuration

**Configuration**:
```nix
(mkInnerVM {
  hostname = "jetson-1";
  mac = "52:54:00:12:34:10";
  ip = "192.168.100.20";
  arch = "aarch64";           # QEMU TCG emulation
  memory = 2048;
  vcpus = 2;
  qosProfile = "constrained";
})
```

**Performance Note**: ARM64 via TCG is very slow (~10-20x). Use only for cross-arch validation.

#### Phase 3: Inner VM Installation Automation ✅ (Completed 2025-12-09)

**Goal**: Automate NixOS installation on inner VMs.

**Completed**:
- [x] Created `tests/emulation/lib/inner-vm-base.nix` - Base NixOS module for inner VMs with:
  - VM-specific hardware settings (virtio, serial console, QEMU guest support)
  - Simplified storage (no disko partitioning, just single root disk)
  - Network configuration via systemd-networkd (DHCP from dnsmasq)
  - Test-friendly authentication (root/test)
- [x] Created `tests/emulation/lib/mkInnerVMImage.nix` - Image builder function that:
  - Imports actual n3x host configs from `hosts/`
  - Overlays inner-vm-base.nix for emulation-specific settings
  - Uses NixOS `make-disk-image` to create bootable qcow2 images
  - Handles both x86_64 and aarch64 architectures
- [x] Updated `mkInnerVM.nix` to accept `diskImagePath` parameter
- [x] Updated `embedded-system.nix` to:
  - Build pre-installed qcow2 images at flake evaluation time
  - Copy images from Nix store to `/var/lib/libvirt/images/` on first boot
  - Configure x86_64 VMs (n100-1, n100-2, n100-3) with pre-built images
  - jetson-1 ARM64 image building disabled by default (slow)
- [x] Fixed flake checks to pass `inputs` to tests
- [x] All flake checks pass (`nix flake check --no-build`)

**Architecture**:
```
Inner VM Image Build:
  1. hosts/${hostname}/configuration.nix  (actual n3x config)
  2. + inner-vm-base.nix                  (VM adaptations)
  3. + emulation-specific settings        (test token, DHCP network)
  4. = make-disk-image → qcow2 image

Runtime Flow:
  1. Outer VM boots
  2. setup-inner-vms.service copies qcow2 from Nix store
  3. libvirt VMs defined
  4. `virsh start n100-1` → boots directly to NixOS!
```

**Usage**:
```bash
# Build emulation VM (first build takes time for inner VM images)
nix build .#packages.x86_64-linux.emulation-vm

# Run outer VM
./result/bin/run-nixos-vm

# Inside outer VM - VMs boot directly to NixOS!
virsh start n100-1 && sleep 10 && virsh console n100-1
# Login: root / test
```

**Known Warnings** (not errors, pre-existing):
- k3s token warning for agent roles (expected - tokens set at deployment)
- Root password options conflict (VM testing convenience)
- systemd.network + networking.useDHCP (emulator-vm specific, see MOTD)

**Note**: ARM64 image building is disabled by default because binfmt emulation is very slow. Enable in `embedded-system.nix` by uncommenting `innerVMImages.jetson-1`.

#### Phase 4: Testing Architecture Redesign (2025-12-12)

**Status**: Architecture decision finalized - pivot to nixosTest multi-node

**Root Cause**: Hyper-V Enlightened VMCS limits virtualization to 2 levels (L0→L1→L2).
See: [docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md](docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md)

---

##### The Problem: Triple-Nested Virtualization on WSL2

The vsim architecture attempted 3-level nesting:
```
Hyper-V (L0) → WSL2 (L1) → nixosTest VM (L2) → libvirt inner VMs (L3)
                                                 ↑ BLOCKED
```

This is architecturally unsupported:
- Enlightened VMCS optimizes only L0↔L1 communication
- Shadow VMCS (required for deeper nesting) is disabled under eVMCS v1
- Microsoft's TLFS defines no L3 terminology - it stops at L2
- Inner VMs hang indefinitely with no boot output

##### The Solution: nixosTest Multi-Node (No Nesting)

Use nixosTest nodes directly as k3s cluster nodes - no libvirt layer:
```
Native Linux:  Host → nixosTest VMs (1 level) ✓
WSL2:          Hyper-V → WSL2 → nixosTest VMs (2 levels) ✓
Darwin:        macOS → Lima/UTM → nixosTest VMs (2 levels) ✓
Cloud:         Hypervisor → NixOS → nixosTest VMs (2 levels) ✓
```

Each nixosTest "node" IS a k3s node - no inner VMs needed for cluster testing.

##### Architecture Comparison

| Approach | Nesting Levels | WSL2 | Native Linux | Darwin | Cloud |
|----------|----------------|------|--------------|--------|-------|
| vsim (libvirt inside nixosTest) | 3 | ❌ | ✓ | ❌ | ⚠️ |
| **nixosTest multi-node** | 1-2 | ✓ | ✓ | ✓ | ✓ |
| emulation-vm interactive | 2-3 | ⚠️ slow | ✓ | ⚠️ | ⚠️ |

##### New Test Architecture

**Primary (CI/automated)**: nixosTest multi-node
```nix
nodes.n100-1 = { imports = [ ../hosts/n100-1 ]; };  # k3s server
nodes.n100-2 = { imports = [ ../hosts/n100-2 ]; };  # k3s agent
nodes.n100-3 = { imports = [ ../hosts/n100-3 ]; };  # k3s agent
testScript = ''
  start_all()
  n100_1.wait_for_unit("k3s")
  n100_2.succeed("kubectl get nodes")
'';
```

**Secondary (interactive/development)**: emulation-vm on native Linux only
- Network simulation with OVS and TC constraints
- Resource constraint testing
- NOT for CI - manual testing only

---

#### Phase 4A: nixosTest Multi-Node Implementation ✅ (Completed 2025-12-12)

**Goal**: Create k3s cluster tests using nixosTest nodes directly.

**Tasks**:
- [x] Create `tests/integration/k3s-cluster-formation.nix` (2025-12-12)
  - Uses nixosTest multi-node: each node IS a k3s cluster node
  - No nested virtualization - works on all platforms (WSL2, Darwin, Cloud)
  - Tests: 2 servers + 1 agent, cluster formation, node joining, workload deployment
  - Run: `nix build '.#checks.x86_64-linux.k3s-cluster-formation'`
- [x] Create `tests/integration/k3s-storage.nix` (2025-12-12)
  - Validates storage prerequisites (kernel modules, iSCSI, directories)
  - Tests local-path-provisioner PVC creation and binding
  - Tests volume mounting and data persistence
  - Tests StatefulSet volumeClaimTemplates across 3 nodes
  - Validates Longhorn prerequisites ready for production deployment
  - Run: `nix build '.#checks.x86_64-linux.k3s-storage'`
- [x] Create `tests/integration/k3s-network.nix` (2025-12-12)
  - Tests pod-to-pod communication across nodes
  - Tests CoreDNS service discovery
  - Tests flannel VXLAN overlay networking on eth1
  - Run: `nix build '.#checks.x86_64-linux.k3s-network'`
- [x] Add network constraints via tc/netem directly on nixosTest nodes (2025-12-12)
  - Created `tests/integration/k3s-network-constraints.nix`
  - No OVS needed - applies constraints to eth1 node interfaces directly
  - Ported TC profiles from vsim to work without nested VMs
  - Tests: latency (50ms +/-10ms), packet loss (5%), bandwidth (10Mbps), combined edge device simulation
  - Validates k3s cluster stability under all constraint profiles
  - Key findings: k3s tolerates moderate network degradation, DNS/API remain responsive
  - Run: `nix build '.#checks.x86_64-linux.k3s-network-constraints'`

#### Phase 4B: Platform-Specific CI Configuration ✅ (Completed 2025-12-12)

**Goal**: Ensure tests work across all target platforms.

**Completed**:
- [x] Created `.gitlab-ci.yml` with full CI/CD pipeline
  - Validation stage: flake check, formatting
  - Test stage: individual k3s tests (cluster-formation, storage, network, constraints)
  - Integration stage: emulation tests, full test suite
  - Proper KVM runner tagging and timeout configuration
- [x] Updated `tests/README.md` with comprehensive platform documentation
- [x] Documented WSL2 (Windows 11) compatibility
- [x] Documented Darwin (arm64 macOS) Lima/UTM requirements
- [x] Documented AWS/Cloud NixOS AMI setup
- [x] Added self-hosted GitLab runner NixOS configuration example
- [x] Added GitHub Actions example

**Platform Support Matrix** (documented in tests/README.md):
| Platform | nixosTest Multi-Node | vsim (Nested Virt) |
|----------|---------------------|-------------------|
| Native Linux | YES | YES |
| WSL2 | YES | NO (2-level limit) |
| Darwin | YES* | NO |
| AWS/Cloud | YES | Varies |

*Requires running inside Lima/UTM Linux VM

**Run Tests**:
```bash
nix build '.#checks.x86_64-linux.k3s-cluster-formation'
nix build '.#checks.x86_64-linux.k3s-storage'
nix build '.#checks.x86_64-linux.k3s-network'
nix build '.#checks.x86_64-linux.k3s-network-constraints'
```

**⚠️ Test Validation Caveat** (discovered 2025-12-13):

`nix build` uses caching - tests that previously passed may not re-execute. To verify tests actually run:

| Indicator | Cached (not run) | Actually ran |
|-----------|------------------|--------------|
| Duration | 6-10 seconds | 5-15 minutes |
| VM boot logs | None | `systemd[1]: Initializing...` |
| Test commands | None | `must succeed:`, `wait_for` |

To force test re-execution:
```bash
# Force rebuild (ignores cache)
nix build '.#checks.x86_64-linux.k3s-cluster-formation' --rebuild

# Or delete cached result first
nix store delete /nix/store/*-vm-test-run-k3s-cluster-formation
```

#### Phase 5: Preserve emulation-vm for Interactive Testing ✅ (Completed 2025-12-12)

**Goal**: Keep emulation-vm infrastructure for specialized use cases.

**Use Cases** (native Linux only):
- Network simulation with OVS bridges
- TC constraint testing (latency, bandwidth, loss)
- Multi-node topology visualization
- ARM64 cross-architecture validation (slow)

**Completed**:
- [x] Added Platform Compatibility section to `tests/emulation/README.md`
- [x] Documented platform support matrix (native Linux YES, WSL2 NO, Darwin NO)
- [x] Explained Hyper-V eVMCS 2-level limit with link to analysis doc
- [x] Added recommended alternatives (nixosTest multi-node, cloud, native Linux)
- [x] Added platform verification script
- [x] Committed Hyper-V analysis documentation

---

##### Historical Context (Phase 4 Investigation)

The original vsim approach was thoroughly investigated:
- POC at `~/src/nested-virt-poc` confirmed L3 hangs
- OVS naming conflict fixed (commit b499075)
- dhcpcd interference fixed (commit c8d7f5b)
- Even with fixes, inner VMs show no boot output after 15+ minutes
- Root cause: Enlightened VMCS architectural limitation, not software bug

##### References

- [Hyper-V Enlightened VMCS Analysis](docs/hyper-v-enlightened-vmcs-caps-nested-virt-at-2-levels.md)
- [NixOS Testing Library](https://nixos.wiki/wiki/NixOS_Testing_library)
- [nix.dev - Integration Testing](https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines.html)
- [Red Hat Nested Virtualization](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_and_managing_virtualization/creating-nested-virtual-machines_configuring-and-managing-virtualization)

---

#### Phase 6: VLAN Tagging Test Infrastructure ✅ (Implemented 2026-01-17)

**Status**: Implementation complete, awaiting runtime validation

**Goal**: Add 802.1Q VLAN tagging support to nixosTest integration tests for production parity.

**Key Decision**: Use Nix's module system and parameterization to maintain both OVS emulation and nixosTest approaches without code duplication.

**Testing Guide**: [docs/VLAN-TESTING-GUIDE.md](docs/VLAN-TESTING-GUIDE.md) - **START HERE FOR TESTING**

**Implemented**:
- [x] Created `tests/lib/network-profiles/` with three profiles:
  - `simple.nix` - Single flat network (baseline, current behavior)
  - `vlans.nix` - 802.1Q VLAN tagging on eth1 trunk (VLAN 200 cluster, VLAN 100 storage)
  - `bonding-vlans.nix` - Bonding + VLANs (full production parity)
- [x] Created `tests/lib/mk-k3s-cluster-test.nix` - Parameterized test builder
  - Accepts `networkProfile` parameter
  - Separates test logic from network configuration
  - Enables easy addition of new profiles without code duplication
- [x] Updated `flake.nix` with three new test variants:
  - `k3s-cluster-simple` - Baseline validation
  - `k3s-cluster-vlans` - VLAN tagging validation
  - `k3s-cluster-bonding-vlans` - Production parity validation
- [x] Updated `tests/emulation/README.md` - Clarified use cases for OVS vs nixosTest
- [x] Updated `tests/README.md` - Added comprehensive network profiles section

**Architecture**:
```nix
# Network profiles define topology
tests/lib/network-profiles/
├── simple.nix           # Single flat network
├── vlans.nix            # 802.1Q VLAN tagging
└── bonding-vlans.nix    # Bonding + VLANs

# Parameterized builder generates tests
mk-k3s-cluster-test.nix { networkProfile = "vlans"; }
  → Loads profile
  → Applies network config to nodes
  → Runs standard k3s cluster tests
```

**VLAN Configuration**:
- **VLAN 200** (Cluster): 192.168.200.0/24 - k3s API, flannel, cluster communication
- **VLAN 100** (Storage): 192.168.100.0/24 - Longhorn, iSCSI, storage replication
- VLANs configured via systemd.network with 8021q kernel module

**Run Tests**:
```bash
nix build '.#checks.x86_64-linux.k3s-cluster-simple'          # Baseline
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'           # VLAN tagging
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'   # Full production
```

**Benefits**:
- **Production Parity**: VLAN tests match future external switch deployment
- **No Duplication**: Test logic defined once, network configs composed via modules
- **Platform Support**: Works on WSL2, Darwin, Cloud (no nested virt required)
- **Maintainable**: New profiles added without touching test code
- **Nix-Idiomatic**: Uses module system composition, not branching

**OVS Emulation Preserved**:
The OVS emulation framework remains available for interactive testing on native Linux. Both approaches are complementary:
- **nixosTest multi-node**: Automated CI/CD, VLAN validation, all platforms
- **OVS emulation**: Interactive debugging, topology visualization, native Linux only

---

##### Testing Status & Validation Checklist

**Implementation**: ✅ Complete (Commits: `8e70f85`, `080eeb3`, `f4dc6cc`)
**Runtime Validation**: ✅ Complete (2026-01-17)

| Test Variant | Status | Platform Tested | Notes |
|--------------|--------|-----------------|-------|
| k3s-cluster-simple | ✅ PASSED | WSL2 (Hyper-V) | Flat network baseline, ~90s |
| k3s-cluster-vlans | ✅ PASSED | WSL2 (Hyper-V) | VLAN 200 IPs verified (192.168.200.x) |
| k3s-cluster-bonding-vlans | ✅ PASSED | WSL2 (Hyper-V) | Bond + VLAN tagging works |

**Key Fixes Applied**:
1. `080eeb3` - Fixed k3s HA cluster formation (lib.recursiveUpdate for extraFlags merge)
2. `f4dc6cc` - Fixed bondConfig invalid ActiveSlave option (moved PrimarySlave to slave network config)

**Validation Criteria** (all met):
- ✅ All 3 tests build without Nix errors
- ✅ VLANs correctly configured (eth1.200 for cluster, eth1.100 for storage)
- ✅ k3s cluster forms over VLAN interfaces (verified INTERNAL-IP shows 192.168.200.x)
- ✅ Bonding + VLANs work together (bond0.200, bond0.100)
- ✅ All 3 nodes reach Ready state
- ✅ CoreDNS and local-path-provisioner pods reach Running state

**Quick Test Commands**:
```bash
# Standard test runs (uses cache)
nix build '.#checks.x86_64-linux.k3s-cluster-simple'
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans'

# Force rebuild (bypasses cache, ~2-3 min each)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild
```

**Known Behavior & Flakiness**:
- etcd HA election adds timing variance (~60-120s for cluster formation)
- Tests may occasionally timeout due to etcd quorum timing; retrying usually works
- Nameserver limits warning is benign (using 1.1.1.1, 8.8.8.8, 9.9.9.9)

**Test Flakiness Analysis** (2026-01-17 investigation):
- Root cause: **Host system load**, not timeout values
- When running `--rebuild` or during system load, VMs get less CPU time
- etcd leader election can stall, causing k8s API "ServiceUnavailable" errors
- Tests have generous timeouts (300s for node ready, 240s for primary server)
- Observed failure: 734s elapsed before timeout at system pod check (120s)
- Retries typically pass (3/3 passed on clean re-run within same session)
- Mitigation: Run tests on idle system; use cache when possible (`--rebuild` bypasses cache)

---

#### Phase 7: CI Validation Infrastructure ⏳

**Status**: Phase 2 Complete - Attic design ready for DevOps team deployment

**Goal**: Validate VLAN tests in GitHub Actions CI before manual testing.

**Plan Document**: [docs/plans/CI-VALIDATION-PLAN.md](docs/plans/CI-VALIDATION-PLAN.md)

**Design Document**: [docs/plans/ATTIC-INFRASTRUCTURE-DESIGN.md](docs/plans/ATTIC-INFRASTRUCTURE-DESIGN.md) ← **HANDOFF READY**

**Phase 2 Deliverable** (2026-01-17):
- ✅ Created comprehensive Attic infrastructure design document (48 pages)
- ✅ Architecture diagrams (high-level, network topology, data flow)
- ✅ Component specifications (Attic server, RDS, S3, ALB, security)
- ✅ 9 decision matrices with detailed pros/cons
- ✅ Specific infrastructure questions for DevOps team
- ✅ Implementation checklist (7-10 hour deployment estimate)
- ✅ Cost projections: $16/mo (shared infra) to $58/mo (dedicated)
- ✅ Monitoring, security, DR plans included
- ✅ Pulumi module skeleton for Go implementation

**Next Action**: DevOps team reviews ATTIC-INFRASTRUCTURE-DESIGN.md, answers infrastructure questions, schedules deployment

**Key Decisions Needed**:
- [ ] Cache provider (Magic Nix Cache vs Cachix)
- [ ] Test execution strategy (parallel vs sequential)
- [ ] Trigger strategy (on push, PR, scheduled, manual)
- [ ] Scope (just VLAN tests or all checks)

**Estimated Costs** (with proper caching):
- Development: ~$17 for 2 weeks
- Maintenance: ~$3.60/month
- Per run: ~$0.12 (3 tests × 5 min with cache)

**Timeline**: 12-15 hours across multiple sessions

**Approach**: Interactive design-first
1. Phase 1: Research & Cost Analysis
2. Phase 2: Cache Strategy Design
3. Phase 3: Portable CI Architecture
4. Phase 4: GitHub Actions Implementation
5. Phase 5: GitLab CI Port

**Why CI First?**:
- Automated validation without local KVM setup
- Proper binary caching benefits future work
- Portable architecture for work GitLab CI
- Cost-effective with Magic Nix Cache ($0.12/run)

**Next Session**: Review CI-VALIDATION-PLAN.md, begin Phase 1 research

---

### Quick Reference

**Build & Run Emulation VM**:
```bash
nix build .#packages.x86_64-linux.emulation-vm
./result/bin/run-nixos-vm
```

**Inside Outer VM**:
```bash
virsh list --all                           # List VMs
virsh start n100-1                         # Start VM
virsh console n100-1                       # Console (Ctrl+] to exit)
ovs-vsctl show                             # OVS topology
/etc/tc-simulate-constraints.sh status     # TC rules
/etc/tc-simulate-constraints.sh constrained # Apply constraints
```

**Known Warnings** (not errors):
- k3s token warning for agent roles (tokens set at deployment)
- Root password options (VM testing convenience)
- systemd.network + networking.useDHCP (emulator-vm specific)

---

### Later Phases (After Testing Validation)

#### Phase 8: Secrets Preparation
1. **Generate Encryption Keys**
   - Generate age keys for admin and all physical hosts
   - Document public keys in secrets/public-keys.txt
   - Securely backup private keys

2. **Create and Encrypt Secrets**
   - Generate strong K3s server and agent tokens
   - Encrypt tokens using sops
   - Validate decryption works with age keys

#### Phase 9: Hardware Deployment
1. **Initial Provisioning**
   - Deploy first N100 server node using nixos-anywhere
   - Verify successful boot and SSH access
   - Confirm K3s control plane initialization
   - Validate secrets decryption on real hardware

2. **Cluster Expansion**
   - Deploy second and third N100 nodes
   - Deploy Jetson nodes (if available)
   - Verify all nodes join cluster successfully
   - Test cross-node communication

#### Phase 10: Kubernetes Stack Deployment
1. **Core Components**
   - Install Kyverno from manifests/
   - Verify PATH patching policy applies to pods
   - Deploy Longhorn via Helm
   - Confirm Longhorn manager starts without errors

2. **Storage Validation**
   - Create test PVC and verify provisioning
   - Test replica distribution across nodes
   - Validate storage network traffic separation
   - Benchmark storage performance

#### Phase 11: Production Hardening
1. **Security**
   - Configure proper TLS certificates for K3s
   - Rotate default tokens to production values
   - Set up RBAC policies
   - Enable audit logging

2. **Operational Readiness**
   - Deploy monitoring stack (Prometheus/Grafana)
   - Configure alerting rules
   - Implement backup strategies for etcd and Longhorn
   - Document operational procedures
   - Create runbooks for common scenarios

## Development Guidelines

### Code Organization
- Keep configurations modular and composable
- Use generator functions to reduce duplication
- Separate concerns between hardware, networking, and services
- Maintain clear separation between secrets and configuration

### Testing Approach

**Automated Testing (Preferred):**
- Use NixOS integration tests (`nixosTest`) for all functional validation
- Tests are declarative Nix derivations that boot VMs and run assertions
- Integrated with `nix flake check` for CI/CD pipelines
- Tests are reproducible and start from clean state every run
- Located in `tests/integration/`

**Emulation Testing (vsim Integration):**
- Use nested virtualization for complex multi-node scenarios
- ARM64 emulation via QEMU TCG for cross-architecture validation
- Network simulation with OVS and traffic control for resilience testing
- Resource constraints testing for embedded system scenarios
- Located in `tests/emulation/` - see [tests/emulation/README.md](tests/emulation/README.md) for comprehensive documentation

**Manual/Interactive Testing:**
- Use `./tests/run-vm-tests.sh` for quick manual exploration
- Build VMs directly: `nix build .#nixosConfigurations.vm-NAME.config.system.build.vm`
- Interactive test debugging: `nix build .#checks.x86_64-linux.TEST-NAME.driverInteractive`
- Use VMs in `tests/vms/` for manual validation

**Testing Hierarchy:**
1. **Fast automated** (nixosTest) - CI/CD, quick validation
2. **Emulation** (vsim) - Complex scenarios, ARM64, network resilience
3. **Manual VMs** - Interactive debugging
4. **Bare-metal** - Final validation on real hardware

**General Practices:**
- Always test in VMs before deploying to hardware
- Validate each layer independently before integration
- Write automated tests for critical functionality
- Use interactive mode for debugging failures
- Document any hardware-specific quirks discovered

**Test Structure:**
```nix
# Example test structure
pkgs.testers.runNixOSTest {
  name = "my-test";
  nodes = {
    machine1 = { config, ... }: { /* NixOS config */ };
    machine2 = { config, ... }: { /* NixOS config */ };
  };
  testScript = ''
    start_all()
    machine1.wait_for_unit("service.service")
    machine1.succeed("test command")
  '';
}
```

### Documentation
- Update README.md when implementation decisions are made
- Document any deviations from the plan
- Keep configuration examples minimal and focused
- Add troubleshooting sections as issues are encountered

## Known Constraints

### Hardware Limitations
- Jetson Orin Nano requires serial console (HDMI doesn't work for console)
- N100 miniPCs need specific kernel parameters for stability
- USB boot issues with certain Jetson firmware versions (use 35.2.1, not 35.3.1)

### Software Requirements
- Kyverno MUST be deployed before Longhorn for PATH compatibility
- Token management MUST use file paths, never inline secrets
- K3s manifests deployment requires careful ordering

## References

### Project Documentation
- [README.md](README.md) - Architecture and implementation patterns
- [tests/emulation/README.md](tests/emulation/README.md) - Emulation testing framework (nested virtualization, network simulation)
- [VSIM-INTEGRATION-PLAN.md](VSIM-INTEGRATION-PLAN.md) - vsim integration roadmap and session tracking
- [tests/README.md](tests/README.md) - Testing framework documentation
- [docs/SECRETS-SETUP.md](docs/SECRETS-SETUP.md) - Secrets management guide

### Community References
- niki-on-github/nixos-k3s (GitOps integration)
- rorosen/k3s-nix (multi-node examples)
- Skasselbard/NixOS-K3s-Cluster (CSV provisioning)
- anduril/jetpack-nixos (Jetson support)