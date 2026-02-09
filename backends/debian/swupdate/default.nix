# SWUpdate module - connects bundle generation with debian-artifacts
#
# This module provides per-machine SWUpdate bundle derivations using
# artifacts from debian-artifacts.nix and versions from versions.nix.
#
# Usage:
#   let
#     swupdate = import ./swupdate { inherit pkgs lib; };
#     jetsonBundle = swupdate.jetson-orin-nano.server;
#   in ...
#
# Currently supports:
#   - jetson-orin-nano (uses rootfs tarball for L4T flash tools)
#
# Future support (when SWUpdate is added to WIC-based targets):
#   - amd-v3c18i
#   - qemuamd64
#
{ pkgs, lib }:

let
  debianArtifacts = import ../debian-artifacts.nix { inherit pkgs lib; };
  versions = debianArtifacts.versions;

  mkBundle = import ./bundle.nix;

  # Helper to create a bundle for a given machine/role
  mkMachineBundle = { targetMachine, role }:
    mkBundle {
      inherit pkgs lib debianArtifacts targetMachine role;
      version = versions.isar.version;
    };

in
{
  # Expose versions for consumers
  inherit versions;

  # ==========================================================================
  # Jetson Orin Nano bundles
  # Uses rootfs tarballs for L4T-based OTA updates
  # ==========================================================================
  jetson-orin-nano = {
    # Primary target: k3s server (control plane)
    server = mkMachineBundle {
      targetMachine = "jetson-orin-nano";
      role = "server";
    };

    # Base image for testing/development
    base = mkMachineBundle {
      targetMachine = "jetson-orin-nano";
      role = "base";
    };
  };

  # ==========================================================================
  # Future: WIC-based targets would need different bundle type
  # Currently bundle.nix only supports rootfs tarballs
  # ==========================================================================
  # amd-v3c18i = { ... };
  # qemuamd64 = { ... };
}
