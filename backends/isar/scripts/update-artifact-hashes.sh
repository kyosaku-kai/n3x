#!/usr/bin/env bash
# Computes sha256 hashes for ISAR artifacts and updates nix/isar-artifacts.nix
#
# Usage:
#   scripts/update-artifact-hashes.sh           # Compute and display hashes
#   scripts/update-artifact-hashes.sh --update  # Also update nix/isar-artifacts.nix
#   scripts/update-artifact-hashes.sh --add     # Also add to nix store
#
# After running with --update, commit the changes to nix/isar-artifacts.nix

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-build/tmp/deploy/images}"
ARTIFACTS_FILE="nix/isar-artifacts.nix"
UPDATE_FILE=false
ADD_TO_STORE=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --update) UPDATE_FILE=true ;;
    --add) ADD_TO_STORE=true ;;
    --help|-h)
      echo "Usage: $0 [--update] [--add]"
      echo "  --update  Update nix/isar-artifacts.nix with computed hashes"
      echo "  --add     Add artifacts to nix store after computing hashes"
      exit 0
      ;;
  esac
done

# Compute Nix base32 hash for a file
compute_hash() {
  local file="$1"
  if [[ -f "$file" ]]; then
    nix-hash --type sha256 --flat --base32 "$file"
  else
    echo "MISSING"
  fi
}

echo "Computing ISAR artifact hashes..."
echo "Deploy directory: $DEPLOY_DIR"
echo ""

# Track artifacts for later operations
declare -A ARTIFACT_HASHES
declare -A ARTIFACT_PATHS

# ==========================================================================
# qemuamd64 artifacts (WIC, vmlinuz)
# ==========================================================================
QEMU_AMD64_BASE_WIC="$DEPLOY_DIR/qemuamd64/isar-k3s-image-base-debian-trixie-qemuamd64.wic"
QEMU_AMD64_BASE_VMLINUZ="$DEPLOY_DIR/qemuamd64/isar-k3s-image-base-debian-trixie-qemuamd64-vmlinuz"
QEMU_AMD64_BASE_INITRD="$DEPLOY_DIR/qemuamd64/isar-k3s-image-base-debian-trixie-qemuamd64-initrd.img"

QEMU_AMD64_SERVER_WIC="$DEPLOY_DIR/qemuamd64/isar-k3s-image-server-debian-trixie-qemuamd64.wic"
QEMU_AMD64_SERVER_VMLINUZ="$DEPLOY_DIR/qemuamd64/isar-k3s-image-server-debian-trixie-qemuamd64-vmlinuz"
QEMU_AMD64_SERVER_INITRD="$DEPLOY_DIR/qemuamd64/isar-k3s-image-server-debian-trixie-qemuamd64-initrd.img"

QEMU_AMD64_AGENT_WIC="$DEPLOY_DIR/qemuamd64/isar-k3s-image-agent-debian-trixie-qemuamd64.wic"
QEMU_AMD64_AGENT_VMLINUZ="$DEPLOY_DIR/qemuamd64/isar-k3s-image-agent-debian-trixie-qemuamd64-vmlinuz"
QEMU_AMD64_AGENT_INITRD="$DEPLOY_DIR/qemuamd64/isar-k3s-image-agent-debian-trixie-qemuamd64-initrd.img"

# ==========================================================================
# qemuarm64 artifacts (EXT4, vmlinux - different from amd64!)
# ==========================================================================
QEMU_ARM64_BASE_EXT4="$DEPLOY_DIR/qemuarm64/isar-k3s-image-base-debian-trixie-qemuarm64.ext4"
QEMU_ARM64_BASE_VMLINUX="$DEPLOY_DIR/qemuarm64/isar-k3s-image-base-debian-trixie-qemuarm64-vmlinux"
QEMU_ARM64_BASE_INITRD="$DEPLOY_DIR/qemuarm64/isar-k3s-image-base-debian-trixie-qemuarm64-initrd.img"

QEMU_ARM64_SERVER_EXT4="$DEPLOY_DIR/qemuarm64/isar-k3s-image-server-debian-trixie-qemuarm64.ext4"
QEMU_ARM64_SERVER_VMLINUX="$DEPLOY_DIR/qemuarm64/isar-k3s-image-server-debian-trixie-qemuarm64-vmlinux"
QEMU_ARM64_SERVER_INITRD="$DEPLOY_DIR/qemuarm64/isar-k3s-image-server-debian-trixie-qemuarm64-initrd.img"

