# ISAR Package Mapping - Single Source of Truth
#
# This module defines the explicit mapping between Nix package names and
# Debian package names for ISAR image verification.
#
# ARCHITECTURE (Plan 016):
#   Tests verify capabilities via commands (e.g., `which curl`)
#   This mapping ensures ISAR images have equivalent Debian packages
#   for every capability the NixOS tests expect.
#
# USAGE:
#   mapping = import ./package-mapping.nix { inherit lib; };
#   mapping.groups.k3s-core  # List of packages for k3s runtime
#   mapping.allPackages      # Flat list of all packages
#   mapping.byNixName."curl" # Lookup by Nix package name
#   mapping.byDebianName."iputils-ping"  # Lookup by Debian name
#
# VERIFICATION FLOW (D2/D3 will implement):
#   1. NixOS test expects command → lookup package by command → get debian name
#   2. Check kas overlay includes that debian package
#   3. Fail `nix flake check` if missing
#
# PACKAGE SCHEMA:
#   {
#     nix = "curl";           # Nix package name (nixpkgs attr)
#     debian = "curl";        # Debian package name (apt)
#     commands = ["curl"];    # Commands this package provides (for test verification)
#     group = "k3s-core";     # Which kas overlay should include this
#     source = "apt";         # "apt" (standard debian) or "isar" (custom recipe)
#     description = "...";    # Human-readable purpose
#   }

{ lib }:

