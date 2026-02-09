# Test Coverage Matrix

**Last Updated**: 2026-02-16 (Plan 028 migration complete, Plan 030 T1 doc refresh)
**Purpose**: Track backend parity for n3x unified platform
**Validation Status**: NixOS L4 cluster tests PASS (4/4 profiles). Debian L4 tests exist but require image rebuild.

## Test Layer Hierarchy

| Layer | What It Tests | Why It Matters |
|-------|---------------|----------------|
| L1 | VM Boot | Can QEMU/KVM boot a VM at all? |
| L2 | Two-VM Network | Can VMs communicate via VDE? |
| L1+ | Network Profile | Are VLAN/bonding configs correctly applied? |
| L3 | K3s Service Starts | Does K3s binary/service start? |
| L4+ | Cluster Formation | Multi-node cluster (NixOS PASS, Debian needs image rebuild) |

## Backend Parity Matrix

**TRUE PARITY** = Same test logic (shared script), different backend image

| Layer | Test Purpose | NixOS Test | Debian Test | TRUE Parity? | Notes |
|-------|--------------|------------|-------------|--------------|-------|
| L1 | VM Boot | `smoke-vm-boot` PASS | `debian-vm-boot` PASS | **YES** | Both use shared test-scripts |
| L2 | Two-VM Network | `smoke-two-vm-network` PASS | `debian-two-vm-network` PASS | **YES** | Both verify VDE connectivity |
| L1+ | Network Simple | `k3s-cluster-simple` PASS | `debian-network-simple` **PASS** | **YES** | Plan 012 - systemd-networkd |
| L1+ | Network VLANs | `k3s-cluster-vlans` PASS | `debian-network-vlans` **PASS** | **YES** | Plan 012 - VLAN tagging verified |
| L1+ | Network Bonding | `k3s-cluster-bonding-vlans` PASS | `debian-network-bonding` **PASS** | **YES** | Plan 012 - bonding+VLANs |
| L3 | K3s Service | `smoke-k3s-service-starts` PASS | `k3s-server-boot.nix` EXISTS | **NO** | Debian systemd boot blocking |

**SWUpdate tests** (Debian backend only, no NixOS equivalent - different functionality):
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

# Layer 1-2 Debian Parity Tests (~2m total)
nix build '.#checks.x86_64-linux.debian-vm-boot'
nix build '.#checks.x86_64-linux.debian-two-vm-network'

# Layer 1-2 Debian SWUpdate (~2m total)
nix build '.#checks.x86_64-linux.test-swupdate-apply'
nix build '.#checks.x86_64-linux.test-swupdate-network-ota'

# Layer 3 NixOS only (~40s)
nix build '.#checks.x86_64-linux.smoke-k3s-service-starts'

# Layer 1+ Debian K3s Network Profile tests (Plan 012 - all PASS)
nix build '.#checks.x86_64-linux.debian-network-simple'     # ~18s
nix build '.#checks.x86_64-linux.debian-network-vlans'      # ~19s
nix build '.#checks.x86_64-linux.debian-network-bonding'    # ~19s
```

## Debian Artifact Build and Registration

**Purpose**: Build Debian backend images (via ISAR) and register them in Nix store for testing.

**Flake app**: `nix run '.#isar-build-all' -- --help`
**Build matrix**: `lib/debian/build-matrix.nix` (variant definitions, naming, kas command generation)
**Hash state**: `lib/debian/artifact-hashes.nix` (only file modified by the build script)

**Workflow**:
```bash
# Build all 16 variants, register all artifacts
nix run '.#isar-build-all'

# Build one variant
nix run '.#isar-build-all' -- --variant server-simple-server-1

# Build all variants for one machine
nix run '.#isar-build-all' -- --machine qemuamd64

# List all variants
nix run '.#isar-build-all' -- --list

