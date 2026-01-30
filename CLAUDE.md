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

### NixOS Test Driver & QEMU Process Management

5. **Orphaned nix build cleanup** - When a `nix build` process needs to be killed:
   - Build processes run as `nixbld*` users inside nix-daemon sandboxes
   - Parent shell/python processes may be reparented to PID 1 (init)
   - Regular `kill` fails due to different UID
   - **CRITICAL (WSL): Prefer SIGTERM over SIGKILL to allow cleanup handlers to run**:
     - `kas-build` wrapper has trap handlers that remount 9p filesystems on exit
     - SIGKILL (-9) bypasses traps, leaving `/mnt/c` unmounted (breaks clipboard, etc.)
     - Always try SIGTERM first, wait 5s, then SIGINT, then only SIGKILL as last resort
   - **Graceful termination procedure**:
     ```bash
     # Find orphaned nix build processes
     ps -ef | grep nixbld | grep -v grep

     # Find the bash wrapper (parent of test-driver, orphaned to PID 1)
     ps -ef | grep -E "nixbld.*bash" | grep -v grep

     # Try graceful termination first (allows kas-build to remount filesystems)
     sudo kill -TERM <bash_pid>
     sleep 5

     # If still running, try interrupt
     sudo kill -INT <bash_pid>
     sleep 3

     # LAST RESORT ONLY - will break WSL mounts if kas-build has them unmounted
     sudo kill -9 <bash_pid>

     # Or kill all processes for a specific build user (same signal priority applies)
     sudo pkill -TERM -u nixbld1
     ```
   - **If SIGKILL was used and mounts are broken**: Run `nix run '.#wsl-remount'` or `wsl --shutdown` from PowerShell

6. **PROACTIVE log monitoring during VM tests** - Do NOT passively wait for test completion:
   - Use `-L` flag with `nix build` to stream build/test logs
   - Check `BashOutput` frequently (every 30-60s) for running background builds
   - Look for early failure indicators:
     - `refused connection` - network/firewall issues
     - `connection timed out` - cluster formation problems
     - `DPT=6443` in kernel logs - firewall blocking k3s API
     - Repeated `etcdserver: leader changed` - etcd instability
   - **Kill early if failure pattern detected** - Don't wait for 10-minute timeout if logs show the test will fail
   - When monitoring, scan for progress indicators:
     - `[PHASE N]` markers in test output
     - `k3s.service: Started`
     - `Node.*Ready` status
     - `kubectl get nodes` showing expected node count

7. **Session cleanup before starting new tests** - ALWAYS verify no orphaned processes before starting a fresh build:
   ```bash
   pgrep -a qemu 2>/dev/null || echo "No QEMU processes"
   pgrep -a nixos-test-driver 2>/dev/null || echo "No test drivers"
   ```

## Project Status and Next Tasks

### Current Status
- **Branch**: `feature/unified-platform-v2` (48 commits ahead of origin/simint)
- **Plan 011**: Unified K3s Platform Architecture - COMPLETE
- **Plan 012**: Unified Network Architecture Refactoring - ✅ COMPLETE (2026-01-27)
- **Plan 013**: Test Infrastructure Review - ✅ COMPLETE (2026-01-27)
- **Plan 014**: L4 Test Parity - ✅ COMPLETE (2026-01-28)
- **ISAR L3 K3s Service Test**: ✅ VALIDATED (2026-01-29)
- **ISAR L4 Cluster Test**: ✅ IMPLEMENTED (2026-01-29) - 2-server HA control plane
- **Test Infrastructure**: Fully integrated NixOS + ISAR backends with shared abstractions
- **BitBake Memory Limits**: BB_NUMBER_THREADS=8, BB_PRESSURE_MAX_MEMORY=10000 (prevents OOM)
- **Next Step**: Run and validate isar-k3s-cluster-simple test

### Plan 012 Summary (2026-01-27) - COMPLETE

**Goal**: Eliminate network configuration duplication between backends

**Accomplished**:
1. ✅ Created `lib/network/mk-network-config.nix` - unified NixOS module generator
2. ✅ Created `lib/k3s/mk-k3s-flags.nix` - shared K3s flag generator
3. ✅ Removed `nodeConfig` and `k3sExtraFlags` from profiles (now data-only)
4. ✅ Updated `mk-k3s-cluster-test.nix` to use new unified architecture
5. ✅ Replaced netplan with `systemd-networkd-config` ISAR recipe
6. ✅ All NixOS smoke tests pass (L1-L3)
7. ✅ All ISAR network profile tests pass (simple, vlans, bonding-vlans)

