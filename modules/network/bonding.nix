{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.networking.bonding;
in
{
  options.n3x.networking.bonding = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable network bonding for dual-NIC redundancy";
    };

    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ "enp1s0" "enp2s0" ];
      description = "List of network interfaces to bond";
    };

    bondName = mkOption {
      type = types.str;
      default = "bond0";
      description = "Name of the bond interface";
    };

    mode = mkOption {
      type = types.enum [ "balance-rr" "active-backup" "balance-xor" "broadcast" "802.3ad" "balance-tlb" "balance-alb" ];
      default = "active-backup";
      description = ''
        Bonding mode to use:
        - balance-rr: Round-robin (mode 0)
        - active-backup: Active-backup for redundancy (mode 1)
        - balance-xor: XOR policy (mode 2)
        - broadcast: Broadcast policy (mode 3)
        - 802.3ad: IEEE 802.3ad Dynamic link aggregation (mode 4)
        - balance-tlb: Adaptive transmit load balancing (mode 5)
        - balance-alb: Adaptive load balancing (mode 6)
      '';
    };

    miimon = mkOption {
      type = types.int;
      default = 100;
      description = "Link monitoring frequency in milliseconds";
    };

    primary = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "enp1s0";
      description = "Primary interface for active-backup mode";
    };

    lacp_rate = mkOption {
      type = types.enum [ "slow" "fast" ];
      default = "slow";
      description = "LACP rate for 802.3ad mode (slow = 30s, fast = 1s)";
    };

    xmit_hash_policy = mkOption {
      type = types.enum [ "layer2" "layer2+3" "layer3+4" "encap2+3" "encap3+4" ];
      default = "layer2+3";
      description = "Transmit hash policy for balance-xor, 802.3ad, and tlb modes";
    };
  };

  config = mkIf cfg.enable {
    # Enable kernel bonding module
    boot.kernelModules = [ "bonding" ];

    # Configure systemd-networkd for bonding
    systemd.network = {
      enable = true;

      # Create bond interface
      netdevs."10-${cfg.bondName}" = {
        netdevConfig = {
          Kind = "bond";
          Name = cfg.bondName;
        };
        bondConfig = {
          Mode = cfg.mode;
          MIIMonitorSec = "${toString cfg.miimon}ms";

          # Add primary interface if specified (for active-backup mode)
          ${if cfg.primary != null then "PrimaryReselectPolicy" else null} =
            if cfg.primary != null then "always" else null;
          ${if cfg.primary != null then "ActiveSlave" else null} = cfg.primary;

          # LACP settings for 802.3ad mode
          ${if cfg.mode == "802.3ad" then "LACPTransmitRate" else null} =
            if cfg.mode == "802.3ad" then cfg.lacp_rate else null;

          # Hash policy for applicable modes
          ${if elem cfg.mode [ "balance-xor" "802.3ad" "balance-tlb" ] then "TransmitHashPolicy" else null} =
            if elem cfg.mode [ "balance-xor" "802.3ad" "balance-tlb" ] then cfg.xmit_hash_policy else null;

          # Additional settings for robustness
          UpDelaySec = "200ms";
          DownDelaySec = "200ms";
        };
      };

      # Bind physical interfaces to bond
      networks = listToAttrs (map (iface: {
        name = "10-${iface}";
        value = {
          matchConfig.Name = iface;
          networkConfig = {
            Bond = cfg.bondName;

            # Disable DHCP on slave interfaces
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
        };
      }) cfg.interfaces);
    };

    # Disable NetworkManager if it's enabled (conflicts with systemd-networkd)
    networking.networkmanager.enable = mkForce false;

    # Use systemd-networkd for network configuration
    networking.useNetworkd = true;

    # Ensure interfaces used for bonding don't get configured elsewhere
    networking.interfaces = listToAttrs (map (iface: {
      name = iface;
      value = {
        useDHCP = mkForce false;
      };
    }) cfg.interfaces);

    # Add monitoring and debugging tools
    environment.systemPackages = with pkgs; [
      ethtool
      iproute2
      tcpdump
      iperf3
    ];

    # Service to verify bond status after boot
    systemd.services.verify-bond = {
      description = "Verify network bond configuration";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
            echo "=== Bond Interface Status ==="
            ${pkgs.iproute2}/bin/ip link show ${cfg.bondName}
            echo ""
            echo "=== Bond Slave Interfaces ==="
            for iface in ${concatStringsSep " " cfg.interfaces}; do
              ${pkgs.iproute2}/bin/ip link show $iface
            done
            echo ""
            echo "=== Bond Information ==="
            if [ -f /proc/net/bonding/${cfg.bondName} ]; then
              cat /proc/net/bonding/${cfg.bondName}
            else
              echo "Bond information not available in /proc/net/bonding/"
            fi
          '
        '';
      };
    };

    # Add bond status checking alias
    environment.shellAliases = {
      bond-status = "cat /proc/net/bonding/${cfg.bondName}";
      bond-info = "ip -d link show ${cfg.bondName}";
    };
  };
}