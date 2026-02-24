# CI Test Failure Modes — Diagnosis and Remediation

This document catalogs test failure patterns observed across different execution environments (WSL2 local, GitHub Actions, and future GitLab CI runners). Many failures are environmental — caused by resource constraints, timing differences, or hypervisor behavior — rather than actual code bugs. Understanding these patterns prevents misdiagnosis and wasted debugging effort.

**Golden rule**: If a test passes locally but fails in CI (or vice versa), investigate the environment before assuming a code bug.

## Environmental Differences That Cause Failures

| Factor | Local (WSL2) | GitHub Actions | GitLab CI (future) |
|--------|-------------|----------------|-------------------|
| CPU cores | 8-20 (shared with host) | 4 vCPU (ubuntu-latest) | Configurable |
| RAM | 16-32 GB | ~7 GB free | Configurable |
| KVM | Host CPU passthrough | Nested virt (slower) | Depends on runner |
| Disk I/O | NVMe via 9p/virtio | Ephemeral SSD | Depends on runner |
| Network | VDE switches, local | VDE switches, shared | VDE switches |
| Concurrency | Sequential (typically) | 20 jobs parallel | Configurable |
| Nix store | Persistent, warm cache | Cold, rebuilt each run | Persistent (self-hosted) |

The key constraint: **cluster tests run 2-3 QEMU VMs each requesting 4 vCPU and 3-4 GB RAM on a runner with only 4 real vCPUs.** This creates severe CPU oversubscription that amplifies every timing-sensitive operation.

## Failure Catalog

### FM-1: etcd Quorum Loss Under Resource Pressure

**Observed in**: CI run 3 (k3s-cluster-bonding-vlans, NixOS Tier 3)

**Symptom**: Test fails at `succeed("k3s kubectl get nodes -o wide")` — the k3s API server is down.

**Root cause chain**:
1. 2-member etcd cluster requires 2/2 members for quorum
2. CI runner's 4 vCPU is oversubscribed by 2 QEMU VMs × 4 vCPU each
3. CPU starvation causes TCP connection drop between etcd peers
4. With only 2 members, losing one = losing quorum
5. k3s detects quorum loss and shuts down cleanly
6. Test's `succeed()` call hits a dead API server → test fails

**Why it works locally**: More CPU headroom means etcd peer connections stay alive.

**Diagnosis pattern**:
```
# In k3s/etcd logs:
"lost leader" or "leader changed"
"member ... is unreachable"
"etcdserver: request timed out"
# Then:
k3s-server.service: Main process exited, code=exited, status=1/FAILURE
```

**Fix applied** (commit `33e5797`):
1. Use `execute()` instead of `succeed()` for informational commands — test doesn't abort on transient unavailability
2. Use `wait_until_succeeds()` where the result matters but may need retry
3. Apply `joiningNodeK3sRestartConfig` to ALL network profiles — k3s auto-recovers after etcd disruption via `Restart=on-failure` + `RestartSec=5`
4. Add explicit post-join etcd health re-check — wait for cluster stability before proceeding

**Design principle**: In 2-member etcd, any disruption is fatal. Tests must tolerate transient k3s unavailability during cluster formation. Use `succeed()` only for commands where failure means the test SHOULD abort.

---

### FM-2: Stale k3s Bootstrap Data from Auto-Start Race

**Observed in**: CI run 4 (debian-vlans, Debian Tier 5)

**Symptom**: `panic: bootstrap data already found and encrypted with different token`

**Root cause chain**:
1. ISAR images ship with k3s-server enabled in `multi-user.target.wants` and a pre-baked token (`test-cluster-fixed-token-for-automated-testing`) at `/var/lib/rancher/k3s/server/token`
2. When the VM boots, systemd auto-starts k3s-server before the test script runs
3. k3s initializes its etcd database and encrypts bootstrap data using the baked token
4. The test's Phase 3 stops k3s (line 664-666) but does NOT clean the data directory
5. Phase 4 starts server-1 with `--cluster-init`, which generates a NEW token
6. Phase 5 injects server-1's new token into server-2 and starts k3s
7. k3s finds local bootstrap data encrypted with the OLD baked token → panic

**Why it works locally**: Less resource contention means k3s often doesn't fully initialize before Phase 3 stops it. The window is shorter.

**Diagnosis pattern**:
```
# k3s log on the joining server:
panic: bootstrap data already found and encrypted with different token
goroutine 331 [running]:
github.com/k3s-io/k3s/pkg/cluster.(*Cluster).Start.func1()

# systemd status:
k3s-server.service: Main process exited, code=exited, status=2/INVALIDARGUMENT
```