# Stage updated hashes and verify
git add lib/debian/artifact-hashes.nix
nix flake check --no-build
```

## Full Test Inventory

### NixOS Backend (`tests/nixos/`)

| Test | Layer | Status | Time | Notes |
|------|-------|--------|------|-------|
| `smoke-vm-boot` | L1 | PASS | ~18s | Single VM boot |
| `smoke-two-vm-network` | L2 | PASS | ~21s | VDE ping between VMs |
| `smoke-k3s-service-starts` | L3 | PASS | ~38s | Single-node k3s service |
| `k3s-cluster-simple` | L4 | **PASS** | ~3m | Plan 020 B1 |
| `k3s-cluster-simple-systemd-boot` | L4 | EXISTS | - | systemd-boot variant |
| `k3s-cluster-vlans` | L4 | **PASS** | ~3m | Plan 020 B2 |
| `k3s-cluster-bonding-vlans` | L4 | **PASS** | ~4m | Plan 020 B3 |
| `k3s-cluster-dhcp-simple` | L4 | **PASS** | ~3m | Plan 020 B4 |
| `k3s-cluster-formation` | L4 | DEPRECATED | - | Use k3s-cluster-simple |
| `k3s-network` | L4 | EXISTS | - | Depends on cluster |
| `k3s-storage` | L4 | EXISTS | - | Depends on cluster |
| `k3s-network-constraints` | L4 | EXISTS | - | Depends on cluster |
| `k3s-bond-failover` | L4 | EXISTS | - | Specialized test |
| `k3s-vlan-negative` | L4 | VALIDATED | ~600s | Intentionally fails |

### Debian Backend (`tests/debian/`)

| Test | Layer | In Flake? | Status | Time | Notes |
|------|-------|-----------|--------|------|-------|
| `debian-vm-boot` | L1 | YES | PASS | ~13s | Uses shared test-scripts |
| `debian-two-vm-network` | L2 | YES | PASS | ~60s | TCP connectivity via nc/socat |
| `test-swupdate-apply` | L1 | YES | PASS | ~1m | Apply .swu bundle |
| `test-swupdate-boot-switch` | L1 | YES | PASS | ~1m | A/B partition switch |
| `test-swupdate-bundle-validation` | L1 | YES | PASS | ~2m | CMS signature validation |
| `test-swupdate-network-ota` | L2 | YES | PASS | ~1m | Two-VM HTTP OTA |
| `debian-network-simple` | L1+ | YES | PASS | ~18s | Plan 012 - systemd-networkd |
| `debian-network-vlans` | L1+ | YES | PASS | ~19s | Plan 012 - VLAN tagging |
| `debian-network-bonding` | L1+ | YES | PASS | ~19s | Plan 012 - bonding+VLANs |
| `debian-server-boot` | L3 | YES | EXISTS | - | Requires image rebuild |
| `debian-cluster-simple` | L4 | YES | EXISTS | - | Requires image rebuild |
| `debian-cluster-vlans` | L4 | YES | EXISTS | - | Requires image rebuild |
| `debian-cluster-bonding-vlans` | L4 | YES | EXISTS | - | Requires image rebuild |
| `debian-cluster-dhcp-simple` | L4 | YES | EXISTS | - | Requires image rebuild |
| `debian-network-debug` | L1+ | YES | PASS | - | Development/debug |

## Blocking Issues

### ~~NixOS L4: Firewall bug~~ RESOLVED (2026-02-01)
- **Resolution**: k3s-cluster-simple PASSED (B1) - all 4 L4 profiles now pass

### ~~Debian Network Profile Tests: Stale Artifacts~~ RESOLVED (2026-01-27)
- **Resolution**: Images rebuilt with systemd-networkd-config, all 3 L1+ tests pass

### Debian L4 Cluster Tests: Require Image Rebuild
- **Status**: Test derivations exist in flake, but require Debian backend image artifacts
- **Action**: Rebuild Debian backend images after any infrastructure changes, then run tests

## Shared Test Scripts (`tests/lib/test-scripts/`)

| Module | Functions | Used By |
|--------|-----------|---------|
| `phases.boot.bootAllNodes` | Boot nodes, wait for multi-user.target | NixOS |
| `phases.boot.debian.bootWithBackdoor` | Boot via nixos-test-backdoor.service | Debian |
| `phases.boot.debian.checkSystemStatus` | Diagnostic for systemd health | Debian |
| `phases.network.verifyAll` | VLAN/interface verification | Both |
| `phases.k3s.verifyCluster` | K3s cluster formation | Both |
| `utils.all` | `tlog`, `log_section`, `log_banner` | Both |

## Parity Status

### L1-L2 Parity: ACHIEVED (2026-01-27)

| Task | Status |
|------|--------|
| Wire `tests/debian/single-vm-boot.nix` into flake as `debian-vm-boot` | DONE |
| Create `tests/debian/two-vm-network.nix` | DONE |
| Wire into flake as `debian-two-vm-network` | DONE |
| Run both and verify PASS | DONE |

**Note**: Debian backend tests use TCP connectivity (nc/socat) instead of ping because the swupdate image doesn't include iputils-ping.

### L3 Parity: BLOCKED
- Debian backend systemd boot blocking issue must be resolved first
- Kernel cmdline `systemd.mask=service-name` approach needs implementation

### Network Profile Parity: ✅ COMPLETE (2026-01-27 Plan 012)
- All 3 Debian network profile tests pass
- Uses unified `systemd-networkd-config` recipe (replaced netplan)
- Validates VLANs and bonding configurations match NixOS behavior

## Session Log

| Date | Session | Changes | Result |
|------|---------|---------|--------|
| 2026-01-26 | P2.6 | Added ISAR helpers to shared test-scripts | Scripts exist |
| 2026-01-27 | Resume | Created this matrix document | Started parity work |
| 2026-01-27 | L1-L2 Parity | Wired debian-vm-boot, created debian-two-vm-network | **L1-L2 PARITY: YES** |
| 2026-01-27 | Plan 012 | Unified network config, ISAR network tests | **L1+ PARITY: YES** |

## Plan 012 Summary: Unified Network Architecture

**Completed 2026-01-27** - Commit range: 13f830d to 264a86e

### What Was Built

1. **Unified Network Configuration** (`lib/network/`)
   - `mk-network-config.nix` - Generates NixOS module from profile data
   - `mk-systemd-networkd.nix` - Generates .network/.netdev file content for the Debian backend
   - Profiles now export pure data only (no `nodeConfig` functions)

2. **Shared K3s Flag Generation** (`lib/k3s/`)
   - `mk-k3s-flags.nix` - DRY K3s extraFlags from profile data
   - Used by both backends consistently

3. **ISAR systemd-networkd-config Recipe** (`backends/debian/meta-n3x/`)
   - Replaced netplan with native systemd-networkd configuration
   - Pre-generated config files for all profiles/nodes
   - Consumed via kas overlays: `simple.yml`, `vlans.yml`, `bonding-vlans.yml`

4. **Debian Network Tests** (`tests/debian/`)
   - `k3s-network-simple.nix` - Single flat network validation
   - `k3s-network-vlans.nix` - 802.1Q VLAN tagging (eth1.200, eth1.100)
   - `k3s-network-bonding.nix` - Bond + VLANs (bond0.200, bond0.100)

### Key Design Decisions

- **Profiles are parameter presets** - Not a separate abstraction layer
- **No profile detection logic** - Caller provides parameters, functions transform them
- **Single source of truth** - lib/network/profiles/ defines topology once
- **Both backends consume the same data** - NixOS via mkNixOSConfig, Debian backend via file generation

### Architecture

```
lib/network/profiles/vlans.nix
│  (exports: ipAddresses, interfaces, vlanIds)
│
├─→ mk-network-config.nix → NixOS systemd.network.* options
│
└─→ mk-systemd-networkd.nix → .network/.netdev files for Debian backend
```
