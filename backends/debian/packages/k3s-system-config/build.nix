# K3s System Configuration Debian Package Builder
#
# Builds a .deb package containing kernel and system configuration for k3s.
#
# Usage:
#   nix build '.#packages.x86_64-linux.k3s-system-config'

{ lib
, stdenv
, dpkg
}:

let
  version = "1.0-1";
in stdenv.mkDerivation {
  pname = "k3s-system-config";
  inherit version;

  src = ./.;

  nativeBuildInputs = [ dpkg ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # Create package directory structure
    PKG_DIR=$TMPDIR/k3s-system-config_${version}_all
    mkdir -p $PKG_DIR/DEBIAN
    mkdir -p $PKG_DIR/etc/modules-load.d
    mkdir -p $PKG_DIR/etc/sysctl.d
    mkdir -p $PKG_DIR/lib/systemd/system/multi-user.target.wants
    mkdir -p $PKG_DIR/usr/lib/k3s

    # Install kernel module configuration
    install -m 0644 $src/debian/k3s.modules-load $PKG_DIR/etc/modules-load.d/k3s.conf

    # Install sysctl configuration
    install -m 0644 $src/debian/k3s.sysctl $PKG_DIR/etc/sysctl.d/99-k3s.conf

    # Install disable-swap service
    install -m 0644 $src/debian/disable-swap.service $PKG_DIR/lib/systemd/system/

    # Enable disable-swap service by default
    ln -sf ../disable-swap.service $PKG_DIR/lib/systemd/system/multi-user.target.wants/

    # Install iptables-legacy configuration script
    install -m 0755 $src/debian/iptables-legacy.sh $PKG_DIR/usr/lib/k3s/

    # Install postinst for sysctl reload
    install -m 0755 $src/debian/postinst $PKG_DIR/DEBIAN/

    # Create DEBIAN/control
    cat > $PKG_DIR/DEBIAN/control << EOF
Package: k3s-system-config
Version: ${version}
Architecture: all
Maintainer: n3x <n3x@localhost>
Depends: systemd, kmod
Description: System configuration for K3s Kubernetes nodes
 Configures the Linux kernel and system settings required for K3s:
 .
  - Loads kernel modules: overlay, br_netfilter, nf_conntrack, iptable_nat
  - Sets sysctl: ip_forward, bridge-nf-call-iptables, conntrack limits
  - Disables swap (Kubernetes requirement)
  - Configures iptables-legacy mode (k3s requirement)
 .
 Install on all K3s nodes (both server and agent).
EOF

    # Build the .deb package
    mkdir -p $out
    dpkg-deb --root-owner-group --build $PKG_DIR $out/k3s-system-config_${version}_all.deb

    runHook postInstall
  '';

  meta = with lib; {
    description = "System configuration for K3s Kubernetes nodes";
    homepage = "https://k3s.io/";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
