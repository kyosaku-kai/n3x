# Platform Notes: Hyper-V Nested Virtualization

**Context**: n3x uses NixOS test VMs (QEMU/KVM) running inside WSL2. Understanding nesting limits is critical for test infrastructure design.

## Nesting Depth Limit: Two Levels Maximum

Hyper-V's Enlightened VMCS architecture supports exactly two hypervisor levels. L0 (Hyper-V) communicates with L1 (KVM in WSL2) via the eVMCS paravirtualized protocol. There is no recursive component — L2 is the deepest supported guest.

| Level | Component | Status |
|-------|-----------|--------|
| L0 | Hyper-V on Windows 11 | Physical hypervisor |
| L1 | WSL2 Linux kernel | Lightweight VM with eVMCS |
| L2 | QEMU/KVM VM (NixOS tests) | Works |
| L3 | VM inside L2 | Hangs indefinitely |

**Why**: eVMCS v1 disables Shadow VMCS, VMX preemption timer, posted interrupts, and APICv — all required for deeper nesting. Microsoft's TLFS defines no L3 terminology. Red Hat docs: "L3 guests have not been properly tested and are not expected to work."

**No workarounds exist**: No kernel parameters, QEMU options, or Windows versions enable L3. Disabling eVMCS removes optimization but keeps the same depth limit.

## Architecture Decision: Eliminate L2 for n3x

The original architecture considered running an OVS VM (L2) containing k3s node VMs (L3). This was rejected due to the L3 limit.

**Adopted approach**: Run k3s VMs directly from L1 (WSL2), making them L2 guests:

```
L0: Windows 11 (Hyper-V)
└── L1: WSL2 NixOS
    ├── QEMU VM: k3s server (L2) — works
    ├── QEMU VM: k3s agent-1 (L2) — works
    └── QEMU VM: k3s agent-2 (L2) — works
```

The NixOS test driver manages multi-VM coordination at L1. Network isolation uses virtual bridges (VDE switches) instead of OVS in a separate VM.

**Containers in L2 are fine**: Containers use namespaces/cgroups (kernel features), not virtualization. A container in an L2 VM adds no nesting layer.

## Performance: L2 vs L3

| Operation | L3 (rejected) | L2 (adopted) |
|-----------|---------------|--------------|
| Container startup | Broken / very slow | Seconds |
| Network latency | Extreme | ~1-2ms overhead |
| Memory overhead | 3x translation walks | 2x translation walks |
| CPU-bound workload | 30-50% overhead | 10-20% overhead |

## References

- Microsoft Hyper-V TLFS: Enlightened VMCS specification
- Red Hat docs: "Use of L2 VMs as hypervisors and creating L3 guests is not expected to work"
- QEMU `hv-evmcs` enlightenment documentation