**Key Architecture**:
- Profiles export **data only** (ipAddresses, interfaces, vlanIds)
- `mkNixOSConfig` transforms data → NixOS systemd.network modules
- `mkSystemdNetworkdFiles` transforms data → ISAR .network/.netdev files
- `mkK3sFlags.mkExtraFlags` transforms data → k3s --node-ip, --flannel-iface, etc.

### Previous Milestones
- **Phase 8** (Secrets Management): ✅ COMPLETE (2026-01-19)
- **Multi-Architecture**: ✅ COMPLETE (2026-01-19) - x86_64 and aarch64 k3s server
- **L1-L2 ISAR Parity**: ✅ COMPLETE (2026-01-26)
- **Network Profile Parity**: ✅ COMPLETE (2026-01-27)

### Phase 8 Summary (Secrets Management) - Completed 2026-01-19

**Outcome**: Original keys not found on thinky-nixos or Bitwarden. Fresh keys generated and stored.

**Completed**:
1. ✅ Generated 4 new age keys (admin + n100-1/2/3)
2. ✅ Updated `.sops.yaml` with new public keys + fixed rule ordering
3. ✅ Generated new k3s tokens and encrypted with all 4 recipients
4. ✅ Verified decryption works with all keys
5. ✅ Stored keys in Bitwarden (folder: Infrastructure/Age-Keys)
6. ✅ Committed changes (see commits f708bde, e20b70a)

**Key Files**:
- `secrets/keys/*.age` - Private keys (gitignored, backed up to Bitwarden)
- `secrets/.sops.yaml` - SOPS configuration with public keys
- `secrets/k3s/tokens.yaml` - Encrypted k3s tokens
- `docs/SECRETS-SETUP.md` - Multi-deployment documentation

**Deferred**:
- `.claude/user-plans/004-bitwarden-infrastructure-organization.md` - Cleanup duplicate/old entries

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

**Implementation**: ✅ Complete (Commits: `8e70f85`, `080eeb3`, `f4dc6cc`, `c845d78`)
**Runtime Validation**: ✅ Complete (2026-01-19)

| Test Variant | Status | Platform Tested | Notes |
|--------------|--------|-----------------|-------|
| k3s-cluster-simple | ✅ PASSED | WSL2 (Hyper-V) | Flat network baseline, ~145s |
| k3s-cluster-vlans | ✅ PASSED | WSL2 (Hyper-V) | VLAN 200 IPs verified (192.168.200.x), ~199s |
| k3s-cluster-bonding-vlans | ✅ PASSED | WSL2 (Hyper-V) | Bond + VLAN tagging works, ~156s |
| k3s-bond-failover | ⚠️ LIMITED | WSL2 (Hyper-V) | Test infra limitation (see below) |
| k3s-vlan-negative | ✅ VALIDATED | WSL2 (Hyper-V) | Misconfiguration correctly detected |

**Key Fixes Applied**:
1. `080eeb3` - Fixed k3s HA cluster formation (lib.recursiveUpdate for extraFlags merge)
2. `f4dc6cc` - Fixed bondConfig invalid ActiveSlave option (moved PrimarySlave to slave network config)
3. `c845d78` - Fixed VLAN ID assertion patterns for iproute2 output format

**Known Test Limitations** (not bugs):

1. **k3s-bond-failover**: Test fails due to nixosTest infrastructure limitation
   - `virtualisation.vlans = [1 2]` creates two separate virtual networks
   - When eth1 goes down, eth2 is on a different network - other nodes unreachable
   - Real hardware doesn't have this problem (both NICs on same switch)
   - The bonding module itself works correctly

2. **k3s-vlan-negative**: Intentionally has long timeout (~600s)
   - Validates that misconfigured VLANs prevent cluster formation
   - Shows `no route to host` errors as expected

3. **Cross-VLAN isolation**: Best-effort in nixosTest
   - nixosTest shared bridge doesn't enforce 802.1Q isolation
   - VLAN interfaces are created correctly with proper tags
   - Real isolation requires OVS emulation or physical hardware

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

#### Phase 7: CI Validation Infrastructure 🔄 **DEFERRED**

