# ISAR Build Matrix - Single source of truth for all variant definitions
#
# This module defines:
#   - Machine configurations (kas file mapping, artifact types)
#   - Role definitions (kas image files, recipe names)
#   - Complete variant list as structured data
#   - Naming functions for unique artifact filenames and attrset paths
#   - Kas command generation from variant attributes
#
# Architecture:
#   build-matrix.nix  (this file - variant definitions + naming)
#   artifact-hashes.nix  (mutable state - unique-filename -> sha256)
#   mk-artifact-registry.nix  (generator - matrix + hashes -> requireFile attrset)
#
{ lib }:

let
  # ===========================================================================
  # Machine definitions
  # ===========================================================================
  machines = {
    qemuamd64 = {
      kasFile = "qemu-amd64";
      arch = "x86_64";
      releaseExtensions = [ ".wic.zst" ".wic.bmap" ];
      # Artifact types produced by ISAR for this machine
      artifactTypes = {
        wic = { extension = ".wic"; attrName = "wic"; };
        kernel = { extension = "-vmlinuz"; attrName = "vmlinuz"; };
        initrd = { extension = "-initrd.img"; attrName = "initrd"; };
      };
    };
    qemuarm64 = {
      kasFile = "qemu-arm64-orin";
      arch = "aarch64";
      releaseExtensions = [ ".wic.zst" ".wic.bmap" ];
      # Produces WIC images (matching release.yml) — Orin emulation profile
      # with UEFI boot and zstd compression
      artifactTypes = {
        wic = { extension = ".wic"; attrName = "wic"; };
        kernel = { extension = "-vmlinux"; attrName = "vmlinux"; };
        initrd = { extension = "-initrd.img"; attrName = "initrd"; };
      };
    };
    jetson-orin-nano = {
      kasFile = "jetson-orin-nano";
      arch = "aarch64";
      releaseExtensions = [ ".tar.gz" ];
      artifactTypes = {
        rootfs = { extension = ".tar.gz"; attrName = "rootfs"; };
      };
    };
    amd-v3c18i = {
      kasFile = "amd-v3c18i";
      arch = "x86_64";
      releaseExtensions = [ ".wic.zst" ".wic.bmap" ];
      artifactTypes = {
        wic = { extension = ".wic"; attrName = "wic"; };
      };
    };
  };

  # ===========================================================================
  # Role definitions
  # ===========================================================================
  roles = {
    base = {
      kasImage = "base";
      recipeName = "base";
    };
    server = {
      kasImage = "k3s-server";
      recipeName = "server";
    };
    agent = {
      kasImage = "k3s-agent";
      recipeName = "agent";
    };
  };

  # ===========================================================================
  # Naming functions
  # ===========================================================================

  # Generate a unique variant ID string from variant attributes.
  # Examples:
  #   { role = "base"; }                                          -> "base"
  #   { role = "base"; variant = "swupdate"; }                    -> "base-swupdate"
  #   { role = "agent"; }                                         -> "agent"
  #   { role = "server"; profile = "simple"; node = "server-1"; } -> "server-simple-server-1"
  mkVariantId = { role, variant ? null, profile ? null, node ? null, ... }:
    lib.concatStringsSep "-" (
      [ role ]
      ++ lib.optional (variant != null) variant
      ++ lib.optional (profile != null) profile
      ++ lib.optional (node != null) node
    );

  # Generate a unique artifact filename.
  # Pattern: isar-{variantId}-{machine}{extension}
  # Examples:
  #   "isar-base-qemuamd64.wic"
  #   "isar-server-simple-server-1-qemuamd64.wic"
  #   "isar-server-simple-server-1-qemuamd64-vmlinuz"
  #   "isar-base-swupdate-qemuamd64.wic"
  mkArtifactName = variant: artifactType:
    let
      variantId = mkVariantId variant;
      machineInfo = machines.${variant.machine};
      typeInfo = machineInfo.artifactTypes.${artifactType};
    in
    "isar-${variantId}-${variant.machine}${typeInfo.extension}";

  # Generate the ISAR output filename (what kas-build actually produces).
  # This is the filename in build/tmp/deploy/images/<machine>/
  # Pattern: n3x-image-{recipeName}-debian-trixie-{machine}{extension}
  mkIsarOutputName = variant: artifactType:
    let
      roleInfo = roles.${variant.role};
      machineInfo = machines.${variant.machine};
      typeInfo = machineInfo.artifactTypes.${artifactType};
    in
    "n3x-image-${roleInfo.recipeName}-debian-trixie-${variant.machine}${typeInfo.extension}";

  # Generate the nested attribute path for accessing this variant's artifacts.
  # Returns a list of strings representing the path in the attrset.
  # Examples:
  #   { machine = "qemuamd64"; role = "base"; }                                  -> ["qemuamd64" "base"]
  #   { machine = "qemuamd64"; role = "base"; variant = "swupdate"; }             -> ["qemuamd64" "swupdate"]
  #   { machine = "qemuamd64"; role = "server"; profile = "simple"; node = "server-1"; }
  #     -> ["qemuamd64" "server" "simple" "server-1"]
  #   { machine = "qemuamd64"; role = "agent"; }                                  -> ["qemuamd64" "agent"]
  mkAttrPath = { machine, role, variant ? null, profile ? null, node ? null, ... }:
    [ machine ]
    ++ (if variant != null then [ variant ] else [ role ])
    ++ lib.optional (profile != null) profile
    ++ lib.optional (node != null) node;

  # Generate the kas-build command overlay chain for a variant.
  # Returns the colon-separated kas config string.
  mkKasCommand = variant:
    let
      machineInfo = machines.${variant.machine};
      roleInfo = roles.${variant.role};
      overlays =
        [ "kas/base.yml" "kas/machine/${machineInfo.kasFile}.yml" ]
        # k3s roles need packages overlays
        ++ lib.optionals (variant.role == "server" || variant.role == "agent") [
          "kas/packages/k3s-core.yml"
          "kas/packages/debug.yml"
        ]
        ++ [ "kas/image/${roleInfo.kasImage}.yml" ]
        # Boot overlay for k3s test images
        ++ lib.optional (variant.role == "server" || variant.role == "agent") "kas/boot/systemd-boot.yml"
        # Special variant overlays
        ++ lib.optional (variant.variant or null == "swupdate") "kas/feature/swupdate.yml"
        # Test overlays
        ++ lib.optional (variant.testOverlay or null != null) "kas/${variant.testOverlay}.yml"
        # Network profile
        ++ lib.optional (variant.profile or null != null) "kas/network/${variant.profile}.yml"
        # Node identity
        ++ lib.optional (variant.node or null != null) "kas/node/${variant.node}.yml";
    in
    lib.concatStringsSep ":" overlays;

  # ===========================================================================
  # CI and release helpers
  # ===========================================================================

  # CI-aware kas command: appends ci-cache.yml always, native-build.yml when
  # the runner's host architecture matches the target machine's architecture.
  mkCiKasCommand = { hostArch }: variant:
    let
      machineInfo = machines.${variant.machine};
      baseCommand = mkKasCommand variant;
      isNative = hostArch == machineInfo.arch;
      ciOverlays = [ "kas/opt/ci-cache.yml" ]
        ++ lib.optional isNative "kas/opt/native-build.yml";
    in
    lib.concatStringsSep ":" ([ baseCommand ] ++ ciOverlays);

  # Release variants: base/production images only (no test overlays, no
  # profile-specific server/agent images). These are the variants that
  # get published as GitHub Release assets.
  releaseVariants = [
    { machine = "qemuamd64"; role = "base"; }
    { machine = "qemuamd64"; role = "base"; variant = "swupdate"; }
    { machine = "qemuarm64"; role = "base"; }
    { machine = "amd-v3c18i"; role = "agent"; }
    { machine = "jetson-orin-nano"; role = "base"; }
  ];

  # Generate release asset filename.
  # Pattern: n3x-{variantId}-{machine}-{version}{extension}
  # Example: "n3x-base-qemuamd64-0.0.2.wic.zst"
  mkReleaseAssetName = { version }: variant: extension:
    "n3x-${mkVariantId variant}-${variant.machine}-${version}${extension}";

  # Generate ISAR output filename with an arbitrary extension (for release
  # artifacts that use compressed formats like .wic.zst instead of raw .wic).
  # Pattern: n3x-image-{recipeName}-debian-trixie-{machine}{extension}
  mkReleaseIsarOutputName = variant: extension:
    let
      roleInfo = roles.${variant.role};
    in
    "n3x-image-${roleInfo.recipeName}-debian-trixie-${variant.machine}${extension}";

  # ===========================================================================
  # Complete variant list
  # ===========================================================================

  # Helper to generate server variants for all profiles × nodes
  mkServerVariants = machine:
    lib.concatMap
      (profile:
        map
          (node: {
            inherit machine profile node;
            role = "server";
            testOverlay = "test-k3s-overlay";
          }) [ "server-1" "server-2" ]
      ) [ "simple" "vlans" "bonding-vlans" "dhcp-simple" ];

  variants = [
    # =========================================================================
    # qemuamd64 (11 variants)
    # =========================================================================

    # Base image with test overlay (for VM boot/network smoke tests)
    {
      machine = "qemuamd64";
      role = "base";
      testOverlay = "test-overlay";
    }

    # Base image with SWUpdate A/B partition layout + test overlay
    {
      machine = "qemuamd64";
      role = "base";
      variant = "swupdate";
      testOverlay = "test-overlay";
    }

    # Agent image with k3s test overlay
    {
      machine = "qemuamd64";
      role = "agent";
      testOverlay = "test-k3s-overlay";
    }

    # Server images: 4 profiles × 2 nodes = 8 variants
  ] ++ mkServerVariants "qemuamd64" ++ [

    # =========================================================================
    # qemuarm64 (2 variants)
    # =========================================================================
    {
      machine = "qemuarm64";
      role = "base";
    }
    {
      machine = "qemuarm64";
      role = "server";
    }

    # =========================================================================
    # jetson-orin-nano (2 variants)
    # =========================================================================
    {
      machine = "jetson-orin-nano";
      role = "base";
    }
    {
      machine = "jetson-orin-nano";
      role = "server";
    }

    # =========================================================================
    # amd-v3c18i (1 variant)
    # =========================================================================
    {
      machine = "amd-v3c18i";
      role = "agent";
    }
  ];

in
{
  inherit machines roles variants releaseVariants;
  inherit mkVariantId mkArtifactName mkIsarOutputName mkAttrPath mkKasCommand;
  inherit mkCiKasCommand mkReleaseAssetName mkReleaseIsarOutputName;

  # Total variant count for assertions
  variantCount = builtins.length variants;

  # All unique artifact names across all variants × artifact types
  allArtifactNames = lib.concatMap
    (variant:
      let
        machineInfo = machines.${variant.machine};
      in
      map (artifactType: mkArtifactName variant artifactType)
        (builtins.attrNames machineInfo.artifactTypes)
    )
    variants;
}
