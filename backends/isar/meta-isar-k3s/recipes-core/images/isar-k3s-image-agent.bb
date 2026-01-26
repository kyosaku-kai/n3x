# =============================================================================
# isar-k3s Agent Image
# =============================================================================
#
# PURPOSE:
#   Provides a Kubernetes worker node using K3s in agent mode.
#   Built on the minimal isar-k3s base for reduced attack surface.
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

DESCRIPTION = "isar-k3s image with K3s Kubernetes worker node"

LICENSE = "gpl-2.0"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.GPLv2;md5=751419260aa954499f7abaabaa882bbe"

PV = "1.0"

inherit image

# Include shared minimal base configuration
require isar-k3s-image.inc

# Include the K3s agent package
# This provides the Kubernetes worker node functionality
IMAGE_INSTALL += "k3s-agent"

# Use k3s-optimized WKS file with extra space
# k3s extracts ~200MB of embedded binaries on first run
WKS_FILE = "sdimage-efi-k3s.wks"
