# Phase 9: Hardware Deployment Checklist

**Created**: 2026-01-20
**Status**: Ready to begin
**Target**: Deploy first N100 node (n100-1) as k3s server

## Prerequisites Validation

### ✅ Phase 8 Complete - Secrets Management
- [x] Age keys generated (admin + n100-1/2/3)
- [x] Keys stored in Bitwarden (Infrastructure/Age-Keys folder)
- [x] K3s tokens encrypted in `secrets/k3s/tokens.yaml`
- [x] SOPS configuration validated (`.sops.yaml`)
- [x] Decryption tested with admin key

**Verification**:
```bash
export SOPS_AGE_KEY_FILE=~/src/n3x/secrets/keys/admin.age
sops -d secrets/k3s/tokens.yaml
# Should show plaintext k3s-server-token and k3s-agent-token
```

### ✅ Phase 6 Complete - Network Profiles Tested
- [x] 3 network profiles implemented (simple, vlans, bonding-vlans)
- [x] All tests passing on WSL2/Hyper-V
- [x] VLAN tagging validated (192.168.200.x cluster IPs)

### ✅ Multi-Architecture Support
- [x] k3s-server.nix supports both x86_64 and aarch64
- [x] Resource limits configurable via lib.mkDefault
- [x] Build validation checks for aarch64 hosts

### ✅ Repository State
- [x] Branch: `simint` with clean working tree
- [x] All changes committed
- [x] Flake checks pass (`nix flake check`)

## Pre-Deployment Hardware Preparation

### Physical Setup
- [ ] N100-1 miniPC powered on and accessible on network
- [ ] Network connectivity verified (ping from deployment machine)
- [ ] BIOS/UEFI configured for network boot or USB boot
- [ ] Serial console access available (optional, for debugging)

### Network Configuration
**Decision Required**: Which network profile to use?
- [ ] **Option A**: Simple (flat network) - Easiest for initial deployment
- [ ] **Option B**: VLANs (production-ready) - Requires switch VLAN configuration
- [ ] **Option C**: Bonding + VLANs (full production) - Requires dual NICs configured

**Recommended**: Start with **Option A** (simple) for first node validation, then migrate to VLANs.

### Target IP/Hostname
- **Hostname**: n100-1
- **Target IP for deployment**: _________________ (fill in)
- **Planned cluster IP**: 192.168.200.10 (if using VLANs)
- **Planned storage IP**: 192.168.100.10 (if using VLANs)

## Deployment Steps

### 1. Prepare Deployment Environment

