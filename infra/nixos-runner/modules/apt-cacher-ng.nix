# apt-cacher-ng module for n3x build runners
#
# Configures apt-cacher-ng as local apt proxy.
# Upstream is JFrog Artifactory (custom packages + Debian mirror).
#
# NOTE: NixOS does not have a built-in apt-cacher-ng module, so we
# configure the service manually using systemd and config files.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.apt-cacher-ng;

  # Generate apt-cacher-ng configuration file
  configFile = pkgs.writeText "acng.conf" ''
    # apt-cacher-ng configuration for n3x build runners

    CacheDir: ${cfg.cacheDir}
    LogDir: ${cfg.logDir}
    Port: ${toString cfg.port}
    BindAddress: ${cfg.bindAddress}

    # Report page (accessible at http://localhost:${toString cfg.port}/acng-report.html)
    ReportPage: acng-report.html

    # Expiration settings
    ExThreshold: 4

    # Support HTTPS passthrough for repos that require it
    PassThroughPattern: .*

    # Remap Debian to upstream (direct or via Artifactory)
    ${optionalString (cfg.artifactoryUrl != "") ''
    # Custom Artifactory upstream for Debian
    Remap-debrep: file:debian_mirrors ${cfg.artifactoryUrl}/debian-remote ; deb.debian.org/debian
    ''}

    ${optionalString (cfg.artifactoryUrl == "") ''
    # Direct upstream Debian mirrors
    Remap-debrep: file:debian_mirrors http://deb.debian.org/debian
    ''}

    # Verbose logging for debugging
    VerboseLog: 1

    # Don't cache incomplete downloads
    DontCache: \.torrent$|incomplete/

    ${cfg.extraConfig}
  '';
in
{
  options.n3x.apt-cacher-ng = {
    enable = mkEnableOption "apt-cacher-ng for ISAR builds";

    port = mkOption {
      type = types.port;
      default = 3142;
      description = "Port for apt-cacher-ng proxy";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address to bind to (0.0.0.0 for all interfaces)";
    };

    cacheDir = mkOption {
      type = types.path;
      default = "/var/cache/apt-cacher-ng";
      description = "Directory for cached packages";
    };

    logDir = mkOption {
      type = types.path;
      default = "/var/log/apt-cacher-ng";
      description = "Directory for log files";
    };

    artifactoryUrl = mkOption {
      type = types.str;
      default = "";
      description = ''
        JFrog Artifactory URL for upstream Debian mirror.
        If empty, uses deb.debian.org directly.
        Example: https://artifactory.example.com/artifactory
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra configuration to append to acng.conf";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open firewall port for apt-cacher-ng";
    };
  };

  config = mkIf cfg.enable {
    # Install apt-cacher-ng package
    environment.systemPackages = [ pkgs.apt-cacher-ng ];

    # Create systemd service for apt-cacher-ng
    systemd.services.apt-cacher-ng = {
      description = "Apt-Cacher NG caching proxy";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "forking";
        ExecStart = "${pkgs.apt-cacher-ng}/bin/apt-cacher-ng -c ${configFile} pidfile=/run/apt-cacher-ng/pid";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        PIDFile = "/run/apt-cacher-ng/pid";
        RuntimeDirectory = "apt-cacher-ng";
        User = "apt-cacher-ng";
        Group = "apt-cacher-ng";
        Restart = "on-failure";
        RestartSec = "5s";
      };

      preStart = ''
        mkdir -p ${cfg.cacheDir} ${cfg.logDir}
        chown apt-cacher-ng:apt-cacher-ng ${cfg.cacheDir} ${cfg.logDir}
      '';
    };

    # Create user and group for apt-cacher-ng
    users.users.apt-cacher-ng = {
      isSystemUser = true;
      group = "apt-cacher-ng";
      home = cfg.cacheDir;
    };
    users.groups.apt-cacher-ng = { };

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
