{ lib, ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/nvme0n1"; # Standard NVMe device for N100 miniPCs
        content = {
          type = "gpt";
          partitions = {
            # EFI System Partition
            ESP = {
              priority = 1;
              size = "1G";
              type = "EF00"; # EFI System
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" "umask=0077" ];
              };
            };

            # Boot partition for kernel and initrd
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

            # Swap partition
            swap = {
              priority = 3;
              size = "8G";
              content = {
                type = "swap";
                randomEncryption = false; # Can be enabled for security
                resumeDevice = false; # Not used for resume
              };
            };

            # Root partition - kept small for system files only
            root = {
              priority = 4;
              size = "50G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [ "defaults" "noatime" "errors=remount-ro" ];
              };
            };

            # Var partition - separated for logs and state
            var = {
              priority = 5;
              size = "50G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var";
                mountOptions = [ "defaults" "noatime" "nosuid" ];
              };
            };

            # Tmp partition - separated for temporary files
            tmp = {
              priority = 6;
              size = "10G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/tmp";
                mountOptions = [ "defaults" "noatime" "nosuid" "nodev" "noexec" ];
              };
            };

            # Container runtime storage
            containerd = {
              priority = 7;
              size = "100G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/rancher";
                mountOptions = [ "defaults" "noatime" ];
              };
            };

            # Longhorn storage partition - uses remaining space
            longhorn = {
              priority = 100; # Last partition gets remaining space
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/longhorn";
                mountOptions = [ "defaults" "noatime" ];
                # Add label for easy identification
                extraArgs = [ "-L" "longhorn" ];
              };
            };
          };
        };
      };
    };
  };

  # Boot loader configuration
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot";
    timeout = 3;
  };

  # File system configuration
  fileSystems = {
    # Bind mount for K3s data to use containerd partition
    "/var/lib/rancher/k3s" = {
      device = "/var/lib/rancher/k3s";
      fsType = "none";
      options = [ "bind" "defaults" ];
    };
  };

  # Swap configuration
  swapDevices = [
    {
      device = "/dev/disk/by-label/swap";
      priority = 10;
    }
  ];

  # Storage optimization
  boot.kernel.sysctl = {
    # Note: VM tuning (vm.swappiness, vm.dirty_*) is configured in modules/common/base.nix
    # Note: File system tuning (fs.inotify.*, fs.file-max) is in modules/roles/k3s-common.nix and modules/hardware/n100.nix
    # Note: Network buffer settings are in modules/common/networking.nix

    # Storage-specific tuning
    "vm.dirty_writeback_centisecs" = 1500;
  };

  # Periodic TRIM for SSD optimization
  services.fstrim = {
    enable = true;
    interval = "weekly";
  };

  # Enable SMART monitoring
  services.smartd = {
    enable = true;
    defaults.monitored = ''
      -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,35,40
    '';
    notifications = {
      mail.enable = false; # Configure if email notifications are needed
    };
  };
}