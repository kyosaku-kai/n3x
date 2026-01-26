# =============================================================================
# NixOS Test Driver Backdoor Service
# =============================================================================
#
# PURPOSE:
#   Provides the guest-side backdoor service required by the NixOS test driver.
#   This service starts a bash shell on /dev/hvc0 (virtio-console) that allows
#   the test driver to execute commands inside the VM.
#
# USAGE:
#   Include in test images via kas overlay:
#     local_conf_header:
#       test-backdoor: |
#         IMAGE_INSTALL:append = " nixos-test-backdoor"
#
# REFERENCE:
#   Based on NixOS test-instrumentation.nix:
#   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/testing/test-instrumentation.nix
#
# =============================================================================

inherit dpkg-raw

SUMMARY = "NixOS test driver backdoor service for VM testing"
DESCRIPTION = "Guest-side service that enables the NixOS test driver to control \
    Debian/ISAR VMs via virtio-console. Starts a bash shell on /dev/hvc0 and \
    prints the handshake string that the test driver waits for."
MAINTAINER = "Your Name <your@email.com>"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b72c5df05c96dff79b35f2"

SRC_URI = "\
    file://nixos-test-backdoor.service \
    file://backdoor.sh \
"

# bash is required for the backdoor shell
DEBIAN_DEPENDS = "bash, coreutils"

do_install() {
    # Install the backdoor script
    install -d ${D}/usr/lib/nixos-test
    install -m 0755 ${WORKDIR}/backdoor.sh ${D}/usr/lib/nixos-test/backdoor.sh

    # Install systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/nixos-test-backdoor.service ${D}${systemd_system_unitdir}/

    # Enable by default - start before getty to be available early
    install -d ${D}${systemd_system_unitdir}/multi-user.target.wants
    ln -sf ../nixos-test-backdoor.service ${D}${systemd_system_unitdir}/multi-user.target.wants/
}

FILES:${PN} = "\
    /usr/lib/nixos-test/backdoor.sh \
    ${systemd_system_unitdir}/nixos-test-backdoor.service \
    ${systemd_system_unitdir}/multi-user.target.wants/nixos-test-backdoor.service \
"