**On deployment machine** (where you'll run nixos-anywhere):

```bash
# Ensure nixos-anywhere is available
nix run github:nix-community/nixos-anywhere -- --version

# Verify flake evaluates correctly
cd ~/src/n3x
nix flake check

# Set SOPS_AGE_KEY_FILE for admin access
export SOPS_AGE_KEY_FILE=~/src/n3x/secrets/keys/admin.age

# Verify secrets decrypt
sops -d secrets/k3s/tokens.yaml
```

### 2. Initial Deployment with nixos-anywhere

**First deployment** (will wipe target disk):

```bash
# DANGER: This will ERASE the target disk!
# Verify target IP is correct before running

nixos-anywhere --flake .#n100-1 root@<TARGET_IP>
```

**What this does**:
1. Boots target into kexec environment
2. Partitions disk according to disko config
3. Installs NixOS from flake configuration
4. Copies host age key to `/var/lib/sops-nix/key.txt`
5. Reboots into installed system

**Expected duration**: 5-15 minutes depending on network speed

### 3. Post-Deployment Validation

#### A. Basic System Health
```bash
# SSH into deployed system
ssh root@<n100-1-ip>

# Check system booted correctly
systemctl status

# Check disk partitioning
lsblk
df -h

# Check network interfaces
ip addr show
ip route show
```

#### B. Secrets Decryption
```bash
# On n100-1, verify sops-nix can decrypt
ls -la /var/lib/sops-nix/key.txt

# Check k3s token file was created
ls -la /run/secrets/k3s-server-token

# Verify token is readable
cat /run/secrets/k3s-server-token
```

#### C. K3s Service Status
```bash
# Check k3s service
systemctl status k3s

# Wait for k3s to be ready (may take 1-2 minutes)
journalctl -u k3s -f

# Verify k3s API responds
kubectl get nodes
# Should show: n100-1   Ready   control-plane,master

kubectl get pods -A
# Should show: kube-system pods running (coredns, metrics-server, etc.)
```

#### D. Storage Prerequisites
```bash
# Check required kernel modules loaded
lsmod | grep overlay
lsmod | grep br_netfilter
lsmod | grep iscsi_tcp

# Check iSCSI daemon
systemctl status iscsid

# Check storage directories exist
ls -la /var/lib/longhorn
```

### 4. Validation Checklist

- [ ] System boots successfully after deployment
- [ ] Network connectivity working (can reach internet)
- [ ] SOPS age key present at `/var/lib/sops-nix/key.txt`
- [ ] K3s token decrypted to `/run/secrets/k3s-server-token`
- [ ] K3s service running (`systemctl status k3s`)
- [ ] K3s API responds (`kubectl get nodes`)
- [ ] Node shows "Ready" status
- [ ] CoreDNS pods running in kube-system namespace
- [ ] Local-path-provisioner available
- [ ] Storage kernel modules loaded

## Rollback Strategy

### If Deployment Fails

**Before deployment completes**:
- Ctrl+C the nixos-anywhere process
- Target machine will remain in kexec environment or fail to boot
- Re-run deployment after fixing issues

**After deployment completes but system broken**:
1. Boot from USB installer or rescue media
2. Mount root filesystem
3. Inspect logs: `/var/log/nixos-anywhere/` (if preserved)
4. Re-deploy with corrected configuration

### If K3s Fails to Start

```bash
# Check k3s logs
journalctl -u k3s -n 100

# Common issues:
# 1. Token file not found -> Check /run/secrets/k3s-server-token
# 2. Network issues -> Check firewall, interfaces
# 3. Disk space -> Check df -h

# Restart k3s after fixes
systemctl restart k3s
```

### If Secrets Decryption Fails

```bash
# Verify age key is correct
cat /var/lib/sops-nix/key.txt
# Should match n100-1 private key from Bitwarden

# Check sops-nix service
systemctl status sops-nix

# Manual decrypt test (if admin key available)
export SOPS_AGE_KEY_FILE=/path/to/admin.age
sops -d /path/to/secrets/k3s/tokens.yaml
```

## Known Issues & Workarounds

### Issue: Serial Console Needed
If SSH fails and display shows no output, connect serial console (USB-C or UART).

### Issue: Network Not Coming Up
Check `systemd-networkd` status and configuration:
```bash
systemctl status systemd-networkd
networkctl status
journalctl -u systemd-networkd
```

### Issue: Disk Partitioning Fails
- Verify target disk is correct in `hosts/n100-1/configuration.nix`
- Check disko configuration in `modules/storage/`
- May need to manually wipe disk first if existing partitions interfere

## Success Criteria

Deployment is successful when:
1. ✅ System boots from internal disk
2. ✅ SSH access works
3. ✅ Secrets decrypt automatically
4. ✅ K3s server is running
5. ✅ `kubectl get nodes` shows n100-1 as Ready
6. ✅ System pods (CoreDNS, metrics-server) are Running

## Next Steps After Successful Deployment

1. **Expand cluster**: Deploy n100-2 and n100-3 as agent nodes
2. **Test workloads**: Deploy test pod to verify scheduling
3. **Validate storage**: Create PVC using local-path-provisioner
4. **Phase 10**: Deploy Kyverno and Longhorn

## Reference Documentation

- [nixos-anywhere documentation](https://github.com/nix-community/nixos-anywhere)
- [SECRETS-SETUP.md](./SECRETS-SETUP.md) - Secrets management guide
- [VLAN-TESTING-GUIDE.md](./VLAN-TESTING-GUIDE.md) - Network profiles
- [tests/README.md](../tests/README.md) - Testing infrastructure
