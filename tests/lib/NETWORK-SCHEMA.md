# Unified Network Schema (A4)

This document defines the unified network schema used by all network profiles in the n3x test infrastructure. The schema is designed to scale from simple single-interface configurations to complex multi-VLAN setups, while remaining consumable by both NixOS modules and ISAR netplan generation.

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

### Bonding + VLANs (Maximum Complexity) - DEFERRED
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

**Note**: Bonding tests are deferred indefinitely per Architecture Review decision (2026-01-26).

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

## ISAR Netplan Generation

ISAR backends use `ipAddresses`, `interfaces`, and `vlanIds` to generate netplan YAML:

```yaml
# Generated from vlans profile for server-1
network:
  version: 2
  ethernets:
    eth1: {}
  vlans:
    eth1.200:
      id: 200
      link: eth1
      addresses:
        - 192.168.200.1/24
    eth1.100:
      id: 100
      link: eth1
      addresses:
        - 192.168.100.1/24
```

## Test Priority Matrix (MVP)

Per Architecture Review (2026-01-26):

```
                simple   vlans   bonding
Single-node     [MVP]    [MVP]   deferred
Server+Agent    [MVP]    [MVP]   deferred
HA Cluster      later    later   deferred
Multi-Agent     later    later   deferred
```

MVP = 4 test combinations (2 use cases x 2 network configs)