# ==========================================================================
# amd-v3c18i artifacts (real hardware - primary: agent)
# ==========================================================================
AMD_AGENT_WIC="$DEPLOY_DIR/amd-v3c18i/isar-k3s-image-agent-debian-trixie-amd-v3c18i.wic"
AMD_AGENT_VMLINUZ="$DEPLOY_DIR/amd-v3c18i/isar-k3s-image-agent-debian-trixie-amd-v3c18i-vmlinuz"
AMD_AGENT_INITRD="$DEPLOY_DIR/amd-v3c18i/isar-k3s-image-agent-debian-trixie-amd-v3c18i-initrd.img"

# ==========================================================================
# jetson-orin-nano artifacts (real hardware - primary: server, tar.gz rootfs)
# ==========================================================================
JETSON_BASE_ROOTFS="$DEPLOY_DIR/jetson-orin-nano/isar-k3s-image-base-debian-trixie-jetson-orin-nano.tar.gz"
JETSON_SERVER_ROOTFS="$DEPLOY_DIR/jetson-orin-nano/isar-k3s-image-server-debian-trixie-jetson-orin-nano.tar.gz"

# ==========================================================================
# Compute hashes for all artifacts
# ==========================================================================

echo "=== QEMU AMD64 (base) ==="
ARTIFACT_HASHES[qemu_amd64_base_wic]=$(compute_hash "$QEMU_AMD64_BASE_WIC")
ARTIFACT_PATHS[qemu_amd64_base_wic]="$QEMU_AMD64_BASE_WIC"
echo "  wic:     ${ARTIFACT_HASHES[qemu_amd64_base_wic]}"

ARTIFACT_HASHES[qemu_amd64_base_vmlinuz]=$(compute_hash "$QEMU_AMD64_BASE_VMLINUZ")
ARTIFACT_PATHS[qemu_amd64_base_vmlinuz]="$QEMU_AMD64_BASE_VMLINUZ"
echo "  vmlinuz: ${ARTIFACT_HASHES[qemu_amd64_base_vmlinuz]}"

ARTIFACT_HASHES[qemu_amd64_base_initrd]=$(compute_hash "$QEMU_AMD64_BASE_INITRD")
ARTIFACT_PATHS[qemu_amd64_base_initrd]="$QEMU_AMD64_BASE_INITRD"
echo "  initrd:  ${ARTIFACT_HASHES[qemu_amd64_base_initrd]}"

echo ""
echo "=== QEMU AMD64 (server) ==="
ARTIFACT_HASHES[qemu_amd64_server_wic]=$(compute_hash "$QEMU_AMD64_SERVER_WIC")
ARTIFACT_PATHS[qemu_amd64_server_wic]="$QEMU_AMD64_SERVER_WIC"
echo "  wic:     ${ARTIFACT_HASHES[qemu_amd64_server_wic]}"

ARTIFACT_HASHES[qemu_amd64_server_vmlinuz]=$(compute_hash "$QEMU_AMD64_SERVER_VMLINUZ")
ARTIFACT_PATHS[qemu_amd64_server_vmlinuz]="$QEMU_AMD64_SERVER_VMLINUZ"
echo "  vmlinuz: ${ARTIFACT_HASHES[qemu_amd64_server_vmlinuz]}"

ARTIFACT_HASHES[qemu_amd64_server_initrd]=$(compute_hash "$QEMU_AMD64_SERVER_INITRD")
ARTIFACT_PATHS[qemu_amd64_server_initrd]="$QEMU_AMD64_SERVER_INITRD"
echo "  initrd:  ${ARTIFACT_HASHES[qemu_amd64_server_initrd]}"

echo ""
echo "=== QEMU AMD64 (agent) ==="
ARTIFACT_HASHES[qemu_amd64_agent_wic]=$(compute_hash "$QEMU_AMD64_AGENT_WIC")
ARTIFACT_PATHS[qemu_amd64_agent_wic]="$QEMU_AMD64_AGENT_WIC"
echo "  wic:     ${ARTIFACT_HASHES[qemu_amd64_agent_wic]}"

ARTIFACT_HASHES[qemu_amd64_agent_vmlinuz]=$(compute_hash "$QEMU_AMD64_AGENT_VMLINUZ")
ARTIFACT_PATHS[qemu_amd64_agent_vmlinuz]="$QEMU_AMD64_AGENT_VMLINUZ"
echo "  vmlinuz: ${ARTIFACT_HASHES[qemu_amd64_agent_vmlinuz]}"

ARTIFACT_HASHES[qemu_amd64_agent_initrd]=$(compute_hash "$QEMU_AMD64_AGENT_INITRD")
ARTIFACT_PATHS[qemu_amd64_agent_initrd]="$QEMU_AMD64_AGENT_INITRD"
echo "  initrd:  ${ARTIFACT_HASHES[qemu_amd64_agent_initrd]}"

