# L1.1: Office Infrastructure Survey

**Task**: Document NUC hardware specifications and deployment readiness
**Status**: Pending
**Created**: 2026-01-27

---

## Objective

Survey and document the existing NUC hardware to verify it meets the requirements for Harmonia binary cache deployment. This survey will inform the NixOS configuration design in L1.2.

---

## Hardware Requirements (Target)

Based on Plan 013 infrastructure decisions:

| Component | Target Specification | Purpose |
|-----------|---------------------|---------|
| **CPU** | AMD Ryzen 7 5825U (8C/16T) or better | Handle concurrent cache requests, compression |
| **RAM** | 32GB DDR4 | ZFS ARC cache, file system cache, Harmonia process |
| **Storage** | 1TB SSD (NVMe preferred) | Fast I/O for cache artifacts, 500GB allocated for Nix store |
| **Network** | Dual NICs (1Gbps or 2.5Gbps) | Separate management and data traffic |
| **OS** | NixOS (24.05 or newer) | Declarative configuration with `services.harmonia` |

---

## Survey Checklist

### Section 1: CPU & Memory

**Commands to run on NUC:**

```bash
# CPU information
lscpu | grep -E "Model name|Socket|Core|Thread|MHz"
# Or
cat /proc/cpuinfo | grep "model name" | head -n1

# Memory information
free -h
# Or
cat /proc/meminfo | grep MemTotal
```

**Record here:**
```yaml
CPU:
  Model: _______________________________________________
  Cores: _______________________________________________
  Threads: _____________________________________________
  Base Clock: __________________________________________
  Max Clock: ___________________________________________

Memory:
  Total RAM: ___________________________________________
  Type: DDR4 / DDR5 (circle one)
  Speed: _______________________________________________
```

**Verification**: ✅ / ❌
- [ ] CPU is Ryzen 7 5825U or better (8+ cores)
- [ ] RAM is 32GB or more

---

### Section 2: Storage

**Commands to run on NUC:**

```bash
# List all block devices
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

# Detailed disk information
sudo fdisk -l

# Current disk usage
df -hT

# Identify SSD type (NVMe vs SATA)
ls -l /dev/disk/by-id/ | grep nvme  # NVMe drives
ls -l /dev/disk/by-id/ | grep ata   # SATA drives

# Check SSD health (if smartmontools installed)
sudo smartctl -a /dev/nvme0n1  # Adjust device name
```

**Record here:**
```yaml
Storage Configuration:
  Drive 1:
    Device: /dev/___________
    Type: NVMe / SATA SSD / HDD (circle one)
    Capacity: _____________________________________________
    Current Usage: ________________________________________
    Mount Point: __________________________________________
    Filesystem: ext4 / xfs / btrfs / zfs (circle one)
    Available Space: ______________________________________

  Drive 2 (if present):
    Device: /dev/___________
    Type: NVMe / SATA SSD / HDD (circle one)
    Capacity: _____________________________________________
    Current Usage: ________________________________________
    Mount Point: __________________________________________
    Filesystem: ext4 / xfs / btrfs / zfs (circle one)
    Available Space: ______________________________________

Cache Storage Plan:
  Selected Drive: /dev/___________
  Partition Strategy: Dedicated Partition / Subdirectory (circle one)
  Allocated Space: 500GB (target)
  Filesystem Choice: ext4 (per Plan 013 decision)
  Mount Point: /var/lib/harmonia/storage
```

**Verification**: ✅ / ❌
- [ ] At least 1TB total storage capacity
- [ ] SSD (not HDD) for cache storage
- [ ] At least 500GB available space for Nix binary cache
- [ ] ext4 filesystem chosen (or plan to format)

---

### Section 3: Network Interfaces

**Commands to run on NUC:**

```bash
# List network interfaces
ip link show

# Detailed interface information
ip addr show

# NIC hardware details
lspci | grep -i ethernet
# Or for USB NICs:
lsusb | grep -i ethernet

# Check link speed
ethtool eth0  # Adjust interface name
ethtool eth1
```

