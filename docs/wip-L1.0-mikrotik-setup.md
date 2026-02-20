# L1.0: Mikrotik Network Setup Guide

**Task**: Configure Mikrotik CRS326-24G-2S+ for isolated LAN (10.0.0.0/24)
**Status**: In Progress
**Created**: 2026-01-27

---

## Objective

Create an isolated network segment (10.0.0.0/24) on the Mikrotik CRS326-24G-2S+ switch for the Nix binary cache infrastructure (Harmonia). This network will be separate from the corporate LAN to provide:
- Full control over network configuration
- Proper isolation for cache traffic
- Dedicated bandwidth for cache operations
- Security boundary between cache and corporate network

---

## Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│                  Corporate Network                           │
│                  (existing network)                          │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ Uplink/Router Port
                         │
                ┌────────▼─────────┐
                │   Mikrotik       │
                │   CRS326-24G-2S+ │
                └────────┬─────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
     Port 1-2       Port 3-24      Uplink to
     (NUC NICs)     (Reserved)     Corporate
```

---

## Prerequisites

- [ ] Physical access to Mikrotik CRS326-24G-2S+ switch
- [ ] Admin credentials for Mikrotik switch
- [ ] Network cable for management access
- [ ] 2 network cables for NUC dual NICs
- [ ] NUC powered on and accessible

---

## Configuration Steps

### Step 1: Access Mikrotik Switch

**Option A: WebFig (Web Interface)**
```bash
# Find switch IP (check DHCP leases on router or use network scanner)
nmap -sn 192.168.1.0/24  # Adjust to your corporate network range

# Access via browser
# Default: http://192.168.88.1 (if factory default)
# Or: http://<discovered-ip>

# Default credentials (if not changed):
# Username: admin
# Password: (blank)
```

**Option B: WinBox (Recommended for RouterOS)**
- Download WinBox from mikrotik.com
- Launch WinBox
- Connect to switch MAC address or IP
- Login with admin credentials

**Option C: SSH**
```bash
ssh admin@<switch-ip>
# Enter password when prompted
```

---

### Step 2: Create VLAN for Isolated Network (Recommended Approach)

Using VLANs keeps the configuration clean and allows coexistence with other networks on the same switch.

**Via WebFig/WinBox:**
1. Navigate to **Interfaces → VLAN**
2. Click **Add New**
3. Configure:
   - Name: `vlan-attic`
   - VLAN ID: `10` (or choose unused VLAN ID)
   - Interface: `bridge` (or appropriate bridge interface)

**Via CLI:**
```bash
/interface vlan add name=vlan-attic vlan-id=10 interface=bridge
```

---

### Step 3: Create Bridge for Attic Network

**Via CLI:**
```bash
# Create bridge for Attic network
/interface bridge add name=bridge-attic protocol-mode=none

# Add VLAN interface to bridge
/interface bridge port add bridge=bridge-attic interface=vlan-attic

# Add physical ports for NUC dual NICs (assuming ports 1-2)
/interface bridge port add bridge=bridge-attic interface=ether1
/interface bridge port add bridge=bridge-attic interface=ether2
```

**Via WebFig:**
1. Navigate to **Bridge**
2. Click **Add New**
3. Name: `bridge-attic`
4. Navigate to **Bridge → Ports**
5. Add ports: ether1, ether2, vlan-attic to bridge-attic

---

### Step 4: Assign IP Address to Bridge Interface

The Mikrotik switch itself will act as the gateway for the isolated network.

**Via CLI:**
```bash
/ip address add address=10.0.0.1/24 interface=bridge-attic
```

**Via WebFig:**
1. Navigate to **IP → Addresses**
2. Click **Add New**
3. Address: `10.0.0.1/24`
4. Interface: `bridge-attic`

---

### Step 5: Configure DHCP Server (Optional - Static IP Recommended)

For simplicity, we'll use a static IP (10.0.0.10) for the NUC. However, DHCP can be useful for testing.

**Option A: Static IP Only (Recommended)**
- Skip DHCP server setup
- Configure NUC with static IP 10.0.0.10/24
- Gateway: 10.0.0.1
- DNS: 1.1.1.1, 8.8.8.8

**Option B: DHCP Server for Convenience**

**Via CLI:**
```bash
# Create DHCP pool
/ip pool add name=pool-attic ranges=10.0.0.100-10.0.0.200

# Create DHCP server
/ip dhcp-server add name=dhcp-attic interface=bridge-attic address-pool=pool-attic disabled=no

