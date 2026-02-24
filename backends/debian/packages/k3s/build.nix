# K3s Debian Package Builder
#
# Builds a .deb package containing the k3s binary and systemd services.
# Both server and agent services are included; neither is enabled by default.
#
# Usage:
#   nix build '.#packages.x86_64-linux.k3s'
#   nix build '.#packages.aarch64-linux.k3s'

{ lib
, stdenv
, fetchurl
, dpkg
}:

let
  version = "1.35.0+k3s3";
  debVersion = "1.35.0-1";

  # K3s uses different binary names per architecture
  binaryName = if stdenv.hostPlatform.isAarch64 then "k3s-arm64" else "k3s";

  # URL-encode the version (+ becomes %2B)
  versionUrl = "v${builtins.replaceStrings ["+"] ["%2B"] version}";

  # Architecture for Debian package
  debArch = if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";

  # Fetch the k3s binary
  k3sBinary = fetchurl {
    url = "https://github.com/k3s-io/k3s/releases/download/${versionUrl}/${binaryName}";
    sha256 =
      if stdenv.hostPlatform.isAarch64
      then "0a52k28v3svjffrj551416a74zjc6bjk8siki65a4ygba9pdficz"  # arm64
      else "0xzzbcnhg3mkyn9jnxlqclpa8cr97ygywd9ckmzmym32cl5vx6fg"; # amd64
  };

in
stdenv.mkDerivation {
  pname = "k3s";
  inherit version;

  src = ./.;

  nativeBuildInputs = [ dpkg ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # Create package directory structure
    PKG_DIR=$TMPDIR/k3s_${debVersion}_${debArch}
    mkdir -p $PKG_DIR/DEBIAN
    mkdir -p $PKG_DIR/usr/bin
    mkdir -p $PKG_DIR/lib/systemd/system
    mkdir -p $PKG_DIR/etc/default
    mkdir -p $PKG_DIR/etc/rancher/k3s/config.yaml.d
    mkdir -p $PKG_DIR/var/lib/rancher/k3s/server

    # Install k3s binary
    install -m 0755 ${k3sBinary} $PKG_DIR/usr/bin/k3s

    # Create symlinks for bundled CLI tools
    ln -sf k3s $PKG_DIR/usr/bin/kubectl
    ln -sf k3s $PKG_DIR/usr/bin/crictl
    ln -sf k3s $PKG_DIR/usr/bin/ctr

    # Install systemd services
    install -m 0644 $src/debian/k3s-server.service $PKG_DIR/lib/systemd/system/
    install -m 0644 $src/debian/k3s-agent.service $PKG_DIR/lib/systemd/system/

    # Install default configuration files
    install -m 0644 $src/debian/k3s-server.default $PKG_DIR/etc/default/k3s-server
    install -m 0644 $src/debian/k3s-agent.default $PKG_DIR/etc/default/k3s-agent

    # Install test token (for automated testing only)
    echo "test-cluster-fixed-token-for-automated-testing" > $PKG_DIR/var/lib/rancher/k3s/server/token
    chmod 0600 $PKG_DIR/var/lib/rancher/k3s/server/token

    # Create DEBIAN/control from debian/control
    cat > $PKG_DIR/DEBIAN/control << EOF
    Package: k3s
    Version: ${debVersion}
    Architecture: ${debArch}
    Maintainer: n3x <n3x@localhost>
    Description: K3s Lightweight Kubernetes
     K3s is a lightweight, certified Kubernetes distribution built for IoT
     and Edge computing. This package includes both server and agent systemd
     services. Neither service is enabled by default.
    Depends: iptables
    EOF

    # Build the .deb package
    mkdir -p $out
    dpkg-deb --root-owner-group --build $PKG_DIR $out/k3s_${debVersion}_${debArch}.deb

    runHook postInstall
  '';

  meta = with lib; {
    description = "K3s Lightweight Kubernetes";
    homepage = "https://k3s.io/";
    license = licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    maintainers = [ ];
  };
}
