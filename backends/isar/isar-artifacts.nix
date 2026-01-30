# ISAR artifact registry using Nix requireFile pattern
# Provides hash-pinned artifact management for reproducible builds
#
# Architecture:
#   - Machine: hardware platform (qemuamd64, jetson-orin-nano, amd-v3c18i)
#   - Role: k3s function (base, server, agent)
#   - Network Profile: network configuration variant (simple, vlans, bonding-vlans)
#
# Primary targets (what we actually deploy):
#   - jetson-orin-nano + server (k3s control plane)
#   - amd-v3c18i + agent (k3s worker node)
#
# Test targets (for nixos-test-driver VM tests):
#   - qemuamd64 + base/server/agent + network profile
#
# Usage:
#   let
#     isarArtifacts = import ./isar-artifacts.nix { inherit pkgs lib; };
#     # Profile-specific artifacts (for network profile tests)
#     simpleImage = isarArtifacts.qemuamd64.server.simple.wic;
#     vlansImage = isarArtifacts.qemuamd64.server.vlans.wic;
#     # Legacy access (defaults to simple profile for backwards compatibility)
#     legacyImage = isarArtifacts.qemuamd64.server.wic;  # same as .simple.wic
#     jetsonRootfs = isarArtifacts.jetson-orin-nano.server.rootfs;
#   in ...
#
# NETWORK PROFILE ARCHITECTURE (Plan 014 A1):
#
#   Unlike NixOS (which generates configs at eval time), ISAR requires
#   pre-built images with network profiles baked in at build time.
#   Each profile variant is a DISTINCT artifact with its own hash.
#
#   NixOS Flow:
#     lib/network/profiles/${profile}.nix → mk-network-config.nix → VM derivation
#     (Dynamic: different profiles = different derivations automatically)
#
#   ISAR Flow:
#     kas/network/${profile}.yml → ISAR build → .wic artifact → nix store
#     (Static: must build each variant, register hash explicitly)
#
#   Build commands for each profile:
#     kas-container --isar build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/simple.yml
#     kas-container --isar build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/vlans.yml
#     kas-container --isar build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/bonding-vlans.yml
#
# After ISAR build, run: scripts/update-artifact-hashes.sh
# Then add to nix store: nix-store --add-fixed sha256 <artifact-path>
{ pkgs, lib }:

let
  versions = import ./versions.nix;

  # Map from machine name (used in artifacts) to kas YAML filename
  machineToKasFile = {
    "qemuamd64" = "qemu-amd64";
    "qemuarm64" = "qemu-arm64";
    "jetson-orin-nano" = "jetson-orin-nano";
    "amd-v3c18i" = "amd-v3c18i";
  };

  # Map from role to kas image YAML and recipe name
  roleToKasImage = {
    "base" = { kasFile = "minimal-base"; recipe = "base"; };
    "server" = { kasFile = "k3s-server"; recipe = "server"; };
    "agent" = { kasFile = "k3s-agent"; recipe = "agent"; };
  };

  # Map from network profile to kas overlay file
  profileToKasOverlay = {
    "simple" = "simple";
    "vlans" = "vlans";
    "bonding-vlans" = "bonding-vlans";
  };

  # Helper for requireFile with ISAR build instructions
  requireIsarArtifact = { name, sha256, machine, artifactType, role ? "base", networkProfile ? null }:
    let
      kasMachine = machineToKasFile.${machine} or machine;
      roleInfo = roleToKasImage.${role};
      profileOverlay = if networkProfile != null then profileToKasOverlay.${networkProfile} else null;
      profileSuffix = if profileOverlay != null then ":kas/network/${profileOverlay}.yml" else "";
      testOverlay = if profileOverlay != null then ":kas/test-overlay.yml" else "";
    in
    pkgs.requireFile {
      inherit name sha256;
      message = ''
        ISAR artifact '${name}' not found in nix store.

        To add from existing local build:
          nix-store --add-fixed sha256 build/tmp/deploy/images/${machine}/${name}

        To rebuild the image:
          kas-build kas/base.yml:kas/machine/${kasMachine}.yml:kas/image/${roleInfo.kasFile}.yml${testOverlay}${profileSuffix}

        Artifact info:
          Machine: ${machine} (kas file: ${kasMachine}.yml)
          Role: ${role} (image: isar-k3s-image-${roleInfo.recipe})
          ${if networkProfile != null then "Network Profile: ${networkProfile}" else "Network Profile: (none - production image)"}
          Type: ${artifactType}
          Expected hash: ${sha256}

        To compute hash of existing file:
          nix-hash --type sha256 --flat --base32 build/tmp/deploy/images/${machine}/${name}
      '';
    };

