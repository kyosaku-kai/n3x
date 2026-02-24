# GitLab Runner module for n3x build runners
#
# Configures GitLab Runner with shell executor for ISAR/Nix builds.
# Runner authentication token is managed via agenix.
#
# NOTE: GitLab deprecated runner registration tokens in 16.0 (removed in 18.0).
# Use authenticationTokenConfigFile for GitLab 16.0+, or registrationConfigFile
# for older GitLab instances. Setting both is an error.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.gitlab-runner;
in
{
  options.n3x.gitlab-runner = {
    enable = mkEnableOption "n3x GitLab Runner configuration";

    authenticationTokenConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to GitLab runner authentication token config file (agenix-managed).
        For GitLab 16.0+ (runner authentication tokens).
        File should contain at least:
          CI_SERVER_URL=https://gitlab.example.com
          CI_SERVER_TOKEN=glrt-<token>

        If null and registrationConfigFile is also null, the gitlab-runner
        service is not configured (placeholder for host configurations that
        haven't set up secrets yet).
      '';
    };

    registrationConfigFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        DEPRECATED: Use authenticationTokenConfigFile for GitLab 16.0+.
        Runner registration tokens were deprecated in GitLab 16.0 and
        will be removed in GitLab 18.0.

        Path to GitLab runner registration config file (agenix-managed).
        File should contain at least:
          CI_SERVER_URL=https://gitlab.example.com
          REGISTRATION_TOKEN=<token>
      '';
    };

    runnerName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "Name for this runner (shown in GitLab UI)";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ "nix" ];
      description = "Tags for this runner (e.g., nix, x86_64, large-disk)";
    };

    concurrent = mkOption {
      type = types.int;
      default = 2;
      description = "Maximum concurrent jobs";
    };

    buildUser = mkOption {
      type = types.str;
      default = "gitlab-runner";
      description = "User to run builds as";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.authenticationTokenConfigFile != null && cfg.registrationConfigFile != null);
        message = "n3x.gitlab-runner: set either authenticationTokenConfigFile or registrationConfigFile, not both.";
      }
    ];

    # GitLab Runner service (only if a config file is provided)
    services.gitlab-runner =
      let
        hasConfig = cfg.authenticationTokenConfigFile != null || cfg.registrationConfigFile != null;
      in
      mkIf hasConfig {
        enable = true;
        settings.concurrent = cfg.concurrent;

        services.n3x-shell = {
          authenticationTokenConfigFile = mkIf (cfg.authenticationTokenConfigFile != null) cfg.authenticationTokenConfigFile;
          registrationConfigFile = mkIf (cfg.registrationConfigFile != null) cfg.registrationConfigFile;
          executor = "shell";
          tagList = cfg.tags;
          runUntagged = false;
          environmentVariables = {
            # Ensure Nix is available in PATH
            PATH = "/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin";
            # Use system Nix daemon
            NIX_REMOTE = "daemon";
          };
        };
      };

    # Ensure gitlab-runner user can access Nix
    users.users.gitlab-runner = {
      isSystemUser = true;
      group = "gitlab-runner";
      extraGroups = [ "docker" "podman" ];
      home = "/var/lib/gitlab-runner";
      createHome = true;
    };
    users.groups.gitlab-runner = { };

    # Allow gitlab-runner to use Nix daemon
    nix.settings.trusted-users = [ "gitlab-runner" ];
  };
}
