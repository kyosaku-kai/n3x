# Helper function to generate disko configuration for standard disk layouts
{ lib, ... }:

{
  # Function to create a standard disk configuration
  mkDiskConfig = {
    device ? "/dev/nvme0n1",
    diskSize ? "512G",
    swapSize ? "8G",
    rootSize ? "50G",
    varSize ? "50G",
    tmpSize ? "10G",
    containerSize ? "100G",
    useZfs ? false,
    zfsPool ? "rpool",
    encryption ? false,
    ...
  }@args:
    let
      # Calculate remaining space for Longhorn
      # This is a placeholder - actual implementation would need proper size calculation
      longhornSize = "100%";

      # Base partition layout
      basePartitions = {
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

        swap = {
          priority = 3;
          size = swapSize;
          content = {
            type = "swap";
            randomEncryption = encryption;
          };
        };
      };

      # EXT4 partitions for standard layout
      ext4Partitions = {
        root = {
          priority = 4;
          size = rootSize;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "defaults" "noatime" "errors=remount-ro" ];
          };
        };

        var = {
          priority = 5;
          size = varSize;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var";
            mountOptions = [ "defaults" "noatime" "nosuid" ];
          };
        };

        tmp = {
          priority = 6;
          size = tmpSize;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/tmp";
            mountOptions = [ "defaults" "noatime" "nosuid" "nodev" "noexec" ];
          };
        };

        containerd = {
          priority = 7;
          size = containerSize;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var/lib/rancher";
            mountOptions = [ "defaults" "noatime" ];
          };
        };

        longhorn = {
          priority = 100;
          size = longhornSize;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var/lib/longhorn";
            mountOptions = [ "defaults" "noatime" ];
            extraArgs = [ "-L" "longhorn" ];
          };
        };
      };

      # ZFS partition for ZFS layout
      zfsPartition = {
        zfs = {
          priority = 100;
          size = "100%";
          content = {
            type = "zfs";
            pool = zfsPool;
          };
        };
      };
    in
    {
      disko.devices = {
        disk = {
          main = {
            type = "disk";
            inherit device;
            content = {
              type = "gpt";
              partitions = if useZfs
                then basePartitions // zfsPartition
                else basePartitions // ext4Partitions;
            };
          };
        };
      } // lib.optionalAttrs useZfs {
        zpool = {
          ${zfsPool} = {
            type = "zpool";
            mode = "";
            rootFsOptions = {
              compression = "lz4";
              acltype = "posixacl";
              xattr = "sa";
              atime = "off";
              mountpoint = "none";
            };
            options = {
              ashift = "12";
              autotrim = "on";
            };
            datasets = {
              root = {
                type = "zfs_fs";
                mountpoint = "/";
                options = {
                  mountpoint = "legacy";
                  compression = "lz4";
                  atime = "off";
                };
              };
              var = {
                type = "zfs_fs";
                mountpoint = "/var";
                options = {
                  mountpoint = "legacy";
                  compression = "lz4";
                  atime = "off";
                };
              };
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
              containerd = {
                type = "zfs_fs";
                mountpoint = "/var/lib/rancher";
                options = {
                  mountpoint = "legacy";
                  compression = "lz4";
                  atime = "off";
                  recordsize = "128K";
                };
              };
              longhorn = {
                type = "zfs_fs";
                mountpoint = "/var/lib/longhorn";
                options = {
                  mountpoint = "legacy";
                  compression = "lz4";
                  atime = "off";
                  recordsize = "128K";
                  logbias = "throughput";
                };
              };
            };
          };
        };
      };
    };

  # Function to create a simple VM disk configuration
  mkVMDiskConfig = {
    device ? "/dev/vda",
    diskSize ? "50G",
    ...
  }@args:
    {
      disko.devices = {
        disk = {
          main = {
            type = "disk";
            inherit device;
            content = {
              type = "gpt";
              partitions = {
                ESP = {
                  priority = 1;
                  size = "512M";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot";
                  };
                };
                root = {
                  priority = 2;
                  size = "100%";
                  content = {
                    type = "filesystem";
                    format = "ext4";
                    mountpoint = "/";
                    mountOptions = [ "defaults" "noatime" ];
                  };
                };
              };
            };
          };
        };
      };
    };
}