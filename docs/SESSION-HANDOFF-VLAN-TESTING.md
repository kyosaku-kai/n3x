# Session Handoff - VLAN Test Infrastructure

**Date**: 2026-01-17
**Branch**: `simint`
**Commits**: `8e70f85` (implementation), `d86ae45` (documentation)
**Status**: Implementation complete, runtime validation pending

---

## Quick Start for New Session

### What Was Implemented

Added 802.1Q VLAN tagging support to nixosTest integration tests via parameterized test builder:

```
✅ Simple profile         (baseline - single flat network)
✅ VLAN profile           (802.1Q tagging - cluster/storage separation)
✅ Bonding+VLAN profile   (full production parity)
```

### Your Mission

**Test the implementation on a KVM-enabled system and report results.**

### Testing Commands

```bash
cd ~/termux-src/n3x

# Test 1: Simple profile (baseline)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild

# Test 2: VLAN tagging (production parity)
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild

# Test 3: Bonding + VLANs (full production)
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans' --rebuild
```

**Expected**: Each test takes 5-15 minutes, boots 3 VMs, forms k3s cluster, passes.

### Essential Reading

1. **[docs/VLAN-TESTING-GUIDE.md](VLAN-TESTING-GUIDE.md)** ← Comprehensive testing guide
2. **[CLAUDE.md](../CLAUDE.md#testing-status--validation-checklist)** ← Testing status checklist

### Prerequisites

- Nix with flakes enabled
- KVM available (`ls -la /dev/kvm` should show device)
- 12GB+ RAM (3 VMs × 3GB + overhead)
- Platform: Native Linux / WSL2 / Darwin (Lima/UTM) / Cloud

---

## Architecture Overview

### Files Created

```
tests/lib/
├── mk-k3s-cluster-test.nix          # Parameterized test builder
├── README.md                         # Developer guide
└── network-profiles/
    ├── simple.nix                    # Single flat network
    ├── vlans.nix                     # 802.1Q VLAN tagging
    └── bonding-vlans.nix             # Bonding + VLANs

docs/
├── VLAN-TESTING-GUIDE.md             # Complete testing guide
└── SESSION-HANDOFF-VLAN-TESTING.md   # This file
```

### How It Works

```nix
# Parameterized test builder
mk-k3s-cluster-test { networkProfile = "vlans"; }
  → Loads network profile
  → Applies config to 3 nodes via Nix modules
  → Runs standard k3s cluster formation test
  → Returns pass/fail
```

### Network Profiles

| Profile | Network Stack | Use Case |
|---------|---------------|----------|
| **simple** | eth1 (flat network) | Baseline, quick validation |
| **vlans** | eth1 → eth1.200 (cluster) + eth1.100 (storage) | VLAN tagging validation |
| **bonding-vlans** | eth1+eth2 → bond0 → bond0.200 + bond0.100 | Production parity |

---

## Expected Test Behavior

### Phase 1: Verification (Flake Structure)

```bash
nix flake show 2>&1 | grep k3s-cluster
```

**Expected**: See 3 new test variants listed.

### Phase 2: Simple Profile Test

```bash
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild
```

**Expected**:
- Duration: 5-15 minutes
- VM boot logs visible
- 3 nodes reach Ready state
- Result symlink created

**If 6-10 seconds**: Test was cached, didn't actually run. Use `--rebuild`.

### Phase 3: VLAN Profile Test

```bash
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild
```

**Expected**:
- VLANs created: eth1.200 (192.168.200.x), eth1.100 (192.168.100.x)
- k3s uses cluster VLAN (192.168.200.x)
- Flannel binds to eth1.200
- Cluster forms successfully

**Look for in logs**:
```
[Phase 2] Verifying network configuration...
  n100-1 interfaces:
eth1.100         UP             192.168.100.1/24
eth1.200         UP             192.168.200.1/24
```

### Phase 4: Bonding+VLAN Profile Test

```bash
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans' --rebuild
```

**Expected**:
- Bond0 created from eth1+eth2
- VLANs on bond0: bond0.200, bond0.100
- k3s cluster forms over bonded+VLAN interfaces

---

## Troubleshooting Quick Reference

### Test Runs Too Fast (Cached)

```bash
# Force rebuild
nix build '.#checks.x86_64-linux.TEST-NAME' --rebuild
```

### Test Fails - Interactive Debug

```bash
nix build '.#checks.x86_64-linux.k3s-cluster-vlans.driverInteractive'
./result/bin/nixos-test-driver

# Inside Python REPL:
>>> start_all()
>>> n100_1.succeed("ip addr show")
>>> n100_1.succeed("ip -d link show | grep vlan")
>>> n100_1.succeed("k3s kubectl get nodes")
```

### Check VLAN Configuration

```python
>>> n100_1.succeed("ip -d link show eth1.200")
>>> n100_1.succeed("lsmod | grep 8021q")
>>> n100_1.succeed("networkctl status")
```

---

## Reporting Results

After testing, update **CLAUDE.md** testing checklist:

```markdown
| Test Variant | Status | Platform Tested | Notes |
|--------------|--------|-----------------|-------|
| k3s-cluster-simple | ✅ PASS | Native Linux | All phases passed |
| k3s-cluster-vlans | ✅ PASS | WSL2 | VLANs working correctly |
| k3s-cluster-bonding-vlans | ❌ FAIL | Darwin/Lima | Bond0 not created |
```

### Information to Include

1. **Platform**: Native Linux / WSL2 / Darwin / Cloud
2. **Test Results**: Pass/Fail for each variant
3. **Failure Details** (if any):
   - Which phase failed
   - Error messages
   - Interactive debug output
4. **System Info**:
   ```bash
   uname -a
   nix --version
   free -h
   ```

---

## Success Criteria

All three tests should:

✅ Build without Nix errors
✅ Boot 3 VMs successfully
✅ Configure network interfaces correctly
✅ Form k3s cluster (all nodes Ready)
✅ Deploy system pods (CoreDNS, local-path-provisioner)
✅ Complete all test phases
✅ Exit cleanly with result symlink

---

## Key Design Decisions

1. **Parameterized builder**: Test logic defined once, network configs separate
2. **Nix module composition**: No code duplication or branching
3. **Production parity**: VLAN tests match future hardware deployment
4. **Platform agnostic**: Works on WSL2, Darwin, Cloud (no nested virt required)
5. **OVS emulation preserved**: Kept separate for interactive testing on native Linux

---

## Context for Claude in New Session

When starting a new session to test this implementation, tell Claude:

> "I want to test the VLAN infrastructure implementation from commit 8e70f85.
> Please read docs/SESSION-HANDOFF-VLAN-TESTING.md and help me run the tests."

Claude will then:
1. Read this handoff document
2. Review VLAN-TESTING-GUIDE.md
3. Guide you through the testing process
4. Help debug any issues
5. Update CLAUDE.md checklist with results

---

## Next Steps After Successful Testing

1. **Mark Phase 6 complete** in CLAUDE.md
2. **Update CI/CD**: Add tests to GitLab CI / GitHub Actions
3. **Production deployment**: Enable VLANs in `hosts/*/configuration.nix`
4. **Hardware setup**: Configure external switch with trunk ports (VLAN 100, 200)
5. **Move to Phase 7**: Secrets preparation for hardware deployment

---

## Known Issues

**None yet** - awaiting first runtime validation.

Expected warnings (safe to ignore):
- k3s token warning (tests use pkgs.writeText instead of sops-nix)
- Root password conflict (test convenience override)
- systemd.network + useDHCP (test framework compatibility)

---

## Files Modified Summary

### New Files
- `tests/lib/mk-k3s-cluster-test.nix` - Parameterized test builder
- `tests/lib/network-profiles/*.nix` - 3 network profiles
- `tests/lib/README.md` - Developer guide
- `docs/VLAN-TESTING-GUIDE.md` - Comprehensive testing guide
- `docs/SESSION-HANDOFF-VLAN-TESTING.md` - This file

### Modified Files
- `flake.nix` - Added 3 test variants
- `tests/README.md` - Network profiles section
- `tests/emulation/README.md` - Use cases clarification
- `CLAUDE.md` - Phase 6 tracking, testing checklist

### Commits
- `8e70f85` - Implementation
- `d86ae45` - Documentation

---

## Contact Points

If testing reveals issues:

1. **Nix evaluation errors**: Check syntax in `tests/lib/` files
2. **VLAN not created**: Check 8021q module, systemd-networkd
3. **k3s cluster fails**: Check flannel interface configuration
4. **Out of memory**: Reduce VM count or memory allocation

All issues should be documented in CLAUDE.md testing checklist for next session.

---

**Ready to test!** Start with [docs/VLAN-TESTING-GUIDE.md](VLAN-TESTING-GUIDE.md).
