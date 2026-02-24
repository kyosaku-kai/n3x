# First-boot volume formatting for AMI-based deployments
#
# When deploying from a custom AMI (system.build.images.amazon), the root
# filesystem is baked into the AMI but secondary EBS volumes are attached blank
# by Pulumi. This module formats them on first boot.
#
# Formats:
#   - ZFS pool + datasets on the cache volume (when n3x.disko-zfs is enabled)
#   - ext4 on the Yocto volume (when n3x.yocto-cache.cacheDevice is set)
#
# Uses a sentinel file (/var/lib/n3x-first-boot-done) instead of
# ConditionFirstBoot= because the latter only fires on genuinely empty
# /etc, which may not be true for AMI-booted instances.
#
# ZFS pool/dataset options intentionally match disko-zfs.nix:158-206 so that
# AMI-deployed and nixos-anywhere-deployed instances have identical storage
# layouts. If you change ZFS options in disko-zfs.nix, update them here too.
{ config, lib, pkgs, ... }:

let
  cfg = config.n3x.first-boot-format;
  zfsCfg = config.n3x.disko-zfs;
  yoctoCfg = config.n3x.yocto-cache;
in
{
  options.n3x.first-boot-format = {
    enable = lib.mkEnableOption "first-boot formatting of secondary EBS volumes";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.n3x-first-boot-format = {
      description = "Format secondary EBS volumes on first boot";
      wantedBy = [ "local-fs-pre.target" ];
      before = [ "local-fs-pre.target" ];
      after = [ "systemd-udev-settle.service" ];
      requires = [ "systemd-udev-settle.service" ];

      unitConfig = {
        ConditionPathExists = "!/var/lib/n3x-first-boot-done";
        DefaultDependencies = false;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = with pkgs; [
        util-linux # blkid, mkfs.ext4
      ] ++ lib.optionals zfsCfg.enable [
        config.boot.zfs.package # zpool, zfs
      ];

      script =
        let
          poolName = zfsCfg.poolName;
          device = zfsCfg.device;
          reservedSpace = zfsCfg.reservedSpace;
        in
        ''
          set -euo pipefail

          echo "n3x-first-boot-format: starting volume initialization"

          ${lib.optionalString zfsCfg.enable ''
            # --- ZFS pool + datasets ---
            # Options match disko-zfs.nix:158-206 (pool options, rootFsOptions, datasets)
            if ! zpool list ${poolName} &>/dev/null; then
              echo "Creating ZFS pool '${poolName}' on ${device}"

              # Pool-level options (-o): match disko-zfs.nix:162-166
              # Root filesystem options (-O): match disko-zfs.nix:169-178
              zpool create \
                -f \
                -o ashift=12 \
                -o autotrim=on \
                -o cachefile=none \
                -O compression=zstd \
                -O atime=off \
                -O "com.sun:auto-snapshot=false" \
                -O canmount=off \
                -O mountpoint=none \
                -O xattr=sa \
                -O acltype=posixacl \
                -O dnodesize=auto \
                ${poolName} ${device}

              # Dataset: nix — match disko-zfs.nix:182-189
              zfs create \
                -o mountpoint=legacy \
                -o recordsize=128K \
                ${poolName}/nix

              # Dataset: reserved — match disko-zfs.nix:192-198
              zfs create \
                -o mountpoint=none \
                -o canmount=off \
                -o refreservation=${reservedSpace} \
                ${poolName}/reserved

              # Mount /nix from ZFS
              mkdir -p /nix
              mount -t zfs ${poolName}/nix /nix

              echo "ZFS pool '${poolName}' created and /nix mounted"
            else
              echo "ZFS pool '${poolName}' already exists, skipping"
            fi
          ''}

          ${lib.optionalString (yoctoCfg.enable && yoctoCfg.cacheDevice != null) ''
            # --- Yocto ext4 volume ---
            if ! blkid -o value -s TYPE ${yoctoCfg.cacheDevice} &>/dev/null; then
              echo "Formatting ${yoctoCfg.cacheDevice} as ext4 (label: yocto)"
              mkfs.ext4 -L yocto ${yoctoCfg.cacheDevice}
              echo "Yocto volume formatted"
            else
              echo "${yoctoCfg.cacheDevice} already formatted, skipping"
            fi
          ''}

          # Write sentinel — this service won't run again
          mkdir -p /var/lib
          touch /var/lib/n3x-first-boot-done
          echo "n3x-first-boot-format: complete"
        '';
    };
  };
}
