# =============================================================================
# n3x Minimal Base Image
# =============================================================================
#
# PURPOSE:
#   Provides the absolute minimum Debian Trixie base for k3s nodes.
#   Follows the Talos Linux philosophy: minimal attack surface.
#
# PHILOSOPHY:
#   - Start with nothing, add only what k3s needs
#   - No documentation, no man pages
#   - Minimal locales (en_US.UTF-8 only)
#   - No desktop/GUI packages
#   - No development tools
#
# TARGET SIZE:
#   ~450MB (comparable to NixOS minimal base)
#
# CONTENTS:
#   - Minimal Debian Trixie base (systemd, apt)
#   - k3s prerequisites (iptables, conntrack, iproute2, etc.)
#   - System configuration (kernel modules, sysctl, swap disable)
#   - SSH server for remote access
#   - Minimal debugging tools (vim-tiny, less, procps)
#
# USAGE:
#   This is the base for k3s server and agent images.
#   Can be built directly for testing, or use n3x-image-server/agent.
#
# BUILD:
#   kas-build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/base.yml
#
# =============================================================================

DESCRIPTION = "n3x minimal base image for k3s nodes"

LICENSE = "gpl-2.0"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.GPLv2;md5=751419260aa954499f7abaabaa882bbe"

PV = "1.0"

inherit image

# Include shared minimal base configuration
require n3x-image.inc

# =============================================================================
# Bootloader Configuration (systemd-boot default)
# =============================================================================
# systemd-boot is the default bootloader - simpler than GRUB, better EFI integration.
#
# To use GRUB instead:
#   Append kas/boot/grub.yml to build command
#
# Use ?= (default) so kas overlays can override via local.conf
WKS_FILE ?= "sdimage-efi-systemd-boot-n3x.wks"

# systemd-boot-efi must be in both imager chroot (WIC plugin) and target rootfs
# IMAGER_INSTALL:wic - packages in WIC build chroot for EFI binary access
# IMAGE_PREINSTALL - packages in target rootfs via apt
IMAGER_INSTALL:wic:append = " systemd-boot-efi"
IMAGE_PREINSTALL:append = " systemd-boot-efi"