in
{
  # Expose versions for consumers
  inherit versions;

  # ==========================================================================
  # QEMU AMD64 artifacts (for nixos-test-driver VM tests only)
  # ==========================================================================
  qemuamd64 = {
    # SWUpdate-enabled base image with A/B partition layout AND nixos-test-backdoor
    # Built with: kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/minimal-base.yml:kas/feature/swupdate.yml:kas/test-overlay.yml
    # Includes cpio for SWUpdate bundle creation during tests
    swupdate = {
      wic = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuamd64.wic";
        sha256 = "1h40mx3qj8nvg05rk4yl19m2ldmampjjcmvijmyl7f4hf8m3rr9w";
        machine = "qemuamd64";
        artifactType = "wic";
        role = "base";
      };
      vmlinuz = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuamd64-vmlinuz";
        sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
        machine = "qemuamd64";
        artifactType = "kernel";
        role = "base";
      };
      initrd = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuamd64-initrd.img";
        sha256 = "1v1gyjz71c70x9b2qppvw2wq8xmr4xq5dglf95flgcmccmy68qgp";
        machine = "qemuamd64";
        artifactType = "initrd";
        role = "base";
      };
    };

    base = {
      wic = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuamd64.wic";
        sha256 = "19sias2j67fglmv3qsrkcn7bpsrkrjzf1ldlyg6mzs9zryji1h1f";
        machine = "qemuamd64";
        artifactType = "wic";
        role = "base";
      };
      vmlinuz = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuamd64-vmlinuz";
        sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
        machine = "qemuamd64";
        artifactType = "kernel";
        role = "base";
      };
      initrd = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuamd64-initrd.img";
        sha256 = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";
        machine = "qemuamd64";
        artifactType = "initrd";
        role = "base";
      };
    };
    server = {
      # =========================================================================
      # Network Profile-Specific Artifacts (for VM tests)
      # Each profile variant is a distinct image with its own hash.
      # =========================================================================

      # Simple network profile (single flat network on eth1)
      # Build: kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/simple.yml
      simple = {
        wic = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64.wic";
          sha256 = "1cvs18f5kb5q14s8dv8r6shvkg3ci0f2wz2bbfgmvd4n57k6anqq";
          machine = "qemuamd64";
          artifactType = "wic";
          role = "server";
          networkProfile = "simple";
        };
        vmlinuz = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64-vmlinuz";
          sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
          machine = "qemuamd64";
          artifactType = "kernel";
          role = "server";
          networkProfile = "simple";
        };
        initrd = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64-initrd.img";
          sha256 = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";
          machine = "qemuamd64";
          artifactType = "initrd";
          role = "server";
          networkProfile = "simple";
        };
      };

      # VLANs network profile (802.1Q tagging on eth1)
      # Build: kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/vlans.yml
      vlans = {
        wic = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64.wic";
          sha256 = "099kmcjqd08sdjx4m0ckf48hn5azrj5y10rqd43cd3mq7aj1rnsh";
          machine = "qemuamd64";
          artifactType = "wic";
          role = "server";
          networkProfile = "vlans";
        };
        vmlinuz = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64-vmlinuz";
          sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a"; # Kernel same across profiles
          machine = "qemuamd64";
          artifactType = "kernel";
          role = "server";
          networkProfile = "vlans";
        };
        initrd = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64-initrd.img";
          sha256 = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r"; # initrd same across profiles
          machine = "qemuamd64";
          artifactType = "initrd";
          role = "server";
          networkProfile = "vlans";
        };
      };

      # Bonding + VLANs network profile (bond0 with 802.1Q tagging)
      # Build: kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/k3s-server.yml:kas/test-overlay.yml:kas/network/bonding-vlans.yml
      bonding-vlans = {
        wic = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64.wic";
          sha256 = "037y61asygdml08bmbi96hdhkn4grlrz40m3crl9r6vzs82bwyz1";
          machine = "qemuamd64";
          artifactType = "wic";
          role = "server";
          networkProfile = "bonding-vlans";
        };
        vmlinuz = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64-vmlinuz";
          sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a"; # Kernel same across profiles
          machine = "qemuamd64";
          artifactType = "kernel";
          role = "server";
          networkProfile = "bonding-vlans";
        };
        initrd = requireIsarArtifact {
          name = "isar-k3s-image-server-debian-trixie-qemuamd64-initrd.img";
          sha256 = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r"; # initrd same across profiles
          machine = "qemuamd64";
          artifactType = "initrd";
          role = "server";
          networkProfile = "bonding-vlans";
        };
      };

      # =========================================================================
      # Legacy Access (backwards compatibility)
      # These point to .simple for existing code that doesn't specify profile.
      # =========================================================================
      wic = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-qemuamd64.wic";
        sha256 = "1cvs18f5kb5q14s8dv8r6shvkg3ci0f2wz2bbfgmvd4n57k6anqq";
        machine = "qemuamd64";
        artifactType = "wic";
        role = "server";
        networkProfile = "simple"; # Default to simple profile
      };
      vmlinuz = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-qemuamd64-vmlinuz";
        sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a";
        machine = "qemuamd64";
        artifactType = "kernel";
        role = "server";
        networkProfile = "simple";
      };
      initrd = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-qemuamd64-initrd.img";
        sha256 = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r";
        machine = "qemuamd64";
        artifactType = "initrd";
        role = "server";
        networkProfile = "simple";
      };
    };
    agent = {
      wic = requireIsarArtifact {
        name = "isar-k3s-image-agent-debian-trixie-qemuamd64.wic";
        sha256 = "0bjc8dldgdn7dd6czgcz4b7rp5l0v0j7xcakcyw93h386hqwa7y9"; # Not yet built
        machine = "qemuamd64";
        artifactType = "wic";
        role = "agent";
      };
      vmlinuz = requireIsarArtifact {
        name = "isar-k3s-image-agent-debian-trixie-qemuamd64-vmlinuz";
        sha256 = "1b2hn9n5sb5aqs3jh36q27qxyv4732nma9cx5zhipg2mw7yijr3a"; # Not yet built
        machine = "qemuamd64";
        artifactType = "kernel";
        role = "agent";
      };
      initrd = requireIsarArtifact {
        name = "isar-k3s-image-agent-debian-trixie-qemuamd64-initrd.img";
        sha256 = "14hl1x8rlgdli3cl7z5lfv58vgb8mmsihv7mr6y3v6q03jmzjj1r"; # Not yet built
        machine = "qemuamd64";
        artifactType = "initrd";
        role = "agent";
      };
    };
  };

  # ==========================================================================
  # QEMU ARM64 artifacts (for nixos-test-driver VM tests - Jetson emulation)
  # Note: qemuarm64 produces ext4 images (not WIC) and vmlinux (ELF, not vmlinuz)
  # ==========================================================================
  qemuarm64 = {
    base = {
      ext4 = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuarm64.ext4";
        sha256 = "13742fwy3jf7xyml02adzggxaz2zddy14id9jdyjxzrgd686wpq5"; # Run update-artifact-hashes.sh
        machine = "qemuarm64";
        artifactType = "ext4";
        role = "base";
      };
      vmlinux = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuarm64-vmlinux";
        sha256 = "07ghxkgzk701z6awnynmwc8brp55d5biqsjmmr6iwlw3ld8i9ylq"; # Run update-artifact-hashes.sh
        machine = "qemuarm64";
        artifactType = "kernel";
        role = "base";
      };
      initrd = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-qemuarm64-initrd.img";
        sha256 = "0ll549sn74xih22s97rh7lxlsqnnzyaw2ipknc7dn77lxdhswgkl"; # Run update-artifact-hashes.sh
        machine = "qemuarm64";
        artifactType = "initrd";
        role = "base";
      };
    };
    server = {
      ext4 = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-qemuarm64.ext4";
        sha256 = "1kfrkhh2avgzjxpk6niv3fbcnzkr87xd01nnfczw4xrircm9hrjw"; # Run update-artifact-hashes.sh
        machine = "qemuarm64";
        artifactType = "ext4";
        role = "server";
      };
      vmlinux = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-qemuarm64-vmlinux";
        sha256 = "07ghxkgzk701z6awnynmwc8brp55d5biqsjmmr6iwlw3ld8i9ylq"; # Run update-artifact-hashes.sh
        machine = "qemuarm64";
        artifactType = "kernel";
        role = "server";
      };
      initrd = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-qemuarm64-initrd.img";
        sha256 = "0ll549sn74xih22s97rh7lxlsqnnzyaw2ipknc7dn77lxdhswgkl"; # Run update-artifact-hashes.sh
        machine = "qemuarm64";
        artifactType = "initrd";
        role = "server";
      };
    };
  };

  # ==========================================================================
  # AMD V3C18i artifacts (real hardware - PRIMARY: k3s agent/worker node)
  # ==========================================================================
  amd-v3c18i = {
    # Primary target: k3s agent (worker node)
    agent = {
      wic = requireIsarArtifact {
        name = "isar-k3s-image-agent-debian-trixie-amd-v3c18i.wic";
        sha256 = "05dld5imxvvmxamkmn2ygq0gx9sn3a9h8inwzz4bqg0a8ssfwc64"; # Not yet built
        machine = "amd-v3c18i";
        artifactType = "wic";
        role = "agent";
      };
    };
  };

  # ==========================================================================
  # Jetson Orin Nano artifacts (real hardware - PRIMARY: k3s server/control plane)
  # Uses tar.gz rootfs for L4T flash tools (not WIC)
  # ==========================================================================
  jetson-orin-nano = {
    # Primary target: k3s server (control plane)
    server = {
      rootfs = requireIsarArtifact {
        name = "isar-k3s-image-server-debian-trixie-jetson-orin-nano.tar.gz";
        sha256 = "1wmy6rjmrs18j5cinh8wqk2v748wjrfdqbajz5ci46cnxhzpnxyx"; # Not yet built
        machine = "jetson-orin-nano";
        artifactType = "rootfs-tarball";
        role = "server";
      };
    };
    # Base image for testing/development
    base = {
      rootfs = requireIsarArtifact {
        name = "isar-k3s-image-base-debian-trixie-jetson-orin-nano.tar.gz";
        sha256 = "0jqlx7fr6lj4bkgnb5fmhchqcm57rj5cz0lb56xdz7krmjfyv9x5";
        machine = "jetson-orin-nano";
        artifactType = "rootfs-tarball";
        role = "base";
      };
    };
  };
}
