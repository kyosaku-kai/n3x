# Debian Backend L4 Multi-Node Cluster Test Architecture

This document explains the architecture for Debian backend L4 (multi-node k3s cluster) tests and how they integrate with the shared test infrastructure.

## Overview

Debian backend L4 tests validate multi-node k3s cluster formation using ISAR-built `.wic` images. The test infrastructure is designed to **share network profile data** with NixOS tests while adapting to ISAR's different configuration mechanisms.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      SHARED INFRASTRUCTURE                               │
├─────────────────────────────────────────────────────────────────────────┤
│  lib/network/profiles/           Network profile DATA                    │
│    ├── simple.nix               (ipAddresses, interfaces, vlanIds)      │
│    ├── vlans.nix                Consumed by BOTH backends               │
│    └── bonding-vlans.nix                                                │
├─────────────────────────────────────────────────────────────────────────┤
│  lib/k3s/mk-k3s-flags.nix       K3s flags generator                     │
│                                 (--node-ip, --flannel-iface, etc.)       │
├─────────────────────────────────────────────────────────────────────────┤
│  tests/lib/test-scripts/        Shared test script phases               │
│    ├── utils.nix                (tlog, log_banner, log_summary)         │
│    └── phases/                                                          │
│        ├── boot.nix             (NixOS & ISAR boot helpers)             │
│        ├── network.nix          (network verification)                  │
│        └── k3s.nix              (k3s cluster phases)                    │
└─────────────────────────────────────────────────────────────────────────┘
                    │                              │
                    ▼                              ▼
┌─────────────────────────────┐    ┌──────────────────────────────┐
│  NixOS Backend              │    │  Debian Backend              │
│  mk-k3s-cluster-test.nix    │    │  mk-debian-cluster-test.nix  │
├─────────────────────────────┤    ├──────────────────────────────┤
│  Profile → NixOS modules    │    │  Profile → Build-time OR     │
│  (systemd.network config)   │    │  runtime network config      │
│  services.k3s options       │    │  /etc/default/k3s-server     │
└─────────────────────────────┘    └──────────────────────────────┘
```

## Key Differences: NixOS vs Debian Backend

| Aspect | NixOS | Debian |
|--------|-------|------|
| **Network Config Timing** | Build time (NixOS modules) | Build time (preferred) OR runtime |
| **Network Config Format** | `systemd.network.*` options | systemd-networkd `.network` files |
| **K3s Config Format** | `services.k3s.*` options | `/etc/default/k3s-server` env file |
| **K3s Service Name** | `k3s.service` | `k3s-server.service`, `k3s-agent.service` |
| **K3s Binary Path** | `/run/current-system/sw/bin/k3s` | `/usr/bin/k3s` |
| **Boot Detection** | `wait_for_unit("multi-user.target")` | `wait_for_unit("nixos-test-backdoor.service")` |

## Debian Backend Network Configuration

### Build-Time Configuration (Preferred)

ISAR images can have network configuration **baked in at build time** using the `systemd-networkd-config` recipe:

```yaml
# kas/network/simple.yml
local_conf_header:
  network-simple: |
    IMAGE_INSTALL:append = " systemd-networkd-config"
    NETWORKD_PROFILE = "simple"
    NETWORKD_NODE_NAME = "server-1"  # Determines IP: 192.168.1.1
```

The recipe installs systemd-networkd `.network` and `.netdev` files that are **generated from the same Nix profiles** used by NixOS tests:

```
lib/network/profiles/simple.nix
        │
        ▼ (nix run '.#generate-networkd-configs')
        │
backends/debian/meta-n3x/recipes-support/systemd-networkd-config/files/
├── simple/
│   ├── server-1/
│   │   └── 10-eth1.network    # IP: 192.168.1.1
│   ├── server-2/
│   │   └── 10-eth1.network    # IP: 192.168.1.2
│   └── agent-1/
│       └── 10-eth1.network    # IP: 192.168.1.3
├── vlans/
│   └── ...
└── bonding-vlans/
    └── ...
```

### Runtime Configuration (Test Workaround)

When testing with a single image (e.g., all nodes use the same `server-1` image), runtime IP commands are used:

```python
# In test script
server_1.succeed("ip addr add 192.168.1.1/24 dev eth1")
server_2.succeed("ip addr add 192.168.1.2/24 dev eth1")
```

**When to use runtime config:**
- Testing cluster formation without building separate images per node
- Quick iteration during development
- Single-image test scenarios

**When NOT to use runtime config (use build-time instead):**
- Production deployments
- Full integration testing with proper node identities
- Testing network configuration itself (VLANs, bonding)

## Debian Backend K3s Configuration

### Environment File Approach

The Debian backend's k3s uses environment files instead of NixOS module options:

```
/etc/default/k3s-server    # For k3s-server.service
/etc/default/k3s-agent     # For k3s-agent.service
```

**Primary Server** (`--cluster-init`):
```bash
K3S_SERVER_OPTS="--cluster-init --node-ip=192.168.1.1 --flannel-iface=eth1"
```

**Secondary Server** (joins primary):
```bash
K3S_SERVER_OPTS="--server https://192.168.1.1:6443 --node-ip=192.168.1.2 --flannel-iface=eth1"
```

**Agent** (joins server):
```bash
K3S_URL="https://192.168.1.1:6443"
K3S_TOKEN="<token-from-server>"
```

### Token Management

The test copies the token from the primary server:

```python
# Get token from primary
token = server_1.succeed("cat /var/lib/rancher/k3s/server/token").strip()

