{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.networking.vlans;
in
{
  options.n3x.networking.vlans = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable VLAN configuration for network segmentation";
    };

    storageVlan = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable dedicated VLAN for storage traffic";
      };

      id = mkOption {
        type = types.int;
        default = 100;
        description = "VLAN ID for storage network";
      };

      interface = mkOption {
        type = types.str;
        default = "bond0";
        description = "Parent interface for storage VLAN";
      };

      ipAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.0.100.11/24";
        description = "IP address for storage VLAN interface";
      };
    };

    managementVlan = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable dedicated VLAN for management traffic";
      };

      id = mkOption {
        type = types.int;
        default = 10;
        description = "VLAN ID for management network";
      };

      interface = mkOption {
        type = types.str;
        default = "bond0";
        description = "Parent interface for management VLAN";
      };

      ipAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.0.10.11/24";
        description = "IP address for management VLAN interface";
      };
    };

    clusterVlan = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable dedicated VLAN for K3s cluster traffic";
      };

      id = mkOption {
        type = types.int;
        default = 200;
        description = "VLAN ID for cluster network";
      };

      interface = mkOption {
        type = types.str;
        default = "bond0";
        description = "Parent interface for cluster VLAN";
      };

      ipAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.0.200.11/24";
        description = "IP address for cluster VLAN interface";
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure 8021q module is loaded for VLAN support
    boot.kernelModules = [ "8021q" ];

    # Configure VLANs using systemd-networkd
    systemd.network = {
      enable = true;

      # Storage VLAN
      netdevs = mkMerge [
        (mkIf cfg.storageVlan.enable {
          "20-vlan-storage" = {
            netdevConfig = {
              Kind = "vlan";
              Name = "${cfg.storageVlan.interface}.${toString cfg.storageVlan.id}";
            };
            vlanConfig.Id = cfg.storageVlan.id;
          };
        })

        # Management VLAN
        (mkIf cfg.managementVlan.enable {
          "20-vlan-management" = {
            netdevConfig = {
              Kind = "vlan";
              Name = "${cfg.managementVlan.interface}.${toString cfg.managementVlan.id}";
            };
            vlanConfig.Id = cfg.managementVlan.id;
          };
        })

        # Cluster VLAN
        (mkIf cfg.clusterVlan.enable {
          "20-vlan-cluster" = {
            netdevConfig = {
              Kind = "vlan";
              Name = "${cfg.clusterVlan.interface}.${toString cfg.clusterVlan.id}";
            };
            vlanConfig.Id = cfg.clusterVlan.id;
          };
        })
      ];

      # Configure networks for VLANs
      networks = mkMerge [
        # Parent interface configuration (ensure VLANs are attached)
        {
          "15-${cfg.storageVlan.interface}" = {
            matchConfig.Name = cfg.storageVlan.interface;
            vlan = mkMerge [
              (mkIf cfg.storageVlan.enable [ "${cfg.storageVlan.interface}.${toString cfg.storageVlan.id}" ])
              (mkIf cfg.managementVlan.enable [ "${cfg.managementVlan.interface}.${toString cfg.managementVlan.id}" ])
              (mkIf cfg.clusterVlan.enable [ "${cfg.clusterVlan.interface}.${toString cfg.clusterVlan.id}" ])
            ];
          };
        }

        # Storage VLAN network configuration
        (mkIf (cfg.storageVlan.enable && cfg.storageVlan.ipAddress != null) {
          "20-vlan-storage" = {
            matchConfig.Name = "${cfg.storageVlan.interface}.${toString cfg.storageVlan.id}";
            address = [ cfg.storageVlan.ipAddress ];
            networkConfig = {
              DHCP = "no";
              IPv6AcceptRA = false;
              LinkLocalAddressing = "no";
            };
          };
        })

        # Management VLAN network configuration
        (mkIf (cfg.managementVlan.enable && cfg.managementVlan.ipAddress != null) {
          "20-vlan-management" = {
            matchConfig.Name = "${cfg.managementVlan.interface}.${toString cfg.managementVlan.id}";
            address = [ cfg.managementVlan.ipAddress ];
            networkConfig = {
              DHCP = "no";
              IPv6AcceptRA = false;
              LinkLocalAddressing = "no";
            };
          };
        })

        # Cluster VLAN network configuration
        (mkIf (cfg.clusterVlan.enable && cfg.clusterVlan.ipAddress != null) {
          "20-vlan-cluster" = {
            matchConfig.Name = "${cfg.clusterVlan.interface}.${toString cfg.clusterVlan.id}";
            address = [ cfg.clusterVlan.ipAddress ];
            networkConfig = {
              DHCP = "no";
              IPv6AcceptRA = false;
              LinkLocalAddressing = "no";
            };
          };
        })
      ];
    };

    # Add VLAN monitoring commands
    environment.shellAliases = mkMerge [
      {
        vlan-list = "ip -d link show | grep vlan";
      }
      (mkIf cfg.storageVlan.enable {
        vlan-storage = "ip -d link show ${cfg.storageVlan.interface}.${toString cfg.storageVlan.id}";
      })
      (mkIf cfg.managementVlan.enable {
        vlan-mgmt = "ip -d link show ${cfg.managementVlan.interface}.${toString cfg.managementVlan.id}";
      })
      (mkIf cfg.clusterVlan.enable {
        vlan-cluster = "ip -d link show ${cfg.clusterVlan.interface}.${toString cfg.clusterVlan.id}";
      })
    ];

    # Service to verify VLAN configuration
    systemd.services.verify-vlans = mkIf (cfg.storageVlan.enable || cfg.managementVlan.enable || cfg.clusterVlan.enable) {
      description = "Verify VLAN configuration";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
            echo "=== VLAN Configuration Status ==="
            ${pkgs.iproute2}/bin/ip -d link show | grep -E "vlan|${cfg.storageVlan.interface}\.${toString cfg.storageVlan.id}|${cfg.managementVlan.interface}\.${toString cfg.managementVlan.id}|${cfg.clusterVlan.interface}\.${toString cfg.clusterVlan.id}" || true
            echo ""
            echo "=== VLAN IP Addresses ==="
            ${pkgs.iproute2}/bin/ip addr show | grep -E "${cfg.storageVlan.interface}\.${toString cfg.storageVlan.id}|${cfg.managementVlan.interface}\.${toString cfg.managementVlan.id}|${cfg.clusterVlan.interface}\.${toString cfg.clusterVlan.id}" -A 2 || true
          '
        '';
      };
    };
  };
}