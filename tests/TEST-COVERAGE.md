# n3x Test Coverage Analysis

This document provides a critical analysis of the test suite and explains what each test validates.

## Test Coverage Matrix

| Category | Test | What It Tests | Why It Matters | Status |
|----------|------|---------------|----------------|--------|
| **K3s Core** | k3s-single-server | Server initialization, API, system pods, workload deployment | Validates basic K3s control plane | ✅ Passing |
| **K3s Clustering** | k3s-agent-join | Agent registration, 2-node cluster, scheduling | Ensures agents can join cluster | ✅ Passing |
| **K3s Scaling** | k3s-multi-node | 3-node cluster formation, multi-replica workloads | Validates cluster scaling | ✅ Passing |
| **Pod Networking** | k3s-networking | **Pod-to-pod communication, DNS, service discovery** | **CRITICAL: Validates Flannel overlay network** | ✅ Passing |
| **Host Networking** | network-bonding | Bond interface, slave config, active-backup mode | Validates NIC redundancy for production | ✅ Passing |
| **Storage Prerequisites** | longhorn-prerequisites | Kernel modules, iSCSI, filesystems, utilities | Ensures OS is ready for Longhorn | ✅ Passing |
| **NixOS Compatibility** | kyverno-deployment | **Kyverno install, PATH patching policy** | **CRITICAL: Required for Longhorn on NixOS** | ✅ Passing |

## Critical Test Additions

### 1. k3s-networking (NEW - CRITICAL)

**Why this was missing:** Previous tests verified pods could *deploy* but not *communicate*. This is a fundamental requirement for Kubernetes clusters.

**What it validates:**
- ✅ Flannel VXLAN overlay network is functional
- ✅ Pod-to-pod communication across nodes (bi-directional ping)
- ✅ Pod IP assignment and routing
- ✅ Service creation and ClusterIP allocation
- ✅ CoreDNS is running and functional
- ✅ DNS resolution works (pod FQDN, service FQDN)
- ✅ Service discovery via DNS

**Test methodology:**
1. Deploys pods on specific nodes using nodeSelector
2. Retrieves pod IPs from different nodes
3. Tests bidirectional ping between pods on different nodes
4. Creates a Kubernetes service
5. Verifies DNS resolution for services and cluster resources
6. Validates CoreDNS is running

**Why it matters:** Without working pod networking, the cluster is useless. This test validates the fundamental network layer that all applications depend on.

### 2. kyverno-deployment (NEW - CRITICAL)

**Why this was missing:** `longhorn-prerequisites` only checked *prerequisites* but didn't validate Kyverno actually works or that the PATH patching policy functions correctly.

**What it validates:**
- ✅ Kyverno can be deployed via Helm
- ✅ Kyverno admission controller is running
- ✅ Kyverno webhooks are configured
- ✅ ClusterPolicy can be created and becomes ready
- ✅ PATH mutation actually happens for pods in longhorn-system namespace
- ✅ NixOS paths (/nix/var/nix/profiles, /run/current-system/sw/bin) are injected
- ✅ Pod specs are modified by Kyverno mutating webhook

**Test methodology:**
1. Installs Kyverno via Helm with appropriate settings
2. Waits for all Kyverno components to be running
3. Creates the actual PATH patching ClusterPolicy from our codebase
4. Creates a test pod in longhorn-system namespace
5. Verifies the pod's environment has NixOS paths added
6. Validates the pod spec was actually mutated (not just runtime env)

**Why it matters:** Longhorn WILL FAIL on NixOS without this. The PATH patching is absolutely required because Longhorn expects FHS paths (/usr/bin/env) but NixOS uses /nix/store paths. This test proves our compatibility layer works.

## Test Coverage Gaps (Documented for Future Work)

### 1. Actual Longhorn Deployment (Future)
**Status:** Not implemented (complex, resource-intensive)

