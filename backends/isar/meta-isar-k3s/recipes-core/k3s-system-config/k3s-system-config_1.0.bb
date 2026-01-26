# =============================================================================
# K3s System Configuration
# =============================================================================
#
# PURPOSE:
#   Configures the system for k3s operation:
#   - Loads required kernel modules at boot
#   - Sets sysctl parameters for container networking
#   - Configures iptables-legacy mode
#   - Disables swap (Kubernetes requirement)
#
# USAGE:
#   Add this package to any k3s image (server or agent)
#
# =============================================================================

inherit dpkg-raw

SUMMARY = "System configuration for k3s nodes"
DESCRIPTION = "System configuration required for k3s Kubernetes operation. \
    Includes kernel module loading, sysctl parameters, iptables-legacy setup, \
    and swap disable service."
MAINTAINER = "Your Name <your@email.com>"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b72c5df05c96dff79b35f2"

SRC_URI = "\
    file://k3s-modules.conf \
    file://k3s-sysctl.conf \
    file://disable-swap.service \
    file://iptables-legacy.sh \
    file://hostname \
"

# Ensure systemd is available
DEBIAN_DEPENDS = "systemd"

do_install() {
    # Install kernel module configuration
    # Modules listed here are loaded at boot by systemd-modules-load.service
    install -d ${D}/etc/modules-load.d
    install -m 0644 ${WORKDIR}/k3s-modules.conf ${D}/etc/modules-load.d/k3s.conf

    # Install sysctl configuration
    # Parameters are applied at boot by systemd-sysctl.service
    install -d ${D}/etc/sysctl.d
    install -m 0644 ${WORKDIR}/k3s-sysctl.conf ${D}/etc/sysctl.d/99-k3s.conf

    # Install swap disable service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/disable-swap.service ${D}${systemd_system_unitdir}/disable-swap.service

    # Enable disable-swap service by default
    install -d ${D}${systemd_system_unitdir}/multi-user.target.wants
    ln -sf ../disable-swap.service ${D}${systemd_system_unitdir}/multi-user.target.wants/disable-swap.service

    # Install iptables-legacy configuration script
    # This runs once during first boot to configure iptables alternatives
    install -d ${D}/usr/lib/isar-k3s
    install -m 0755 ${WORKDIR}/iptables-legacy.sh ${D}/usr/lib/isar-k3s/iptables-legacy.sh

    # Install hostname
    install -m 0644 ${WORKDIR}/hostname ${D}/etc/hostname
}

# Add postinst script to run iptables-legacy configuration
pkg_postinst:${PN}() {
    # Run iptables-legacy configuration if not in cross-compile environment
    if [ -z "$D" ]; then
        /usr/lib/isar-k3s/iptables-legacy.sh
    fi
}

FILES:${PN} = "\
    /etc/modules-load.d/k3s.conf \
    /etc/sysctl.d/99-k3s.conf \
    /etc/hostname \
    ${systemd_system_unitdir}/disable-swap.service \
    ${systemd_system_unitdir}/multi-user.target.wants/disable-swap.service \
    /usr/lib/isar-k3s/iptables-legacy.sh \
"
