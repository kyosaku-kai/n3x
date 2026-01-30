# Test Coverage Matrix

**Last Updated**: 2026-01-27 (Plan 012 COMPLETE)
**Purpose**: Track backend parity for n3x unified platform

## Test Layer Hierarchy

| Layer | What It Tests | Why It Matters |
|-------|---------------|----------------|
| L1 | VM Boot | Can QEMU/KVM boot a VM at all? |
| L2 | Two-VM Network | Can VMs communicate via VDE? |
| L1+ | Network Profile | Are VLAN/bonding configs correctly applied? |
| L3 | K3s Service Starts | Does K3s binary/service start? |
| L4+ | Cluster Formation | Multi-node cluster (DEFERRED - firewall bug) |

## Backend Parity Matrix

**TRUE PARITY** = Same test logic (shared script), different backend image

| Layer | Test Purpose | NixOS Test | ISAR Test | TRUE Parity? | Notes |
|-------|--------------|------------|-----------|--------------|-------|
| L1 | VM Boot | `smoke-vm-boot` PASS | `isar-vm-boot` PASS | **YES** | Both use shared test-scripts |
| L2 | Two-VM Network | `smoke-two-vm-network` PASS | `isar-two-vm-network` PASS | **YES** | Both verify VDE connectivity |
| L1+ | Network Simple | `k3s-cluster-simple` PASS | `isar-k3s-network-simple` **PASS** | **YES** | Plan 012 - systemd-networkd |
| L1+ | Network VLANs | `k3s-cluster-vlans` PASS | `isar-k3s-network-vlans` **PASS** | **YES** | Plan 012 - VLAN tagging verified |
| L1+ | Network Bonding | `k3s-cluster-bonding-vlans` PASS | `isar-k3s-network-bonding` **PASS** | **YES** | Plan 012 - bonding+VLANs |
| L3 | K3s Service | `smoke-k3s-service-starts` PASS | `k3s-server-boot.nix` EXISTS | **NO** | ISAR systemd boot blocking |

**SWUpdate tests** (ISAR-only, no NixOS equivalent - different functionality):
| Test | Layer | Status |
|------|-------|--------|
| `test-swupdate-apply` | L1 | PASS |
| `test-swupdate-boot-switch` | L1 | PASS |
| `test-swupdate-bundle-validation` | L1 | PASS |
| `test-swupdate-network-ota` | L2 | PASS |

## Quick Regression Commands

```bash
# Evaluation only (fast, ~30s)
nix flake check --no-build

# Layer 1-2 NixOS (~40s total)
nix build '.#checks.x86_64-linux.smoke-vm-boot'
nix build '.#checks.x86_64-linux.smoke-two-vm-network'

# Layer 1-2 ISAR Parity Tests (~2m total)
nix build '.#checks.x86_64-linux.isar-vm-boot'
nix build '.#checks.x86_64-linux.isar-two-vm-network'

# Layer 1-2 ISAR SWUpdate (~2m total)
nix build '.#checks.x86_64-linux.test-swupdate-apply'
nix build '.#checks.x86_64-linux.test-swupdate-network-ota'

# Layer 3 NixOS only (~40s)
nix build '.#checks.x86_64-linux.smoke-k3s-service-starts'

# Layer 1+ ISAR K3s Network Profile tests (Plan 012 - all PASS)
nix build '.#checks.x86_64-linux.isar-k3s-network-simple'     # ~18s
nix build '.#checks.x86_64-linux.isar-k3s-network-vlans'      # ~19s
nix build '.#checks.x86_64-linux.isar-k3s-network-bonding'    # ~19s
```

## ISAR Artifact Rebuild Workflow

**Purpose**: Build ISAR images and register them in Nix store for testing.

**Script**: `backends/isar/scripts/rebuild-isar-artifacts.sh`
**Flake app**: `nix run '.#rebuild-isar-artifacts' -- --help`

**Workflow**:
```bash
# From backends/isar/ directory:
cd backends/isar

# Build server image with simple network profile
./scripts/rebuild-isar-artifacts.sh all -m qemuamd64 -r server -o test-k3s -o simple

# Build server image with vlans network profile
./scripts/rebuild-isar-artifacts.sh all -m qemuamd64 -r server -o test-k3s -o vlans

# Build server image with bonding-vlans network profile
./scripts/rebuild-isar-artifacts.sh all -m qemuamd64 -r server -o test-k3s -o bonding-vlans
```

