# =============================================================================
# isar-k3s Minimal Base Image
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
#   Can be built directly for testing, or use isar-k3s-image-server/agent.
#
# BUILD:
#   kas-container --isar build kas/base.yml:kas/machine/qemu-amd64.yml:kas/image/minimal-base.yml
#
# =============================================================================

DESCRIPTION = "isar-k3s minimal base image for k3s nodes"

LICENSE = "gpl-2.0"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.GPLv2;md5=751419260aa954499f7abaabaa882bbe"

PV = "1.0"

inherit image

# Include shared minimal base configuration
require isar-k3s-image.inc
