# =============================================================================
# K3s Server Recipe
# =============================================================================
#
# PURPOSE:
#   Provides K3s configured as a Kubernetes control plane (server mode).
#   This package enables a node to act as the cluster's control plane,
#   managing the API server, scheduler, controller, and etcd datastore.
#
# USAGE:
#   After installing this package, the K3s server starts automatically.
#   Access your cluster with: kubectl get nodes
#
# CONFIGURATION:
#   - Service options: /etc/default/k3s-server
#   - Drop-in configs: /etc/rancher/k3s/config.yaml.d/
#   - Kubeconfig:      /etc/rancher/k3s/k3s.yaml (created at first run)
#   - Node token:      /var/lib/rancher/k3s/server/node-token (for agents)
#
# SEE ALSO:
#   - k3s-base.inc: Shared configuration with k3s-agent recipe
#   - k3s-agent_*.bb: Worker node recipe (mutually exclusive with this)
#
# =============================================================================

# -----------------------------------------------------------------------------
# Recipe Inheritance and Includes
# -----------------------------------------------------------------------------
# inherit dpkg-raw: Use ISAR's class for packaging pre-built binaries as .deb
#   This class handles debian/ directory generation and dpkg-buildpackage.
#
# require k3s-base.inc: Include shared K3s configuration
#   The 'require' directive is similar to 'include' but fails if file is missing.

inherit dpkg-raw

require k3s-base.inc

# -----------------------------------------------------------------------------
# Package Metadata
# -----------------------------------------------------------------------------
# DESCRIPTION: Human-readable summary (shown in apt/dpkg)
# MAINTAINER: Package maintainer contact

DESCRIPTION = "K3s Lightweight Kubernetes - Server (control plane)"
MAINTAINER = "Your Name <your@email.com>"

# Set the role for this recipe (used in k3s-base.inc if needed)
K3S_ROLE = "server"

# -----------------------------------------------------------------------------
# Server-Specific Source Files
# -----------------------------------------------------------------------------
# SRC_URI += appends to the base SRC_URI from k3s-base.inc
# file:// URIs reference files in the 'files/' subdirectory

SRC_URI += "file://k3s-server.service \
            file://k3s-server.env"

# -----------------------------------------------------------------------------
# Server-Specific Dependencies
# -----------------------------------------------------------------------------
# The server needs ca-certificates for TLS validation when fetching images
# and communicating with external services.

DEBIAN_DEPENDS += ", ca-certificates"

# -----------------------------------------------------------------------------
# Server-Specific Installation
# -----------------------------------------------------------------------------
# do_install:append() extends the base do_install() from k3s-base.inc
# The :append syntax adds to existing function rather than replacing it.

do_install:append() {
    # Install systemd service unit for automatic startup
    # ${systemd_system_unitdir} resolves to the correct path for the target distro:
    #   - Debian bookworm: /lib/systemd/system
    #   - Debian trixie:   /usr/lib/systemd/system
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/k3s-server.service ${D}${systemd_system_unitdir}/k3s-server.service

    # Enable the service by default - create symlink in multi-user.target.wants
    install -d ${D}${systemd_system_unitdir}/multi-user.target.wants
    ln -sf ../k3s-server.service ${D}${systemd_system_unitdir}/multi-user.target.wants/k3s-server.service

    # Install environment file with default configuration
    # Users can edit /etc/default/k3s-server to customize startup options
    install -d ${D}/etc/default
    install -m 0644 ${WORKDIR}/k3s-server.env ${D}/etc/default/k3s-server

    # Create directory for configuration drop-ins
    # Place YAML files here for modular configuration (merged at startup)
    install -d ${D}/etc/rancher/k3s/config.yaml.d

    # Pre-configure test token for automated testing
    # WARNING: This is for testing only - production should use secure tokens
    # The server will use this token for agent authentication
    install -d ${D}/var/lib/rancher/k3s/server
    echo "test-cluster-fixed-token-for-automated-testing" > \
        ${D}/var/lib/rancher/k3s/server/token
    chmod 0600 ${D}/var/lib/rancher/k3s/server/token
}

# -----------------------------------------------------------------------------
# Server-Specific Package Contents
# -----------------------------------------------------------------------------
# FILES:${PN} += appends to the base file list from k3s-base.inc

FILES:${PN} += " \
    ${systemd_system_unitdir}/k3s-server.service \
    ${systemd_system_unitdir}/multi-user.target.wants/k3s-server.service \
    /etc/default/k3s-server \
    /etc/rancher/k3s/config.yaml.d \
    /var/lib/rancher/k3s/server/token \
"

# -----------------------------------------------------------------------------
# Package Conflicts
# -----------------------------------------------------------------------------
# RCONFLICTS declares runtime conflicts (packages that cannot be installed
# together). A node must be either a server OR an agent, not both.

RCONFLICTS:${PN} = "k3s-agent"
