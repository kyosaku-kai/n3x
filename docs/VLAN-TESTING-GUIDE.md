# VLAN Test Infrastructure - Testing Guide

**Implementation Date**: 2026-01-17
**Branch**: `main`
**Status**: Operational

---

## Overview

This guide provides instructions for testing the newly implemented VLAN tagging infrastructure.

### What Was Implemented

Three network profiles with parameterized test builder:
- **simple**: Single flat network (baseline)
- **vlans**: 802.1Q VLAN tagging (production parity)
- **bonding-vlans**: Bonding + VLANs (complete production simulation)

### Architecture

```
lib/network/profiles/
├── simple.nix                    # Single flat network
├── vlans.nix                     # 802.1Q VLAN tagging
├── bonding-vlans.nix             # Bonding + VLANs
├── dhcp-simple.nix               # DHCP-based simple network
└── vlans-broken.nix              # Intentionally broken (negative tests)

tests/lib/
└── mk-k3s-cluster-test.nix      # Parameterized test builder
```

---

## Prerequisites

### System Requirements

| Requirement | Check Command | Expected Output |
|-------------|---------------|-----------------|
| Nix installed | `nix --version` | `nix (Nix) 2.x` |
| KVM available | `ls -la /dev/kvm` | Device exists |
| Flake support | `nix flake show --help` | Help output |
| Sufficient RAM | `free -h` | At least 12GB available (3 VMs × 3GB + overhead) |

### Platform Compatibility

| Platform | Supported | Notes |
|----------|-----------|-------|
| Native Linux | ✅ YES | Full support |
| WSL2 (Windows 11) | ✅ YES | Requires KVM enabled |
| Darwin (macOS) | ✅ YES | Via Lima or UTM Linux VM |
| Cloud (AWS/GCP) | ✅ YES | Use KVM-enabled instances |

---

## Testing Instructions

### Phase 1: Verification (Syntax & Structure)

**Goal**: Verify implementation builds without runtime execution.

```bash
cd ~/termux-src/n3x

# 1. Check flake structure (should show new checks)
nix flake show 2>&1 | grep k3s-cluster

# Expected output:
# ├───k3s-cluster-bonding-vlans: derivation 'vm-test-run-k3s-cluster-bonding-vlans'
# ├───k3s-cluster-simple: derivation 'vm-test-run-k3s-cluster-simple'
# ├───k3s-cluster-vlans: derivation 'vm-test-run-k3s-cluster-vlans'

# 2. Verify network profiles load without errors
nix eval --raw '.#checks.x86_64-linux.k3s-cluster-simple.name'
nix eval --raw '.#checks.x86_64-linux.k3s-cluster-vlans.name'
nix eval --raw '.#checks.x86_64-linux.k3s-cluster-bonding-vlans.name'

# Expected output: Test names printed without errors

# 3. Check for syntax errors (dry-run)
nix flake check --dry-run 2>&1 | grep -E "(error|warning)" | head -20

# Expected: Only known warnings (k3s token, root password options)
```

**Success Criteria**:
- ✅ All three test variants appear in flake output
- ✅ No Nix syntax errors
- ✅ Only expected warnings (not errors)

---

### Phase 2: Simple Profile (Baseline)

**Goal**: Validate baseline test still works with parameterized builder.

```bash
# Build test (uses cache if available)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --print-build-logs

# Force rebuild (bypasses cache - REQUIRED for validation)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild
```

**Expected Behavior**:
1. **Duration**: 5-15 minutes (fresh build)
2. **VM Boot Logs**: `systemd[1]: Initializing machine ID...`
3. **Test Phases**: 8 phases execute (boot, network, k3s init, cluster formation)
4. **Network Interfaces**:
   ```
   eth1: 192.168.1.1/24, 192.168.1.2/24, 192.168.1.3/24
   ```
5. **k3s Cluster**: All 3 nodes reach Ready state
6. **Exit**: Test passes, result symlink created

**Success Criteria**:
- ✅ Test completes without errors
- ✅ All 3 nodes join cluster
- ✅ CoreDNS and local-path-provisioner running
- ✅ Result available at `./result`

**Common Issues**:
- **Cached result (6-10 sec)**: Test didn't actually run - use `--rebuild`
- **KVM permission denied**: Add user to `kvm` group, logout/login
- **Out of memory**: Close other applications, ensure 12GB+ available

---

### Phase 3: VLAN Profile (Production Parity)

**Goal**: Validate 802.1Q VLAN tagging works correctly.

```bash
# Force rebuild to ensure test runs
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild --print-build-logs
```

