# ISAR Artifact Registry Generator
#
# Combines build-matrix.nix (variant definitions) with artifact-hashes.nix
# (sha256 hashes) to generate the complete requireFile attrset.
#
# Output structure matches the original isar-artifacts.nix:
#   {
#     versions = { ... };
#     qemuamd64.base.wic = <requireFile>;
#     qemuamd64.server.simple."server-1".wic = <requireFile>;
#     qemuamd64.server.simple.wic = <requireFile>;  # legacy alias -> server-1
#     qemuamd64.server.wic = <requireFile>;          # legacy alias -> simple.server-1
#     ...
#   }
#
{ pkgs, lib }:

let
  matrix = import ./build-matrix.nix { inherit lib; };
  hashes = import ./artifact-hashes.nix;
  versions = import ../../backends/debian/versions.nix;

  inherit (matrix) machines roles variants mkVariantId mkArtifactName mkIsarOutputName mkAttrPath mkKasCommand;

  # Helper: set a value at a nested attribute path
  # setAtPath ["a" "b" "c"] value -> { a.b.c = value; }
  setAtPath = path: value:
    if path == [ ] then value
    else if builtins.length path == 1 then
      { ${builtins.head path} = value; }
    else
      { ${builtins.head path} = setAtPath (builtins.tail path) value; };

  # Generate a requireFile for a single artifact
  mkRequireFile = variant: artifactType:
    let
      uniqueName = mkArtifactName variant artifactType;
      isarName = mkIsarOutputName variant artifactType;
      hash = hashes.${uniqueName} or (throw "No hash found for artifact '${uniqueName}' in artifact-hashes.nix");
      machineInfo = machines.${variant.machine};
      kasCmd = mkKasCommand variant;
      typeInfo = machineInfo.artifactTypes.${artifactType};
    in
    pkgs.requireFile {
      name = uniqueName;
      sha256 = hash;
      message = ''
        ISAR artifact '${uniqueName}' not found in nix store.

        To add from existing local build (rename from ISAR output name):
          cp build/tmp/deploy/images/${variant.machine}/${isarName} build/tmp/deploy/images/${variant.machine}/${uniqueName}
          nix-store --add-fixed sha256 build/tmp/deploy/images/${variant.machine}/${uniqueName}

        To rebuild the image:
          nix develop -c bash -c "cd backends/debian && kas-build ${kasCmd}"

        Or use the automated build script:
          nix run '.#isar-build-all' -- --variant ${mkVariantId variant}

        Artifact info:
          Unique name: ${uniqueName}
          ISAR output name: ${isarName}
          Machine: ${variant.machine} (kas file: ${machineInfo.kasFile}.yml)
          Role: ${variant.role} (image: n3x-image-${(roles.${variant.role}).recipeName})
          ${if variant.profile or null != null then "Network Profile: ${variant.profile}" else "Network Profile: (none)"}
          ${if variant.node or null != null then "Node: ${variant.node}" else "Node: (none)"}
          Type: ${artifactType} (${typeInfo.attrName})
          Expected hash: ${hash}

        To compute hash of existing file:
          nix-hash --type sha256 --flat --base32 build/tmp/deploy/images/${variant.machine}/${uniqueName}
      '';
    };

  # Generate all artifact entries for a single variant
  # Returns an attrset at the variant's path, e.g.:
  #   { qemuamd64.server.simple."server-1" = { wic = ...; vmlinuz = ...; initrd = ...; }; }
  mkVariantArtifacts = variant:
    let
      machineInfo = machines.${variant.machine};
      path = mkAttrPath variant;
      artifacts = lib.mapAttrs'
        (artifactType: typeInfo:
          lib.nameValuePair typeInfo.attrName (mkRequireFile variant artifactType)
        )
        machineInfo.artifactTypes;
    in
    setAtPath path artifacts;

  # Generate all variant attrsets and deep-merge them
  allVariantAttrsets = map mkVariantArtifacts variants;

  # Deep merge: recursively merges attrsets, rightmost wins for leaf values
  deepMerge = lib.foldl' lib.recursiveUpdate { };

  # Primary registry (all variants merged)
  registry = deepMerge allVariantAttrsets;

  # ===========================================================================
  # Legacy aliases
  # ===========================================================================
  # For backwards compatibility, provide:
  # 1. Profile-level aliases: qemuamd64.server.{profile}.wic -> server-1's artifact
  # 2. Role-level aliases: qemuamd64.server.wic -> simple.server-1's artifact

  # Find the server-1 variant for a given machine/profile
  findServer1Variant = machine: profile:
    let
      matches = builtins.filter
        (v:
          v.machine == machine
          && v.role == "server"
          && (v.profile or null) == profile
          && (v.node or null) == "server-1"
        )
        variants;
    in
    if matches == [ ] then null
    else builtins.head matches;

  # Generate profile-level legacy aliases for a machine
  # e.g., qemuamd64.server.simple.wic = qemuamd64.server.simple."server-1".wic
  mkProfileLegacyAliases = machine:
    let
      profiles = [ "simple" "vlans" "bonding-vlans" "dhcp-simple" ];
      mkProfileAlias = profile:
        let
          server1 = findServer1Variant machine profile;
        in
        if server1 == null then { }
        else
          let
            machineInfo = machines.${machine};
            artifacts = lib.mapAttrs'
              (artifactType: typeInfo:
                lib.nameValuePair typeInfo.attrName (mkRequireFile server1 artifactType)
              )
              machineInfo.artifactTypes;
          in
          setAtPath [ machine "server" profile ] artifacts;
    in
    deepMerge (map mkProfileAlias profiles);

  # Generate role-level legacy aliases for a machine
  # e.g., qemuamd64.server.wic = qemuamd64.server.simple."server-1".wic
  mkRoleLegacyAliases = machine:
    let
      server1 = findServer1Variant machine "simple";
    in
    if server1 == null then { }
    else
      let
        machineInfo = machines.${machine};
        artifacts = lib.mapAttrs'
          (artifactType: typeInfo:
            lib.nameValuePair typeInfo.attrName (mkRequireFile server1 artifactType)
          )
          machineInfo.artifactTypes;
      in
      setAtPath [ machine "server" ] artifacts;

  # All legacy aliases for qemuamd64 (the only machine with profile/node structure)
  legacyAliases = deepMerge [
    (mkProfileLegacyAliases "qemuamd64")
    (mkRoleLegacyAliases "qemuamd64")
  ];

in
# Merge: registry first, then legacy aliases overlaid
  # Legacy aliases use lib.recursiveUpdate so they add leaves without replacing node-level attrs
lib.recursiveUpdate (lib.recursiveUpdate registry legacyAliases) {
  inherit versions;
}
