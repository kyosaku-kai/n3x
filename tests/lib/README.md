# tests/lib - Shared Test Infrastructure

This directory contains reusable test builders and network profiles for parameterized testing.

## Structure

```
tests/lib/
├── README.md                         # This file
├── mk-k3s-cluster-test.nix          # Parameterized k3s cluster test builder
└── network-profiles/                 # Network topology configurations
    ├── simple.nix                    # Single flat network (baseline)
    ├── vlans.nix                     # 802.1Q VLAN tagging
    └── bonding-vlans.nix             # Bonding + VLANs (production parity)
```

## Purpose

Enables testing the same k3s cluster logic with different network configurations without code duplication.

## Usage

### Creating a Test Variant

In `flake.nix`:

```nix
checks.x86_64-linux.my-test = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
  inherit pkgs lib;
  networkProfile = "vlans";  # or "simple" or "bonding-vlans"
  testName = "my-custom-test";  # optional, defaults to k3s-cluster-${networkProfile}
};
```

### Adding a New Network Profile

1. Create `tests/lib/network-profiles/myprofile.nix`:

```nix
{ lib }:
{
  # Network IPs for each node
  nodeIPs = {
    n100-1 = "192.168.1.1";
    n100-2 = "192.168.1.2";
    n100-3 = "192.168.1.3";
  };

  # K3s API endpoint
  serverApi = "https://192.168.1.1:6443";

  # K3s network CIDRs
  clusterCidr = "10.42.0.0/16";
  serviceCidr = "10.43.0.0/16";

  # Per-node configuration function
  nodeConfig = nodeName: { config, pkgs, lib, ... }: {
    # Network configuration specific to this profile
    networking.interfaces.eth1.ipv4.addresses = [{
      address = nodeIPs.${nodeName};
      prefixLength = 24;
    }];
  };

  # k3s flags specific to this network profile
  k3sExtraFlags = nodeName: [
    "--node-ip=${nodeIPs.${nodeName}}"
    "--flannel-iface=eth1"
  ];
}
```

2. Add test variant to `flake.nix`:

```nix
k3s-cluster-myprofile = pkgs.callPackage ./tests/lib/mk-k3s-cluster-test.nix {
  inherit pkgs lib;
  networkProfile = "myprofile";
};
```

3. Test it:

```bash
nix build '.#checks.x86_64-linux.k3s-cluster-myprofile' --rebuild
```

## Network Profile API

Each network profile must provide:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `nodeIPs` | attrset | No | Map of node names to IP addresses (for reference) |
| `serverApi` | string | Yes | K3s API server URL (used by agents/secondary servers) |
| `clusterCidr` | string | Yes | K3s pod network CIDR |
| `serviceCidr` | string | Yes | K3s service network CIDR |
| `nodeConfig` | function | Yes | `nodeName -> NixOS module` - Network config for each node |
| `k3sExtraFlags` | function | Yes | `nodeName -> [string]` - k3s flags for network profile |

## Test Builder API

`mk-k3s-cluster-test.nix` accepts:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `networkProfile` | string | `"simple"` | Name of network profile to use |
| `testName` | string | `"k3s-cluster-${networkProfile}"` | Name of the test |
| `testScript` | string | Standard cluster test | Custom Python test script |
| `extraNodeConfig` | attrset | `{}` | Additional config merged into all nodes |

## Benefits

- **No duplication**: Test logic defined once in `mk-k3s-cluster-test.nix`
- **Composable**: Network profiles are pure Nix modules
- **Maintainable**: Changes to test logic automatically apply to all profiles
- **Extensible**: Add new profiles without modifying test builder
- **Nix-idiomatic**: Uses module system, not branching or conditionals

## Examples

### Simple Profile (Baseline)
```bash
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild
```
Single flat network on eth1, no VLANs, no bonding.

### VLAN Profile (Production Parity)
```bash
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild
```
802.1Q VLAN tagging: cluster traffic on VLAN 200, storage on VLAN 100.

### Bonding + VLANs (Full Production)
```bash
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans' --rebuild
```
Active-backup bonding with VLAN tagging on bond interface.

## Testing Guide

See [docs/VLAN-TESTING-GUIDE.md](../../docs/VLAN-TESTING-GUIDE.md) for comprehensive testing instructions.

## Maintenance

When modifying test logic:
1. Edit `mk-k3s-cluster-test.nix`
2. Changes automatically apply to all test variants
3. Test all profiles to ensure compatibility:
   ```bash
   nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild
   nix build '.#checks.x86_64-linux.k3s-cluster-vlans' --rebuild
   nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans' --rebuild
   ```

When adding network profiles:
1. Create profile in `network-profiles/`
2. Add test variant to `flake.nix`
3. Update `tests/README.md` with new profile
4. Document expected behavior
