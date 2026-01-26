# Nix and ISAR Integration Guide
## Multi-Node K3s Platform for Industrial Embedded Linux

---

## Executive Summary

This guide describes the recommended architecture for integrating Nix with your existing ISAR (Debian-based Yocto) build system to create a multi-node, multi-arch (x86_64 and arm64) embedded Linux platform for k3s-based vendor software delivery in an industrial environment.

### Recommended Approach: ISAR Artifacts as Nix Inputs

Based on your project requirements and decision criteria, the recommended approach is to **treat ISAR-built artifacts (rootfs, kernel, initramfs) as fixed inputs to Nix derivations**. This provides:

- Clear separation of concerns: ISAR owns the base OS, Nix owns orchestration and deployment
- Reproducibility guarantees via Nix's content-addressed store
- No disruption to your working ISAR pipeline
- Path toward bit-for-bit reproducibility as organizational maturity grows
- Natural fit for multi-node, multi-arch k3s cluster management

### Why This Approach Fits Your Project

| Your Requirement | How This Approach Addresses It |
|------------------|-------------------------------|
| Existing ISAR pipeline producing working images | ISAR continues unchanged; Nix consumes its outputs |
| Organization requires Debian OS | ISAR's Debian Trixie images remain the base |
| Jetson Orin Nano with SWUpdate | Platform-specific recipes stay in ISAR where they work |
| Multi-arch (x86_64/arm64) | Nix handles cross-platform orchestration naturally |
| K3s-based vendor software delivery | Nix manages k3s manifests, Helm charts, and deployment |
| Bit-for-bit reproducibility (future goal) | Nix's hash-based model enables gradual adoption |
| Team learning curve | Nix for new work; ISAR knowledge preserved for base images |

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Importing ISAR Artifacts into Nix](#importing-isar-artifacts-into-nix)
3. [Multi-Arch Build Patterns](#multi-arch-build-patterns)
4. [K3s Cluster Configuration](#k3s-cluster-configuration)
5. [SWUpdate Integration](#swupdate-integration)
6. [Multi-Node Deployment Orchestration](#multi-node-deployment-orchestration)
7. [Reproducibility Strategy](#reproducibility-strategy)
8. [Project Structure](#project-structure)
9. [Troubleshooting](#troubleshooting)
10. [Appendix: Running ISAR Inside Nix](#appendix-running-isar-inside-nix)

---

## Architecture Overview

### System Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Nix-Managed Layer                               │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  K3s Workloads (Helm charts, manifests, vendor software)    │   │
│  ├─────────────────────────────────────────────────────────────┤   │
│  │  K3s Configuration (node roles, networking, storage)         │   │
│  ├─────────────────────────────────────────────────────────────┤   │
│  │  Deployment Orchestration (multi-node, multi-arch)          │   │
│  ├─────────────────────────────────────────────────────────────┤   │
│  │  SWUpdate Artifacts (update bundles, signatures)            │   │
│  └─────────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────────┤
│                     ISAR-Built Layer (Inputs to Nix)                │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐    │
│  │   Rootfs     │  │   Kernel     │  │   Device-Specific      │    │
│  │ (Debian      │  │   Initramfs  │  │   Firmware (Jetson)    │    │
│  │  Trixie)     │  │   DTBs       │  │   Bootloaders          │    │
│  └──────────────┘  └──────────────┘  └────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### Build Flow

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│   ISAR Build    │ ──── │  Artifact       │ ──── │   Nix Build     │
│   (Existing     │      │  Repository     │      │   (New)         │
│    Pipeline)    │      │  (Hashed)       │      │                 │
└─────────────────┘      └─────────────────┘      └─────────────────┘
        │                        │                        │
        ▼                        ▼                        ▼
  • Debian Trixie          • rootfs.tar.xz          • Final images
  • Jetson recipes         • Image-aarch64          • K3s configs
  • SWUpdate base          • initramfs.cpio         • Update bundles
  • Platform FW            • *.dtb files            • Deployment specs
```

---

## Importing ISAR Artifacts into Nix

### Core Concept: Fixed-Output Derivations

Nix identifies fixed-output derivations (FODs) by the hash of their output, not their build process. This allows ISAR artifacts to integrate seamlessly into Nix's reproducibility model.

```nix
# The hash guarantees content integrity regardless of source
pkgs.fetchurl {
  url = "https://builds.example.com/isar/debian-trixie-rootfs-arm64.tar.xz";
  sha256 = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=";
}
```

### ISAR-Specific Fetcher Module

Create a centralized module for ISAR artifact management:

```nix
# nix/isar-artifacts.nix
{ pkgs, lib }:

let
  # Version-pin your ISAR build outputs
  isarVersion = "2025.01";
  artifactBase = "https://builds.example.com/isar/${isarVersion}";
  
  # Helper for consistent artifact fetching
  fetchIsarArtifact = { name, sha256, arch ? "arm64" }:
    pkgs.fetchurl {
      url = "${artifactBase}/${arch}/${name}";
      inherit sha256;
      # Preserve original filename for debugging
      name = "${isarVersion}-${arch}-${name}";
    };

in {
  # Jetson Orin Nano (arm64)
  jetson-orin-nano = {
    rootfs = fetchIsarArtifact {
      name = "debian-trixie-jetson-orin-nano-rootfs.tar.xz";
      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      arch = "arm64";
    };
    
    kernel = fetchIsarArtifact {
      name = "Image-jetson-orin-nano";
      sha256 = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
      arch = "arm64";
    };
    
    initramfs = fetchIsarArtifact {
      name = "initramfs-jetson-orin-nano.cpio.gz";
      sha256 = "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=";
      arch = "arm64";
    };
    
    dtb = fetchIsarArtifact {
      name = "tegra234-p3768-0000+p3767-0005-nv.dtb";
      sha256 = "sha256-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=";
      arch = "arm64";
    };
    
    # Jetson-specific firmware handled by ISAR
    firmware = fetchIsarArtifact {
      name = "jetson-firmware-bundle.tar.xz";
      sha256 = "sha256-EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=";
      arch = "arm64";
    };
  };
  
  # x86_64 industrial controller nodes
  x86-controller = {
    rootfs = fetchIsarArtifact {
      name = "debian-trixie-x86-controller-rootfs.tar.xz";
      sha256 = "sha256-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF=";
      arch = "x86_64";
    };
    
    kernel = fetchIsarArtifact {
      name = "bzImage-x86-controller";
      sha256 = "sha256-GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG=";
      arch = "x86_64";
    };
    
    initramfs = fetchIsarArtifact {
      name = "initramfs-x86-controller.cpio.gz";
      sha256 = "sha256-HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH=";
      arch = "x86_64";
    };
  };
}
```

### Using requireFile for Air-Gapped or CI Artifacts

When ISAR builds aren't publicly accessible:

```nix
# nix/isar-artifacts-local.nix
{ pkgs }:

let
  requireIsarArtifact = { name, sha256, buildInstructions ? "" }:
    pkgs.requireFile {
      inherit name sha256;
      message = ''
        The ISAR artifact '${name}' must be manually obtained.
        
        Option 1: Copy from ISAR build output
          cp /path/to/isar/build/tmp/deploy/images/*/${name} .
          nix-store --add-fixed sha256 ${name}
        
        Option 2: Download from internal CI
          curl -O https://ci.internal/isar/artifacts/${name}
          nix-prefetch-url file://$PWD/${name}
        
        ${buildInstructions}
      '';
    };

in {
  jetson-orin-nano = {
    rootfs = requireIsarArtifact {
      name = "debian-trixie-jetson-orin-nano-rootfs.tar.xz";
      sha256 = "sha256-...";
      buildInstructions = ''
        To rebuild from ISAR:
          cd /path/to/isar-project
          bitbake mc:jetson-orin-nano:isar-image-base
      '';
    };
  };
}
```

---

## Multi-Arch Build Patterns

### Flake Structure for Multi-Arch Support

```nix
# flake.nix
{
  description = "Multi-node K3s industrial platform";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  
  outputs = { self, nixpkgs, flake-utils }:
    let
      # Define target architectures
      targetSystems = [ "x86_64-linux" "aarch64-linux" ];
      
      # Cross-compilation matrix
      crossMatrix = {
        # Build host -> Target
        "x86_64-linux" = [ "x86_64-linux" "aarch64-linux" ];
        "aarch64-linux" = [ "aarch64-linux" ];
      };
      
    in flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        
        # Import ISAR artifacts module
        isarArtifacts = import ./nix/isar-artifacts.nix { inherit pkgs; lib = pkgs.lib; };
        
        # Cross-compilation pkgs for arm64 targets when building on x86_64
        pkgsArm64 = if system == "x86_64-linux" 
          then import nixpkgs { 
            inherit system; 
            crossSystem = { config = "aarch64-unknown-linux-gnu"; };
          }
          else pkgs;
          
      in {
        packages = {
          # Node-specific final images
          jetson-orin-nano-image = import ./nix/images/jetson.nix {
            inherit pkgs;
            isarBase = isarArtifacts.jetson-orin-nano;
            k3sConfig = import ./nix/k3s/worker-config.nix;
          };
          
          x86-controller-image = import ./nix/images/x86-controller.nix {
            inherit pkgs;
            isarBase = isarArtifacts.x86-controller;
            k3sConfig = import ./nix/k3s/server-config.nix;
          };
          
          # SWUpdate bundles per architecture
          swupdate-bundle-arm64 = import ./nix/swupdate/bundle.nix {
            inherit pkgs;
            targetArch = "arm64";
            isarBase = isarArtifacts.jetson-orin-nano;
          };
          
          swupdate-bundle-x86 = import ./nix/swupdate/bundle.nix {
            inherit pkgs;
            targetArch = "x86_64";
            isarBase = isarArtifacts.x86-controller;
          };
        };
        
        # Development shells
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            kubectl
            k9s
            helm
            age       # for secret encryption
            sops      # for secrets management
          ];
        };
      }
    );
}
```

### Architecture-Aware Image Builder

```nix
# nix/images/common.nix
{ pkgs, lib, isarBase, k3sConfig, nodeRole, arch }:

let
  archConfig = {
    "arm64" = {
      kernelName = "Image";
      qemuArch = "aarch64";
      bootloader = "u-boot";
    };
    "x86_64" = {
      kernelName = "bzImage";
      qemuArch = "x86_64";
      bootloader = "grub";
    };
  };
  
  config = archConfig.${arch};

in pkgs.stdenv.mkDerivation {
  name = "platform-image-${arch}-${nodeRole}";
  
  nativeBuildInputs = with pkgs; [ 
    gnutar xz cpio 
    util-linux e2fsprogs dosfstools
  ];
  
  # No source - we're composing from ISAR artifacts
  dontUnpack = true;
  
  buildPhase = ''
    # Extract ISAR rootfs
    mkdir -p rootfs
    tar -xJf ${isarBase.rootfs} -C rootfs
    
    # Inject k3s configuration
    mkdir -p rootfs/etc/rancher/k3s
    cp ${k3sConfig} rootfs/etc/rancher/k3s/config.yaml
    
    # Set node role marker
    echo "${nodeRole}" > rootfs/etc/k3s-role
    
    # Copy kernel artifacts
    mkdir -p boot
    cp ${isarBase.kernel} boot/${config.kernelName}
    ${lib.optionalString (isarBase ? dtb) "cp ${isarBase.dtb} boot/"}
    ${lib.optionalString (isarBase ? initramfs) "cp ${isarBase.initramfs} boot/initramfs.cpio.gz"}
  '';
  
  installPhase = ''
    mkdir -p $out
    
    # Create rootfs image
    size=$(du -sb rootfs | cut -f1)
    size=$((size * 130 / 100))  # 30% overhead for k3s runtime
    truncate -s $size $out/rootfs.ext4
    mkfs.ext4 -d rootfs $out/rootfs.ext4
    
    # Copy boot artifacts
    cp -r boot $out/
    
    # Generate image metadata
    cat > $out/metadata.json <<EOF
    {
      "arch": "${arch}",
      "nodeRole": "${nodeRole}",
      "isarVersion": "$(cat rootfs/etc/isar-version 2>/dev/null || echo 'unknown')",
      "buildTime": "$(date -Iseconds)",
      "k3sConfig": "${k3sConfig}"
    }
    EOF
  '';
}
```

---

## K3s Cluster Configuration

### Node Configuration Module

```nix
# nix/k3s/config.nix
{ lib }:

let
  # Common k3s settings for industrial environment
  commonConfig = {
    # Disable components not needed in edge deployment
    disable = [ "traefik" "servicelb" "local-storage" ];
    
    # Network configuration for industrial subnet
    cluster-cidr = "10.42.0.0/16";
    service-cidr = "10.43.0.0/16";
    
    # Security hardening
    protect-kernel-defaults = true;
    secrets-encryption = true;
    
    # Kubelet configuration for embedded systems
    kubelet-arg = [
      "max-pods=50"
      "system-reserved=cpu=100m,memory=256Mi"
      "kube-reserved=cpu=100m,memory=256Mi"
      "eviction-hard=memory.available<100Mi,nodefs.available<10%"
    ];
  };

in {
  # Server (control plane) configuration
  serverConfig = { nodeIp, clusterToken, ... }: lib.generators.toYAML {} (commonConfig // {
    node-ip = nodeIp;
    token = clusterToken;
    
    # Server-specific settings
    write-kubeconfig-mode = "0644";
    tls-san = [ nodeIp "k3s.industrial.local" ];
    
    # Embedded etcd for HA (if multi-server)
    cluster-init = true;
  });
  
  # Agent (worker) configuration  
  agentConfig = { nodeIp, serverUrl, clusterToken, nodeLabels ? {}, ... }: 
    lib.generators.toYAML {} (commonConfig // {
      node-ip = nodeIp;
      server = serverUrl;
      token = clusterToken;
      
      # Node labels for workload scheduling
      node-label = lib.mapAttrsToList (k: v: "${k}=${v}") ({
        "node.kubernetes.io/instance-type" = "edge";
      } // nodeLabels);
    });
    
  # Jetson-specific worker (GPU-enabled)
  jetsonAgentConfig = args: lib.generators.toYAML {} (
    builtins.fromJSON (lib.generators.toYAML {} (commonConfig // {
      node-ip = args.nodeIp;
      server = args.serverUrl;
      token = args.clusterToken;
      
      node-label = [
        "nvidia.com/gpu=true"
        "node.kubernetes.io/instance-type=jetson-orin"
        "topology.kubernetes.io/zone=edge"
      ];
      
      # Container runtime for GPU support
      container-runtime-endpoint = "unix:///run/containerd/containerd.sock";
    }))
  );
}
```

### Generating Node-Specific Configurations

```nix
# nix/k3s/nodes.nix
{ pkgs, lib }:

let
  k3sConfig = import ./config.nix { inherit lib; };
  
  # Cluster topology definition
  cluster = {
    servers = {
      ctrl-1 = { ip = "192.168.1.10"; arch = "x86_64"; };
    };
    
    workers = {
      jetson-1 = { ip = "192.168.1.20"; arch = "arm64"; type = "jetson"; };
      jetson-2 = { ip = "192.168.1.21"; arch = "arm64"; type = "jetson"; };
      x86-edge-1 = { ip = "192.168.1.30"; arch = "x86_64"; type = "standard"; };
    };
  };
  
  # Generate config files for each node
  generateNodeConfigs = clusterToken: serverUrl:
    let
      serverConfigs = lib.mapAttrs (name: node: 
        pkgs.writeText "k3s-config-${name}.yaml" (k3sConfig.serverConfig {
          nodeIp = node.ip;
          inherit clusterToken;
        })
      ) cluster.servers;
      
      workerConfigs = lib.mapAttrs (name: node:
        pkgs.writeText "k3s-config-${name}.yaml" (
          if node.type == "jetson" then
            k3sConfig.jetsonAgentConfig {
              nodeIp = node.ip;
              inherit serverUrl clusterToken;
            }
          else
            k3sConfig.agentConfig {
              nodeIp = node.ip;
              inherit serverUrl clusterToken;
              nodeLabels = { "node-type" = node.type; };
            }
        )
      ) cluster.workers;
      
    in serverConfigs // workerConfigs;

in {
  inherit cluster generateNodeConfigs;
}
```

---

## SWUpdate Integration

### SWUpdate Bundle Generator

```nix
# nix/swupdate/bundle.nix
{ pkgs, lib, targetArch, isarBase, version ? "0.0.0" }:

let
  # SWUpdate sw-description template
  swDescription = pkgs.writeText "sw-description" ''
    software = {
      version = "${version}";
      hardware-compatibility = [ "${targetArch}" ];
      
      images: (
        {
          filename = "rootfs.tar.xz";
          type = "archive";
          path = "/";
          sha256 = "@rootfs.tar.xz.sha256";
          compressed = "zlib";
        },
        {
          filename = "kernel";
          type = "rawfile";
          path = "/boot/";
          sha256 = "@kernel.sha256";
        }
      );
      
      scripts: (
        {
          filename = "post-update.sh";
          type = "shellscript";
          sha256 = "@post-update.sh.sha256";
        }
      );
    };
  '';
  
  postUpdateScript = pkgs.writeScript "post-update.sh" ''
    #!/bin/sh
    set -e
    
    # Restart k3s after update
    systemctl restart k3s || systemctl restart k3s-agent
    
    # Verify node rejoins cluster
    for i in $(seq 1 30); do
      if kubectl get nodes | grep -q Ready; then
        exit 0
      fi
      sleep 10
    done
    
    echo "Node failed to rejoin cluster after update"
    exit 1
  '';

in pkgs.stdenv.mkDerivation {
  name = "swupdate-bundle-${targetArch}-${version}";
  
  nativeBuildInputs = with pkgs; [ 
    cpio 
    openssl  # for signing
    xz
  ];
  
  dontUnpack = true;
  
  buildPhase = ''
    mkdir -p bundle
    
    # Copy artifacts
    cp ${isarBase.rootfs} bundle/rootfs.tar.xz
    cp ${isarBase.kernel} bundle/kernel
    cp ${postUpdateScript} bundle/post-update.sh
    
    # Generate hashes for sw-description
    for f in bundle/*; do
      sha256sum "$f" | cut -d' ' -f1 > "$f.sha256"
    done
    
    # Process sw-description template (replace @file.sha256 placeholders)
    cp ${swDescription} bundle/sw-description
    for f in bundle/*.sha256; do
      name=$(basename "$f")
      hash=$(cat "$f")
      sed -i "s|@$name|$hash|g" bundle/sw-description
    done
  '';
  
  installPhase = ''
    mkdir -p $out
    
    # Create SWU bundle (cpio archive with sw-description first)
    cd bundle
    (echo sw-description; ls -1 | grep -v sw-description) | cpio -o -H crc > $out/update-${targetArch}-${version}.swu
    
    # Generate bundle metadata
    sha256sum $out/*.swu > $out/checksums.txt
  '';
}
```

### Coordinated Fleet Updates

```nix
# nix/swupdate/fleet-update.nix
{ pkgs, lib, cluster }:

let
  # Generate update manifest for fleet management
  fleetManifest = { version, bundles }: pkgs.writeText "fleet-manifest.json" (builtins.toJSON {
    inherit version;
    timestamp = "PLACEHOLDER";  # Set at build time
    nodes = lib.mapAttrs (name: node: {
      inherit (node) ip arch;
      bundle = bundles.${node.arch};
      updateOrder = if node ? server then 1 else 2;  # Servers first
    }) (cluster.servers // cluster.workers);
  });

in {
  # Create fleet update package
  createFleetUpdate = { version, armBundle, x86Bundle }: pkgs.stdenv.mkDerivation {
    name = "fleet-update-${version}";
    
    dontUnpack = true;
    
    installPhase = ''
      mkdir -p $out/bundles
      
      # Copy architecture-specific bundles
      cp ${armBundle}/*.swu $out/bundles/
      cp ${x86Bundle}/*.swu $out/bundles/
      
      # Generate manifest
      cat ${fleetManifest {
        inherit version;
        bundles = {
          arm64 = "${armBundle}/update-arm64-${version}.swu";
          x86_64 = "${x86Bundle}/update-x86_64-${version}.swu";
        };
      }} | sed "s/PLACEHOLDER/$(date -Iseconds)/" > $out/manifest.json
      
      # Checksums for all bundles
      sha256sum $out/bundles/*.swu > $out/checksums.txt
    '';
  };
}
```

---

## Multi-Node Deployment Orchestration

### Deployment Configuration

```nix
# nix/deploy/config.nix
{ lib }:

{
  # Node deployment specifications
  nodes = {
    # K3s server (control plane)
    ctrl-1 = {
      targetHost = "192.168.1.10";
      arch = "x86_64";
      role = "server";
      deployMethod = "ssh";  # or "usb", "pxe"
    };
    
    # Jetson worker nodes
    jetson-1 = {
      targetHost = "192.168.1.20";
      arch = "arm64";
      role = "agent";
      deployMethod = "ssh";
      extraConfig = {
        # Jetson-specific: use SDK Manager for initial flash
        flashTool = "nvidia-sdkmanager";
      };
    };
    
    jetson-2 = {
      targetHost = "192.168.1.21";
      arch = "arm64";
      role = "agent";
      deployMethod = "ssh";
    };
  };
  
  # Deployment order for cluster bootstrap
  deploymentOrder = [
    [ "ctrl-1" ]                      # Phase 1: Control plane
    [ "jetson-1" "jetson-2" ]         # Phase 2: Workers (parallel)
  ];
}
```

### Deployment Script Generator

```nix
# nix/deploy/scripts.nix
{ pkgs, lib, deployConfig, images }:

let
  # Generate SSH deployment script for a node
  sshDeployScript = { name, node, image }: pkgs.writeShellScript "deploy-${name}" ''
    set -euo pipefail
    
    TARGET="${node.targetHost}"
    IMAGE="${image}"
    
    echo "Deploying ${name} (${node.arch}) to $TARGET..."
    
    # Verify connectivity
    if ! ssh -o ConnectTimeout=5 root@$TARGET true; then
      echo "ERROR: Cannot connect to $TARGET"
      exit 1
    fi
    
    # Transfer image
    echo "Transferring image..."
    rsync -avz --progress $IMAGE/ root@$TARGET:/tmp/deploy/
    
    # Apply update
    ssh root@$TARGET << 'REMOTE'
      set -e
      cd /tmp/deploy
      
      # Backup current system
      echo "Creating backup..."
      tar -czf /var/backup/system-$(date +%Y%m%d-%H%M%S).tar.gz /etc /boot
      
      # Apply rootfs
      echo "Applying rootfs..."
      mount -o remount,rw /
      tar -xJf rootfs.tar.xz -C / --exclude='./etc/machine-id'
      
      # Update boot
      cp boot/* /boot/
      
      # Trigger reboot
      echo "Rebooting..."
      systemctl reboot
    REMOTE
    
    echo "Deployment initiated. Waiting for reboot..."
    sleep 30
    
    # Verify node came back
    for i in $(seq 1 12); do
      if ssh -o ConnectTimeout=5 root@$TARGET "systemctl is-active k3s-agent || systemctl is-active k3s" 2>/dev/null; then
        echo "Node ${name} successfully deployed and running!"
        exit 0
      fi
      echo "Waiting for node... ($i/12)"
      sleep 10
    done
    
    echo "WARNING: Node may not have come back properly"
    exit 1
  '';

in {
  # Individual node deployment scripts
  nodeScripts = lib.mapAttrs (name: node: 
    sshDeployScript {
      inherit name node;
      image = images.${name};
    }
  ) deployConfig.nodes;
  
  # Full cluster deployment script
  clusterDeploy = pkgs.writeShellScript "deploy-cluster" ''
    set -euo pipefail
    
    echo "=== Cluster Deployment ==="
    echo "Deployment order:"
    ${lib.concatStringsSep "\n" (lib.imap0 (i: phase: 
      "echo \"  Phase ${toString (i + 1)}: ${lib.concatStringsSep ", " phase}\""
    ) deployConfig.deploymentOrder)}
    
    ${lib.concatStringsSep "\n\n" (lib.imap0 (i: phase: ''
      echo ""
      echo "=== Phase ${toString (i + 1)}: ${lib.concatStringsSep ", " phase} ==="
      
      # Deploy phase nodes in parallel
      pids=()
      ${lib.concatMapStringsSep "\n" (node: ''
        ${sshDeployScript {
          name = node;
          node = deployConfig.nodes.${node};
          image = images.${node};
        }} &
        pids+=($!)
      '') phase}
      
      # Wait for all nodes in phase
      for pid in "''${pids[@]}"; do
        wait $pid
      done
      
      echo "Phase ${toString (i + 1)} complete."
    '') deployConfig.deploymentOrder)}
    
    echo ""
    echo "=== Cluster deployment complete ==="
    
    # Verify cluster health
    echo "Verifying cluster health..."
    kubectl get nodes
  '';
}
```

---

## Reproducibility Strategy

### Current State: Hash-Pinned ISAR Artifacts

Your current setup provides reproducibility at the ISAR output boundary:

```nix
# Every ISAR artifact is hash-pinned
rootfs = fetchurl {
  url = "...";
  sha256 = "sha256-XXXX...";  # Content-addressed
};
```

This guarantees:
- Same hash = identical content
- Nix builds are reproducible given same ISAR artifacts
- Changes to ISAR outputs are tracked via hash changes

### Future State: Full Pipeline Reproducibility

As organizational maturity grows, consider wrapping ISAR itself:

```nix
# Phase 1 (Current): ISAR artifacts as inputs
isarRootfs = fetchurl { ... };

# Phase 2 (Future): ISAR build reproducible via Nix
isarBuild = import ./nix/isar-in-nix.nix {
  isarCommit = "abc123...";
  debianSnapshot = "2025-01-15";  # Snapshot.debian.org pin
  # ...
};
```

### Artifact Versioning and Tracking

```nix
# nix/versions.nix
{
  # Pin specific ISAR build outputs
  isar = {
    version = "2025.01.15-build.42";
    commit = "abc123def456...";
    
    artifacts = {
      jetson-orin-nano = {
        rootfs = "sha256-AAAA...";
        kernel = "sha256-BBBB...";
      };
      x86-controller = {
        rootfs = "sha256-CCCC...";
        kernel = "sha256-DDDD...";
      };
    };
  };
  
  # Track upstream versions
  k3s.version = "v1.29.0+k3s1";
  containerd.version = "1.7.11";
}
```

---

## Project Structure

Recommended repository layout:

```
project-root/
├── flake.nix                      # Main flake definition
├── flake.lock                     # Locked dependencies
│
├── isar/                          # ISAR project (existing)
│   ├── sources/
│   ├── recipes-*/
│   └── conf/
│
├── nix/                           # Nix configurations
│   ├── isar-artifacts.nix         # ISAR artifact definitions
│   ├── versions.nix               # Version pinning
│   │
│   ├── images/                    # Image builders
│   │   ├── common.nix
│   │   ├── jetson.nix
│   │   └── x86-controller.nix
│   │
│   ├── k3s/                       # K3s configuration
│   │   ├── config.nix
│   │   ├── nodes.nix
│   │   └── manifests/             # K8s manifests
│   │       ├── vendor-app/
│   │       └── platform-services/
│   │
│   ├── swupdate/                  # SWUpdate bundles
│   │   ├── bundle.nix
│   │   └── fleet-update.nix
│   │
│   └── deploy/                    # Deployment orchestration
│       ├── config.nix
│       └── scripts.nix
│
├── k8s/                           # Kubernetes resources
│   ├── helm/                      # Helm charts
│   └── kustomize/                 # Kustomize overlays
│
└── docs/                          # Documentation
    ├── architecture.md
    └── operations.md
```

---

## Troubleshooting

### Hash Mismatch When Fetching ISAR Artifacts

**Problem:**
```
error: hash mismatch in fixed-output derivation '/nix/store/...-rootfs.tar.xz'
  specified: sha256-AAAA...
  got:       sha256-BBBB...
```

**Solution:** ISAR output changed. Update the hash:
```bash
# Get new hash
nix-prefetch-url https://builds.example.com/isar/rootfs.tar.xz

# Or use empty string to get hash from error
sha256 = "";  # Nix will show correct hash
```

### Multi-Arch Build Failures

**Problem:** Building arm64 artifacts on x86_64 fails.

**Solution:** Ensure cross-compilation or emulation is configured:
```nix
# In flake.nix or configuration.nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

Or use native arm64 builders:
```nix
# In flake.nix
nixConfig = {
  extra-platforms = [ "aarch64-linux" ];
  extra-sandbox-paths = [ "/run/binfmt" ];
};
```

### K3s Node Fails to Join Cluster

**Problem:** Worker nodes don't appear in `kubectl get nodes`.

**Diagnosis:**
```bash
# On the worker node
journalctl -u k3s-agent -f
cat /etc/rancher/k3s/config.yaml
ping <server-ip>
```

**Common causes:**
- Token mismatch: Regenerate tokens and redeploy
- Network: Ensure ports 6443, 10250 are open
- Time sync: Ensure NTP is configured on all nodes

### SWUpdate Bundle Verification Fails

**Problem:** SWUpdate rejects the bundle.

**Solution:** Verify sw-description hashes match actual file hashes:
```bash
# Extract and verify
cpio -idv < update.swu
sha256sum rootfs.tar.xz
grep rootfs sw-description  # Compare hashes
```

---

## Appendix: Running ISAR Inside Nix

While not recommended for your current situation (working ISAR pipeline exists), this approach may be valuable if you later want full reproducibility of the base images themselves.

### When to Consider This

- Organization mandates reproducible builds at every layer
- ISAR build environment needs to be version-controlled
- Multiple developers need identical ISAR build environments

### FHS Environment for ISAR

ISAR (like Yocto) expects FHS-compliant filesystem layout:

```nix
# nix/isar-env.nix
{ pkgs ? import <nixpkgs> {} }:

pkgs.buildFHSUserEnvBubblewrap {
  name = "isar-env";
  
  targetPkgs = pkgs: with pkgs; [
    # ISAR host dependencies
    python3
    python3Packages.pip
    python3Packages.setuptools
    
    # Debian packaging tools
    dpkg
    debootstrap
    
    # BitBake requirements
    gcc
    gnumake
    git
    wget
    diffstat
    chrpath
    cpio
    
    # QEMU for rootfs building
    qemu
    
    # Locale support
    glibcLocales
  ];
  
  extraBuildCommands = ''
    ln -sf ${pkgs.glibcLocales}/lib/locale/locale-archive $out/usr/lib/locale
  '';
  
  profile = ''
    export LANG="C.UTF-8"
    export LC_ALL="C.UTF-8"
    export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive
    export BB_ENV_EXTRAWHITE="LOCALE_ARCHIVE"
  '';
  
  runScript = "bash";
}
```

**Usage:**
```bash
nix-build nix/isar-env.nix -o isar-shell
./isar-shell/bin/isar-env

# Inside the shell, ISAR commands work normally
cd /path/to/isar-project
source isar-init-build-env
bitbake mc:jetson-orin-nano:isar-image-base
```

This approach is documented here for completeness but is not the recommended path given your existing working ISAR pipeline.

---

## Additional Resources

### Documentation

- [Nix Fetchers Reference](https://nixos.org/manual/nixpkgs/stable/#chap-pkgs-fetchers)
- [ISAR Documentation](https://github.com/ilbers/isar)
- [K3s Documentation](https://docs.k3s.io/)
- [SWUpdate Documentation](https://sbabic.github.io/swupdate/)

### Community

- [NixOS Discourse](https://discourse.nixos.org/) — Nix community support
- [ISAR Mailing List](https://groups.io/g/isar-users) — ISAR-specific questions

---

*Document Version: 2.0 (Revised)*  
*Project Context: Multi-node K3s industrial platform with ISAR base images*  
*Last Updated: January 2025*
