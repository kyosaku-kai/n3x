# K3s Image Configuration Contract

This document defines the requirements for ISAR images to be compatible with the n3x test infrastructure. When ISAR images meet this contract, they can use shared network profiles and test scripts from `tests/lib/`.

## Why This Contract Exists

NixOS uses the `services.k3s` module which handles K3s configuration declaratively. ISAR images must be built with equivalent configuration for tests to pass on both backends.

## Contract Version

- **Version**: 1.0
- **K3s Version**: 1.32.x (aligned with ISAR recipe `k3s-server_1.32.0.bb`)
- **Last Updated**: 2026-01-26

## Required Components

### 1. K3s Binary

| Requirement | Value | Notes |
|-------------|-------|-------|
| Location | `/usr/bin/k3s` | ISAR installs here; NixOS has symlink from `/run/current-system/sw/bin` |
| Version | 1.32.x | Match ISAR recipe version |
| Architecture | Auto-selected | `k3s` for amd64, `k3s-arm64` for arm64 |
| Symlinks | `kubectl`, `crictl`, `ctr` | All link to `/usr/bin/k3s` |

### 2. Systemd Services

| Role | Service Name | Description |
|------|-------------|-------------|
| Server | `k3s-server.service` | Control plane (API, scheduler, controller, etcd) |
| Agent | `k3s-agent.service` | Worker node (joins server cluster) |

**NixOS Note**: The NixOS k3s module uses `k3s.service` for both roles. ISAR uses role-specific names to avoid package conflicts.

**Service Requirements**:
```
[Service]
Type=notify
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Restart=always
RestartSec=5s
```

### 3. Configuration Paths

| Path | Purpose | Permissions |
|------|---------|-------------|
| `/etc/rancher/k3s/` | Configuration directory | 755 |
| `/etc/rancher/k3s/config.yaml` | Main config (optional) | 644 |
| `/etc/rancher/k3s/config.yaml.d/` | Drop-in configs (optional) | 755 |
| `/etc/default/k3s-server` | Server env vars (ISAR) | 644 |
| `/etc/default/k3s-agent` | Agent env vars (ISAR) | 644 |
| `/var/lib/rancher/k3s/` | Runtime data directory | 755 |
| `/var/lib/rancher/k3s/server/token` | Cluster token (server) | 600 |
| `/var/lib/rancher/k3s/server/node-token` | Agent join token | 600 |

### 4. Runtime Dependencies

Both NixOS and ISAR must provide these packages:

| Package | Purpose |
|---------|---------|
| `iptables` | Packet filtering for pod networking |
| `nftables` | Modern firewall backend |
| `iproute2` | Network configuration (`ip` command) |
| `kmod` | Kernel module loading (`modprobe`) |
| `socat` | Socket relay for port forwarding |
| `ipset` | IP set management for kube-proxy |
| `ethtool` | Network interface configuration |
| `conntrack` | Connection tracking for kube-proxy |
| `bridge-utils` | Network bridge management |
| `util-linux` | System utilities (`mount`, `nsenter`) |
| `systemd` | Service management |

**ISAR recipe**: `DEBIAN_DEPENDS` in `k3s-base.inc`

**NixOS module**: Provided via `environment.systemPackages` in `k3s-common.nix`

### 5. Kernel Requirements

**Modules** (must be loaded or built-in):

| Module | Category | Purpose |
|--------|----------|---------|
| `overlay` | Container | OverlayFS for containerd |
| `br_netfilter` | Network | Bridge netfilter support |
| `iscsi_tcp` | Storage | iSCSI for Longhorn |
| `dm_crypt` | Storage | Encrypted volumes |

**Sysctl Parameters**:

```
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
```

**ISAR**: Configured via `k3s-system-config` recipe

**NixOS**: Configured via `boot.kernel.sysctl` in `k3s-common.nix`

### 6. Network Configuration

The test infrastructure uses the unified network schema from `tests/lib/network-profiles/`.

**Required Flannel Interface**:

