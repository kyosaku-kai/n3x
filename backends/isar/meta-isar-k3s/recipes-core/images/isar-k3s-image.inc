# =============================================================================
# isar-k3s Minimal Base Include
# =============================================================================
#
# PURPOSE:
#   Shared configuration for minimal isar-k3s images (k3s server/agent).
#   Follows the Talos Linux philosophy: minimal attack surface.
#
# USAGE:
#   Include in image recipes with: require isar-k3s-image.inc
#
# PACKAGE PHILOSOPHY:
#   Start with nothing, add only what k3s needs:
#   - No documentation, no man pages
#   - Minimal locales (en_US.UTF-8 only)
#   - No desktop/GUI packages
#   - No development tools
#
# SIZE OPTIMIZATIONS (K4 audit, 2026-01-17):
#   - Strip docs and man pages (~100MB)
#   - Strip locales properly (~15MB)
#   - Remove sftp-server and sqv binaries (~6MB)
#
# FUTURE OPTIMIZATIONS (deferred - requires ISAR investigation):
#   - Switch to dracut (removes perl ~50MB) - ISAR uses update-initramfs
#   - Remove apt/dpkg post-build (~15MB) - breaks initramfs generation
#   - Remove cpio post-build (~1MB) - mkinitramfs needs it during do_generate_initramfs
#
# =============================================================================

# -----------------------------------------------------------------------------
# Initramfs Configuration
# -----------------------------------------------------------------------------
# NOTE: ISAR uses initramfs-tools via update-initramfs during do_generate_initramfs.
# Switching to dracut requires more investigation into ISAR's rootfs.bbclass.
# For now, we keep initramfs-tools (which pulls in perl).

# -----------------------------------------------------------------------------
# Package Selection
# -----------------------------------------------------------------------------
# Minimal packages for k3s operation. The kernel is added automatically
# by image.bbclass via KERNEL_IMAGE_PKG.
#
# IMAGE_PREINSTALL = Debian packages from apt repository
# IMAGE_INSTALL = Packages built by ISAR (local .bb recipes)
#
# Core runtime:
#   ca-certificates  - SSL certificate handling
#   curl             - For k3s installation/updates
#
# Networking (k3s requirements):
#   iptables         - Network packet filtering (required for pod networking)
#   conntrack        - Connection tracking tool (required for kube-proxy)
#   iproute2         - Network configuration (ip command)
#   ipvsadm          - IPVS load balancing (for kube-proxy IPVS mode)
#   bridge-utils     - Network bridge management (for CNI)
#
# System utilities:
#   procps           - Process utilities (ps, top, free)
#   util-linux       - System utilities (mount, lsblk, etc.)
#
# Testing/debugging (minimal):
#   openssh-server   - Remote access for testing (sftp-server removed post-build)
#   vim-tiny         - Minimal editor
#   less             - Pager for log viewing

IMAGE_PREINSTALL += "\
    ca-certificates \
    curl \
    iptables \
    conntrack \
    iproute2 \
    ipvsadm \
    bridge-utils \
    procps \
    util-linux \
    openssh-server \
    vim-tiny \
    less \
"

# System configuration packages (built by ISAR):
#   k3s-system-config - Kernel modules, sysctl, iptables-legacy, swap, hostname
#   sshd-regen-keys   - Regenerate SSH host keys on first boot
IMAGE_INSTALL += "k3s-system-config sshd-regen-keys"

# -----------------------------------------------------------------------------
# Locale Configuration
# -----------------------------------------------------------------------------
# Keep only en_US.UTF-8 to reduce image size
# Format: "locale charset" with \n between entries
# This is set via image-locales-extension.bbclass

LOCALE_GEN = "en_US.UTF-8 UTF-8"
LOCALE_DEFAULT = "en_US.UTF-8"

# -----------------------------------------------------------------------------
# Rootfs Features
# -----------------------------------------------------------------------------
# Enable standard features for manifest and SBOM generation
# Clean up caches to reduce image size

ROOTFS_FEATURES += "\
    clean-package-cache \
    clean-pycache \
    generate-manifest \
    export-dpkg-status \
    clean-log-files \
    clean-debconf-cache \
"

# -----------------------------------------------------------------------------
# Post-Processing: Remove Bloat
# -----------------------------------------------------------------------------
# These functions run after package installation to remove unnecessary files.

ROOTFS_POSTPROCESS_COMMAND += "\
    remove_docs_and_manpages \
    remove_extra_locales \
    remove_unnecessary_binaries \
    create_kernel_symlinks \
"

