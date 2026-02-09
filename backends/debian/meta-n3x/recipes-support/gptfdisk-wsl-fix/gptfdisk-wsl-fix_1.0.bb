# =============================================================================
# gptfdisk-wsl-fix - WSL2 sync() hang workaround for sgdisk
# =============================================================================
#
# PURPOSE:
#   Provides a workaround for the sgdisk sync() hang that occurs in WSL2
#   when 9p mounts (/mnt/c) are present. The sync() syscall iterates ALL
#   mounted filesystems, and the 9p implementation can hang indefinitely.
#
# HOW IT WORKS:
#   1. Installs nosync.so - a tiny LD_PRELOAD library that overrides sync()
#      to be a no-op (fsync() is NOT affected, maintaining data integrity)
#   2. Renames /usr/bin/sgdisk to /usr/bin/sgdisk.real via dpkg-divert
#   3. Installs a wrapper at /usr/bin/sgdisk that uses LD_PRELOAD
#
# USAGE:
#   Add to IMAGER_INSTALL:wic in your local.conf or image recipe:
#     IMAGER_INSTALL:wic += "gptfdisk-wsl-fix"
#
# NOTES:
#   - This package has a dependency on gdisk
#   - Install AFTER gdisk to ensure dpkg runs postinst in correct order
#   - Only affects sync() - all other filesystem operations work normally
#   - Safe to use on non-WSL systems (wrapper checks for library existence)
#
# =============================================================================

DESCRIPTION = "WSL2 sync() hang workaround for sgdisk/gptfdisk"
HOMEPAGE = "https://github.com/timblaktu/n3x"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b72c5df05c96dff79b35f2"

MAINTAINER = "Your Name <your@email.com>"

inherit dpkg

# Build for native arch (not 'all') since we compile a shared library
DPKG_ARCH = "${DISTRO_ARCH}"

# Sources: nosync.c library and sgdisk wrapper script
SRC_URI = " \
    file://nosync.c \
    file://sgdisk-wrapper.sh \
"

# Build dependencies
DEBIAN_BUILD_DEPENDS = "libc6-dev, gcc"

# Runtime dependencies
DEBIAN_DEPENDS = "gdisk, libc6"

# Create debian packaging structure
do_prepare_build() {
    # Create source directory structure
    cp ${WORKDIR}/nosync.c ${S}/
    cp ${WORKDIR}/sgdisk-wrapper.sh ${S}/

    # Create debian directory
    mkdir -p ${S}/debian

    # Create changelog
    deb_add_changelog

    # Create control file
    cat > ${S}/debian/control << EOF
Source: ${PN}
Section: admin
Priority: optional
Maintainer: ${MAINTAINER}
Build-Depends: debhelper-compat (= 13), libc6-dev, gcc
Standards-Version: 4.6.0

Package: ${PN}
Architecture: any
Depends: gdisk, \${shlibs:Depends}, \${misc:Depends}
Description: WSL2 sync() hang workaround for sgdisk
 This package provides a workaround for the sgdisk sync() hang that
 occurs in WSL2 when 9p mounts (/mnt/c) are present.
 .
 It installs a LD_PRELOAD library that overrides sync() to be a no-op,
 and a wrapper script that applies this to sgdisk calls.
EOF

    # Create rules file
    cat > ${S}/debian/rules << 'EOF'
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_build:
	$(CC) -shared -fPIC -o nosync.so nosync.c

override_dh_auto_install:
	install -d $(CURDIR)/debian/gptfdisk-wsl-fix/usr/lib
	install -m 0644 nosync.so $(CURDIR)/debian/gptfdisk-wsl-fix/usr/lib/
	install -d $(CURDIR)/debian/gptfdisk-wsl-fix/usr/lib/gptfdisk-wsl-fix
	install -m 0755 sgdisk-wrapper.sh $(CURDIR)/debian/gptfdisk-wsl-fix/usr/lib/gptfdisk-wsl-fix/sgdisk-wrapper
EOF
    chmod +x ${S}/debian/rules

    # Create postinst script
    cat > ${S}/debian/postinst << 'EOF'
#!/bin/sh
set -e

case "$1" in
    configure)
        # Use dpkg-divert to rename the original sgdisk
        if [ -x /usr/bin/sgdisk ] && [ ! -L /usr/bin/sgdisk ]; then
            dpkg-divert --add --rename --divert /usr/bin/sgdisk.real --package gptfdisk-wsl-fix /usr/bin/sgdisk || true
        fi
        # Create symlink to our wrapper
        ln -sf /usr/lib/gptfdisk-wsl-fix/sgdisk-wrapper /usr/bin/sgdisk
        ;;
esac

#DEBHELPER#

exit 0
EOF
    chmod +x ${S}/debian/postinst

    # Create prerm script
    cat > ${S}/debian/prerm << 'EOF'
#!/bin/sh
set -e

case "$1" in
    remove|upgrade|deconfigure)
        # Remove our wrapper symlink
        rm -f /usr/bin/sgdisk
        # Remove the diversion, which restores sgdisk.real -> sgdisk
        dpkg-divert --remove --rename --package gptfdisk-wsl-fix /usr/bin/sgdisk || true
        ;;
esac

#DEBHELPER#

exit 0
EOF
    chmod +x ${S}/debian/prerm

    # Create compat file
    echo "13" > ${S}/debian/compat

    # Create source format
    mkdir -p ${S}/debian/source
    echo "3.0 (native)" > ${S}/debian/source/format
}
