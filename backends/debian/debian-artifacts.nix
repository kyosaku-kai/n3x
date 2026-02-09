# ISAR artifact registry - thin wrapper around generated registry
#
# The registry is generated from:
#   lib/debian/build-matrix.nix   - variant definitions and naming functions
#   lib/debian/artifact-hashes.nix - mutable SHA256 hashes (only file build script modifies)
#   lib/debian/mk-artifact-registry.nix - generator combining matrix + hashes
#
# See lib/debian/build-matrix.nix for the complete variant matrix.
#
# Usage:
#   let
#     debianArtifacts = import ./debian-artifacts.nix { inherit pkgs lib; };
#     server1Image = debianArtifacts.qemuamd64.server.simple."server-1".wic;
#     legacyImage = debianArtifacts.qemuamd64.server.simple.wic;  # alias for server-1
#   in ...
#
{ pkgs, lib }:
import ../../lib/debian/mk-artifact-registry.nix { inherit pkgs lib; }