**Expected Behavior**:
1. **Duration**: 5-15 minutes
2. **VLAN Interfaces Created**:
   ```
   eth1        (trunk, no IP)
   eth1.200    192.168.200.x/24  (cluster VLAN)
   eth1.100    192.168.100.x/24  (storage VLAN)
   ```
3. **k3s Configuration**:
   - Node IPs use cluster VLAN (192.168.200.x)
   - Flannel uses `eth1.200` interface
   - Storage network on `eth1.100` (ready for Longhorn)
4. **Cluster Formation**: Same as simple profile but on VLAN-tagged interfaces

**Validation Checklist**:
- ✅ VLANs appear in test logs: `ip -br addr show` output shows eth1.200 and eth1.100
- ✅ k3s uses cluster VLAN: `--node-ip=192.168.200.x` in test output
- ✅ Flannel binds to VLAN interface: `--flannel-iface=eth1.200`
- ✅ All pods communicate across VXLAN over VLAN 200
- ✅ Test passes with all 3 nodes Ready

**Success Criteria**:
- ✅ VLANs correctly configured on all nodes
- ✅ k3s cluster forms over VLAN-tagged interfaces
- ✅ Pod-to-pod communication works
- ✅ No kernel errors related to 8021q module

**What to Look For**:
```bash
# In test output, you should see:
[Phase 2] Verifying network configuration...
  n100-1 interfaces:
eth1             DOWN
eth1.100         UP             192.168.100.1/24
eth1.200         UP             192.168.200.1/24
```

---

### Phase 4: Bonding + VLANs (Full Production)

**Goal**: Validate bonding with VLAN tagging (matches hardware deployment).

```bash
# This test requires more resources (2 NICs per node)
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans' --rebuild --print-build-logs
```

**Expected Behavior**:
1. **Duration**: 7-20 minutes (bonding adds overhead)
2. **Network Stack**:
   ```
   eth1, eth2          (bonded slaves, no IP)
   bond0               (active-backup bond, no IP)
   bond0.200           192.168.200.x/24  (cluster VLAN)
   bond0.100           192.168.100.x/24  (storage VLAN)
   ```
3. **Bonding Mode**: active-backup (eth1 primary)
4. **VLAN on Bond**: VLANs tagged on bond0, not physical interfaces
5. **k3s**: Uses bond0.200 for cluster communication

**Validation Checklist**:
- ✅ Bond0 created with eth1 and eth2 as slaves
- ✅ Active-backup mode configured
- ✅ VLANs created on bond0 (not eth1/eth2)
- ✅ k3s cluster forms over bond0.200
- ✅ Failover capability (eth1 can fail, bond0 stays up)

**Success Criteria**:
- ✅ Bond interface shows both slaves
- ✅ VLANs correctly attached to bond
- ✅ k3s cluster operational
- ✅ Test passes with all nodes Ready

**What to Look For**:
```bash
# In test output, you should see:
[Phase 2] Verifying network configuration...
  n100-1 interfaces:
eth1             UP             (slave to bond0)
eth2             UP             (slave to bond0)
bond0            UP
bond0.100        UP             192.168.100.1/24
bond0.200        UP             192.168.200.1/24
```

---

## Interactive Debugging

If any test fails, use interactive mode to investigate:

```bash
# Build interactive driver
nix build '.#checks.x86_64-linux.k3s-cluster-vlans.driverInteractive'

# Launch interactive test
./result/bin/nixos-test-driver

# Inside Python REPL:
>>> start_all()
>>> n100_1.succeed("ip addr show")
>>> n100_1.succeed("ip -d link show | grep vlan")
>>> n100_1.succeed("systemctl status k3s")
>>> n100_1.succeed("k3s kubectl get nodes")
```

**Useful Commands**:
```python
# Check VLAN configuration
n100_1.succeed("ip -d link show eth1.200")
n100_1.succeed("cat /proc/net/vlan/eth1.200")

# Check k3s flannel interface
n100_1.succeed("k3s kubectl get nodes -o wide")
n100_1.succeed("ps aux | grep flannel")

# Check kernel modules
n100_1.succeed("lsmod | grep 8021q")

# Get shell access
n100_1.shell_interact()
```

---

## Expected Warnings (Safe to Ignore)

These warnings are expected and do not indicate failures:

1. **k3s token warning**:
   ```
   warning: `services.k3s.tokenFile` is not set, which is insecure
   ```
   **Reason**: Agent roles expect tokenFile to be set via sops-nix in production. Tests use `pkgs.writeText` for convenience.

