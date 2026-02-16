# Harmonia binary cache module for n3x build runners
#
# Serves the local /nix/store as an HTTP binary cache.
# Designed to sit behind Caddy reverse proxy (Task 7) for TLS termination.
#
# Each node runs its own Harmonia instance; nodes share caches via HTTP substituters.
# No ZFS replication needed — Nix content-addressing ensures identical store paths.
{ config, lib, pkgs, ... }:

let
  cfg = config.n3x.harmonia;
in
{
  options.n3x.harmonia = {
    enable = lib.mkEnableOption "Harmonia binary cache server";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:5000";
      description = ''
        Address and port for Harmonia to listen on.
        Default binds to localhost only (Caddy handles external TLS).
      '';
    };

    priority = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = ''
        Binary cache priority advertised in /nix-cache-info.
        Lower values = higher priority. cache.nixos.org defaults to 40.
        Set lower than 40 so local caches are preferred over upstream.
      '';
    };

    workers = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of Harmonia worker processes";
    };

    maxConnectionRate = lib.mkOption {
      type = lib.types.int;
      default = 256;
      description = "Maximum concurrent connections per worker";
    };

    signKeyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Paths to private signing keys for narinfo responses.
        Typically populated by the cache-signing module via agenix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.harmonia = {
      enable = true;

      signKeyPaths = cfg.signKeyPaths;

      settings = {
        bind = cfg.listenAddress;
        priority = cfg.priority;
        workers = cfg.workers;
        max_connection_rate = cfg.maxConnectionRate;
      };
    };

    # Open firewall for localhost only — Caddy handles external access.
    # No firewall rule needed since default listenAddress is 127.0.0.1.

    # Ensure Harmonia can read the Nix store
    systemd.services.harmonia.serviceConfig = {
      # Harmonia needs read access to /nix/store
      ReadOnlyPaths = [ "/nix/store" "/nix/var/nix" ];
    };
  };
}
