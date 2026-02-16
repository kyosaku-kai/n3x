# Cache signing module for n3x build runners
#
# Manages Nix binary cache signing keys via agenix (SOPS-encrypted secrets).
# Wires the decrypted private key into both:
#   - Harmonia's signKeyPaths (for serving signed narinfo)
#   - nix.settings.secret-key-files (for signing builds on the nix daemon)
#
# Optionally configures a post-build hook that signs store paths immediately
# after build completion, useful for remote build scenarios.
#
# Key generation:
#   nix key generate-secret --key-name cache.n3x.example.com-1 > secret-key
#   nix key convert-secret-to-public < secret-key > public-key
#
# The public key must be distributed to all substituter clients via
# nix.settings.trusted-public-keys.
{ config, lib, pkgs, ... }:

let
  cfg = config.n3x.cache-signing;

  # Post-build hook script that signs newly built store paths.
  # Nix invokes this after each build with OUT_PATHS env var set.
  postBuildHookScript = pkgs.writeShellScript "sign-store-paths" ''
    set -euo pipefail
    export IFS=' '
    if [ -n "''${OUT_PATHS:-}" ]; then
      echo "Signing store paths: $OUT_PATHS"
      ${config.nix.package}/bin/nix store sign --key-file "${cfg.privateKeyFile}" $OUT_PATHS
    fi
  '';
in
{
  options.n3x.cache-signing = {
    enable = lib.mkEnableOption "Nix binary cache signing";

    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to the decrypted private signing key file.
        Typically set to an agenix-managed secret path:
          config.age.secrets.cache-signing-key.path
      '';
      example = "/run/agenix/cache-signing-key";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      description = ''
        Public key corresponding to the signing keypair.
        Distributed to substituter clients in nix.settings.trusted-public-keys.
        Generate with: nix key convert-secret-to-public < secret-key
      '';
      example = "cache.n3x.example.com-1:f0SwU6mESyVKgNeWzE916N4Syf25VxmUQG8ASNWJQTs=";
    };

    postBuildHook = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable a post-build hook that signs store paths immediately after build.
        Useful for remote build machines where paths should be signed before
        they are available for substitution.
        On machines running Harmonia, this is optional since Harmonia can sign
        on-the-fly via signKeyPaths.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the .age encrypted secret key file for agenix.
        When set, configures age.secrets for automatic decryption.
        When null, assumes privateKeyFile is managed externally.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Configure agenix secret decryption (when secretsFile is provided)
    age.secrets = lib.mkIf (cfg.secretsFile != null) {
      cache-signing-key = {
        file = cfg.secretsFile;
        mode = "0400";
        owner = "root";
        group = "root";
      };
    };

    # Wire signing key into Harmonia (if enabled)
    n3x.harmonia.signKeyPaths = lib.mkIf config.n3x.harmonia.enable [
      cfg.privateKeyFile
    ];

    # Wire signing key into the Nix daemon for local builds
    nix.settings.secret-key-files = [ cfg.privateKeyFile ];

    # Add our public key to trusted keys so local store trusts its own signatures
    nix.settings.trusted-public-keys = [ cfg.publicKey ];

    # Optional post-build hook for immediate signing
    nix.settings.post-build-hook = lib.mkIf cfg.postBuildHook
      (toString postBuildHookScript);
  };
}
