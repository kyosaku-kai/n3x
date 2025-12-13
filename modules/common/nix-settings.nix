{ config, lib, pkgs, inputs, ... }:

{
  nix = {
    # Enable flakes and new nix command
    settings = {
      experimental-features = [ "nix-command" "flakes" ];

      # Automatically optimize the store to save space
      auto-optimise-store = true;

      # Build settings
      max-jobs = "auto"; # Use all available cores
      cores = 0; # Use all cores for individual builds

      # Trusted settings for remote builds
      trusted-users = [ "root" "@wheel" ];
      allowed-users = [ "@wheel" ];

      # Substituters (binary caches)
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];

      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];

      # Security and sandboxing
      sandbox = true;
      sandbox-fallback = false;
      require-sigs = true;

      # Keep build logs
      keep-outputs = true;
      keep-derivations = true;

      # Warn about dirty git trees
      warn-dirty = false;

      # Connection settings
      connect-timeout = 5;
      download-attempts = 3;

      # Don't allow import from derivation (IFD) for security
      allow-import-from-derivation = false;

      # Log lines to show on build failure
      log-lines = 25;

      # Diff hook for better error messages
      run-diff-hook = true;
      diff-hook = pkgs.writeShellScript "diff-hook" ''
        ${pkgs.diffutils}/bin/diff -u "$1" "$2" || true
      '';

      # Minimum free space required (in kB)
      min-free = 1024 * 1024 * 2; # 2GB
      max-free = 1024 * 1024 * 10; # 10GB

      # Narinfo cache TTL
      narinfo-cache-negative-ttl = 0; # Don't cache failures
      narinfo-cache-positive-ttl = 3600; # Cache successes for 1 hour
    };

    # Garbage collection configuration
    gc = {
      automatic = true;
      dates = "weekly"; # Run weekly
      persistent = true; # Catch up if the system was powered off

      # Keep at least 14 days of generations
      options = "--delete-older-than 14d";
    };

    # Optimize store on schedule
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };

    # Registry configuration (pin nixpkgs to the flake input)
    registry = lib.mapAttrs (_: value: { flake = value; }) inputs;

    # Nix path configuration
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;

    # Extra configuration
    extraOptions = ''
      # Keep going even if a build fails
      keep-going = true

      # Show more information during builds
      print-build-logs = true

      # Fallback to building from source if binary cache fails
      fallback = true

      # HTTP/2 for better download performance
      http2 = true

      # Extra platforms for cross-compilation (if needed)
      # extra-platforms = aarch64-linux

      # Timeout for builds (in seconds)
      # 0 means no timeout
      timeout = 0

      # Use xz compression for store paths
      compress-build-log = true

      # Flakes configuration
      accept-flake-config = false # Don't auto-accept flake configurations
    '';
  };

  # System packages for Nix management
  environment.systemPackages = with pkgs; [
    nix-output-monitor # Better build output
    nix-tree # Explore nix store dependencies
    nix-diff # Diff nix derivations
    nixpkgs-fmt # Format nix files
    nil # Nix LSP for development
    cachix # Push to cachix binary caches
  ];

  # Nix daemon configuration
  systemd.services.nix-daemon = {
    environment = {
      # Limit memory usage of the Nix daemon
      MALLOC_ARENA_MAX = "1";
    };

    # Restart on failure
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";

      # CPU and memory limits
      CPUWeight = 50; # Lower priority
      MemoryMax = "2G"; # Limit memory usage
    };
  };

  # Enable nix-ld for running unpatched binaries
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      openssl
      curl
      expat
      # Add more libraries as needed
    ];
  };

  # Create a systemd timer for store optimization
  systemd.timers.nix-optimise-extra = {
    description = "Extra Nix Store Optimization Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      AccuracySec = "6h";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  systemd.services.nix-optimise-extra = {
    description = "Extra Nix Store Optimization";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nix}/bin/nix-store --optimise";
      CPUWeight = 20; # Very low priority
      IOWeight = 20; # Very low I/O priority
      Nice = 19; # Lowest priority nice level
    };
  };

  # Create a systemd service to clean old profiles
  systemd.services.nix-clean-profiles = {
    description = "Clean old Nix profiles";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "clean-profiles" ''
        # Remove profiles older than 14 days
        ${pkgs.nix}/bin/nix-env --delete-generations +7 --profile /nix/var/nix/profiles/system

        # Also clean user profiles if they exist
        for profile in /nix/var/nix/profiles/per-user/*/profile; do
          if [ -e "$profile" ]; then
            ${pkgs.nix}/bin/nix-env --delete-generations +7 --profile "$profile"
          fi
        done
      '';
      User = "root";
    };
  };

  systemd.timers.nix-clean-profiles = {
    description = "Timer for cleaning old Nix profiles";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "2h";
    };
  };
}
