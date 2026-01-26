# =============================================================================
# K3s Agent Recipe
# =============================================================================
#
# PURPOSE:
#   Provides K3s configured as a Kubernetes worker node (agent mode).
#   This package enables a node to join an existing K3s cluster and run
#   container workloads under the control of the cluster's server.
#
# PREREQUISITES:
#   Before starting the agent, you must configure connection to a server:
#   1. Edit /etc/default/k3s-agent
#   2. Set K3S_URL to the server URL (e.g., https://server-ip:6443)
#   3. Set K3S_TOKEN to the node token from the server
#
#   To get the token from the server, run:
#     cat /var/lib/rancher/k3s/server/node-token
#
# USAGE:
#   After configuring, start the agent:
#     systemctl start k3s-agent
#
#   Verify the node joined the cluster (from server):
#     kubectl get nodes
#
# CONFIGURATION:
#   - Service options: /etc/default/k3s-agent
#
# SEE ALSO:
#   - k3s-base.inc: Shared configuration with k3s-server recipe
#   - k3s-server_*.bb: Control plane recipe (mutually exclusive with this)
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

DESCRIPTION = "K3s Lightweight Kubernetes - Agent (worker node)"
MAINTAINER = "Your Name <your@email.com>"

# Set the role for this recipe (used in k3s-base.inc if needed)
K3S_ROLE = "agent"

# -----------------------------------------------------------------------------
# Agent-Specific Source Files
# -----------------------------------------------------------------------------
# SRC_URI += appends to the base SRC_URI from k3s-base.inc
# file:// URIs reference files in the 'files/' subdirectory

SRC_URI += "file://k3s-agent.service \
            file://k3s-agent.env"

# -----------------------------------------------------------------------------
# Agent-Specific Installation
# -----------------------------------------------------------------------------
# do_install:append() extends the base do_install() from k3s-base.inc
# The :append syntax adds to existing function rather than replacing it.
#
# Note: Agent has fewer configuration options than server - no drop-in
# directory is needed since agents are configured via K3S_URL and K3S_TOKEN.

do_install:append() {
    # Install systemd service unit for automatic startup
    # ${systemd_system_unitdir} resolves to the correct path for the target distro:
    #   - Debian bookworm: /lib/systemd/system
    #   - Debian trixie:   /usr/lib/systemd/system
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/k3s-agent.service ${D}${systemd_system_unitdir}/k3s-agent.service

    # Install environment file with placeholder configuration
    # Users MUST edit /etc/default/k3s-agent to set K3S_URL and K3S_TOKEN
    install -d ${D}/etc/default
    install -m 0644 ${WORKDIR}/k3s-agent.env ${D}/etc/default/k3s-agent

    # Pre-configure test token for automated testing
    # WARNING: This is for testing only - production should use secure tokens
    # The agent will use this same token to authenticate with the server
    install -d ${D}/var/lib/rancher/k3s/server
    echo "test-cluster-fixed-token-for-automated-testing" > \
        ${D}/var/lib/rancher/k3s/server/token
    chmod 0600 ${D}/var/lib/rancher/k3s/server/token
}

# -----------------------------------------------------------------------------
# Agent-Specific Package Contents
# -----------------------------------------------------------------------------
# FILES:${PN} += appends to the base file list from k3s-base.inc

FILES:${PN} += " \
    ${systemd_system_unitdir}/k3s-agent.service \
    /etc/default/k3s-agent \
    /var/lib/rancher/k3s/server/token \
"

# -----------------------------------------------------------------------------
# Package Conflicts
# -----------------------------------------------------------------------------
# RCONFLICTS declares runtime conflicts (packages that cannot be installed
# together). A node must be either a server OR an agent, not both.

RCONFLICTS:${PN} = "k3s-server"
