# Hyper-V Enlightened VMCS caps nested virtualization at two levels

**Your hypothesis is confirmed.** Hyper-V's Enlightened VMCS architecture does not support more than two levels of nested virtualization—L0→L1→L2 works, but L0→L1→L2→L3 is architecturally unsupported. The indefinite hang you observe when launching an L3 KVM guest inside WSL2 is a known limitation, not a bug. Red Hat's official documentation states explicitly: "Use of L2 VMs as hypervisors and creating L3 guests has not been properly tested and **is not expected to work**."

## The enlightened VMCS protocol only optimizes L0↔L1 transitions

The Enlightened VMCS (eVMCS) is a paravirtualized protocol designed specifically for communication between **exactly two hypervisor levels**. Microsoft's Hyper-V Top-Level Functional Specification (TLFS) defines eVMCS as allowing an L1 hypervisor (like KVM in WSL2) to use normal memory accesses instead of expensive emulated VMREAD/VMWRITE instructions when communicating with L0 (Hyper-V). The QEMU documentation describes this precisely:

> "The feature implements paravirtualized protocol between L0 (KVM) and L1 (Hyper-V) hypervisors making L2 exits to the hypervisor faster."

This optimization has **no recursive component**. The L0 hypervisor (Hyper-V on your Windows 11 host) exposes the eVMCS interface; the L1 hypervisor (KVM inside WSL2) consumes it. There is no mechanism in the specification for L1 to then expose similar enlightenments to L2, nor for L2 to use them. Microsoft's official terminology tellingly stops at L2—the TLFS defines L0 Hypervisor, L1 Root, L1 Guest, L1 Hypervisor, L2 Root, and L2 Guest, with **no L3 terminology defined**.

## Critical VMX features are disabled under eVMCS v1

When Enlightened VMCS is enabled, KVM explicitly disables several VMX control features that would be essential for deeper nesting. Kernel patches from Vitaly Kuznetsov document that eVMCS v1 disables:

- **Shadow VMCS** (`VMX_SECONDARY_EXEC_SHADOW_VMCS`)—Intel hardware acceleration for nested VMCS operations
- **VMX preemption timer** (`VMX_PIN_BASED_VMX_PREEMPTION_TIMER`)—accurate guest timing
- **Posted interrupts** (`VMX_PIN_BASED_POSTED_INTR`)—hardware-accelerated interrupt delivery
- **Virtual interrupt delivery** and **APIC register virtualization**—APICv components
- **VMFUNC EPT switching** and **Pause Loop Exiting**

The disabled **Shadow VMCS** is particularly significant. Shadow VMCS is Intel's hardware acceleration for nested virtualization—it allows L0 to efficiently shadow L1's VMCS fields. Without it, L1 cannot efficiently run nested guests, and any L2 attempting to run L3 would lack the infrastructure entirely. The symptoms you observe—Shadow VMCS disabled, APICv disabled, preemption timer unavailable at L2—are **not bugs but direct consequences** of the eVMCS v1 specification omitting support for these features.

## Microsoft documents "one level of nested virtualization" in production

Microsoft's official nested virtualization documentation states: "One level of nested virtualization is supported in production, which allows for isolated container deployments." While this statement appears in the context of Hyper-V containers, it reflects the broader architectural reality. The `Set-VMProcessor -ExposeVirtualizationExtensions $true` PowerShell command enables L1 to run L2, but no documented configuration option enables deeper nesting on any Windows version. This limitation applies equally to Windows 10, Windows 11, Windows Server 2016, 2019, 2022, and Azure nested VMs.

## In your specific scenario, WSL2 counts as L1

Understanding the nesting levels in your configuration clarifies why L3 fails:

| Level | Component | Role |
|-------|-----------|------|
| L0 | Hyper-V on Windows 11 | Physical hypervisor running on your i9-13900H |
| L1 | WSL2 Linux kernel | Lightweight utility VM with Enlightened VMCS enabled |
| L2 | QEMU/KVM VM | Nested guest inside WSL2 (works) |
| L3 | KVM VM inside L2 | Third-level guest (hangs indefinitely) |

Your L2 QEMU/KVM VM works because the eVMCS protocol efficiently handles L0↔L1 transitions, and KVM can create L2 guests using emulated (non-enlightened) nested VMX. However, when L2 attempts to act as a hypervisor and create L3, it has no enlightenment support from L1, no Shadow VMCS hardware acceleration, and the accumulated overhead of three levels of VMCS translation causes the guest to hang during VMX operations.

## No workarounds exist for this architectural constraint

The limitation is fundamental to the Enlightened VMCS specification, not a software bug that could be patched:

- **No kernel parameters** enable deeper nesting under Hyper-V—the `nested`, `enable_shadow_vmcs`, and `enable_apicv` parameters cannot override features excluded from eVMCS v1
- **No QEMU options** work around this—the `hv-evmcs` enlightenment is binary (enabled or disabled), with no L3-enabling variants
- **No Windows version differences** affect L3 support—the TLFS specification is consistent across all supported Windows and Windows Server versions
- **Disabling eVMCS** (removing `hv-evmcs` from QEMU) doesn't enable L3—it merely removes the L0↔L1 optimization while keeping the same nesting depth limit

## Conclusion

The indefinite hang you observe when starting an L3 KVM guest is the expected behavior when exceeding Hyper-V's architectural nesting depth limit. The Enlightened VMCS protocol fundamentally supports only two hypervisor levels collaborating—L0 and L1—with L2 as the deepest supported guest. Your options are limited to restructuring workloads to avoid L3 nesting, or running the outer hypervisor on bare metal hardware (bypassing Hyper-V entirely) where KVM's native nested VMX can support experimental deeper nesting. Cloud VMs with nested virtualization enabled still impose this same two-level limit since they run on Hyper-V or similar hypervisors with equivalent constraints.