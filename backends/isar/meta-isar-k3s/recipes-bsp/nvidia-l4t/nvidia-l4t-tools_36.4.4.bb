# NVIDIA L4T Tools Package
#
# Contains essential Jetson tools:
#   - nvbootctrl: Boot slot management for A/B OTA updates
#   - tegrastats: Real-time system monitoring
#   - jetson_clocks: Performance/power management
#
# Download from NVIDIA's Jetson apt repository (t234 for Orin/Thor platforms).
# SHA256 verified against jetpack-nixos sourceinfo/r36.4-debs.json
#
# Usage:
#   Add to IMAGE_INSTALL in your image recipe or kas configuration.
#   Example: IMAGE_INSTALL:append = " nvidia-l4t-tools"

inherit dpkg-prebuilt

SUMMARY = "NVIDIA L4T Tools - Essential Jetson utilities"
DESCRIPTION = "NVIDIA L4T Tools package providing essential Jetson utilities \
    including nvbootctrl for A/B boot slot management (required for OTA updates), \
    tegrastats for system monitoring, and jetson_clocks for performance tuning."
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

SRC_URI = "https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-tools/nvidia-l4t-tools_${PV}_arm64.deb"
SRC_URI[sha256sum] = "864281721f202c9e3ae8c7b66ff469b05ee8abc6d3ae6cb0eaaa8a5e7769398f"

# Depends on nvidia-l4t-core
DEPENDS = "nvidia-l4t-core"

# Only for Orin family Jetson platforms (Nano, NX, AGX Orin)
# Uses regex pattern to cover all Orin variants which share L4T packages
COMPATIBLE_MACHINE = "jetson-orin-.*"