echo ""
echo "=== QEMU ARM64 (base) ==="
ARTIFACT_HASHES[qemu_arm64_base_ext4]=$(compute_hash "$QEMU_ARM64_BASE_EXT4")
ARTIFACT_PATHS[qemu_arm64_base_ext4]="$QEMU_ARM64_BASE_EXT4"
echo "  ext4:    ${ARTIFACT_HASHES[qemu_arm64_base_ext4]}"

ARTIFACT_HASHES[qemu_arm64_base_vmlinux]=$(compute_hash "$QEMU_ARM64_BASE_VMLINUX")
ARTIFACT_PATHS[qemu_arm64_base_vmlinux]="$QEMU_ARM64_BASE_VMLINUX"
echo "  vmlinux: ${ARTIFACT_HASHES[qemu_arm64_base_vmlinux]}"

ARTIFACT_HASHES[qemu_arm64_base_initrd]=$(compute_hash "$QEMU_ARM64_BASE_INITRD")
ARTIFACT_PATHS[qemu_arm64_base_initrd]="$QEMU_ARM64_BASE_INITRD"
echo "  initrd:  ${ARTIFACT_HASHES[qemu_arm64_base_initrd]}"

echo ""
echo "=== QEMU ARM64 (server) ==="
ARTIFACT_HASHES[qemu_arm64_server_ext4]=$(compute_hash "$QEMU_ARM64_SERVER_EXT4")
ARTIFACT_PATHS[qemu_arm64_server_ext4]="$QEMU_ARM64_SERVER_EXT4"
echo "  ext4:    ${ARTIFACT_HASHES[qemu_arm64_server_ext4]}"

ARTIFACT_HASHES[qemu_arm64_server_vmlinux]=$(compute_hash "$QEMU_ARM64_SERVER_VMLINUX")
ARTIFACT_PATHS[qemu_arm64_server_vmlinux]="$QEMU_ARM64_SERVER_VMLINUX"
echo "  vmlinux: ${ARTIFACT_HASHES[qemu_arm64_server_vmlinux]}"

ARTIFACT_HASHES[qemu_arm64_server_initrd]=$(compute_hash "$QEMU_ARM64_SERVER_INITRD")
ARTIFACT_PATHS[qemu_arm64_server_initrd]="$QEMU_ARM64_SERVER_INITRD"
echo "  initrd:  ${ARTIFACT_HASHES[qemu_arm64_server_initrd]}"

echo ""
echo "=== AMD V3C18i (agent) ==="
ARTIFACT_HASHES[amd_agent_wic]=$(compute_hash "$AMD_AGENT_WIC")
ARTIFACT_PATHS[amd_agent_wic]="$AMD_AGENT_WIC"
echo "  wic:     ${ARTIFACT_HASHES[amd_agent_wic]}"

ARTIFACT_HASHES[amd_agent_vmlinuz]=$(compute_hash "$AMD_AGENT_VMLINUZ")
ARTIFACT_PATHS[amd_agent_vmlinuz]="$AMD_AGENT_VMLINUZ"
echo "  vmlinuz: ${ARTIFACT_HASHES[amd_agent_vmlinuz]}"

ARTIFACT_HASHES[amd_agent_initrd]=$(compute_hash "$AMD_AGENT_INITRD")
ARTIFACT_PATHS[amd_agent_initrd]="$AMD_AGENT_INITRD"
echo "  initrd:  ${ARTIFACT_HASHES[amd_agent_initrd]}"

echo ""
echo "=== Jetson Orin Nano (base) ==="
ARTIFACT_HASHES[jetson_base_rootfs]=$(compute_hash "$JETSON_BASE_ROOTFS")
ARTIFACT_PATHS[jetson_base_rootfs]="$JETSON_BASE_ROOTFS"
echo "  rootfs:  ${ARTIFACT_HASHES[jetson_base_rootfs]}"

echo ""
echo "=== Jetson Orin Nano (server) ==="
ARTIFACT_HASHES[jetson_server_rootfs]=$(compute_hash "$JETSON_SERVER_ROOTFS")
ARTIFACT_PATHS[jetson_server_rootfs]="$JETSON_SERVER_ROOTFS"
echo "  rootfs:  ${ARTIFACT_HASHES[jetson_server_rootfs]}"

echo ""