# Configure DHCP network
/ip dhcp-server network add address=10.0.0.0/24 gateway=10.0.0.1 dns-server=1.1.1.1,8.8.8.8
```

**Via WebFig:**
1. Navigate to **IP → Pool**
   - Add pool: `pool-attic` with range `10.0.0.100-10.0.0.200`
2. Navigate to **IP → DHCP Server**
   - Add server: interface `bridge-attic`, pool `pool-attic`
3. Navigate to **IP → DHCP Server → Networks**
   - Add network: `10.0.0.0/24`, gateway `10.0.0.1`, DNS `1.1.1.1,8.8.8.8`

---

### Step 6: Configure Firewall Rules (Security)

Allow traffic within the isolated network but restrict access from corporate network.

**Via CLI:**
```bash
# Allow traffic within bridge-attic
/ip firewall filter add chain=forward in-interface=bridge-attic out-interface=bridge-attic action=accept comment="Allow internal Attic network traffic"

# Allow established/related connections
/ip firewall filter add chain=forward connection-state=established,related action=accept comment="Allow established/related"

# Allow Attic network to internet (for downloading packages)
/ip firewall filter add chain=forward in-interface=bridge-attic out-interface=ether-corporate action=accept comment="Allow Attic to internet"

# Drop everything else from corporate network to Attic network (isolation)
/ip firewall filter add chain=forward in-interface=ether-corporate out-interface=bridge-attic action=drop comment="Block corporate to Attic"
```

**Note**: Adjust `ether-corporate` to match your actual uplink interface name.

---

### Step 7: Configure NAT for Internet Access

The cache server needs internet access to download Nix packages. Configure NAT (masquerade) for the isolated network.

**Via CLI:**
```bash
/ip firewall nat add chain=srcnat out-interface=ether-corporate src-address=10.0.0.0/24 action=masquerade comment="NAT for Attic network"
```

**Via WebFig:**
1. Navigate to **IP → Firewall → NAT**
2. Click **Add New**
3. Chain: `srcnat`
4. Src. Address: `10.0.0.0/24`
5. Out. Interface: `ether-corporate` (adjust to uplink interface)
6. Action: `masquerade`

---

### Step 8: Physical Connections

1. **Identify NUC Network Interfaces**:
   - NIC 1: Will be connected to Mikrotik port 1 (management)
   - NIC 2: Will be connected to Mikrotik port 2 (data)

2. **Connect Cables**:
   - Connect NUC NIC 1 → Mikrotik port ether1
   - Connect NUC NIC 2 → Mikrotik port ether2

3. **Verify Link Status**:
   ```bash
   # On Mikrotik CLI
   /interface monitor-traffic ether1,ether2
   # Should show link up and traffic when NUC is booted
   ```

---

### Step 9: Test Connectivity

**From Mikrotik Switch:**
```bash
# Ping NUC (assumes NUC configured with 10.0.0.10)
/ping 10.0.0.10 count=5

# Expected output: 5 packets transmitted, 5 received, 0% packet loss
```

**From Developer Laptop:**

First, connect laptop to the isolated network (temporarily plug into port 3 or higher on the bridge-attic ports):

```bash
# On laptop - get IP via DHCP or configure static in 10.0.0.0/24 range
ip addr show  # Check assigned IP

# Ping gateway
ping 10.0.0.1

# Ping NUC
ping 10.0.0.10

# Test internet connectivity through NAT
ping 1.1.1.1
ping google.com
```

---

### Step 10: Document Configuration

Record the following information for the infrastructure survey (L1.1):

```yaml
Network Configuration:
  Subnet: 10.0.0.0/24
  Gateway: 10.0.0.1 (Mikrotik bridge-attic)
  VLAN ID: 10 (vlan-attic)
  DHCP Range: 10.0.0.100-10.0.0.200 (if enabled)
  DNS Servers: 1.1.1.1, 8.8.8.8

  NUC Assignments:
    IP Address: 10.0.0.10/24 (static)
    Hostname: attic-cache
    NIC 1 (Management): Connected to ether1, MAC: <to be filled>
    NIC 2 (Data): Connected to ether2, MAC: <to be filled>

  Mikrotik Ports:
    ether1: NUC Management NIC
    ether2: NUC Data NIC
    ether3-24: Reserved for future expansion
    Uplink: <corporate network interface>