**Fix applied** (commit `8f8a6dd`):
```python
# In Phase 3, after stopping k3s:
server_1.execute("rm -rf /var/lib/rancher/k3s/server/db 2>&1 || true")
server_2.execute("rm -rf /var/lib/rancher/k3s/server/db 2>&1 || true")
```

**Design principle**: Any service that auto-starts at boot and creates persistent state must have that state cleaned before the test takes control. Never assume `systemctl stop` is sufficient — stale state on disk survives the stop.

---

### FM-3: ISAR Output Filename Collision in Multi-Variant Builds

**Observed in**: CI run 2 (debian-simple, debian-vlans, debian-bonding, Tier 5)

**Symptom**: Wrong ISAR image registered in Nix store; test boots server-2's image as server-1 (or vice versa), causing k3s configuration mismatches.

**Root cause chain**:
1. ISAR produces the same output filename for both server-1 and server-2 variants of the same network profile (e.g., `n3x-image-server-debian-trixie-qemuamd64.wic`)
2. The CI workflow built ALL variants first, then registered ALL artifacts
3. server-2's build overwrote server-1's output file before it could be registered
4. `isar-build-all --rename-existing` copied the wrong file

**Diagnosis pattern**:
```
# Test boots but k3s has wrong IP/flags configured
# Or: k3s starts but can't reach the expected peer
# The .wic file hash doesn't match what was expected
```

**Fix applied** (commit `b3e89f3`):
Interleave build and register operations per variant instead of batching:
```bash
# WRONG: build all, then register all
for v in $variants; do build $v; done
for v in $variants; do register $v; done

# RIGHT: build+register each variant before moving to next
for v in $variants; do build $v && register $v; done
```

**Design principle**: When multiple build variants share the same output filename, always register/rename immediately after building — never batch builds across variants that collide.

---

### FM-4: TCP Establishment Latency on Bonded VDE Interfaces

**Observed in**: Local WSL2 (k3s-cluster-bonding-vlans, originally Plan 019)

**Symptom**: k3s on server-2 times out fetching `/cacerts` from server-1:6443. The secondary server fails to join the cluster.

**Root cause chain**:
1. Bonded VDE virtual interfaces have ~7 second TCP establishment latency on the first connection
2. k3s has internal timeouts for the initial `/cacerts` HTTPS fetch
3. The first TCP SYN/SYN-ACK takes abnormally long through the bond→VLAN→VDE stack
4. Subsequent connections are fast (ARP cache populated, bond interface "warmed up")

**Diagnosis pattern**:
```
# ICMP (ping) works immediately
# TCP connection attempt hangs for ~7 seconds before succeeding
# k3s logs: "failed to get CA certs" or "connection timed out"
# Second attempt works immediately
```

**Fix applied** (in `mk-debian-cluster-test.nix` Phase 5):
```python
# Pre-warm TCP connection before starting k3s
for attempt in range(3):
    warmup_code, warmup_out = server_2.execute(
        "timeout 15 curl -sk https://server-1:6443/cacerts 2>&1"
    )
    if warmup_code == 0 or "cacerts" in warmup_out.lower():
        break
    time.sleep(2)
```

**Design principle**: Never assume TCP connectivity is instant just because ICMP works. Virtual network stacks (VDE, bonds, VLANs) can have significant first-packet latency. Always pre-warm connections before timing-sensitive operations.

---

### FM-5: QEMU vCPU Oversubscription Warning

**Observed in**: All CI runs (informational, non-fatal)

**Symptom**: QEMU warning in test output:
```
qemu-system-x86_64: warning: Number of SMP cpus requested (4) exceeds
the recommended cpus supported by KVM (2)
```

**Root cause**: GitHub Actions `ubuntu-latest` runners have 4 vCPUs total. Each test VM requests 4 vCPUs. With 2-3 VMs, the total vCPU request far exceeds available physical CPUs. KVM warns but allows it (CPU time-slicing).

**Impact**: Not a direct failure, but contributes to FM-1 (etcd quorum loss) and FM-2 (auto-start race window) by making all operations slower and less predictable.

**Mitigation options** (not yet implemented):
- Reduce VM vCPU count in CI (e.g., 2 instead of 4) — but changes k3s/etcd behavior
- Use larger runners (8+ vCPU) — costs money on private repos
- Self-hosted runners with adequate resources — the GitLab CI path

---

### FM-6: `sgdisk` Sync Hang on WSL2 9p Mounts

**Observed in**: Local WSL2 only (ISAR builds, not tests)

**Symptom**: ISAR build hangs indefinitely during WIC image generation.

**Root cause**: `sgdisk` calls `sync()` which hangs on 9p filesystem mounts in WSL2. The kas-container wrapper's mount management prevents this by unmounting 9p mounts before the build.