**Status**: DEFERRED - will be revisited after Phase 8 and Phase 10

**Reason for Deferral**: Prioritizing secrets management (Phase 8) and k8s deployment (Phase 10) tests first.

**Design Document**: [docs/plans/ATTIC-INFRASTRUCTURE-DESIGN.md](docs/plans/ATTIC-INFRASTRUCTURE-DESIGN.md) ← Ready when needed

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

### Upcoming Phases

#### Phase 8: Secrets Preparation ⏳ **NEXT**
**Status**: Next priority - includes writing new test suite

1. **Generate Encryption Keys**
   - Generate age keys for admin and all physical hosts
   - Document public keys in secrets/public-keys.txt
   - Securely backup private keys

2. **Create and Encrypt Secrets**
   - Generate strong K3s server and agent tokens
   - Encrypt tokens using sops
   - Validate decryption works with age keys

3. **Write Secrets Test Suite** (NEW)
   - Create `tests/integration/secrets-*.nix` tests
   - Validate sops-nix decryption in VM environment
   - Test age key management workflows
   - Test token rotation scenarios

#### Phase 9: Hardware Deployment 🔄 **DEFERRED**
**Status**: DEFERRED - will revisit after Phase 8 and 10

1. **Initial Provisioning** (DEFERRED)
   - Deploy first N100 server node using nixos-anywhere
   - Verify successful boot and SSH access
   - Confirm K3s control plane initialization
   - Validate secrets decryption on real hardware

2. **Cluster Expansion** (DEFERRED)
   - Deploy second and third N100 nodes
   - Deploy Jetson nodes (if available)
   - Verify all nodes join cluster successfully
   - Test cross-node communication

#### Phase 10: Kubernetes Stack Deployment ⏳ **UPCOMING**
**Status**: After Phase 8 - includes writing new test suite

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

3. **Write K8s Deployment Test Suite** (NEW)
   - Create `tests/integration/k8s-*.nix` tests
   - Test Kyverno policy enforcement
   - Test Longhorn deployment and PVC lifecycle
   - Test storage network isolation

#### Phase 11: Production Hardening 🔄 **DEFERRED**
**Status**: DEFERRED - will revisit after earlier phases complete

1. **Security** (DEFERRED)
   - Configure proper TLS certificates for K3s
   - Rotate default tokens to production values
   - Set up RBAC policies
   - Enable audit logging

2. **Operational Readiness** (DEFERRED)
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

## Technical Learnings

### ISAR Test Framework
- **Decision**: Use NixOS VM Test Driver (nixos-test-driver) with ISAR-built .wic images - NOT Avocado
- ISAR builds images (BitBake/kas produces .wic files), Nix provides test harness
- Tests run on host NixOS/Nix environment, not inside kas-container
- Test images need `nixos-test-backdoor` package - include via `kas/test-k3s-overlay.yml`
- Build test images: `kas-container --isar build kas/base.yml:kas/machine/qemu-amd64.yml:kas/test-k3s-overlay.yml:kas/image/minimal-base.yml`
- VM script derivations must NOT use `run-<name>-vm` pattern in derivation name (conflicts with nixos-test-driver regex)
- nixos-test-driver backdoor protocol: service prints "Spawning backdoor root shell..." to /dev/hvc0 (virtconsole)

### kas-container Build Process
- **Claude CAN run kas-container builds** - prefer subagents to minimize context usage
- **Monitoring**: Run in foreground, check `build/tmp/deploy/images/` for progress
- **Stuck builds**: Check `sudo podman ps -a` for orphaned containers
- **Cleanup**: `sudo podman rm -f <container_id>` or `pgrep -a podman`
- **NEVER manually clean sstate/work** - use `bitbake -c cleansstate <recipe>` when needed
- **ASK before rebuilds** - prefer test-level fixes (QEMU args, kernel cmdline) over image changes

### ISAR Build Cache
- **Shared cache** configured in `backends/isar/kas/base.yml`:
  - `DL_DIR = "${HOME}/.cache/yocto/downloads"`
  - `SSTATE_DIR = "${HOME}/.cache/yocto/sstate"`
- **Stale sstate fix**: `kas-container shell <kas-config> -c "bitbake -c cleansstate <recipe>"`