```

---

## Verification Checklist

- [ ] Mikrotik switch accessible via WebFig/WinBox/SSH
- [ ] VLAN `vlan-attic` (VLAN ID 10) created
- [ ] Bridge `bridge-attic` created with VLAN and physical ports
- [ ] IP address 10.0.0.1/24 assigned to `bridge-attic`
- [ ] DHCP server configured (or skipped if using static IP)
- [ ] Firewall rules configured (internal allow, corporate isolation)
- [ ] NAT configured for internet access
- [ ] NUC dual NICs connected to ether1 and ether2
- [ ] Link status shows UP on both ports
- [ ] Can ping 10.0.0.10 from Mikrotik switch
- [ ] Can ping 10.0.0.10 from developer laptop (when connected to isolated network)
- [ ] Internet connectivity works from isolated network (ping 1.1.1.1)

---

## Troubleshooting

### Issue: Cannot ping NUC at 10.0.0.10

**Diagnosis**:
1. Check NUC is powered on and network configured
2. Verify link status on Mikrotik:
   ```bash
   /interface print stats
   # Look for ether1 and ether2 - should show "running"
   ```
3. Check bridge membership:
   ```bash
   /interface bridge port print
   # Verify ether1 and ether2 are in bridge-attic
   ```
4. Verify NUC network configuration:
   ```bash
   # On NUC (via console or SSH if already configured)
   ip addr show  # Check IP assigned to interfaces
   ip route show  # Check default gateway
   ```

**Solution**:
- If link down: Check cable connections
- If link up but no ping: Verify NUC has IP 10.0.0.10/24 configured
- If NUC has IP but no ping: Check firewall rules on Mikrotik

---

### Issue: No Internet Access from Isolated Network

**Diagnosis**:
1. Check NAT rule configured:
   ```bash
   /ip firewall nat print
   # Should show srcnat rule for 10.0.0.0/24
   ```
2. Check default route on Mikrotik:
   ```bash
   /ip route print
   # Should show default route via corporate network
   ```
3. Test from Mikrotik itself:
   ```bash
   /ping 1.1.1.1
   # If works, issue is with NAT or routing
   ```

**Solution**:
- Add NAT masquerade rule (see Step 7)
- Verify uplink interface name in NAT rule matches actual interface
- Check corporate network allows traffic from Mikrotik

---

### Issue: Corporate Network Can Access Attic Network (Isolation Broken)

**Diagnosis**:
1. Check firewall filter rules:
   ```bash
   /ip firewall filter print
   # Should show DROP rule for corporate → bridge-attic
   ```
2. Verify rule order (rules are processed top to bottom):
   ```bash
   /ip firewall filter print
   # DROP rule should come BEFORE any general ACCEPT rules
   ```

**Solution**:
- Add or move DROP rule higher in the chain
- Ensure no overly-permissive ACCEPT rules before the DROP rule

---

## Alternative: Physical Port Isolation (No VLAN)

If VLAN configuration is complex or unnecessary, you can use physical port isolation:

1. **Assign ports 1-8 to isolated network**
2. **Create separate bridge** (bridge-attic)
3. **Add ports to bridge** (ether1-ether8)
4. **Configure IP, DHCP, NAT as above**

This is simpler but uses more physical ports.

---

## Security Considerations

1. **Change Default Credentials**: If using factory default Mikrotik credentials, change them immediately:
   ```bash
   /user set admin password=<new-strong-password>
   ```

2. **Disable Unused Services**:
   ```bash
   /ip service disable telnet,ftp,www
   /ip service enable ssh,winbox,api-ssl
   ```

3. **Restrict Management Access**:
   ```bash
   # Only allow management from corporate network or specific IPs
   /ip service set ssh address=192.168.1.0/24
   /ip service set winbox address=192.168.1.0/24
   ```

4. **Regular Firmware Updates**:
   - Check RouterOS version: `/system package print`
   - Update via System → Packages → Check For Updates (WebFig)

---

## Definition of Done (L1.0)

- [x] Mikrotik switch configured with isolated LAN (10.0.0.0/24)
- [x] NUC dual NICs connected to switch (ether1 and ether2)
- [x] Network reachable from developer laptop (test connectivity)
- [x] Internet access working from isolated network (for Nix downloads)
- [x] Firewall configured (isolation + NAT)
- [x] Configuration documented (network settings, port assignments)

---

## Next Steps

Proceed to **L1.1: Survey Office Infrastructure** to document NUC hardware specifications.
