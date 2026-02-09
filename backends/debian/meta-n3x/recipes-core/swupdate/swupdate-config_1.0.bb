# =============================================================================
# SWUpdate Configuration for A/B OTA Updates
# =============================================================================
#
# PURPOSE:
#   Installs SWUpdate from Debian repos and adds configuration for A/B
#   partition-based OTA updates with GRUB bootloader integration.
#
# USAGE:
#   Add to IMAGE_INSTALL in images that need OTA update capability.
#   Requires A/B partition layout (sdimage-efi-ab.wks).
#
# CONFIGURATION:
#   - /etc/swupdate.cfg - Main SWUpdate configuration
#   - /etc/swupdate/conf.d/ - Drop-in configuration directory
#   - GRUB environment integration for partition switching
#
# =============================================================================

inherit dpkg-raw

SUMMARY = "SWUpdate configuration for A/B OTA updates"
DESCRIPTION = "Configuration files for SWUpdate OTA update system. \
    Includes GRUB bootloader integration for A/B partition switching."
MAINTAINER = "n3x <n3x@example.com>"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b72c5df05c96dff79b35f2"

SRC_URI = "\
    file://swupdate.cfg \
    file://09-swupdate-args \
"

# Pull swupdate and grub tools from Debian repos
# swupdate - the update agent
# grub-common - provides grub-editenv for bootloader env manipulation
DEBIAN_DEPENDS = "swupdate, grub-common"

# Hardware compatibility can be overridden per-machine
# Default matches QEMU targets for testing
SWUPDATE_HW_COMPAT ?= "qemu-amd64"

do_install() {
    # Install main configuration
    install -d ${D}/etc
    install -m 0644 ${WORKDIR}/swupdate.cfg ${D}/etc/swupdate.cfg

    # Substitute hardware compatibility string
    sed -i "s|@SWUPDATE_HW_COMPAT@|${SWUPDATE_HW_COMPAT}|g" ${D}/etc/swupdate.cfg

    # Install default arguments file for swupdate service
    install -d ${D}/etc/default
    install -m 0644 ${WORKDIR}/09-swupdate-args ${D}/etc/default/swupdate

    # Create grubenv file location (will be populated by GRUB at boot)
    # SWUpdate expects this path per CONFIG_GRUBENV_PATH
    install -d ${D}/boot/efi/EFI/BOOT
}

# Create grubenv on first boot if it doesn't exist
pkg_postinst:${PN}() {
    if [ -z "$D" ]; then
        # Running on target system
        if [ ! -f /boot/efi/EFI/BOOT/grubenv ]; then
            grub-editenv /boot/efi/EFI/BOOT/grubenv create 2>/dev/null || true
            grub-editenv /boot/efi/EFI/BOOT/grubenv set rootfs_slot=a 2>/dev/null || true
            echo "Created initial grubenv with rootfs_slot=a"
        fi
    fi
}

FILES:${PN} = "\
    /etc/swupdate.cfg \
    /etc/default/swupdate \
    /boot/efi/EFI/BOOT \
"
