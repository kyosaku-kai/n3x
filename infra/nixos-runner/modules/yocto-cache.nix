# Yocto cache module for n3x build runners
#
# Configures DL_DIR and SSTATE_DIR for ISAR/Yocto builds.
# Caches are ephemeral (accept rebuild cost for simplicity).
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.yocto-cache;
in
{
  options.n3x.yocto-cache = {
    enable = mkEnableOption "Yocto/ISAR cache directories";

    dlDir = mkOption {
      type = types.path;
      default = "/var/cache/yocto/downloads";
      description = "Yocto DL_DIR for source downloads";
    };

    sstateDir = mkOption {
      type = types.path;
      default = "/var/cache/yocto/sstate";
      description = "Yocto SSTATE_DIR for shared state cache";
    };

    cacheDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Device for cache volume (e.g., /dev/nvme1n1)";
    };

    cacheMountPoint = mkOption {
      type = types.path;
      default = "/var/cache/yocto";
      description = "Mount point for cache volume";
    };

    cacheUser = mkOption {
      type = types.str;
      default = "gitlab-runner";
      description = "User that owns the cache directories";
    };

    cacheGroup = mkOption {
      type = types.str;
      default = "gitlab-runner";
      description = "Group that owns the cache directories";
    };
  };

  config = mkIf cfg.enable {
    # Mount cache device if specified (using disko-compatible approach)
    fileSystems = mkIf (cfg.cacheDevice != null) {
      "${cfg.cacheMountPoint}" = {
        device = cfg.cacheDevice;
        fsType = "ext4";
        options = [ "defaults" "noatime" ];
        autoFormat = false;  # Assume pre-formatted
      };
    };

    # Create cache directories with proper permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheMountPoint} 0755 ${cfg.cacheUser} ${cfg.cacheGroup} -"
      "d ${cfg.dlDir} 0755 ${cfg.cacheUser} ${cfg.cacheGroup} -"
      "d ${cfg.sstateDir} 0755 ${cfg.cacheUser} ${cfg.cacheGroup} -"
    ];

    # Environment variables for Yocto/ISAR builds
    # These can be picked up by kas or bitbake directly
    environment.variables = {
      YOCTO_DL_DIR = cfg.dlDir;
      YOCTO_SSTATE_DIR = cfg.sstateDir;
    };

    # Profile script to set DL_DIR and SSTATE_DIR for interactive shells
    environment.etc."profile.d/yocto-cache.sh".text = ''
      # Yocto/ISAR cache directories
      export DL_DIR="${cfg.dlDir}"
      export SSTATE_DIR="${cfg.sstateDir}"
    '';
  };
}
