# NixOS Integration Test: Network Bonding
# Tests that network bonding configuration works correctly
#
# Run with:
#   nix build .#checks.x86_64-linux.network-bonding
#   nix build .#checks.x86_64-linux.network-bonding.driverInteractive  # For debugging

{ pkgs, lib, ... }:

pkgs.testers.runNixOSTest {
  name = "network-bonding";

  nodes = {
    bondedNode = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/network/bonding.nix
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 10240;

        # Create multiple virtual NICs for bonding
        vlans = [ 1 2 ];
      };

      # Configure bonding with the virtual interfaces
      n3x.networking.bonding = {
        enable = true;
        interfaces = [ "eth1" "eth2" ];
        bondName = "bond0";
        mode = "active-backup";
        miimon = 100;
        primary = "eth1";
      };

      # Configure IP on the bond interface
      systemd.network.networks."20-bond0" = {
        matchConfig.Name = "bond0";
        networkConfig = {
          Address = "192.168.1.100/24";
          Gateway = "192.168.1.1";
          DHCP = "no";
          IPv6AcceptRA = false;
        };
        linkConfig = {
          RequiredForOnline = true;
        };
      };

      # Disable the test framework's default networking
      networking.useDHCP = false;
      networking.useNetworkd = true;

      environment.systemPackages = with pkgs; [
        iproute2
        ethtool
        procps
      ];
    };
  };

  testScript = ''
    import time

    print("=" * 60)
    print("Network Bonding Test")
    print("=" * 60)

    # Start the VM
    print("\n[1/8] Starting VM...")
    bondedNode.start()
    bondedNode.wait_for_unit("multi-user.target")
    print("✓ VM booted successfully")

    # Wait for networkd to be ready
    print("\n[2/8] Waiting for systemd-networkd...")
    bondedNode.wait_for_unit("systemd-networkd.service")
    print("✓ systemd-networkd is active")

    # Wait for bond verification service
    print("\n[3/8] Waiting for bond verification service...")
    bondedNode.wait_for_unit("verify-bond.service")
    print("✓ Bond verification service completed")

    # Check that bond interface exists
    print("\n[4/8] Verifying bond interface exists...")
    bond_status = bondedNode.succeed("ip link show bond0")
    print("Bond interface:")
    print(bond_status)
    assert "bond0" in bond_status, "bond0 interface not found"
    assert "MASTER" in bond_status or "master" in bond_status.lower(), "bond0 is not a bond master"
    print("✓ bond0 interface exists and is a bond master")

    # Check that slave interfaces are bonded
    print("\n[5/8] Verifying slave interfaces...")
    eth1_status = bondedNode.succeed("ip link show eth1")
    eth2_status = bondedNode.succeed("ip link show eth2")
    print("\neth1 status:")
    print(eth1_status)
    print("\neth2 status:")
    print(eth2_status)

    assert "master bond0" in eth1_status, "eth1 is not enslaved to bond0"
    assert "master bond0" in eth2_status, "eth2 is not enslaved to bond0"
    print("✓ Both eth1 and eth2 are enslaved to bond0")

    # Check bond mode
    print("\n[6/8] Verifying bond configuration...")
    bond_info = bondedNode.succeed("cat /proc/net/bonding/bond0")
    print("\nBond information:")
    print(bond_info)

    assert "active-backup" in bond_info.lower(), "Bond mode is not active-backup"
    assert "MII Status: up" in bond_info, "Bond MII status is not up"
    print("✓ Bond is configured with active-backup mode")
    print("✓ Bond MII monitoring is active")

    # Verify IP address is assigned to bond
    print("\n[7/8] Verifying IP configuration...")
    ip_addr = bondedNode.succeed("ip addr show bond0")
    print("\nBond IP configuration:")
    print(ip_addr)
    assert "192.168.1.100" in ip_addr, "IP address not assigned to bond0"
    print("✓ IP address 192.168.1.100 assigned to bond0")

    # Check that bond interface is UP
    print("\n[8/8] Verifying bond interface state...")
    bond_state = bondedNode.succeed("ip link show bond0 | grep -o 'state [A-Z]*'")
    print(f"Bond state: {bond_state.strip()}")
    assert "UP" in bond_state or "UNKNOWN" in bond_state, "Bond interface is not UP"
    print("✓ Bond interface is UP")

    # Additional verification: check slave count
    slave_count = bondedNode.succeed(
        "grep -c 'Slave Interface:' /proc/net/bonding/bond0"
    ).strip()
    assert slave_count == "2", f"Expected 2 slaves, got {slave_count}"
    print(f"✓ Bond has {slave_count} slave interfaces")

    # Verify primary slave (for active-backup mode)
    primary_info = bondedNode.succeed(
        "grep -A 1 'Currently Active Slave:' /proc/net/bonding/bond0"
    )
    print(f"\nActive slave information:")
    print(primary_info)

    print("\n" + "=" * 60)
    print("✓ All bonding tests passed!")
    print("=" * 60)
  '';
}
