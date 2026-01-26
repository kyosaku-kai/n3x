# =============================================================================
# isar-k3s Server Image
# =============================================================================
#
# PURPOSE:
#   Provides a complete Kubernetes control plane node using K3s.
#   Built on the minimal isar-k3s base for reduced attack surface.
#
# CONTENTS:
#   - Minimal Debian Trixie base
#   - K3s binary (lightweight Kubernetes distribution by Rancher)
#   - kubectl, crictl, and ctr CLI tools (symlinked to k3s binary)
#   - Systemd service for automatic startup
#   - Default configuration in /etc/default/k3s-server
#
# USAGE:
#   After booting, K3s server starts automatically. Access the cluster with:
#     kubectl get nodes
#
#   The kubeconfig is available at /etc/rancher/k3s/k3s.yaml
#   The node token for joining agents is at /var/lib/rancher/k3s/server/node-token
#
# BUILD:
#   kas-container --isar build kas/base.yml:kas/machine/<target>.yml:kas/image/k3s-server.yml
#
# =============================================================================

DESCRIPTION = "isar-k3s image with K3s Kubernetes control plane"

LICENSE = "gpl-2.0"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.GPLv2;md5=751419260aa954499f7abaabaa882bbe"

PV = "1.0"

inherit image

# Include shared minimal base configuration
require isar-k3s-image.inc

# Include the K3s server package
# This provides the Kubernetes control plane functionality
IMAGE_INSTALL += "k3s-server"

# Use k3s-optimized WKS file with extra space
# k3s extracts ~200MB of embedded binaries on first run
WKS_FILE = "sdimage-efi-k3s.wks"
