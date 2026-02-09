# NVIDIA L4T Cross-Build Support and Validation
#
# This class provides support for building images with NVIDIA L4T packages
# during cross-compilation (when /proc/device-tree/compatible is not available).
#
# Features:
# 1. Pre-install marker creation: Bypasses L4T platform detection during build
# 2. Post-install validation: Verifies critical L4T binaries are present
#
# The nvidia-l4t-core package includes a preinst script that checks for
# /proc/device-tree/compatible to verify it's running on Jetson hardware.
# This check fails during ISAR's chroot-based build because the build host
# is not a Jetson device.
#
# NVIDIA provides an official bypass mechanism: if the marker file
# /opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall
# exists, the preinst script skips all platform detection checks.
#
# Usage in local.conf or kas configuration:
#   INHERIT += "nvidia-l4t-cross-build"
#
# The marker function runs with weight 100, well before
# rootfs_install_pkgs_install (weight 8000).

# L4T binaries that MUST be present for Jetson OTA functionality
# - nvbootctrl: A/B boot slot management (CRITICAL for OTA updates)
# - tegrastats: System monitoring utility
# - jetson_clocks: Performance/power management utility
L4T_REQUIRED_BINARIES ?= "nvbootctrl tegrastats jetson_clocks"

# Prepend our marker function to the rootfs install command sequence
# This ensures the marker file is created before any packages are installed
ROOTFS_INSTALL_COMMAND:prepend = "rootfs_create_l4t_marker "

# Create the L4T preinstall marker file in the rootfs
# This must be created BEFORE nvidia-l4t-core's dpkg preinst script runs
# Only runs for Jetson machine builds that are actual images
rootfs_create_l4t_marker[weight] = "100"
rootfs_create_l4t_marker() {
    # Check if this is an image build (IMAGE_FULLNAME is set by image.bbclass)
    # sbuild-chroot and other build tools don't have this set
    if [ -z "${IMAGE_FULLNAME}" ]; then
        return 0
    fi

    # Skip for non-Jetson machines
    case "${MACHINE}" in
        jetson-*)
            bbnote "Creating NVIDIA L4T preinstall marker for cross-build (${MACHINE})"
            sudo -s <<'EOSUDO'
                set -e
                mkdir -p "${ROOTFSDIR}/opt/nvidia/l4t-packages"
                touch "${ROOTFSDIR}/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"
EOSUDO
            ;;
        *)
            # Non-Jetson machines don't need the marker
            ;;
    esac
}

# Add L4T validation to rootfs postprocess
# This runs AFTER packages are installed but BEFORE the image is finalized
# The validation function itself checks for Jetson machines and skips otherwise
ROOTFS_POSTPROCESS_COMMAND:append = " rootfs_validate_l4t_binaries"

# Validate that required L4T binaries are present in the rootfs
# Fails the build with bbfatal if any required binary is missing
# Only runs for actual image builds on compatible Jetson machines
rootfs_validate_l4t_binaries() {
    # Check if this is an image build (IMAGE_FULLNAME is set by image.bbclass)
    # sbuild-chroot and other build tools don't have this set
    if [ -z "${IMAGE_FULLNAME}" ]; then
        return 0
    fi

    # Skip validation for non-Jetson machines
    case "${MACHINE}" in
        jetson-*)
            bbnote "Validating NVIDIA L4T binaries in rootfs for ${MACHINE}..."
            ;;
        *)
            bbnote "Skipping L4T validation - not a Jetson machine (MACHINE=${MACHINE})"
            return 0
            ;;
    esac

    missing_binaries=""
    found_binaries=""

    for binary in ${L4T_REQUIRED_BINARIES}; do
        # Search common binary locations
        binary_path=""
        for dir in usr/sbin usr/bin sbin bin; do
            if [ -f "${ROOTFSDIR}/${dir}/${binary}" ]; then
                binary_path="${dir}/${binary}"
                break
            fi
        done

        if [ -n "$binary_path" ]; then
            found_binaries="${found_binaries} ${binary}(${binary_path})"
            bbnote "  Found: ${binary} at /${binary_path}"
        else
            missing_binaries="${missing_binaries} ${binary}"
            bbwarn "  MISSING: ${binary}"
        fi
    done

    if [ -n "$missing_binaries" ]; then
        bbfatal "L4T validation failed! Missing required binaries:${missing_binaries}

This build is for a Jetson platform (${MACHINE}) and requires NVIDIA L4T packages.
Ensure the following packages are in IMAGE_INSTALL:
  - nvidia-l4t-core
  - nvidia-l4t-tools

The missing binaries are critical for:
  - nvbootctrl: A/B OTA boot slot management
  - tegrastats: System monitoring
  - jetson_clocks: Performance management

Add to your kas config or local.conf:
  IMAGE_INSTALL:append = \" nvidia-l4t-core nvidia-l4t-tools\"
"
    fi

    bbnote "L4T validation passed. Found binaries:${found_binaries}"
}