remove_docs_and_manpages() {
    # Remove documentation (saves ~50-100MB)
    sudo rm -rf "${IMAGE_ROOTFS}/usr/share/doc/"*
    sudo rm -rf "${IMAGE_ROOTFS}/usr/share/man/"*
    sudo rm -rf "${IMAGE_ROOTFS}/usr/share/info/"*
    sudo rm -rf "${IMAGE_ROOTFS}/usr/share/groff/"*
    sudo rm -rf "${IMAGE_ROOTFS}/usr/share/lintian/"*

    # Remove changelog files
    sudo find "${IMAGE_ROOTFS}/usr/share" -name 'changelog*' -delete 2>/dev/null || true
    sudo find "${IMAGE_ROOTFS}/usr/share" -name 'NEWS*' -delete 2>/dev/null || true
    sudo find "${IMAGE_ROOTFS}/usr/share" -name 'README*' -delete 2>/dev/null || true
    sudo find "${IMAGE_ROOTFS}/usr/share" -name 'AUTHORS*' -delete 2>/dev/null || true
}

remove_extra_locales() {
    # Keep only en_US locale (saves ~20-50MB)
    # Note: Keep C locale as fallback
    if [ -d "${IMAGE_ROOTFS}/usr/share/locale" ]; then
        sudo find "${IMAGE_ROOTFS}/usr/share/locale" -mindepth 1 -maxdepth 1 \
            ! -name 'en' ! -name 'en_US' ! -name 'C' \
            -exec rm -rf {} \; 2>/dev/null || true
    fi

    # Remove locale-archive if it exists (regenerated with only needed locales)
    sudo rm -f "${IMAGE_ROOTFS}/usr/lib/locale/locale-archive" 2>/dev/null || true

    # Remove libc-l10n translations we don't need
    if [ -d "${IMAGE_ROOTFS}/usr/share/i18n/locales" ]; then
        sudo find "${IMAGE_ROOTFS}/usr/share/i18n/locales" -type f \
            ! -name 'en_US' ! -name 'en_GB' ! -name 'C' ! -name 'POSIX' ! -name 'i18n*' ! -name 'iso*' ! -name 'translit*' \
            -delete 2>/dev/null || true
    fi
}

remove_unnecessary_binaries() {
    # Remove sftp-server (we only need SSH, not SFTP) - saves ~1MB
    sudo rm -f "${IMAGE_ROOTFS}/usr/lib/openssh/sftp-server" 2>/dev/null || true

    # Remove sqv (Sequoia signature verification) - saves ~5MB
    # Only needed during build, not runtime
    sudo rm -f "${IMAGE_ROOTFS}/usr/bin/sqv" 2>/dev/null || true

    # NOTE: Cannot remove cpio here! ROOTFS_POSTPROCESS_COMMAND runs BEFORE
    # do_generate_initramfs, and mkinitramfs requires cpio to build the initramfs.
    # Same issue as dpkg removal - needs post-image hook or WIC plugin.
}

create_kernel_symlinks() {
    # Create symlinks for kernel and initrd in /boot
    # GRUB expects /vmlinuz and /initrd.img but Debian installs versioned files
    # The bootimg-efi-isar WIC plugin copies files from /boot to EFI partition
    # These symlinks allow GRUB to find the kernel without version suffixes
    local boot_dir="${IMAGE_ROOTFS}/boot"

    # Find the actual kernel and initrd files (may have version suffix)
    local vmlinuz_file=$(ls -1 ${boot_dir}/vmlinuz-* 2>/dev/null | head -1 | xargs -r basename)
    local initrd_file=$(ls -1 ${boot_dir}/initrd.img-* 2>/dev/null | head -1 | xargs -r basename)

    if [ -n "$vmlinuz_file" ] && [ ! -e "${boot_dir}/vmlinuz" ]; then
        sudo ln -sf "$vmlinuz_file" "${boot_dir}/vmlinuz"
        bbnote "Created symlink: vmlinuz -> $vmlinuz_file"
    fi

    if [ -n "$initrd_file" ] && [ ! -e "${boot_dir}/initrd.img" ]; then
        sudo ln -sf "$initrd_file" "${boot_dir}/initrd.img"
        bbnote "Created symlink: initrd.img -> $initrd_file"
    fi
}

# FUTURE: Remove apt/dpkg post-build for immutable images
# Currently disabled because ISAR's do_generate_initramfs runs AFTER
# ROOTFS_POSTPROCESS_COMMAND and mkinitramfs requires dpkg.
# To enable this, need to either:
# 1. Switch ISAR to use dracut instead of initramfs-tools
# 2. Move dpkg removal to IMAGE_POSTPROCESS_COMMAND (if such exists in ISAR)
# 3. Create a custom WIC plugin that removes dpkg from the final image
#
# remove_package_manager() {
#     # Remove apt and dpkg from final image (saves ~15MB)
#     sudo rm -rf "${IMAGE_ROOTFS}/usr/bin/apt"* 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/usr/bin/dpkg"* 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/usr/lib/apt" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/usr/lib/dpkg" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/var/lib/apt" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/var/cache/apt" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/etc/apt" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/var/lib/dpkg/info" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/var/lib/dpkg/updates" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/var/lib/dpkg/alternatives" 2>/dev/null || true
#     sudo rm -rf "${IMAGE_ROOTFS}/var/lib/dpkg/triggers" 2>/dev/null || true
# }
