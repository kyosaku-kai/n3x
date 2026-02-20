# DHCP Test Infrastructure

This document describes the DHCP networking support in n3x's test infrastructure, including the architectural decisions and their rationale.

## Overview

The n3x test infrastructure supports DHCP-based IP assignment for test VMs, enabling testing of DHCP client behavior in both NixOS and Debian backends. This matches production environments that use DHCP and validates the full network initialization path.

## Architecture Decision: Service VM Approach

### The Problem

NixOS test driver creates **VDE (Virtual Distributed Ethernet) switches** for inter-VM networking. These VDE switches are:

1. **Isolated networks** - Each `virtualisation.vlans` entry creates a separate VDE switch
2. **Not accessible from the host** - The test driver runs QEMU processes but doesn't join their networks
3. **No bridge to host networking** - Unlike Docker's bridge mode, VDE switches have no host-side interface

This means **host-side DHCP servers cannot serve VMs on VDE networks**.

### Why NOT Host-Side dnsmasq

A naive approach might be to run dnsmasq on the test driver host:

```
┌─────────────────────────────────────────┐
│ Test Driver Host                         │
│  ├── dnsmasq (DHCP server)              │  ← Cannot reach VMs!
│  │                                       │
│  └── QEMU processes                     │
│      ├── server-1 ─┐                    │
│      ├── server-2 ──├── VDE Switch      │  ← Isolated network
│      └── agent-1  ─┘                    │
└─────────────────────────────────────────┘
```

The VDE switch exists only between the QEMU processes. There's no tap interface on the host to connect dnsmasq.

### Why NOT Kubernetes-Style Node Running DHCP

Running the DHCP server on one of the k3s nodes creates circular dependencies:

```
server-1 ────► DHCP server ────► IP assignment ────► Boot
    ↑                                                  │
    └──────────────────────────────────────────────────┘
    Circular: Server needs IP to boot, but runs DHCP server
```

Additionally:
- Complicates k3s configuration (one node becomes "special")
- Harder to test DHCP client behavior on the DHCP server node itself
- Breaks the symmetry of cluster tests

### Chosen Approach: Dedicated Service VM

A dedicated `dhcp-server` VM joins the same VDE network as cluster nodes:

```
┌─────────────────────────────────────────────────────────────────┐
│                     NixOS Test Driver                           │
│                                                                 │
│  ┌──────────────┐   VDE Switch (vlan1)   ┌──────────────┐      │
│  │ dhcp-server  │◄──────────────────────►│  server-1    │      │
│  │              │        ▲               │  DHCP client │      │
│  │ dnsmasq      │        │               │  k3s server  │      │
│  │ 192.168.1.254│        │               │  192.168.1.1 │      │
│  └──────────────┘        │               └──────────────┘      │
│                          │                                      │
│                          ├───────────────┐                      │
│                          │               │                      │
│                 ┌────────┴───────┐ ┌─────┴────────┐            │
│                 │  server-2      │ │  agent-1     │            │
│                 │  DHCP client   │ │  DHCP client │            │
│                 │  k3s server    │ │  k3s agent   │            │
│                 │  192.168.1.2   │ │  192.168.1.3 │            │
│                 └────────────────┘ └──────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

**Benefits**:
- DHCP server is on the same VDE network as cluster nodes
- No circular dependencies - dhcp-server boots first, then cluster
- Clean separation of concerns
- Proven pattern used in `tests/emulation/embedded-system.nix`

## Related Work: NixOS VM Test Infrastructure

### Current State (as of 2026-02)

The NixOS test infrastructure uses **VDE switches** for inter-VM networking. This is a mature, stable approach that works reliably across platforms (Linux, WSL2, Darwin via Lima).

### Upstream Work: systemd-nspawn Containers (PR #478109)

There is ongoing upstream work in nixpkgs to add **systemd-nspawn container support** to the NixOS test driver:

- **PR**: [nixpkgs#478109](https://github.com/NixOS/nixpkgs/pull/478109)
- **Purpose**: Speed up tests by using containers instead of VMs
- **Networking**: Extends VDE support, doesn't replace it
- **Status**: Under development, not yet merged

**Key insight**: This PR extends the existing VDE networking model. Containers would join VDE networks just like VMs do. The service VM approach for DHCP is compatible with both QEMU VMs and potential future nspawn containers.

### Implications for DHCP Architecture

1. **VDE remains the network abstraction** - Both VMs and containers use VDE
2. **Service VM pattern is forward-compatible** - DHCP server VM works whether cluster nodes are VMs or containers
3. **No architectural changes needed** - Our approach aligns with nixpkgs direction

### References

- NixOS test driver source: `nixpkgs/nixos/lib/test-driver/`
- VDE networking: `qemu-vm.nix` virtualisation.vlans
- Existing DHCP pattern: `n3x/tests/emulation/embedded-system.nix`

## Implementation Details

### MAC Address Scheme

Deterministic MACs enable MAC-based DHCP reservations:

```
52:54:00:CC:NN:HH