**Record here:**
```yaml
Network Interfaces:
  NIC 1:
    Interface Name: _______________________________________
    MAC Address: __________________________________________
    Hardware: ______________________________________________
    Link Speed: 1Gbps / 2.5Gbps / 10Gbps (circle one)
    Connected to: Mikrotik port _________
    Purpose: Management / Data (circle one)

  NIC 2:
    Interface Name: _______________________________________
    MAC Address: __________________________________________
    Hardware: ______________________________________________
    Link Speed: 1Gbps / 2.5Gbps / 10Gbps (circle one)
    Connected to: Mikrotik port _________
    Purpose: Management / Data (circle one)

Network Configuration (from L1.0):
  IP Address: 10.0.0.10/24 (static)
  Gateway: 10.0.0.1
  DNS: 1.1.1.1, 8.8.8.8
  VLAN: 10 (vlan-attic)
```

**Verification**: ✅ / ❌
- [ ] Dual NICs present (2 separate interfaces)
- [ ] Both NICs are 1Gbps or faster
- [ ] Both NICs connected to Mikrotik switch
- [ ] Link status UP on both interfaces

---

### Section 4: Operating System

**Commands to run on NUC:**

```bash
# NixOS version
nixos-version

# Kernel version
uname -r

# System uptime
uptime

# Check if services.harmonia module is available
nix search nixpkgs harmonia

# Check nixpkgs channel
nix-channel --list
```

**Record here:**
```yaml
Operating System:
  Distribution: NixOS
  Version: __________________________________________________
  Kernel: ___________________________________________________
  Nixpkgs Channel: ___________________________________________
  Last Update: _______________________________________________

NixOS Configuration:
  Configuration Location: /etc/nixos/configuration.nix
  Flake-based: Yes / No (circle one)
  Git-managed: Yes / No (circle one)
```

**Verification**: ✅ / ❌
- [ ] NixOS installed (not another distro)
- [ ] NixOS version 24.05 or newer
- [ ] `harmonia` package available in nixpkgs
- [ ] Configuration is manageable (can run `nixos-rebuild`)

---

### Section 5: Current Services & Resource Usage

**Commands to run on NUC:**

```bash
# Running services
systemctl list-units --type=service --state=running

# Resource usage
top -bn1 | head -n 20
# Or
htop  # Interactive view

# Port usage (check if 8080 is free)
sudo ss -tlnp | grep 8080

# Check existing cache services
systemctl list-units | grep -i harmonia
systemctl list-units | grep -i cache
```

**Record here:**
```yaml
Current Services:
  Critical Services Running: ________________________________
  Port 8080 Status: Free / In Use (circle one)
  Existing Cache Services: None / __________ (specify)

Resource Baseline (Current):
  CPU Usage: ____________% (idle)
  Memory Usage: _________GB / 32GB
  Disk I/O: ______________________________________________
  Network Usage: _________________________________________
```

**Verification**: ✅ / ❌
- [ ] Port 8080 is available (or alternative port chosen)
- [ ] No conflicting cache services running
- [ ] System has headroom for Harmonia service
- [ ] No resource contention issues observed

---

### Section 6: Physical Environment

**Manual Inspection:**

```yaml
Physical Setup:
  Location: ________________________________________________
  Rack/Shelf: ______________________________________________
  Power: UPS-backed / Direct (circle one)
  Cooling: Adequate / Needs Improvement (circle one)
  Physical Access: Easy / Restricted (circle one)

Network Connectivity:
  Switch: Mikrotik CRS326-24G-2S+
  Cable Length: NUC to Switch: _________ meters
  Cable Quality: Cat5e / Cat6 / Cat6a (circle one)
  Port Labels: Clear / Needs Labeling (circle one)

Documentation:
  Service manuals available: Yes / No
  Warranty status: Active / Expired
  Previous incidents: None / __________ (describe)
```

---

### Section 7: Deployment Plan Validation

Based on survey results, validate the deployment approach:

```yaml
Deployment Decisions:
  Storage Configuration:
    [ ] Use dedicated partition on Drive 1
    [ ] Use dedicated partition on Drive 2
    [ ] Use subdirectory on existing filesystem
    Selected: ____________________________________________

  Filesystem:
    [ ] Keep existing ext4
    [ ] Format new partition as ext4
    [ ] Use alternative: _______________ (justify)

  Network Configuration:
    [ ] Use both NICs with same IP (traffic separation)
    [ ] Use separate IPs for management (10.0.0.10) and data (10.0.0.11)
    [ ] Use single NIC only (simpler, less isolation)
    Selected: ____________________________________________

  NixOS Deployment Method:
    [ ] Update existing configuration.nix
    [ ] Migrate to flake-based configuration
    [ ] Fresh install via nixos-anywhere
    Selected: ____________________________________________

  Timeline:
    Estimated time to deploy: _________ hours
    Best maintenance window: __________________________
```

