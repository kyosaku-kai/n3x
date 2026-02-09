# Debian Package Parity Verification
# =============================================================================
#
# PURPOSE:
#   Verify kas overlay YAML files contain all packages defined in package-mapping.nix.
#   Fails at Nix evaluation time if packages are missing.
#
# DESIGN (Plan 016 D2 - Option C):
#   - Pure Nix eval-time verification (no build step required)
#   - Uses builtins.readFile + lib.hasInfix for package detection
#   - Leading space check (" pkg") prevents false positives
#   - Fails immediately with actionable error message
#
# USAGE:
#   In flake.nix:
#     checks.x86_64-linux.debian-package-parity = import ./lib/debian/verify-kas-packages.nix {
#       inherit lib pkgs;
#       kasPath = ./backends/debian/kas;
#     };
#
# =============================================================================

{ lib, pkgs, kasPath }:

let
  # Import the package mapping (single source of truth)
  mapping = import ./package-mapping.nix { inherit lib; };

  # Read kas overlay content from files
  kasFiles = {
    k3s-core = builtins.readFile (kasPath + "/packages/k3s-core.yml");
    debug = builtins.readFile (kasPath + "/packages/debug.yml");
    # test group is in test-k3s-overlay.yml (not packages/test.yml)
    test = builtins.readFile (kasPath + "/test-k3s-overlay.yml");
  };

  # Group-to-file name mapping for error messages
  groupFileNames = {
    k3s-core = "packages/k3s-core.yml";
    debug = "packages/debug.yml";
    test = "test-k3s-overlay.yml";
  };

  # Check if a package name exists in the file content
  # Uses leading space to avoid matching partial names (e.g., " curl" won't match "libcurl")
  hasPackage = content: pkg: lib.hasInfix " ${pkg}" content;

  # Verify all packages in a group exist in the corresponding kas file
  # Returns: { valid = bool; missing = [ "pkg1" "pkg2" ]; }
  verifyGroup = groupName:
    let
      content = kasFiles.${groupName};
      packages = mapping.debianPackagesForGroup groupName;
      missing = lib.filter (pkg: !(hasPackage content pkg)) packages;
    in {
      valid = missing == [];
      inherit missing;
      file = groupFileNames.${groupName};
    };

  # Verify all groups
  groupResults = lib.mapAttrs (name: _: verifyGroup name) kasFiles;

  # Collect all failures
  failures = lib.filterAttrs (name: result: !result.valid) groupResults;

  # Build error message if there are failures
  errorMessage =
    let
      formatFailure = name: result: ''
        - ${result.file}: missing ${lib.concatStringsSep ", " result.missing}
      '';
      failureLines = lib.mapAttrsToList formatFailure failures;
    in ''

      Debian Package Parity Verification Failed (Plan 016)
      ===================================================

      The following packages are defined in lib/debian/package-mapping.nix
      but are missing from their corresponding kas overlay files:

      ${lib.concatStrings failureLines}
      Fix: Add the missing packages to IMAGE_PREINSTALL:append or IMAGE_INSTALL:append
      in the corresponding file under backends/debian/kas/

      See: .claude/user-plans/016-image-capability-contracts.md
    '';

  # The actual check: throw at eval time if verification fails
  verified =
    if failures == {} then
      true
    else
      throw errorMessage;

in
# Return a derivation that can be used as a flake check
# The verification happens at eval time - lib.seq forces evaluation of 'verified'
# before the derivation is instantiated. If verification fails, throw fires immediately.
lib.seq verified (
  pkgs.runCommand "debian-package-parity" {} ''
    # This only runs if verified == true (otherwise throw already fired during eval)
    echo "Debian Package Parity Verification Passed"
    echo ""
    echo "Verified groups:"
    echo "  - k3s-core: ${toString (builtins.length (mapping.debianPackagesForGroup "k3s-core"))} packages"
    echo "  - debug: ${toString (builtins.length (mapping.debianPackagesForGroup "debug"))} packages"
    echo "  - test: ${toString (builtins.length (mapping.debianPackagesForGroup "test"))} packages"
    touch $out
  ''
)