**Why not included yet:**
- Requires 3+ nodes with significant storage
- Takes 10-15 minutes to fully deploy and stabilize
- Requires CSI driver installation and validation
- Needs volume attach/detach testing

**What it would test:**
- Longhorn manager deployment
- CSI driver functionality
- PVC creation and binding
- Volume attachment to pods
- Data persistence across pod restarts
- Replica distribution across nodes

**Recommendation:** Run manual Longhorn deployment tests in hardware environment first.

### 2. Multi-Server HA Configuration (Future)
**Status:** Not implemented (resource-intensive)

**Why not included yet:**
- Requires 3 server nodes (12GB+ RAM total)
- etcd quorum testing is complex
- Control plane failover testing requires killing nodes

**What it would test:**
- 3-server cluster formation
- etcd distributed consensus
- Control plane failover
- Leader election

**Recommendation:** Test HA configuration during actual deployment phase.

### 3. Network Bonding Failover (Limitation)
**Status:** Partially tested (bond creation verified, failover not tested)

**Why failover not tested:**
- Difficult to simulate NIC failure in VMs reliably
- Would require custom QEMU scripts to disable interfaces
- Active-backup mode failover timing is non-deterministic in VMs

**What is tested:**
- Bond interface creation
- Slave interface configuration
- MII monitoring enabled
- Bond status reporting

**Recommendation:** Test failover manually on physical hardware.

### 4. Storage Network VLAN Isolation (Future)
**Status:** Not implemented

**What it would test:**
- Multus CNI attachment
- VLAN tagging and isolation
- Storage traffic on separate network
- Longhorn using storage network

## Test Execution Recommendations

### During Development
```bash
# Run quick smoke tests
nix build .#checks.x86_64-linux.k3s-single-server
nix build .#checks.x86_64-linux.k3s-networking

# Test networking and storage stack
nix build .#checks.x86_64-linux.network-bonding
nix build .#checks.x86_64-linux.longhorn-prerequisites
nix build .#checks.x86_64-linux.kyverno-deployment
```

### Before Hardware Deployment
```bash
# Run full test suite (takes 15-30 minutes)
nix flake check

# Or run critical path tests
nix build .#checks.x86_64-linux.k3s-multi-node
nix build .#checks.x86_64-linux.k3s-networking
nix build .#checks.x86_64-linux.kyverno-deployment
```

### For CI/CD Integration
```yaml
# GitHub Actions example
- name: Run NixOS Integration Tests
  run: |
    nix flake check --print-build-logs
```

## Test Quality Assessment

### What We Test Well ✅
- K3s installation and initialization
- Cluster formation (single server + agents)
- Pod scheduling across nodes
- **Pod-to-pod networking and DNS (NEW)**
- Network bonding configuration
- Longhorn OS prerequisites
- **Kyverno deployment and PATH patching (NEW)**

### What We Can't Test in VMs ⚠️
- Real NIC failover behavior
- Actual storage performance
- Long-term stability
- Resource exhaustion scenarios
- Production-scale workloads

### What Requires Hardware Testing 🔧
- Longhorn multi-node storage
- Network bonding failover
- VLAN isolation
- Performance benchmarking
- Power failure recovery

## Conclusion

The test suite now provides comprehensive coverage of:
1. **K3s core functionality** - cluster formation, scheduling, scaling
2. **Network infrastructure** - bonding, overlay networking, DNS
3. **Storage prerequisites** - kernel modules, iSCSI, filesystems
4. **NixOS compatibility** - Kyverno PATH patching for Longhorn

**Critical additions made:**
- `k3s-networking` - Validates pod-to-pod communication and DNS (was missing)
- `kyverno-deployment` - Validates actual Kyverno deployment and mutation (was missing)

The test suite now validates the "right things" - not just that components exist, but that they *work together correctly*.

**Next steps:**
1. Run full test suite before hardware deployment
2. Validate Longhorn deployment manually on first physical cluster
3. Document any hardware-specific issues discovered
4. Add hardware-specific tests as patterns emerge