let
  # ==========================================================================
  # Package Definitions - Grouped by kas overlay
  # ==========================================================================

  # K3s Core Runtime - packages required for any k3s node
  # Maps to: kas/packages/k3s-core.yml
  k3sCorePackages = [
    {
      nix = "cacert";
      debian = "ca-certificates";
      commands = [ ]; # No user command, provides SSL certs
      group = "k3s-core";
      source = "apt";
      description = "SSL certificate handling for HTTPS";
    }
    {
      nix = "curl";
      debian = "curl";
      commands = [ "curl" ];
      group = "k3s-core";
      source = "apt";
      description = "HTTP client for k3s downloads and health checks";
    }
    {
      nix = "iptables";
      debian = "iptables";
      commands = [ "iptables" "iptables-save" "iptables-restore" ];
      group = "k3s-core";
      source = "apt";
      description = "Network packet filtering (required for pod networking)";
    }
    {
      nix = "conntrack-tools";
      debian = "conntrack";
      commands = [ "conntrack" ];
      group = "k3s-core";
      source = "apt";
      description = "Connection tracking (required for kube-proxy)";
    }
    {
      nix = "iproute2";
      debian = "iproute2";
      commands = [ "ip" "ss" "bridge" ];
      group = "k3s-core";
      source = "apt";
      description = "Network configuration (ip command)";
    }
    {
      nix = "ipvsadm";
      debian = "ipvsadm";
      commands = [ "ipvsadm" ];
      group = "k3s-core";
      source = "apt";
      description = "IPVS load balancing (for kube-proxy IPVS mode)";
    }
    {
      nix = "bridge-utils";
      debian = "bridge-utils";
      commands = [ "brctl" ];
      group = "k3s-core";
      source = "apt";
      description = "Network bridge management (for CNI)";
    }
    {
      nix = "procps";
      debian = "procps";
      commands = [ "ps" "top" "free" "pgrep" "pkill" ];
      group = "k3s-core";
      source = "apt";
      description = "Process utilities for monitoring";
    }
    {
      nix = "util-linux";
      debian = "util-linux";
      commands = [ "mount" "lsblk" "findmnt" ];
      group = "k3s-core";
      source = "apt";
      description = "System utilities (mount, block devices)";
    }
    # K3s binary package (unified server + agent)
    {
      nix = null; # No direct Nix equivalent - custom package
      debian = "k3s";
      commands = [ "k3s" "kubectl" "crictl" "ctr" ];
      group = "k3s-core";
      source = "packages"; # Built from packages/ directory
      description = "K3s Kubernetes binary (server + agent modes)";
    }
    # K3s system configuration
    {
      nix = null; # No Nix equivalent - ISAR-only
      debian = "k3s-system-config";
      commands = [ ];
      group = "k3s-core";
      source = "packages"; # Built from packages/ directory
      description = "Kernel modules, sysctl, iptables-legacy, swap disable";
    }
  ];

  # Debug/Development - packages for testing and troubleshooting
  # Maps to: kas/packages/debug.yml
  debugPackages = [
    {
      nix = "openssh";
      debian = "openssh-server";
      commands = [ "sshd" ];
      group = "debug";
      source = "apt";
      description = "SSH access for testing";
    }
    {
      nix = "vim";
      debian = "vim-tiny";
      commands = [ "vim" "vi" ];
      group = "debug";
      source = "apt";
      description = "Minimal editor";
    }
    {
      nix = "less";
      debian = "less";
      commands = [ "less" ];
      group = "debug";
      source = "apt";
      description = "Pager for log viewing";
    }
    {
      nix = "iputils";
      debian = "iputils-ping";
      commands = [ "ping" "ping6" ];
      group = "debug";
      source = "apt";
      description = "Network diagnostics (ping command)";
    }
    # Custom ISAR-built package
    {
      nix = null;
      debian = "sshd-regen-keys";
      commands = [ ];
      group = "debug";
      source = "isar";
      description = "Regenerate SSH host keys on first boot";
    }
  ];

  # NixOS Test Backdoor - required for test harness (test images only)
  # Maps to: kas/test-k3s-overlay.yml
  testPackages = [
    {
      nix = null;
      debian = "nixos-test-backdoor";
      commands = [ ];
      group = "test";
      source = "isar";
      description = "NixOS test driver communication channel";
    }
  ];

  # ==========================================================================
  # Aggregate and Index Functions
  # ==========================================================================

  allPackages = k3sCorePackages ++ debugPackages ++ testPackages;

  # Index by Nix package name (excludes ISAR-only packages)
  byNixName = lib.listToAttrs (
    map (pkg: { name = pkg.nix; value = pkg; })
      (lib.filter (pkg: pkg.nix != null) allPackages)
  );

  # Index by Debian package name
  byDebianName = lib.listToAttrs (
    map (pkg: { name = pkg.debian; value = pkg; })
      allPackages
  );

  # Index by command (many-to-one: multiple commands can map to one package)
  byCommand = lib.foldl'
    (acc: pkg:
      lib.foldl' (acc': cmd: acc' // { ${cmd} = pkg; }) acc pkg.commands
    )
    { }
    allPackages;

  # Group packages by their group field
  groups = {
    k3s-core = k3sCorePackages;
    debug = debugPackages;
    test = testPackages;
  };

  # Get Debian packages for a group
  debianPackagesForGroup = group:
    map (pkg: pkg.debian) (groups.${group} or [ ]);

  # Get apt packages only (exclude ISAR custom recipes)
  aptPackagesForGroup = group:
    map (pkg: pkg.debian)
      (lib.filter (pkg: pkg.source == "apt") (groups.${group} or [ ]));

  # Get ISAR custom packages only (legacy recipes in meta-n3x)
  isarPackagesForGroup = group:
    map (pkg: pkg.debian)
      (lib.filter (pkg: pkg.source == "isar") (groups.${group} or [ ]));

  # Get packages built from packages/ directory
  packagesPackagesForGroup = group:
    map (pkg: pkg.debian)
      (lib.filter (pkg: pkg.source == "packages") (groups.${group} or [ ]));

  # Get custom packages (both legacy ISAR recipes and new packages/)
  customPackagesForGroup = group:
    map (pkg: pkg.debian)
      (lib.filter (pkg: pkg.source != "apt") (groups.${group} or [ ]));

in
{
  # Package lists by group (mirrors kas overlay structure)
  inherit groups;

  # All packages as flat list
  inherit allPackages;

  # Lookup indices
  inherit byNixName byDebianName byCommand;

  # Helper functions for kas YAML generation/verification
  inherit debianPackagesForGroup aptPackagesForGroup isarPackagesForGroup;
  inherit packagesPackagesForGroup customPackagesForGroup;

  # Convenience: all Debian packages needed for a complete test image
  allDebianPackages = map (pkg: pkg.debian) allPackages;

  # Convenience: commands that tests may verify
  allCommands = lib.unique (lib.concatMap (pkg: pkg.commands) allPackages);
}
