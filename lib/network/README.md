# lib/network/ - Unified Network Configuration

This directory contains the **single source of truth** for network configuration across all n3x backends (NixOS and ISAR).

## Why This Exists

Previously, network configuration was duplicated:
- NixOS used `systemd.network.*` module options
- ISAR used netplan YAML files in separate recipes

This created drift between backends. Now, network profiles define everything in one place, and each backend consumes them appropriately.

## Directory Structure

```
lib/network/
├── profiles/                  # Network profile definitions
│   ├── simple.nix            # Single flat network (baseline)
│   ├── vlans.nix             # 802.1Q VLAN tagging
│   ├── bonding-vlans.nix     # Bonding + VLANs (production parity)
│   └── vlans-broken.nix      # Intentionally broken (negative testing)
├── mk-systemd-networkd.nix   # Generates .network/.netdev file content
└── README.md                 # This file
```

## Profile Schema

Each profile exports:

```nix
{
  # IP addresses per node per interface
  ipAddresses = {
    "server-1" = { cluster = "192.168.1.1"; storage = "192.168.100.1"; };
    "server-2" = { cluster = "192.168.1.2"; storage = "192.168.100.2"; };
    ...
  };

  # Interface names (abstract → actual)
  interfaces = {
    cluster = "eth1";        # Flat interface
    # OR
    cluster = "eth1.200";    # VLAN interface
    storage = "eth1.100";
  };

  # VLAN IDs (if applicable)
  vlanIds = {
    cluster = 200;
    storage = 100;
  };

  # K3s server API endpoint
  serverApi = "https://192.168.1.1:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # NixOS: Per-node configuration function
  nodeConfig = nodeName: { config, pkgs, lib, ... }: { ... };

  # K3s extra flags for node
  k3sExtraFlags = nodeName: [ "--node-ip=..." "--flannel-iface=..." ];
}
```

## Backend Consumption

### NixOS Backend

Uses the `nodeConfig` function to apply systemd-networkd configuration:

```nix
# In tests/lib/mk-k3s-cluster-test.nix
profile = import ../../lib/network/profiles/simple.nix { inherit lib; };

nodes.server-1 = { ... }:
  lib.mkMerge [
    (profile.nodeConfig "server-1")
    { ... }
  ];
```

### ISAR Backend

Uses the exported data to configure networking at runtime:

```nix
# In tests/lib/isar/mk-network-config.nix
profile = import ../../../lib/network/profiles/simple.nix { inherit lib; };

# Access profile.ipAddresses, profile.interfaces for runtime config
```

For image-level networking, the `mk-systemd-networkd.nix` generates `.network` and `.netdev` files that the ISAR recipe installs to `/etc/systemd/network/`.

## Adding a New Profile

1. Create `lib/network/profiles/myprofile.nix`
2. Export required fields (ipAddresses, interfaces, nodeConfig, k3sExtraFlags, etc.)
3. Add to `flake.nix` under `lib.networkProfiles`
4. Use in tests: `networkProfile = "myprofile"`

## Migration History

- **2026-01-27**: Moved from `tests/lib/network-profiles/` to `lib/network/profiles/`
  - This is IMAGE-BUILDING infrastructure, not test-specific
  - Both backends now consume from this unified location
