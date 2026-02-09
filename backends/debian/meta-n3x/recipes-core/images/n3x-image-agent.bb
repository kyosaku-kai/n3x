# =============================================================================
# n3x Agent Image
# =============================================================================
#
# PURPOSE:
#   Provides a Kubernetes worker node using K3s in agent mode.
#   Built on the minimal n3x base for reduced attack surface.
#
# CONTENTS:
#   - Minimal Debian Trixie base
#   - K3s binary (lightweight Kubernetes distribution by Rancher)
#   - kubectl, crictl, and ctr CLI tools (symlinked to k3s binary)
#   - Systemd service for automatic startup
#   - Default configuration in /etc/default/k3s-agent
#
# PREREQUISITES:
#   Before the agent can start, you must configure:
#   1. K3S_URL - The URL of the K3s server (e.g., https://server-ip:6443)
#   2. K3S_TOKEN - The node token from the server
#
#   Edit /etc/default/k3s-agent to set these values, then start the service:
#     systemctl start k3s-agent
#
#   To get the token from the server, run on the server node:
#     cat /var/lib/rancher/k3s/server/node-token
#
# BUILD:
#   kas-container --isar build kas/base.yml:kas/machine/<target>.yml:kas/image/k3s-agent.yml
#
# =============================================================================

DESCRIPTION = "n3x image with K3s Kubernetes worker node"

LICENSE = "gpl-2.0"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.GPLv2;md5=751419260aa954499f7abaabaa882bbe"

PV = "1.0"

inherit image

# Include shared minimal base configuration
require n3x-image.inc

# Include the K3s agent package
# This provides the Kubernetes worker node functionality
IMAGE_INSTALL += "k3s-agent"

# =============================================================================
# Bootloader Configuration (systemd-boot default)
# =============================================================================
# systemd-boot is the default bootloader - simpler than GRUB, better EFI integration.
# k3s extracts ~200MB of embedded binaries on first run, so we use a k3s-specific WKS.
#
# To use GRUB instead (for SWUpdate A/B compatibility):
#   Append kas/boot/grub.yml to build command
#
# Use ?= (default) so kas overlays can override via local.conf
WKS_FILE ?= "sdimage-efi-systemd-boot-n3x.wks"

# systemd-boot-efi must be in both imager chroot (WIC plugin) and target rootfs
# IMAGER_INSTALL:wic - packages in WIC build chroot for EFI binary access
# IMAGE_PREINSTALL - packages in target rootfs via apt
IMAGER_INSTALL:wic:append = " systemd-boot-efi"
IMAGE_PREINSTALL:append = " systemd-boot-efi"
