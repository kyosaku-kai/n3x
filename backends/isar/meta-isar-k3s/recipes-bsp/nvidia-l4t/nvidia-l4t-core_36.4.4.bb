# NVIDIA L4T Core Package
#
# Base L4T package required as a dependency for nvidia-l4t-tools and other L4T components.
# This package provides platform detection and base L4T functionality.
#
# Download from NVIDIA's Jetson apt repository (t234 for Orin/Thor platforms).
# SHA256 verified against jetpack-nixos sourceinfo/r36.4-debs.json
#
# Usage:
#   Add to IMAGE_INSTALL in your image recipe or kas configuration.
#   This package is typically installed as a dependency of nvidia-l4t-tools.

inherit dpkg-prebuilt

SUMMARY = "NVIDIA L4T Core - Base platform support for Jetson"
DESCRIPTION = "NVIDIA L4T Core package providing base platform detection \
    and dependencies for all other L4T packages. This package checks that \
    it is running on a valid Tegra SoC."
HOMEPAGE = "https://developer.nvidia.com/embedded/jetpack"
MAINTAINER = "isar-k3s maintainers"

# NVIDIA proprietary license - packages are subject to NVIDIA's EULA
# (https://developer.nvidia.com/embedded/jetson-software-license-agreement)
# LIC_FILES_CHKSUM points to MIT as a build system placeholder; the actual
# license governing these binaries is NVIDIA's proprietary EULA, not MIT.
LICENSE = "NVIDIA"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b72c5df05c96dff79b35f2"

# L4T R36.4.4 version from NVIDIA Jetson repository (t234 = Orin/Thor)
# Version and SHA256 from jetpack-nixos sourceinfo/r36.4-debs.json
#
# L4T_VERSION: To find all L4T version references, run:
#   rg -n "L4T_VERSION|36\.4\.4" meta-isar-k3s/recipes-bsp/nvidia-l4t/
# Update both nvidia-l4t-core and nvidia-l4t-tools recipes when upgrading.
PV = "36.4.4-20250616085344"

SRC_URI = "https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-core/nvidia-l4t-core_${PV}_arm64.deb"
SRC_URI[sha256sum] = "04975607d121dd679a9f026939d5c126dd9e682bbba6b71c01942212ebc2b090"

# Only for Orin family Jetson platforms (Nano, NX, AGX Orin)
# Uses regex pattern to cover all Orin variants which share L4T packages
# Note: Platform detection bypass is handled by nvidia-l4t-cross-build.bbclass
# which creates the marker file before package installation
COMPATIBLE_MACHINE = "jetson-orin-.*"
