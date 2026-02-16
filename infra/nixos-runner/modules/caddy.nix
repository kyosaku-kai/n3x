# Caddy reverse proxy module for n3x build runners
#
# Provides HTTPS termination in front of Harmonia binary cache.
# Uses the internal CA from n3x.internal-ca for TLS certificate issuance.
#
# TLS modes:
#   1. Internal ACME (preferred): When n3x.internal-ca.acmeServer is set,
#      Caddy uses ACME to obtain certificates from the internal CA (e.g., step-ca).
#   2. Self-signed: When no ACME server is configured, Caddy uses its built-in
#      self-signed certificates (`tls internal`). Sufficient for prototype/dev.
#
# Caddy listens on port 443 and reverse proxies to Harmonia on localhost:5000.
{ config, lib, pkgs, ... }:

let
  cfg = config.n3x.caddy;
  caCfg = config.n3x.internal-ca;
  harmoniaCfg = config.n3x.harmonia;
in
{
  options.n3x.caddy = {
    enable = lib.mkEnableOption "Caddy reverse proxy for Harmonia binary cache";

    cacheHostname = lib.mkOption {
      type = lib.types.str;
      default = "cache.${config.networking.hostName}.${caCfg.domain}";
      defaultText = lib.literalExpression ''"cache.''${config.networking.hostName}.''${config.n3x.internal-ca.domain}"'';
      description = ''
        Hostname for the binary cache virtual host.
        Clients use this as their substituter URL.
      '';
      example = "cache.nuc-1.n3x.internal";
    };

    harmoniaUpstream = lib.mkOption {
      type = lib.types.str;
      default = "http://${harmoniaCfg.listenAddress}";
      defaultText = lib.literalExpression ''"http://''${config.n3x.harmonia.listenAddress}"'';
      description = ''
        Upstream URL for Harmonia. Caddy reverse proxies all requests here.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open port 443 in the firewall for HTTPS access.";
    };

    extraVirtualHostConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Additional Caddyfile directives appended inside the virtual host block.
        Use for custom access logging, rate limiting, etc.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = harmoniaCfg.enable;
        message = "n3x.caddy requires n3x.harmonia to be enabled (it provides the upstream).";
      }
    ];

    services.caddy = {
      enable = true;

      # When internal ACME is configured, Caddy uses it automatically via
      # security.acme.defaults.server (set by internal-ca module).
      # When not configured, we use `tls internal` for self-signed certs.
      virtualHosts.${cfg.cacheHostname} = {
        extraConfig = ''
          ${lib.optionalString (caCfg.enable && caCfg.acmeServer == null) "tls internal"}

          reverse_proxy ${cfg.harmoniaUpstream} {
            # Harmonia streams NARs — disable buffering for large responses
            flush_interval -1
          }

          # Security headers (all responses)
          header {
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
          }

          # Cache narinfo for 1 hour
          @cacheinfo {
            path /nix-cache-info
            path /*.narinfo
          }
          header @cacheinfo Cache-Control "public, max-age=3600"

          # Cache NARs for 1 day (immutable content-addressed)
          @nar path /nar/*
          header @nar Cache-Control "public, max-age=86400, immutable"

          ${cfg.extraVirtualHostConfig}
        '';
      };
    };

    # Open HTTPS port if requested
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 443 ];
  };
}
