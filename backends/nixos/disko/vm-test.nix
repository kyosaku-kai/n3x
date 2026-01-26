{ lib, ... }:

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = lib.mkDefault "/dev/vda"; # Virtual disk for QEMU/KVM
        content = {
          type = "gpt";
          partitions = {
            # EFI System Partition
            ESP = {
              priority = 1;
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "defaults" "umask=0077" ];
              };
            };

            # Swap partition - smaller for VMs
            swap = {
              priority = 2;
              size = "2G";
              content = {
                type = "swap";
              };
            };

            # Root partition - single partition for simplicity in testing
            root = {
              priority = 100;
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

  # Boot loader configuration for VMs
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot";
    timeout = 1; # Faster boot for testing
  };

  # Minimal storage configuration for testing
  boot.kernel.sysctl = {
    "vm.swappiness" = 60; # Default for VMs
    "fs.inotify.max_user_watches" = 524288;
    "fs.file-max" = 1048576;
  };

  # Create necessary directories for K3s and Longhorn testing
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher 0755 root root -"
    "d /var/lib/rancher/k3s 0755 root root -"
    "d /var/lib/longhorn 0755 root root -"
    "d /var/lib/longhorn/replicas 0755 root root -"
  ];

  # Disable services not needed in VMs
  services.fstrim.enable = false;
  services.smartd.enable = false;
}