2. **Root password conflict**:
   ```
   warning: The option `users.users.root.password' has conflicting definitions
   ```
   **Reason**: Tests override base.nix password for test-friendly authentication.

3. **systemd.network + useDHCP**:
   ```
   warning: Both systemd.network and networking.useDHCP are enabled
   ```
   **Reason**: Test VMs need both for compatibility with nixosTest framework.

---

## Troubleshooting

### Test Runs Too Fast (6-10 seconds)

**Symptom**: Test completes in seconds, no VM boot logs visible.

**Cause**: Nix cached the result from previous successful run.

**Solution**:
```bash
# Force rebuild
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild

# Or delete cached result first
nix store delete /nix/store/*-vm-test-run-k3s-cluster-vlans
nix build '.#checks.x86_64-linux.k3s-cluster-vlans'
```

---

### VLAN Interfaces Not Created

**Symptom**: Test shows only eth1, no eth1.200 or eth1.100.

**Possible Causes**:
1. 8021q module not loaded
2. systemd-networkd not started
3. Network profile not applied

**Debug**:
```bash
# Interactive mode
nix build '.#checks.x86_64-linux.k3s-cluster-vlans.driverInteractive'
./result/bin/nixos-test-driver

# Check kernel module
>>> n100_1.succeed("lsmod | grep 8021q")

# Check systemd-networkd
>>> n100_1.succeed("systemctl status systemd-networkd")

# Check network configuration
>>> n100_1.succeed("networkctl status")
>>> n100_1.succeed("ls -la /etc/systemd/network/")
```

---

### k3s Cluster Formation Fails

**Symptom**: Nodes don't reach Ready state or timeout.

**Possible Causes**:
1. Network interface misconfiguration
2. Flannel can't create VXLAN overlay
3. API server unreachable

**Debug**:
```bash
# Check k3s service
>>> n100_1.succeed("systemctl status k3s")
>>> n100_1.succeed("journalctl -u k3s | tail -50")

# Check flannel
>>> n100_1.succeed("k3s kubectl get pods -n kube-system | grep flannel")
>>> n100_1.succeed("k3s kubectl logs -n kube-system -l app=flannel")

# Check node status
>>> n100_1.succeed("k3s kubectl get nodes -o yaml")
>>> n100_1.succeed("k3s kubectl describe node n100-1")
```

---

### Out of Memory

**Symptom**: Test VM freezes or kernel OOM kills processes.

**Solution**:
```bash
# Check available memory
free -h

# Reduce VM memory in interactive debugging:
# Edit vmConfig.memorySize in mk-k3s-cluster-test.nix (default: 3072 MB)

# Or close other applications to free RAM
```

---

## Reporting Issues

When reporting test failures, include:

1. **Platform**: Native Linux / WSL2 / Darwin / Cloud
2. **Test Name**: simple / vlans / bonding-vlans
3. **Failure Phase**: Which test phase failed
4. **Error Output**: Last 50-100 lines of test output
5. **System Info**:
   ```bash
   uname -a
   nix --version
   free -h
   ls -la /dev/kvm
   ```

6. **Test Command Used**:
   ```bash
   # Example
   nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild --print-build-logs
   ```

7. **Interactive Debug Output** (if applicable):
   ```python
   >>> n100_1.succeed("ip addr show")
   >>> n100_1.succeed("systemctl status k3s")
   ```

---

## Success Metrics

All three tests should:

✅ **Build successfully** - No Nix evaluation errors
✅ **Boot 3 VMs** - systemd reaches multi-user.target
✅ **Configure networks** - Interfaces created with correct IPs
✅ **Form k3s cluster** - All 3 nodes reach Ready state
✅ **Deploy system pods** - CoreDNS and local-path-provisioner Running
✅ **Complete test phases** - All 8 phases pass
✅ **Exit cleanly** - Result symlink created

---

## Next Steps After Validation

Once all three tests pass:

1. **Update GitHub Actions / GitLab CI**: Add new tests to CI pipeline
2. **Hardware Deployment**: Use VLAN tests as pre-deployment validation
3. **Production Config**: Enable VLANs in `hosts/*/configuration.nix`
4. **External Switch**: Configure trunk ports with VLAN 100, 200

---

## Files Modified in This Implementation

```
lib/network/profiles/
├── simple.nix                            # Baseline profile
├── vlans.nix                             # VLAN tagging profile
├── bonding-vlans.nix                     # Bonding + VLANs profile
├── dhcp-simple.nix                       # DHCP-based simple profile
└── vlans-broken.nix                      # Negative test profile

tests/lib/
└── mk-k3s-cluster-test.nix              # Parameterized test builder

flake.nix                                 # Test variants registered
docs/VLAN-TESTING-GUIDE.md                # This guide
```

---

## Contact & Feedback

After testing, provide feedback on:
- Which tests passed/failed
- Platform tested on
- Any unexpected behavior
- Performance issues
- Documentation clarity

This will help improve the implementation before hardware deployment.
