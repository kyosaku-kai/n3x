{ lib, ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            # EFI System Partition
            ESP = {
              priority = 1;
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" "umask=0077" ];
              };
            };

            # Boot partition for ZFS-incompatible files
            boot = {
              priority = 2;
              size = "2G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/boot/efi";
                mountOptions = [ "defaults" "noatime" ];
              };
            };

            # Swap partition (ZFS swap can be problematic)
            swap = {
              priority = 3;
              size = "8G";
              content = {
                type = "swap";
                randomEncryption = false;
              };
            };

            # ZFS partition for everything else
            zfs = {
              priority = 100;
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };
    };

    zpool = {
      rpool = {
        type = "zpool";
        mode = ""; # Single disk, no redundancy
        rootFsOptions = {
          compression = "lz4";
          acltype = "posixacl";
          xattr = "sa";
          atime = "off";
          mountpoint = "none";
          # Security and performance options
          "com.sun:auto-snapshot" = "false";
        };

        options = {
          ashift = "12"; # 4K sectors
          autotrim = "on"; # Enable TRIM
        };

        datasets = {
          # Root dataset
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
              atime = "off";
              xattr = "sa";
              acltype = "posixacl";
            };
          };

          # Home dataset
          home = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
              atime = "off";
            };
          };

          # Var dataset
          var = {
            type = "zfs_fs";
            mountpoint = "/var";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
              atime = "off";
              xattr = "sa";
            };
          };

          # Var/log dataset with different compression
          "var/log" = {
            type = "zfs_fs";
            mountpoint = "/var/log";
            options = {
              mountpoint = "legacy";
              compression = "zstd";
              atime = "off";
            };
          };

          # Tmp dataset
          tmp = {
            type = "zfs_fs";
            mountpoint = "/tmp";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
              atime = "off";
              devices = "off";
              setuid = "off";
              exec = "off";
            };
          };

          # Container runtime storage
          containerd = {
            type = "zfs_fs";
            mountpoint = "/var/lib/rancher";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
              atime = "off";
              # Optimize for container layers
              recordsize = "128K";
              logbias = "throughput";
            };
          };

          # Longhorn storage dataset
          longhorn = {
            type = "zfs_fs";
            mountpoint = "/var/lib/longhorn";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
              atime = "off";
              # Optimize for Longhorn block storage
              recordsize = "128K";
              logbias = "throughput";
              primarycache = "all";
              secondarycache = "all";
              redundant_metadata = "all";
            };
          };

          # Reserved dataset for snapshots and system use
          reserved = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              reservation = "10G";
            };
          };
        };
      };
    };
  };

  # Boot loader configuration
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      efi.efiSysMountPoint = "/boot";
      timeout = 3;
    };

    # ZFS support
    supportedFilesystems.zfs = true;
    zfs = {
      devNodes = "/dev/disk/by-id";
      forceImportAll = false;
      forceImportRoot = false;
    };

    # ZFS kernel parameters
    kernelParams = [
      "zfs.zfs_arc_max=4294967296" # 4GB ARC max
      "zfs.zfs_arc_min=1073741824" # 1GB ARC min
      "zfs.l2arc_write_boost=8388608" # 8MB L2ARC write boost
      "zfs.l2arc_write_max=8388608" # 8MB L2ARC write max
    ];
  };

  # ZFS maintenance services
  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "Sun, 02:00";
    };
    autoSnapshot = {
      enable = false; # Disable auto-snapshots by default
      # Can be enabled per-dataset if needed
    };
    trim = {
      enable = true;
      interval = "weekly";
    };
  };

  # Storage optimization for ZFS
  boot.kernel.sysctl = {
    # VM tuning for ZFS
    "vm.swappiness" = 10;
    "vm.dirty_ratio" = 15;
    "vm.dirty_background_ratio" = 5;

    # File system tuning
    "fs.inotify.max_user_watches" = 1048576;
    "fs.inotify.max_user_instances" = 8192;
    "fs.file-max" = 2097152;

    # Network tuning for storage traffic
    # Note: Network buffer settings configured in modules/common/networking.nix
  };

  # ZFS event daemon for monitoring
  services.zfs.zed = {
    enable = true;
    settings = {
      ZED_DEBUG_LOG = "/var/log/zed.debug.log";
      ZED_EMAIL_ADDR = ""; # Configure for alerts
      ZED_NOTIFY_VERBOSE = true;
    };
  };

  # SMART monitoring for disk health
  services.smartd = {
    enable = true;
    defaults.monitored = ''
      -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,35,40
    '';
  };
}
