# Nix configuration module for n3x build runners
#
# Enables flakes, configures binary cache substituters.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.nix-config;
in
{
  options.n3x.nix-config = {
    enable = mkEnableOption "n3x Nix configuration";

    extraSubstituters = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional binary cache substituters (e.g., peer Harmonia nodes, Cachix)";
      example = [ "https://nix-community.cachix.org" ];
    };

    trustedPublicKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Public keys for trusted substituters";
      example = [ "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" ];
    };

    maxJobs = mkOption {
      type = types.either types.int (types.enum [ "auto" ]);
      default = "auto";
      description = "Maximum number of parallel Nix build jobs";
    };

    cores = mkOption {
      type = types.int;
      default = 0;
      description = "Number of CPU cores per build job (0 = all available)";
    };

    gcKeepOutputs = mkOption {
      type = types.bool;
      default = true;
      description = "Keep build outputs during garbage collection";
    };

    gcKeepDerivations = mkOption {
      type = types.bool;
      default = true;
      description = "Keep derivations during garbage collection";
    };
  };

  config = mkIf cfg.enable {
    # Enable Nix with flakes and modern CLI
    nix = {
      # Enable garbage collection
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      settings = {
        # Enable experimental features (flakes, nix command)
        experimental-features = [ "nix-command" "flakes" ];

        # Binary cache configuration
        substituters = [
          "https://cache.nixos.org"
        ] ++ cfg.extraSubstituters;

        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        ] ++ cfg.trustedPublicKeys;

        # Build settings
        max-jobs = cfg.maxJobs;
        cores = cfg.cores;

        # Keep outputs and derivations for CI builds
        keep-outputs = cfg.gcKeepOutputs;
        keep-derivations = cfg.gcKeepDerivations;

        # Auto-optimize store (deduplicate)
        auto-optimise-store = true;

        # Allow building as root (for CI)
        sandbox = true;

        # Tolerate unavailable caches (timeout) and fall back to building
        connect-timeout = 5;
        fallback = true;
      };
    };

    # Install useful Nix-related tools
    environment.systemPackages = with pkgs; [
      nix-output-monitor # Better build output (nom)
      nix-tree # Visualize derivation dependencies
      nixpkgs-fmt # Nix code formatter
    ];
  };
}