# Write to secondary
server_2.succeed(f"mkdir -p /var/lib/rancher/k3s/server && echo '{token}' > /var/lib/rancher/k3s/server/token")
```

## Debian Backend L4 Test Helpers

The `mk-debian-cluster-test.nix` builder provides these helpers:

### 1. `mkNetworkSetupCommands` - Runtime Network Configuration

Generates shell commands to configure network at test runtime. Uses the **same profile data** as NixOS tests:

```nix
# Simple profile → flat eth1 network
server_1.succeed("ip addr add 192.168.1.1/24 dev eth1")

# VLANs profile → create VLAN interfaces
server_1.succeed("modprobe 8021q")
server_1.succeed("ip link add link eth1 name eth1.200 type vlan id 200")
server_1.succeed("ip addr add 192.168.200.1/24 dev eth1.200")

# Bonding+VLANs → create bond, add VLANs on top
server_1.succeed("modprobe bonding")
server_1.succeed("ip link add bond0 type bond mode active-backup")
server_1.succeed("ip link add link bond0 name bond0.200 type vlan id 200")
```

### 2. `mkPrimaryServerConfig` - Configure Primary K3s Server

Generates k3s flags from profile and configures `/etc/default/k3s-server`:

```python
# Uses lib/k3s/mk-k3s-flags.nix (shared with NixOS)
server_1.succeed('sed -i \'s|K3S_SERVER_OPTS=.*|K3S_SERVER_OPTS="--cluster-init --node-ip=192.168.1.1 --flannel-iface=eth1"|\' /etc/default/k3s-server')
```

### 3. `mkSecondaryServerConfig` - Configure Secondary Server

Configures secondary to join primary with same profile-derived flags:

```python
server_2.succeed('sed -i \'s|K3S_SERVER_OPTS=.*|K3S_SERVER_OPTS="--server https://192.168.1.1:6443 --node-ip=192.168.1.2 --flannel-iface=eth1"|\' /etc/default/k3s-server')
```

### 4. `mkVMWorkarounds` - Test VM Fixes

Applies workarounds needed for k3s in test VMs:

```python
# k3s requires a default route (checks /proc/net/route)
server_1.succeed("ip route add default via 192.168.1.254 dev eth1 || true")

# kubelet needs /dev/kmsg - symlink to /dev/null in test VMs
server_1.execute("rm -f /dev/kmsg && ln -s /dev/null /dev/kmsg")
```

## Usage

### Basic Usage

```nix
# In flake.nix checks
mkDebianClusterTest = pkgs.callPackage ./tests/lib/debian/mk-debian-cluster-test.nix { inherit pkgs lib; };

debian-cluster-simple = mkDebianClusterTest { networkProfile = "simple"; };
```

### With Custom Machines

```nix
debian-cluster-custom = mkDebianClusterTest {
  networkProfile = "vlans";
  machines = {
    server_1 = { image = debianArtifacts.qemuamd64.server.vlans.wic; memory = 4096; cpus = 4; };
    server_2 = { image = debianArtifacts.qemuamd64.server.vlans.wic; memory = 4096; cpus = 4; };
    agent_1 = { image = debianArtifacts.qemuamd64.agent.vlans.wic; memory = 2048; cpus = 2; };
  };
};
```

### With Custom Test Script

```nix
debian-cluster-workload = mkDebianClusterTest {
  networkProfile = "simple";
  testScript = ''
    ${testScripts.utils.all}
    # ... custom test logic ...
  '';
};
```

## Test Phases

The default L4 test follows these phases:

1. **PHASE 1: Boot** - Start all VMs, wait for backdoor service
2. **PHASE 2: Network** - Configure IPs (runtime or verify build-time config)
3. **PHASE 3: Workarounds** - Apply default route and /dev/kmsg fixes
4. **PHASE 4: Primary Server** - Configure `--cluster-init`, start, wait for Ready
5. **PHASE 5: Secondary Server** - Copy token, configure `--server`, start, wait for join
6. **PHASE 6: Cluster Health** - Verify both nodes Ready, etcd quorum
7. **PHASE 7: Components** - Verify CoreDNS, local-path-provisioner running

## Prerequisites

### Required ISAR Artifacts

For full L4 testing, these images must be built:

| Test Variant | Required Images |
|--------------|-----------------|
| 2-server HA | `qemuamd64.server.{simple,vlans,bonding-vlans}.wic` |
| 2-server + agent | Above + `qemuamd64.agent.{profile}.wic` |

### Current Status

| Image | Status |
|-------|--------|
| `qemuamd64.server.simple.wic` | ✅ Built |
| `qemuamd64.server.vlans.wic` | ✅ Built |
| `qemuamd64.server.bonding-vlans.wic` | ✅ Built |
| `qemuamd64.agent.*.wic` | ❌ Not yet built |

### Building Additional Images

```bash
# Server image with VLAN profile, server-2 node name
kas-container --isar build \
  kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/vlans.yml

# To build with specific node name, edit kas/network/vlans.yml or override in local.conf:
# NETWORKD_NODE_NAME = "server-2"

# Agent image
kas-container --isar build \
  kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-agent.yml:kas/test-overlay.yml:kas/network/simple.yml
```

## Future Improvements

1. **Per-node image builds** - Create kas overlays for each node identity
2. **Agent testing** - Build agent images, extend test to include agents
3. **Network profile detection** - Detect if image has baked-in config, skip runtime setup
4. **Debian backend cluster phases** - Extract helpers to `test-scripts/phases/k3s.nix` for reuse

## Related Documentation

- [tests/lib/README.md](../tests/lib/README.md) - Shared test infrastructure
- [lib/network/README.md](../lib/network/README.md) - Network configuration system
- [backends/debian/README.md](../backends/debian/README.md) - Debian backend overview
- [CLAUDE.md](../CLAUDE.md) - Project status and technical learnings