**Not applicable to CI**: GitHub Actions runners use native ext4, not 9p.

---

### FM-7: Download Cache Architecture Collision

**Observed in**: CI (when building for multiple architectures)

**Symptom**: ISAR build succeeds but the resulting image contains the wrong architecture's k3s binary (e.g., x86_64 binary on an arm64 image, or vice versa).

**Root cause**: The k3s BitBake recipe uses `downloadfilename=k3s` for both x86_64 and arm64 architectures. When builds for different architectures share a download cache, the cached binary may be the wrong architecture.

**Fix applied** (in CI workflow):
```yaml
# Split download cache by runner architecture
key: isar-dl-X64-${{ hashFiles(...) }}   # on x86_64 runners
key: isar-dl-ARM64-${{ hashFiles(...) }} # on arm64 runners
```

**TODO**: Fix the k3s recipe to use architecture-specific `downloadfilename` (e.g., `k3s-amd64`, `k3s-arm64`) to eliminate the collision at the source.

---

## General Diagnosis Framework

When a test fails in CI but passes locally, work through this checklist:

### 1. Is it a timing issue?

**Indicators**:
- Test passes on retry (or passed in a previous/subsequent CI run)
- Failure involves `succeed()` hitting a service that should be running
- etcd/k3s logs show "slow" operations or timeouts
- QEMU oversubscription warnings present

**Actions**:
- Replace `succeed()` with `execute()` for informational commands
- Add `wait_until_succeeds()` with appropriate timeout for verification commands
- Add explicit readiness checks before proceeding to next phase
- Pre-warm TCP connections before timing-sensitive service operations

### 2. Is it a state issue?

**Indicators**:
- Failure mentions "already exists" or "encrypted with different token"
- Service exits with status 2 (INVALIDARGUMENT)
- Behavior differs between first-run and re-run

**Actions**:
- Check if a service auto-started at boot before the test could configure it
- Clean persistent state directories after stopping services
- Verify no stale configuration survives from image build-time to test-time

### 3. Is it a resource issue?

**Indicators**:
- OOM killer messages in `dmesg`
- Very slow operations (build logs show multi-second pauses)
- etcd election timeouts or leader changes
- "out of disk space" errors

**Actions**:
- Check runner specifications (vCPU, RAM, disk)
- Consider reducing VM resource requests for CI
- Use `jlumbroso/free-disk-space` (x86 only) or manual cleanup
- Monitor disk usage in post-run steps

### 4. Is it a build artifact issue?

**Indicators**:
- Wrong binary architecture or image contents
- "file not found" during artifact registration
- Hash mismatches

**Actions**:
- Verify cache keys include architecture
- Check for output filename collisions across variants
- Ensure build+register operations are interleaved, not batched

## CI Run History

Tracking CI run outcomes helps identify patterns. Persistent failures on the same test suggest a code issue; rotating failures across different tests suggest environmental flakiness.

| Run | ID | Result | Failed Job | Root Cause | Fix |
|-----|-----|--------|-----------|------------|-----|
| 1 | `22269371949` | Partial | (cancelled) | Superseded by run 2 | — |
| 2 | `22269505832` | 16/20 | debian-simple/vlans/bonding | FM-3: filename collision | Interleave build+register |
| 3 | `22269961203` | 19/20 | nixos-bonding-vlans | FM-1: etcd quorum loss | execute()/wait_until_succeeds() |
| 4 | `22271718514` | 19/20 | debian-vlans | FM-2: stale bootstrap data | Clean k3s db in Phase 3 |
| 5 | `22278429840` | 20/20 | — | — | — |

## Environment-Specific Notes

### GitHub Actions Runners

- `ubuntu-latest` (x86_64): 4 vCPU, 16 GB RAM, ~14 GB free disk (after cleanup), KVM available
- `ubuntu-24.04-arm` (arm64): Cobalt 100 ARM, KVM available, `--privileged` Docker works, `jlumbroso/free-disk-space` action does NOT support ARM64 — use manual cleanup
- Magic Nix Cache may return HTTP 418 (rate limited) — non-fatal, just slower

### WSL2

- KVM available via host CPU passthrough (no nested virt)
- 9p mounts can cause `sgdisk` sync hangs (handled by kas-build wrapper)
- Typically more CPU/RAM headroom than CI runners
- `wsl --shutdown` is the nuclear recovery option for stuck mounts/processes

### Future GitLab CI

- Self-hosted runners allow control over vCPU, RAM, and disk resources
- Persistent Nix store and ISAR caches will eliminate cold-cache overhead
- KVM support depends on runner executor (shell executor on bare metal recommended for VM tests)
- Auto-scaling can be configured to provide adequate resources per job
- Same failure modes apply — resource-constrained runners will see the same timing issues