### WIC Generation Hang (WSL2)
- **Symptom**: Build hangs at 96% during `do_image_wic` in WSL2
- **Root cause**: `sgdisk` calls `sync()` which hangs on 9p mounts (`/mnt/c`)
- **Solution**: `kas-build` wrapper unmounts `/mnt/[a-z]` drives before build, remounts after
- **Cleanup after hang**: `wsl --shutdown` from PowerShell, then clean `build/tmp/schroot-overlay/*/upper/tmp/*.wic/`

### ISAR fstab Boot Issue (2026-01-27)
- **Symptom**: Systemd boot stuck, `dev-sda1.device` waits forever
- **Root cause**: `/etc/fstab` has `/dev/sda1 /boot` but QEMU virtio disk is `/dev/vda1`
- **Fix required**: Change WIC/fstab to use `PARTUUID=` instead of `/dev/sda1`
- **Location**: ISAR WIC kickstart files or base-files recipe

### Jetson Orin Nano OTA (Plan 006)
- **Fork**: `~/src/jetpack-nixos` branch `feature/pluggable-rootfs`
- **Key function**: `lib.mkExternalRootfsConfig { som, carrierBoard, rootfsTarball }`
- **Flash script**: Built with `--impure` (rootfs path is local file)
- **Jetson produces tar.gz not WIC**: `IMAGE_FSTYPES = "tar.gz"` - L4T flash tools handle partitioning
- **L4T packages**: ISAR recipes download .deb from NVIDIA repo
- **Container image**: Use `ghcr.io/siemens/kas/kas-isar:5.1` (includes bubblewrap)

### Nix-ISAR Integration Architecture
- **Hybrid approach**: ISAR builds artifacts, Nix provides test harness and flash tooling
- **Pattern 1**: Import ISAR .wic/.tar.gz artifacts into Nix tests
- **Pattern 2**: External rootfs for Jetson flash script
- **kas-container**: Functionally equivalent to `buildFHSUserEnvBubblewrap` but containerized

### VDE Multi-VM Networking
- **Use case**: Multi-VM tests (SWUpdate, network OTA) with VDE virtual ethernet
- **VDE switch timing**: Needs 3s initial delay + traffic to learn MACs before forwarding
- **HTTP serving**: Use `socat TCP-LISTEN:8080,fork,reuseaddr EXEC:/handler.sh` (not python http.server)
- **pkill cleanup**: Use `execute()` not `succeed()` - process may already be gone

### Unified K3s Platform (Plan 011)
- **Core Terminology**:
  - **Machine** = Hardware platform (arch + BSP + boot): `qemu-amd64`, `n100-bare`, `jetson-orin-nano`
  - **System** = Complete buildable artifact (nixosConfiguration / ISAR image recipe)
  - **Role** = `server` | `agent` only
- **Architecture**: `tests/lib/` = shared, `backends/nixos/` = NixOS, `backends/isar/` = ISAR
- **Network Abstraction**: Interface keys (`cluster`, `storage`, `external`), VLAN notation in interface name
- **Test Layers**: L1 (VM Boot), L2 (Two-VM Network), L3 (K3s Service), L4 (Cluster)
- **NixOS cluster tests DEFERRED**: Firewall bug blocks multi-node (port 6443 refused from eth1)

### ISAR L4 Cluster Test Architecture (2026-01-29)
- **Shared infrastructure**: Same network profiles (`lib/network/profiles/`) used by NixOS
- **Name mapping**: Python vars (`server_1`) ↔ Profile names (`server-1`) via `builtins.replaceStrings`
- **Runtime network config**: Current workaround since images all have `NETWORKD_NODE_NAME="server-1"`
- **Proper solution**: Build per-node images with correct `NETWORKD_NODE_NAME` for each
- **K3s config**: Modified via `/etc/default/k3s-server` env file at runtime
- **Token sharing**: Copied from primary at test time (`/var/lib/rancher/k3s/server/token`)
- **Documentation**: [docs/ISAR-L4-TEST-ARCHITECTURE.md](docs/ISAR-L4-TEST-ARCHITECTURE.md)
- **Test command**: `nix build '.#checks.x86_64-linux.isar-k3s-cluster-simple'`

### ISAR L4 Test Debugging Session (2026-01-28 - 2026-01-29)

**Status**: IN PROGRESS - Network debug test shows connectivity works; L4 test has timing/sequence issue