**Available overlays**:
- `test` - nixos-test-backdoor for VM testing
- `test-k3s` - test + k3s for k3s VM tests
- `swupdate` - A/B partition layout for OTA
- `simple` - Simple flat network (systemd-networkd-config)
- `vlans` - 802.1Q VLAN tagging
- `bonding-vlans` - Bonding plus VLANs

## Full Test Inventory

### NixOS Backend (`tests/nixos/`)

| Test | Layer | Status | Time | Notes |
|------|-------|--------|------|-------|
| `smoke-vm-boot` | L1 | PASS | ~18s | Single VM boot |
| `smoke-two-vm-network` | L2 | PASS | ~21s | VDE ping between VMs |
| `smoke-k3s-service-starts` | L3 | PASS | ~38s | Single-node k3s service |
| `k3s-cluster-simple` | L4 | DEFERRED | - | Firewall blocks port 6443 |
| `k3s-cluster-vlans` | L4 | DEFERRED | - | Firewall blocks port 6443 |
| `k3s-cluster-bonding-vlans` | L4 | DEFERRED | - | Firewall blocks port 6443 |
| `k3s-cluster-formation` | L4 | DEFERRED | - | Legacy test, same issue |
| `k3s-network` | L4 | DEFERRED | - | Depends on cluster |
| `k3s-storage` | L4 | DEFERRED | - | Depends on cluster |
| `k3s-network-constraints` | L4 | DEFERRED | - | Depends on cluster |
| `k3s-bond-failover` | L4 | DEFERRED | - | Test infra limitation |
| `k3s-vlan-negative` | L4 | VALIDATED | ~600s | Intentionally fails |

### ISAR Backend (`tests/isar/`)

| Test | Layer | In Flake? | Status | Time | Notes |
|------|-------|-----------|--------|------|-------|
| `isar-vm-boot` | L1 | YES | PASS | ~13s | Uses shared test-scripts |
| `isar-two-vm-network` | L2 | YES | PASS | ~60s | TCP connectivity via nc/socat |
| `test-swupdate-apply` | L1 | YES | PASS | ~1m | Apply .swu bundle |
| `test-swupdate-boot-switch` | L1 | YES | PASS | ~1m | A/B partition switch |
| `test-swupdate-bundle-validation` | L1 | YES | PASS | ~2m | CMS signature validation |
| `test-swupdate-network-ota` | L2 | YES | PASS | ~1m | Two-VM HTTP OTA |
| `isar-k3s-network-simple` | L1+ | YES | **PASS** | ~18s | Plan 012 - systemd-networkd |
| `isar-k3s-network-vlans` | L1+ | YES | **PASS** | ~19s | Plan 012 - VLAN tagging |
| `isar-k3s-network-bonding` | L1+ | YES | **PASS** | ~19s | Plan 012 - bonding+VLANs |
| `k3s-server-boot.nix` | L3 | NO | SKIPPED | - | systemd boot blocking issue |

## Blocking Issues

### ISAR L3: systemd boot blocking (2026-01-26)
- **Symptom**: k3s-server.service CANCELED during boot
- **Root cause**: 41+ pending systemd jobs block entire boot transaction
- **Workaround tried**: Image-level mask of systemd-networkd-wait-online.service
- **Proper fix**: Use kernel cmdline `systemd.mask=service-name` at test time
- **Decision**: SKIP until network abstraction work provides clarity

### NixOS L4: Firewall bug (2026-01-27)
- **Symptom**: Port 6443 works on localhost but blocked from eth1
- **Evidence**: `refused connection: IN=eth1 ... DPT=6443` in kernel logs
- **Config**: serverFirewall.allowedTCPPorts includes 6443
- **Root cause**: Likely `lib.recursiveUpdate` merge issue OR base.nix override
- **Decision**: DEFER L4+ tests; focus on L1-2 parity