# Update nix/isar-artifacts.nix if requested
if $UPDATE_FILE; then
  echo "Updating $ARTIFACTS_FILE..."

  if [[ ! -f "$ARTIFACTS_FILE" ]]; then
    echo "ERROR: $ARTIFACTS_FILE not found"
    exit 1
  fi

  # Create a backup
  cp "$ARTIFACTS_FILE" "$ARTIFACTS_FILE.bak"

  # Update hashes using sed - each artifact has a unique name so we can match precisely
  # Helper function to update hash in nix file
  update_hash() {
    local artifact_name="$1"
    local hash_key="$2"
    local hash="${ARTIFACT_HASHES[$hash_key]}"
    if [[ "$hash" != "MISSING" && -n "$hash" ]]; then
      # Escape dots in artifact name for sed regex
      local escaped_name="${artifact_name//./\\.}"
      sed -i "/name = \"${escaped_name}\";/{n;s/sha256 = \"[^\"]*\";/sha256 = \"${hash}\";/}" "$ARTIFACTS_FILE"
    fi
  }

  # qemuamd64 base
  update_hash "isar-k3s-image-base-debian-trixie-qemuamd64.wic" "qemu_amd64_base_wic"
  update_hash "isar-k3s-image-base-debian-trixie-qemuamd64-vmlinuz" "qemu_amd64_base_vmlinuz"
  update_hash "isar-k3s-image-base-debian-trixie-qemuamd64-initrd.img" "qemu_amd64_base_initrd"

  # qemuamd64 server
  update_hash "isar-k3s-image-server-debian-trixie-qemuamd64.wic" "qemu_amd64_server_wic"
  update_hash "isar-k3s-image-server-debian-trixie-qemuamd64-vmlinuz" "qemu_amd64_server_vmlinuz"
  update_hash "isar-k3s-image-server-debian-trixie-qemuamd64-initrd.img" "qemu_amd64_server_initrd"

  # qemuamd64 agent
  update_hash "isar-k3s-image-agent-debian-trixie-qemuamd64.wic" "qemu_amd64_agent_wic"
  update_hash "isar-k3s-image-agent-debian-trixie-qemuamd64-vmlinuz" "qemu_amd64_agent_vmlinuz"
  update_hash "isar-k3s-image-agent-debian-trixie-qemuamd64-initrd.img" "qemu_amd64_agent_initrd"

  # qemuarm64 base (ext4 + vmlinux)
  update_hash "isar-k3s-image-base-debian-trixie-qemuarm64.ext4" "qemu_arm64_base_ext4"
  update_hash "isar-k3s-image-base-debian-trixie-qemuarm64-vmlinux" "qemu_arm64_base_vmlinux"
  update_hash "isar-k3s-image-base-debian-trixie-qemuarm64-initrd.img" "qemu_arm64_base_initrd"

  # qemuarm64 server (ext4 + vmlinux)
  update_hash "isar-k3s-image-server-debian-trixie-qemuarm64.ext4" "qemu_arm64_server_ext4"
  update_hash "isar-k3s-image-server-debian-trixie-qemuarm64-vmlinux" "qemu_arm64_server_vmlinux"
  update_hash "isar-k3s-image-server-debian-trixie-qemuarm64-initrd.img" "qemu_arm64_server_initrd"

  # amd-v3c18i agent
  update_hash "isar-k3s-image-agent-debian-trixie-amd-v3c18i.wic" "amd_agent_wic"

  # jetson-orin-nano base
  update_hash "isar-k3s-image-base-debian-trixie-jetson-orin-nano.tar.gz" "jetson_base_rootfs"

  # jetson-orin-nano server
  update_hash "isar-k3s-image-server-debian-trixie-jetson-orin-nano.tar.gz" "jetson_server_rootfs"

  echo "Done. Review changes with: git diff $ARTIFACTS_FILE"
  echo "Backup saved to: $ARTIFACTS_FILE.bak"
fi

# Add artifacts to nix store if requested
if $ADD_TO_STORE; then
  echo ""
  echo "Adding artifacts to nix store..."

  for key in "${!ARTIFACT_HASHES[@]}"; do
    hash="${ARTIFACT_HASHES[$key]}"
    path="${ARTIFACT_PATHS[$key]}"

    if [[ "$hash" != "MISSING" && -f "$path" ]]; then
      echo "  Adding: $(basename "$path")"
      nix-store --add-fixed sha256 "$path" || echo "    Failed (may already exist)"
    fi
  done

  echo "Done."
fi

echo ""
echo "Next steps:"
if ! $UPDATE_FILE; then
  echo "  1. Run with --update to update nix/isar-artifacts.nix"
fi
if ! $ADD_TO_STORE; then
  echo "  2. Run with --add to add artifacts to nix store"
fi
echo "  3. Stage changes: git add nix/isar-artifacts.nix scripts/"
echo "  4. Run validation: nix flake check"