**Session 1 (2026-01-28) Accomplishments**:
1. ✅ Added `iputils-ping` to ISAR image (`isar-k3s-image.inc` line 81)
2. ✅ Rebuilt ISAR image with kas-container
3. ✅ Updated artifact hash in `isar-artifacts.nix` (sha256: `1cvs18f5kb5q14s8dv8r6shvkg3ci0f2wz2bbfgmvd4n57k6anqq`)

**Session 2 (2026-01-29) Accomplishments**:
1. ✅ Fixed **hostname issue**: Added `hostname ${profileName}` in `mkVMWorkarounds`
2. ✅ Fixed **sed pattern for k3s config**: Added `^` anchor to only match uncommented `K3S_SERVER_OPTS=` line
3. ✅ Fixed **systemd-networkd restart**: Masked (not just stopped) to prevent restart via k3s's `After=network-online.target`
4. ✅ Verified: server-1 k3s listening on `*:6443`, iptables ACCEPT policy, curl to 127.0.0.1:6443 works
5. ✅ Verified: ICMP ping from server-2 to server-1 (192.168.1.1) works

**Session 3 (2026-01-29) Key Finding - Network Works in Isolation**:
1. ✅ Created `tests/isar/network-debug.nix` - minimal network debug test
2. ✅ Registered in flake as `isar-network-debug` check
3. ✅ **IPs persist for 60+ seconds** - no disappearance during monitoring
4. ✅ **TCP to port 6443 WORKS** after k3s starts on vm1: `exit_code=0`, `Connected to 192.168.1.1`
5. ✅ **k3s on vm1 does NOT affect vm2's network** - vm2's IP remains intact

**Corrected Root Cause Analysis**:
The original hypothesis (IP disappearing) was WRONG. Network debug test proves:
- IP addresses persist correctly
- TCP connectivity to 6443 works
- No firewall blocking

**Actual L4 Test Failure**:
- L4 test shows curl timeout BEFORE starting k3s on server-2
- But k3s on server-2 starts and runs as standalone (not joining cluster)
- k3s logs: `Started tunnel to 192.168.1.2:6443` (itself, not primary!)
- k3s doesn't error, just silently becomes standalone

**Likely Issue - Token or Timing**:
1. Token is written to `/var/lib/rancher/k3s/server/token` AFTER editing env file
2. k3s may read old token before new one is written
3. Or k3s starts before `--server` flag is picked up from env file
4. Need to verify: `systemctl daemon-reload` before starting k3s?

**Files Created This Session**:
- `tests/isar/network-debug.nix` - Minimal 2-VM network test with k3s startup simulation
- Added `isar-network-debug` check to `flake.nix`

**Debug Test Command**:
```bash
nix build '.#checks.x86_64-linux.isar-network-debug' -L  # ~2 min, tests network isolation
nix build '.#checks.x86_64-linux.isar-k3s-cluster-simple' -L  # ~10 min, full L4 test
```

**Next Steps**:
1. **Add daemon-reload before k3s start** - ensure env file changes are picked up
2. **Check token timing** - ensure token is written before k3s starts
3. **Compare exact sequence** - debug test vs L4 test, find the difference
4. **Check k3s startup logs** - get FULL logs (not just last 30 lines) to see connection attempts

**Lesson Learned - Need Faster Debug Cycle**:
- Full ISAR L4 test takes ~7-10 minutes per run
- Proposed: Create lightweight network-only test that validates IP persistence without k3s
- This would enable rapid iteration on the network config issue

## References

### Project Documentation
- [README.md](README.md) - Architecture and implementation patterns
- [tests/emulation/README.md](tests/emulation/README.md) - Emulation testing framework (nested virtualization, network simulation)
- [VSIM-INTEGRATION-PLAN.md](VSIM-INTEGRATION-PLAN.md) - vsim integration roadmap and session tracking
- [tests/README.md](tests/README.md) - Testing framework documentation
- [docs/SECRETS-SETUP.md](docs/SECRETS-SETUP.md) - Secrets management guide
- [docs/ISAR-L4-TEST-ARCHITECTURE.md](docs/ISAR-L4-TEST-ARCHITECTURE.md) - ISAR L4 cluster test design

### Community References
- niki-on-github/nixos-k3s (GitOps integration)
- rorosen/k3s-nix (multi-node examples)
- Skasselbard/NixOS-K3s-Cluster (CSV provisioning)
- anduril/jetpack-nixos (Jetson support)
- ALWAYS remember to stop and check with me anytime you think you need to add apackage or configuration to any ISAR image.