### ~~ISAR Network Profile Tests: Stale Artifacts~~ ✅ RESOLVED (2026-01-27)
- ~~**Symptom**: Tests fail because nix store has old image without systemd-networkd-config~~
- **Resolution**: Images rebuilt with systemd-networkd-config, all 3 tests pass
- Commit 264a86e merged final fixes

## Shared Test Scripts (`tests/lib/test-scripts/`)

| Module | Functions | Used By |
|--------|-----------|---------|
| `phases.boot.bootAllNodes` | Boot nodes, wait for multi-user.target | NixOS |
| `phases.boot.isar.bootWithBackdoor` | Boot via nixos-test-backdoor.service | ISAR |
| `phases.boot.isar.checkSystemStatus` | Diagnostic for systemd health | ISAR |
| `phases.network.verifyAll` | VLAN/interface verification | Both |
| `phases.k3s.verifyCluster` | K3s cluster formation | Both |
| `utils.all` | `tlog`, `log_section`, `log_banner` | Both |

## Parity Status

### L1-L2 Parity: ACHIEVED (2026-01-27)

| Task | Status |
|------|--------|
| Wire `tests/isar/single-vm-boot.nix` into flake as `isar-vm-boot` | DONE |
| Create `tests/isar/two-vm-network.nix` | DONE |
| Wire into flake as `isar-two-vm-network` | DONE |
| Run both and verify PASS | DONE |

**Note**: ISAR tests use TCP connectivity (nc/socat) instead of ping because the swupdate image doesn't include iputils-ping.

### L3 Parity: BLOCKED
- ISAR systemd boot blocking issue must be resolved first
- Kernel cmdline `systemd.mask=service-name` approach needs implementation

### Network Profile Parity: ✅ COMPLETE (2026-01-27 Plan 012)
- All 3 ISAR network profile tests pass
- Uses unified `systemd-networkd-config` recipe (replaced netplan)
- Validates VLANs and bonding configurations match NixOS behavior

## Session Log

| Date | Session | Changes | Result |
|------|---------|---------|--------|
| 2026-01-26 | P2.6 | Added ISAR helpers to shared test-scripts | Scripts exist |
| 2026-01-27 | Resume | Created this matrix document | Started parity work |
| 2026-01-27 | L1-L2 Parity | Wired isar-vm-boot, created isar-two-vm-network | **L1-L2 PARITY: YES** |
| 2026-01-27 | Plan 012 | Unified network config, ISAR network tests | **L1+ PARITY: YES** |

## Plan 012 Summary: Unified Network Architecture

**Completed 2026-01-27** - Commit range: 13f830d to 264a86e

### What Was Built

1. **Unified Network Configuration** (`lib/network/`)
   - `mk-network-config.nix` - Generates NixOS module from profile data
   - `mk-systemd-networkd.nix` - Generates .network/.netdev file content for ISAR
   - Profiles now export pure data only (no `nodeConfig` functions)

2. **Shared K3s Flag Generation** (`lib/k3s/`)
   - `mk-k3s-flags.nix` - DRY K3s extraFlags from profile data
   - Used by both backends consistently

3. **ISAR systemd-networkd-config Recipe** (`backends/isar/meta-isar-k3s/`)
   - Replaced netplan with native systemd-networkd configuration
   - Pre-generated config files for all profiles/nodes
   - Consumed via kas overlays: `simple.yml`, `vlans.yml`, `bonding-vlans.yml`

4. **ISAR Network Tests** (`tests/isar/`)
   - `k3s-network-simple.nix` - Single flat network validation
   - `k3s-network-vlans.nix` - 802.1Q VLAN tagging (eth1.200, eth1.100)
   - `k3s-network-bonding.nix` - Bond + VLANs (bond0.200, bond0.100)

### Key Design Decisions

- **Profiles are parameter presets** - Not a separate abstraction layer
- **No profile detection logic** - Caller provides parameters, functions transform them
- **Single source of truth** - lib/network/profiles/ defines topology once
- **Both backends consume the same data** - NixOS via mkNixOSConfig, ISAR via file generation

### Architecture

```
lib/network/profiles/vlans.nix
│  (exports: ipAddresses, interfaces, vlanIds)
│
├─→ mk-network-config.nix → NixOS systemd.network.* options
│
└─→ mk-systemd-networkd.nix → .network/.netdev files for ISAR
```
