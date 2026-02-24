# =============================================================================
# K3s Base Include File
# =============================================================================
#
# PURPOSE:
#   Shared configuration for k3s-server and k3s-agent recipes. K3s is a
#   lightweight, certified Kubernetes distribution from Rancher Labs designed
#   for edge computing, IoT, and resource-constrained environments.
#
# ARCHITECTURE OVERVIEW:
#   K3s provides a single ~50MB binary that includes:
#     - Kubernetes control plane components (API server, scheduler, controller)
#     - containerd as the container runtime
#     - Built-in networking (flannel CNI)
#     - kubectl, crictl, and ctr CLI tools
#
# HOW THIS FILE IS USED:
#   Both k3s-server_*.bb and k3s-agent_*.bb recipes use "require k3s-base.inc"
#   to inherit this common configuration. Each recipe then adds role-specific
#   files (systemd services, environment configs) via do_install:append().
#
# BITBAKE VARIABLE NAMING CONVENTIONS:
#   - UPPERCASE variables (e.g., HOMEPAGE) are BitBake standard variables
#   - K3S_* variables are custom variables specific to this recipe family
#   - ${D} is the destination directory where files are staged during install
#   - ${WORKDIR} is where fetched/extracted source files are placed
#   - ${PN} is the package name (e.g., "k3s-server" or "k3s-agent")
#
# RELATED FILES:
#   - k3s-server_1.35.0.bb: Server (control plane) recipe
#   - k3s-agent_1.35.0.bb: Agent (worker node) recipe
#   - files/k3s-server.service: Systemd unit for server mode
#   - files/k3s-agent.service: Systemd unit for agent mode
#   - files/k3s-*.env: Environment configuration files
#
# =============================================================================

# -----------------------------------------------------------------------------
# Package Metadata
# -----------------------------------------------------------------------------
# These standard BitBake variables describe the upstream project.
# HOMEPAGE: Where to find documentation and releases
# LICENSE: Must match upstream; K3s uses Apache 2.0

HOMEPAGE = "https://k3s.io/"
LICENSE = "Apache-2.0"

# -----------------------------------------------------------------------------
# Version Configuration
# -----------------------------------------------------------------------------
# K3S_VERSION: The semantic version including the K3s-specific suffix
# K3S_VERSION_URL: URL-encoded version for GitHub download URLs
#   Note: The '+' in version strings must be encoded as %2B for URLs

K3S_VERSION = "1.35.0+k3s3"
K3S_VERSION_URL = "v1.35.0%2Bk3s3"

# -----------------------------------------------------------------------------
# Binary Selection for Multi-Architecture Support
# -----------------------------------------------------------------------------
# K3s uses different binary names for different architectures:
#   - amd64: "k3s"
#   - arm64: "k3s-arm64"
#
# The inline Python expression ${@...} evaluates at parse time to select
# the correct binary name based on DISTRO_ARCH.

K3S_BINARY_NAME = "${@'k3s-arm64' if d.getVar('DISTRO_ARCH') == 'arm64' else 'k3s'}"

# -----------------------------------------------------------------------------
# Source URI and Checksum Configuration
# -----------------------------------------------------------------------------
# SRC_URI defines where to download the K3s binary from.
# Parameters:
#   - downloadfilename: Uses K3S_BINARY_NAME so each architecture gets a unique
#     cache key ("k3s" for amd64, "k3s-arm64" for arm64). Without this, builds
#     sharing a download cache (DL_DIR) can pick up the wrong-arch binary.
#   - name=k3s: Reference name for the checksum variable below
#
# TODO: Add proper SHA256 checksums before production use.
# To get the checksum: sha256sum /path/to/downloaded/k3s

SRC_URI = "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/${K3S_BINARY_NAME};downloadfilename=${K3S_BINARY_NAME};name=k3s"
SRC_URI[k3s.sha256sum] = ""

# BB_STRICT_CHECKSUM = "0" disables checksum validation during development.
# WARNING: Set to "1" and add proper checksums for production builds!
BB_STRICT_CHECKSUM = "0"

# -----------------------------------------------------------------------------
# Role Configuration (Set by Including Recipe)
# -----------------------------------------------------------------------------
# K3S_ROLE identifies whether this is a "server" or "agent" build.
# This variable is set by the including recipe (k3s-server or k3s-agent).
# Currently unused but available for conditional logic if needed.

K3S_ROLE ?= ""

# -----------------------------------------------------------------------------
# Runtime Dependencies
# -----------------------------------------------------------------------------
# DEBIAN_DEPENDS lists packages that must be installed alongside K3s.
# These are NOT build dependencies - they're runtime requirements.
#
# This list mirrors the NixOS k3s wrapper PATH dependencies to ensure
# k3s operates identically on Debian-based ISAR images.
#
# Required packages:
#   - iptables: Network packet filtering (required for pod networking)
#   - nftables: Modern firewall backend (k3s detects and uses if available)
#   - iproute2: Network configuration utilities (ip command)
#   - kmod: Kernel module loading (modprobe for overlay, br_netfilter)
#   - socat: Socket relay for port forwarding
#   - ipset: IP set management for kube-proxy
#   - ethtool: Network interface configuration
#   - conntrack: Connection tracking (required for kube-proxy)
#   - bridge-utils: Network bridge management (brctl for CNI)
#   - util-linux: System utilities (mount, nsenter for containerd)
#   - systemd: Service management (K3s runs as a systemd service)
#
# Note: K3s bundles containerd, so no external container runtime is needed.

DEBIAN_DEPENDS = "iptables, nftables, iproute2, kmod, socat, ipset, ethtool, conntrack, bridge-utils, util-linux, systemd"

# -----------------------------------------------------------------------------
# Installation Logic
# -----------------------------------------------------------------------------
# do_install() defines how files are placed into the package staging area.
#
# Important paths:
#   ${D}/usr/bin/       - Executable binaries (Debian policy: not /usr/local/bin)
#   ${D}/etc/rancher/k3s/ - Configuration directory
#   ${D}/var/lib/rancher/k3s/ - Runtime data (etcd, containerd state, etc.)

do_install() {
    # Install the K3s binary to /usr/bin
    # Permission 0755: rwxr-xr-x (executable by all, writable by owner)
    install -d ${D}/usr/bin
    install -m 0755 ${WORKDIR}/${K3S_BINARY_NAME} ${D}/usr/bin/k3s

    # Create symlinks for bundled CLI tools
    # K3s binary implements kubectl/crictl/ctr when invoked via these names
    ln -sf k3s ${D}/usr/bin/kubectl   # Kubernetes CLI
    ln -sf k3s ${D}/usr/bin/crictl    # Container runtime interface CLI
    ln -sf k3s ${D}/usr/bin/ctr       # containerd CLI

    # Create configuration directory (for config.yaml, etc.)
    install -d ${D}/etc/rancher/k3s

    # Create data directory for runtime state
    # This will contain etcd data, containerd state, CNI config, etc.
    install -d ${D}/var/lib/rancher/k3s
}

# -----------------------------------------------------------------------------
# Package File List
# -----------------------------------------------------------------------------
# FILES:${PN} lists all files/directories that should be included in the
# final .deb package. Directories listed here will be owned by this package.

FILES:${PN} = " \
    /usr/bin/k3s \
    /usr/bin/kubectl \
    /usr/bin/crictl \
    /usr/bin/ctr \
    /etc/rancher/k3s \
    /var/lib/rancher/k3s \
"
