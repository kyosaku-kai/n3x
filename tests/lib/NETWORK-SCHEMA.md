# Unified Network Schema (A4)

This document defines the unified network schema used by all network profiles in the n3x test infrastructure. The schema is designed to scale from simple single-interface configurations to complex multi-VLAN setups, while remaining consumable by both NixOS modules and Debian backend systemd-networkd file generation.

## Schema Overview

```
networkConfig = {
  # Named logical interfaces (what test scripts reference)
  interfaces = {
    cluster = "eth1";           # K3s and inter-node traffic
    storage = "eth1.100";       # Longhorn/storage traffic (optional)
    # external = "eth0";        # NAT/DHCP (implicit, managed by test harness)
  };

  # IP assignments per system per interface
  ipAddresses = {
    "server-1" = { cluster = "192.168.1.1"; };
    "server-2" = { cluster = "192.168.1.2"; };
    "agent-1"  = { cluster = "192.168.1.3"; };
    "agent-2"  = { cluster = "192.168.1.4"; };
  };

  # VLAN IDs (only present if VLANs are used)
  vlanIds = {
    cluster = 200;
    storage = 100;
  };

  # Bonding configuration (only present if bonding is used)
  bondConfig = {
    mode = "active-backup";
    primary = "eth1";
    miimon = 100;
  };

  # K3s-specific network params
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";
};
```

## Interface Keys (Semantic Names)

| Key | Purpose | Required |
|-----|---------|----------|
| `cluster` | K3s control plane and pod traffic, flannel CNI | Yes |
| `storage` | Longhorn replication, iSCSI traffic | Optional |
| `external` | NAT/DHCP for internet access | Implicit |
| `trunk` | Parent interface for VLANs (when used) | Only with VLANs |

## VLAN Notation

VLANs are encoded in the interface name itself:

- **Flat network**: `eth1` (no VLAN)
- **VLAN 200 on eth1**: `eth1.200`
- **VLAN 100 on bond0**: `bond0.100`

This allows test scripts to remain agnostic to whether they're using VLANs or not - they just reference the interface name.

## Profile Complexity Levels

### Simple (Baseline)
```nix
interfaces = { cluster = "eth1"; };
ipAddresses = { "server-1" = { cluster = "192.168.1.1"; }; ... };
# No vlanIds, no bondConfig
```

### VLANs (Multi-Network)
```nix
interfaces = {
  trunk = "eth1";
  cluster = "eth1.200";
  storage = "eth1.100";
};
ipAddresses = {
  "server-1" = { cluster = "192.168.200.1"; storage = "192.168.100.1"; };
  ...
};
vlanIds = { cluster = 200; storage = 100; };
```

### Bonding + VLANs (Maximum Complexity)
```nix
interfaces = {
  trunk = "bond0";
  cluster = "bond0.200";
  storage = "bond0.100";
  bondMembers = [ "eth1" "eth2" ];
};
ipAddresses = { ... };
vlanIds = { cluster = 200; storage = 100; };
bondConfig = { mode = "active-backup"; primary = "eth1"; miimon = 100; };
```

**Status**: Implemented and passing for both NixOS and Debian backends (Plan 012, Plan 019).

## Machine Names

All profiles support these standard machine names (from `machine-roles.nix`):

| Machine | Role | Typical Use |
|---------|------|-------------|
| `server-1` | K3s server (primary) | Control plane, HA leader |
| `server-2` | K3s server (secondary) | Control plane, HA member |
| `agent-1` | K3s agent | Workload node |
| `agent-2` | K3s agent | Workload node |

Topology patterns:
- **2s+1a**: 2 servers (HA) + 1 agent
- **1s+2a**: 1 server + 2 agents (workload scaling)

## Profile Exports

Each profile exports these attributes:

| Attribute | Type | Purpose |
|-----------|------|---------|
| `nodeIPs` / `clusterIPs` / `storageIPs` | attrset | Legacy IP lookups |
| `ipAddresses` | attrset | Unified IP map (P2.1) |
| `interfaces` | attrset | Interface name map (P2.1) |
| `vlanIds` | attrset | VLAN ID map (if applicable) |
| `bondConfig` | attrset | Bonding params (if applicable) |
| `serverApi` | string | K3s API endpoint URL |
| `clusterCidr` | string | K3s pod CIDR |
| `serviceCidr` | string | K3s service CIDR |
| `nodeConfig` | function | NixOS module generator |
| `k3sExtraFlags` | function | K3s flags generator |

## Debian Backend systemd-networkd Generation

Debian backends use `ipAddresses`, `interfaces`, and `vlanIds` to generate systemd-networkd `.network` and `.netdev` files via `lib/network/mk-systemd-networkd.nix`:

```ini
# Generated from vlans profile for server-1

# 10-trunk.network
[Match]
Name=eth1

[Network]
VLAN=eth1.200
VLAN=eth1.100

# 20-cluster.netdev
[NetDev]
Name=eth1.200
Kind=vlan

[VLAN]
Id=200

# 20-cluster.network
[Match]
Name=eth1.200

[Network]
Address=192.168.200.1/24
```

## Test Coverage Matrix

```
                simple   vlans   bonding-vlans
L1+ Network     PASS     PASS    PASS          (NixOS + Debian)
L4 Cluster      PASS     PASS    PASS          (NixOS)
L4 Cluster      exists   exists  exists        (Debian — requires image rebuild)
```

See [tests/TEST-COVERAGE.md](../../tests/TEST-COVERAGE.md) for full coverage details.
