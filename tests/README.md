# n3x VM Testing

This directory contains VM configurations and test scripts for validating the n3x cluster setup before deploying to physical hardware.

## Overview

The VM testing framework allows you to:
- Test individual node configurations (server/agent)
- Validate multi-node cluster deployment
- Test networking, storage, and K3s configurations
- Debug issues in a safe, isolated environment

## Directory Structure

```
tests/
├── vms/
│   ├── default.nix           # Base VM configuration
│   ├── k3s-server-vm.nix     # K3s control plane VM
│   ├── k3s-agent-vm.nix      # K3s worker node VM
│   └── multi-node-cluster.nix # Multi-node cluster test
├── run-vm-tests.sh           # Test runner script
└── README.md                 # This file
```

## Quick Start

### Running All Tests

```bash
# From the n3x root directory
./tests/run-vm-tests.sh
```

### Running Specific Tests

```bash
# Test only the K3s server VM
./tests/run-vm-tests.sh server

# Test only the K3s agent VM
./tests/run-vm-tests.sh agent

# Test multi-node cluster
./tests/run-vm-tests.sh cluster
```

### Interactive VM Sessions

Start an interactive VM for manual testing:

```bash
./tests/run-vm-tests.sh interactive
```

## Building VMs Manually

### Build a Single VM

```bash
# Build the K3s server VM
nix build .#nixosConfigurations.vm-k3s-server.config.system.build.vm

# Run the VM
./result/bin/run-vm-k3s-server-vm
```

### Build and Run with Options

```bash
# Build with specific memory and CPU settings
nix build .#nixosConfigurations.vm-k3s-server.config.system.build.vm \
  --arg memorySize 8192 \
  --arg cores 4

# Run with QEMU options
QEMU_OPTS="-m 8192 -smp 4" ./result/bin/run-vm-k3s-server-vm
```

## VM Configurations

### Base VM (`default.nix`)
- 4GB RAM, 2 CPU cores
- 20GB disk
- SSH enabled (root/test)
- Port forwarding for K3s services
- Minimal NixOS configuration

### K3s Server VM (`k3s-server-vm.nix`)
- 4GB RAM, 2 CPU cores
- 30GB disk
- K3s control plane configuration
- etcd for cluster state
- Automatic verification script

### K3s Agent VM (`k3s-agent-vm.nix`)
- 2GB RAM, 2 CPU cores
- 20GB disk
- K3s worker node configuration
- Container runtime configured
- Storage drivers enabled

### Multi-node Cluster (`multi-node-cluster.nix`)
- 1 control plane node (4GB RAM)
- 2 worker nodes (2GB RAM each)
- Internal network for cluster communication
- Automated test script

## Accessing VMs

### SSH Access

All VMs have SSH enabled with default credentials:
- Username: `root`
- Password: `test`

Connect to a running VM:
```bash
# Default SSH port is forwarded to 2222
ssh -p 2222 root@localhost
```

### K3s API Access

The K3s API is forwarded to the host:
```bash
# Access K3s API from host
kubectl --kubeconfig=/path/to/kubeconfig get nodes
```

### Serial Console

For debugging boot issues:
```bash
# Start VM with serial console
./result/bin/run-vm-k3s-server-vm -nographic
```

## Testing Scenarios

### 1. Basic Functionality Test

```bash
# Build and start server VM
nix build .#nixosConfigurations.vm-k3s-server.config.system.build.vm
./result/bin/run-vm-k3s-server-vm &

# Wait for VM to boot
sleep 60

# SSH into VM and check K3s
ssh -p 2222 root@localhost "k3s kubectl get nodes"
```

### 2. Cluster Formation Test

```bash
# Start control plane
nix build .#nixosConfigurations.vm-control-plane.config.system.build.vm
./result/bin/run-vm-control-plane-vm &

# Start workers
nix build .#nixosConfigurations.vm-worker-1.config.system.build.vm
./result/bin/run-vm-worker-1-vm &

nix build .#nixosConfigurations.vm-worker-2.config.system.build.vm
./result/bin/run-vm-worker-2-vm &

# Check cluster status
ssh -p 2222 root@control-plane "k3s kubectl get nodes"
```

### 3. Storage Test

```bash
# Deploy Longhorn in VM
ssh -p 2222 root@localhost <<EOF
k3s kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml
k3s kubectl get pods -n longhorn-system
EOF
```

### 4. Network Policy Test

```bash
# Test network policies and Multus CNI
ssh -p 2222 root@localhost <<EOF
# Apply network policy
k3s kubectl apply -f /path/to/network-policy.yaml

# Test connectivity
k3s kubectl run test --image=busybox --rm -it -- ping google.com
EOF
```

## Troubleshooting

### VM Won't Start

Check QEMU/KVM requirements:
```bash
# Check KVM support
lsmod | grep kvm

# Check QEMU installation
which qemu-system-x86_64
```

### Out of Memory

Adjust VM memory in the configuration:
```nix
virtualisation.memorySize = 8192;  # 8GB
```

### Network Issues

Check firewall rules:
```bash
# In VM
iptables -L -n
systemctl status firewalld
```

### K3s Not Starting

Check K3s logs:
```bash
# In VM
journalctl -u k3s -f
k3s check-config
```

## Performance Tuning

### VM Performance Options

```nix
virtualisation = {
  # Increase resources
  memorySize = 8192;
  cores = 4;

  # Enable KVM acceleration
  qemu.options = [
    "-enable-kvm"
    "-cpu host"
  ];

  # Use virtio for better I/O
  qemu.networkingOptions = [
    "-device virtio-net-pci"
  ];
};
```

### Host System Tuning

```bash
# Increase QEMU memory lock limit
echo "* soft memlock unlimited" >> /etc/security/limits.conf
echo "* hard memlock unlimited" >> /etc/security/limits.conf

# Enable huge pages
echo 1024 > /proc/sys/vm/nr_hugepages
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: VM Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: cachix/install-nix-action@v20
      - run: ./tests/run-vm-tests.sh all
```

### Local Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit
./tests/run-vm-tests.sh server
```

## Next Steps

After successful VM testing:

1. **Deploy to Physical Hardware**
   - Use `nixos-anywhere` for bare-metal provisioning
   - Apply the same configurations tested in VMs

2. **Production Configuration**
   - Replace test tokens with secure ones
   - Configure proper networking (VLANs, bonding)
   - Set up monitoring and logging

3. **Scale Testing**
   - Add more worker VMs to test scaling
   - Test failover scenarios
   - Benchmark storage performance

## Additional Resources

- [NixOS VM Testing](https://nixos.org/manual/nixos/stable/#sec-nixos-tests)
- [QEMU Documentation](https://www.qemu.org/documentation/)
- [K3s Documentation](https://docs.k3s.io/)
- [n3x Main README](../README.md)