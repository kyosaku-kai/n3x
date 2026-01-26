# SWUpdate bundle derivation for ISAR-built rootfs
#
# Creates a .swu bundle from ISAR rootfs tarball for OTA updates.
# The bundle follows SWUpdate's cpio format with sw-description metadata.
# Includes a minimal post-update script placeholder for future use.
#
# Usage:
#   let
#     bundle = import ./bundle.nix {
#       inherit pkgs lib;
#       isarArtifacts = import ../isar-artifacts.nix { inherit pkgs lib; };
#       targetMachine = "jetson-orin-nano";
#       role = "server";
#       version = "2026.01.23";
#     };
#   in bundle
#
# Output:
#   $out/update-<machine>-<role>-<version>.swu
#   $out/checksums.txt
#
{ pkgs
, lib
, isarArtifacts
, targetMachine
, role ? "server"
, version
}:

let
  # Get artifact for this machine/role combination
  # Jetson uses rootfs tarball, others might use WIC in the future
  artifact = isarArtifacts.${targetMachine}.${role}.rootfs or
    (throw "No rootfs artifact found for ${targetMachine}/${role}. SWUpdate bundles currently only support rootfs tarballs.");

  # Hardware compatibility list for sw-description
  hwCompat = targetMachine;

  # Minimal post-update script placeholder
  # For A/B partition schemes, the system reboots into the new rootfs,
  # so services start naturally via systemd. This script demonstrates
  # the SWUpdate scripts capability for future live-update scenarios.
  postUpdateScript = pkgs.writeScript "post-update.sh" ''
    #!/bin/sh
    set -e
    echo "Post-update: Update applied successfully"
    echo "Post-update: System will use new rootfs on next boot"
    exit 0
  '';

  # Generate sw-description following libconfig format
  # See: https://sbabic.github.io/swupdate/sw-description.html
  swDescription = pkgs.writeText "sw-description" ''
    software = {
      version = "${version}";
      hardware-compatibility = [ "${hwCompat}" ];

      images: (
        {
          filename = "rootfs.tar.gz";
          type = "archive";
          path = "/";
          sha256 = "@rootfs.sha256@";
          compressed = "zlib";
        }
      );

      scripts: (
        {
          filename = "post-update.sh";
          type = "postinstall";
          sha256 = "@post-update.sha256@";
        }
      );
    };
  '';

in
pkgs.stdenv.mkDerivation {
  name = "swupdate-bundle-${targetMachine}-${role}-${version}";

  nativeBuildInputs = with pkgs; [ cpio ];

  # No source to unpack
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p bundle

    # Copy rootfs tarball
    echo "Copying rootfs artifact: ${artifact}"
    cp ${artifact} bundle/rootfs.tar.gz

    # Copy post-update script
    echo "Copying post-update script: ${postUpdateScript}"
    cp ${postUpdateScript} bundle/post-update.sh
    chmod +x bundle/post-update.sh

    # Compute SHA256 hashes (hex format, as expected by SWUpdate)
    echo "Computing SHA256 hashes..."
    ROOTFS_SHA256=$(sha256sum bundle/rootfs.tar.gz | cut -d' ' -f1)
    echo "  rootfs.tar.gz: $ROOTFS_SHA256"
    POSTUPDATE_SHA256=$(sha256sum bundle/post-update.sh | cut -d' ' -f1)
    echo "  post-update.sh: $POSTUPDATE_SHA256"

    # Process sw-description template
    echo "Generating sw-description..."
    cp ${swDescription} bundle/sw-description
    sed -i "s|@rootfs.sha256@|$ROOTFS_SHA256|g" bundle/sw-description
    sed -i "s|@post-update.sha256@|$POSTUPDATE_SHA256|g" bundle/sw-description

    echo "sw-description contents:"
    cat bundle/sw-description

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    # Create .swu archive using cpio CRC format
    # IMPORTANT: sw-description MUST be the first file in the archive
    echo "Creating SWUpdate bundle..."
    cd bundle
    (echo sw-description; ls -1 | grep -v sw-description) | cpio -o -H crc > $out/update-${targetMachine}-${role}-${version}.swu

    # Generate checksums for the bundle
    echo "Generating checksums..."
    cd $out
    sha256sum *.swu > checksums.txt

    echo ""
    echo "Bundle created successfully:"
    ls -la $out/
    echo ""
    echo "Checksums:"
    cat $out/checksums.txt

    runHook postInstall
  '';

  meta = with lib; {
    description = "SWUpdate OTA bundle for ${targetMachine} (${role})";
    platforms = platforms.all;
  };
}