| Profile | Flannel Interface | K3s Flag |
|---------|-------------------|----------|
| simple | `eth1` | `--flannel-iface=eth1` |
| vlans | `eth1.200` | `--flannel-iface=eth1.200` |
| bonding-vlans | `bond0.200` | `--flannel-iface=bond0.200` |

**K3s Network CIDRs** (defaults, configurable per test):

```
--cluster-cidr=10.42.0.0/16   # Pod network
--service-cidr=10.43.0.0/16   # Service network
--cluster-dns=10.43.0.10      # CoreDNS service IP
```

### 7. Firewall Ports

**Server Node**:

| Port | Protocol | Purpose |
|------|----------|---------|
| 6443 | TCP | Kubernetes API server |
| 2379 | TCP | etcd client |
| 2380 | TCP | etcd peer |
| 10250 | TCP | kubelet API |
| 8472 | UDP | Flannel VXLAN |
| 51820 | UDP | Flannel WireGuard |
| 30000-32767 | TCP/UDP | NodePort range |

**Agent Node**:

| Port | Protocol | Purpose |
|------|----------|---------|
| 10250 | TCP | kubelet API |
| 8472 | UDP | Flannel VXLAN |
| 51820 | UDP | Flannel WireGuard |
| 30000-32767 | TCP/UDP | NodePort range |

## Token Authentication

### Server Token

The server must have a pre-configured token for automated testing:

```
/var/lib/rancher/k3s/server/token
```

**ISAR recipe** (`k3s-server_1.32.0.bb`):
```bash
echo "test-cluster-fixed-token-for-automated-testing" > \
    ${D}/var/lib/rancher/k3s/server/token
chmod 0600 ${D}/var/lib/rancher/k3s/server/token
```

**NixOS** (`services.k3s.tokenFile`):
```nix
services.k3s.tokenFile = "/path/to/token";
```

### Agent Join Token

Agents connect to the server using:
```
--server=https://<server-ip>:6443
--token=<contents of /var/lib/rancher/k3s/server/token>
```

## Airgap Images (Optional)

For offline testing, preload container images to:
```
/var/lib/rancher/k3s/agent/images/
```

**NixOS**: Uses `pkgs.k3s.passthru.airgapImages`

**ISAR**: Would require fetching from releases and including in image (not implemented)

## Contract Verification Test

A minimal verification test should:

1. Boot the VM
2. Wait for `multi-user.target`
3. Wait for `k3s-server.service` (or `k3s-agent.service`)
4. Verify `/usr/bin/k3s` exists and is executable
5. Verify `kubectl get nodes` returns Ready status (server only)

Example test script (Python, nixos-test-driver API):
```python
# For server
server.wait_for_unit("multi-user.target")
server.wait_for_unit("k3s-server.service")
server.succeed("test -x /usr/bin/k3s")
server.wait_until_succeeds("kubectl get nodes | grep Ready", timeout=120)

# For agent (requires server)
agent.wait_for_unit("multi-user.target")
agent.wait_for_unit("k3s-agent.service")
agent.succeed("test -x /usr/bin/k3s")
```

## Differences Between NixOS and ISAR

| Aspect | NixOS | ISAR |
|--------|-------|------|
| Service name | `k3s.service` | `k3s-server.service` / `k3s-agent.service` |
| Config location | `services.k3s.*` options | `/etc/default/k3s-*` env files |
| Token management | `sops-nix` / `agenix` | Static file in recipe |
| Package source | nixpkgs | GitHub releases |
| Data directory | `/var/lib/k3s` (custom) | `/var/lib/rancher/k3s` (default) |

**Note**: The different data directories are intentional. NixOS uses `/var/lib/k3s` for FHS compliance with symlink from default location. ISAR uses the K3s default.

## Related Documentation

- `tests/lib/README.md` - Shared test infrastructure
- `tests/lib/NETWORK-SCHEMA.md` - Unified network schema
- `backends/isar/meta-isar-k3s/recipes-core/k3s/` - ISAR K3s recipes
- `backends/nixos/modules/roles/k3s-*.nix` - NixOS K3s modules

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-26 | Initial contract definition |
