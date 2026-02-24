# Disko ZFS module for n3x build runners
#
# Configures ZFS-backed storage via disko for /nix/store with zstd compression.
# Supports two disk layouts:
#   - "dedicated" (default): whole disk is ZFS (EC2 pattern, second disk)
#   - "single-disk": ESP + root ext4 + ZFS on one disk (bare metal)
#
# ZFS value: zstd compression (1.5-2x savings), checksumming, snapshots, ARC cache.
# No ZFS replication — HTTP substituters handle cache sharing between nodes.
#
# NOTE: ZFS pool and dataset options are shared with first-boot-format.nix
# (used for AMI-based deployments). Keep both files in sync.
{ config, lib, ... }:

let
  cfg = config.n3x.disko-zfs;
in
{
  options.n3x.disko-zfs = {
    enable = lib.mkEnableOption "ZFS-backed storage via disko";

    device = lib.mkOption {
      type = lib.types.str;
      description = "Block device for the ZFS cache pool (e.g., /dev/nvme0n1, /dev/nvme1n1)";
      example = "/dev/nvme1n1";
    };

    diskLayout = lib.mkOption {
      type = lib.types.enum [ "dedicated" "single-disk" ];
      default = "dedicated";
      description = ''
        Disk partitioning layout:
        - "dedicated": whole disk is a single ZFS partition (EC2 pattern, second disk)
        - "single-disk": ESP + root ext4 + ZFS partition on one disk (bare metal)
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "EFI System Partition size (only for single-disk layout)";
    };

    rootSize = lib.mkOption {
      type = lib.types.str;
      default = "50G";
      description = "Root ext4 partition size (only for single-disk layout)";
    };

    poolName = lib.mkOption {
      type = lib.types.str;
      default = "cache";
      description = "Name of the ZFS pool";
    };

    hostId = lib.mkOption {
      type = lib.types.str;
      description = "8-character hex host ID required by ZFS. Generate with: head -c4 /dev/urandom | od -A none -t x4 | tr -d ' '";
      example = "a8c0b12f";
    };

    reservedSpace = lib.mkOption {
      type = lib.types.str;
      default = "10G";
      description = "Space reservation for SSD over-provisioning health";
    };

    extraDatasets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          mountpoint = lib.mkOption {
            type = lib.types.str;
            description = "Where to mount this dataset";
          };
          properties = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Additional ZFS properties for this dataset (e.g., recordsize)";
          };
        };
      });
      default = { };
      description = "Additional ZFS datasets beyond /nix";
      example = lib.literalExpression ''
        {
          "yocto" = {
            mountpoint = "/var/cache/yocto";
            properties.recordsize = "1M";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ZFS requires a unique hostId per machine
    networking.hostId = cfg.hostId;

    # Bootloader: only for single-disk layout (bare metal manages its own boot)
    # EC2 (dedicated) uses cloud-provided bootloader
    boot.loader.systemd-boot.enable = lib.mkIf (cfg.diskLayout == "single-disk") (lib.mkDefault true);
    boot.loader.efi.canTouchEfiVariables = lib.mkIf (cfg.diskLayout == "single-disk") (lib.mkDefault true);

    disko.devices = {
      disk =
        if cfg.diskLayout == "dedicated" then {
          # Dedicated disk: whole device is a single ZFS partition
          ${cfg.poolName} = {
            type = "disk";
            device = cfg.device;
            content = {
              type = "gpt";
              partitions = {
                zfs = {
                  size = "100%";
                  content = {
                    type = "zfs";
                    pool = cfg.poolName;
                  };
                };
              };
            };
          };
        } else {
          # Single-disk: ESP + root ext4 + ZFS on one drive
          main = {
            type = "disk";
            device = cfg.device;
            content = {
              type = "gpt";
              partitions = {
                esp = {
                  size = cfg.espSize;
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot";
                    mountOptions = [ "umask=0077" ];
                  };
                };
                root = {
                  size = cfg.rootSize;
                  content = {
                    type = "filesystem";
                    format = "ext4";
                    mountpoint = "/";
                  };
                };
                zfs = {
                  size = "100%";
                  content = {
                    type = "zfs";
                    pool = cfg.poolName;
                  };
                };
              };
            };
          };
        };

      zpool.${cfg.poolName} = {
        type = "zpool";

        # Pool-level options (zpool create -o)
        options = {
          ashift = "12"; # 4K sectors for NVMe/modern storage
          autotrim = "on"; # Continuous TRIM for SSD health
          cachefile = "none"; # NixOS manages pool imports
        };

        # Root filesystem options (zpool create -O, inherited by all datasets)
        rootFsOptions = {
          compression = "zstd";
          atime = "off";
          "com.sun:auto-snapshot" = "false";
          canmount = "off";
          mountpoint = "none";
          xattr = "sa";
          acltype = "posixacl";
          dnodesize = "auto";
        };

        datasets = {
          # Primary dataset: /nix (includes /nix/store)
          "nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              recordsize = "128K";
            };
          };

          # SSD over-provisioning reservation (unmountable, just reserves space)
          "reserved" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              canmount = "off";
              refreservation = cfg.reservedSpace;
            };
          };
        } // lib.mapAttrs
          (name: ds: {
            type = "zfs_fs";
            mountpoint = ds.mountpoint;
            options = {
              mountpoint = "legacy";
            } // ds.properties;
          })
          cfg.extraDatasets;
      };
    };

    # ZFS kernel support
    boot.supportedFilesystems.zfs = true;
    boot.zfs.forceImportRoot = false;

    # Data integrity: weekly scrub
    services.zfs.autoScrub.enable = true;

    # Periodic TRIM (supplements autotrim=on for thoroughness)
    services.zfs.trim.enable = true;
  };
}