52:54:00   - QEMU locally administered OUI
CC         - Cluster ID (01 = default test cluster)
NN         - Network type (01 = cluster, 02 = storage)
HH         - Host number (01 = server-1, 02 = server-2, etc.)
```

| Node | MAC Address | Reserved IP |
|------|-------------|-------------|
| dhcp-server | 52:54:00:01:01:00 | 192.168.1.254 |
| server-1 | 52:54:00:01:01:01 | 192.168.1.1 |
| server-2 | 52:54:00:01:01:02 | 192.168.1.2 |
| agent-1 | 52:54:00:01:01:03 | 192.168.1.3 |
| agent-2 | 52:54:00:01:01:04 | 192.168.1.4 |

### dnsmasq Configuration

The dhcp-server VM runs dnsmasq with:

```nix
services.dnsmasq = {
  enable = true;
  settings = {
    interface = "eth1";
    bind-interfaces = true;
    dhcp-range = [ "192.168.1.100,192.168.1.200,12h" ];
    dhcp-host = [
      "52:54:00:01:01:01,server-1,192.168.1.1"
      "52:54:00:01:01:02,server-2,192.168.1.2"
      "52:54:00:01:01:03,agent-1,192.168.1.3"
    ];
  };
};
```

### Boot Sequence

```
1. dhcp-server.start()
2. dhcp-server.wait_for_unit("dnsmasq.service")
3. server_1.start(), server_2.start(), agent_1.start()  # parallel
4. server_1.wait_until_succeeds("ip addr show eth1 | grep '192.168.1.1'")
5. # Continue with K3s setup
```

### VLAN Considerations

**Phase 1 (Plan 019)**: Flat network only (`dhcp-simple` profile)

**Why defer VLAN DHCP**:
- DHCP broadcasts don't cross VLAN boundaries
- DHCP relay (RFC 3046) adds complexity
- Production VLAN environments often use static IP
- Limited testing value vs. implementation cost

**Future Phase 2** (not in Plan 019):
- `dhcp-vlans` with DHCP relay on dhcp-server node
- dhcp-server needs VLAN interfaces (eth1.100, eth1.200)
- Each VLAN gets separate DHCP range

## File Locations

| Component | File |
|-----------|------|
| DHCP profile data | `lib/network/profiles/dhcp-simple.nix` |
| DHCP server config | `tests/lib/test-scripts/phases/dhcp.nix` |
| Test builder | `tests/lib/mk-k3s-cluster-test.nix` |
| Debian DHCP overlay | `backends/debian/kas/network/dhcp-simple.yml` |

## See Also

- [Test Framework README](../tests/README.md)
- [Plan 019: Test Infrastructure Hardening](../.claude/user-plans/archive/019-test-infrastructure-hardening.md)
- [Embedded System Emulator](../tests/emulation/embedded-system.nix) - Reference dnsmasq pattern