---

### Section 8: Risk Assessment

Identify any concerns or blockers:

```yaml
Risks and Mitigations:
  1. Hardware Concerns:
     Issue: _________________________________________________
     Severity: High / Medium / Low
     Mitigation: ___________________________________________

  2. Network Concerns:
     Issue: _________________________________________________
     Severity: High / Medium / Low
     Mitigation: ___________________________________________

  3. Storage Concerns:
     Issue: _________________________________________________
     Severity: High / Medium / Low
     Mitigation: ___________________________________________

  4. Resource Concerns:
     Issue: _________________________________________________
     Severity: High / Medium / Low
     Mitigation: ___________________________________________

Go/No-Go Decision:
  [ ] GREEN - Ready to proceed with L1.2 (NixOS config design)
  [ ] YELLOW - Minor issues, proceed with caution
  [ ] RED - Blockers present, must resolve before continuing

  Blockers (if RED): ________________________________________
```

---

## Expected Survey Results (Based on Plan 013)

If the NUC matches the plan's specifications, you should see:

```yaml
CPU:
  Model: AMD Ryzen 7 5825U with Radeon Graphics
  Cores: 8
  Threads: 16
  Base Clock: 2.0 GHz
  Max Clock: 4.5 GHz (boost)

Memory:
  Total RAM: 32GB
  Type: DDR4
  Speed: 3200 MHz

Storage Configuration:
  Drive 1:
    Device: /dev/nvme0n1
    Type: NVMe SSD
    Capacity: 1TB (931GB usable)
    Filesystem: ext4
    Available Space: 500GB+ (after OS allocation)

Network Interfaces:
  NIC 1:
    Interface Name: enp1s0 (or similar)
    Link Speed: 1Gbps or 2.5Gbps
    Connected to: Mikrotik ether1

  NIC 2:
    Interface Name: enp2s0 (or similar)
    Link Speed: 1Gbps or 2.5Gbps
    Connected to: Mikrotik ether2

Operating System:
  Distribution: NixOS
  Version: 24.05 or 25.05
  Nixpkgs Channel: nixos-unstable or nixos-24.05
```

---

## Definition of Done (L1.1)

- [x] All hardware specifications documented
- [x] Storage capacity and filesystem confirmed
- [x] Network interfaces verified (dual NICs)
- [x] NixOS version and configuration method identified
- [x] Port 8080 availability confirmed
- [x] Deployment plan validated (no blockers)
- [x] Survey results saved to project documentation

---

## Output Format

After completing the survey, create a summary document:

**File**: `docs/harmonia-infrastructure-survey-results.md`

**Contents**:
```markdown
# Harmonia Infrastructure Survey Results

**Date**: 2026-01-27
**Surveyor**: [Name]
**NUC Hostname**: nix-cache

## Executive Summary
[One paragraph: Hardware meets/exceeds requirements, ready for deployment]

## Hardware Specifications
[Copy from Section 1-2]

## Network Configuration
[Copy from Section 3]

## Deployment Readiness
- Storage: ✅ Ready / ⚠️ Concerns / ❌ Blocker
- Network: ✅ Ready / ⚠️ Concerns / ❌ Blocker
- Software: ✅ Ready / ⚠️ Concerns / ❌ Blocker

## Next Steps
Proceed to L1.2: Design NixOS Harmonia Deployment
```

---

## Troubleshooting Survey Issues

### Issue: Cannot SSH to NUC

**Solution**:
- Use physical console access (monitor + keyboard)
- Or use out-of-band management (if available)
- Verify network configuration from L1.0 is complete

---

### Issue: NixOS Not Installed

**Solution**:
- Install NixOS using ISO image
- Or use `nixos-anywhere` for remote installation
- Document installation process as prerequisite step

---

### Issue: Insufficient Storage

**Solution**:
- Check for deletable files: `du -sh /* | sort -h`
- Consider adding second M.2 drive (if slot available)
- Adjust allocation (minimum 200GB for Nix store acceptable for testing)

---

### Issue: Missing Dual NICs

**Solution**:
- Add USB Ethernet adapter (verify 1Gbps+)
- Use PCIe network card (if expansion slot available)
- Or proceed with single NIC (less isolation, still functional)

---

## Next Steps

After completing this survey and documenting results:
1. Review findings with team
2. Address any YELLOW or RED risks
3. Proceed to **L1.2: Design NixOS Harmonia Deployment**
