# Custom kernel 6.12 LTS for NVIDIA Jetson Orin Nano (Tegra234)
#
# Based on upstream ISAR linux-mainline recipe pattern.
# Uses arm64 defconfig as base with Tegra234 config fragment overlay.
#
# Produces Debian packages: linux-image-*, linux-headers-*, linux-kbuild-*
#
# Copyright (c) 2026
# SPDX-License-Identifier: MIT

inherit linux-kernel

DESCRIPTION = "Linux kernel 6.12 LTS with Tegra234 SoC support"

ARCHIVE_VERSION = "${@ d.getVar('PV')[:-2] if d.getVar('PV').endswith('.0') else d.getVar('PV') }"

SRC_URI += " \
    ${KERNEL_MIRROR}/v6.x/linux-${ARCHIVE_VERSION}.tar.xz \
    file://tegra234-enable.cfg"

SRC_URI[sha256sum] = "4b493657f218703239c4f22415f027b3644949bf2761abd18b849f0aad5f7665"

S = "${WORKDIR}/linux-${ARCHIVE_VERSION}"

# Use kernel's built-in arm64 defconfig as base; Tegra234 fragment applied on top
KERNEL_DEFCONFIG:jetson-orin-nano = "defconfig"

LINUX_VERSION_EXTENSION = "-tegra"

# Restrict to Jetson platforms only
COMPATIBLE_MACHINE = "jetson-orin-.*"
