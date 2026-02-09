# Nix derivation that builds a Debian package
#
# Usage:
#   nix build '.#packages.x86_64-linux.PACKAGE-NAME'
#
# This template shows a source package. For binary-wrapper or config-only
# packages, see the examples in packages/k3s-server/ and packages/k3s-system-config/

{ lib
, stdenv
, dpkg
, fakeroot
, # Add your build dependencies here
}:

stdenv.mkDerivation rec {
  pname = "PACKAGE-NAME";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    dpkg
    fakeroot
  ];

  # For packages with source code, add build dependencies:
  # buildInputs = [ ];

  buildPhase = ''
    runHook preBuild

    # For source packages: build your software here
    # make

    # For binary packages: download/extract binary here
    # curl -L -o binary https://...

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Create package structure
    mkdir -p pkg/DEBIAN
    mkdir -p pkg/usr/bin

    # Install files
    # install -m 0755 binary pkg/usr/bin/

    # Generate DEBIAN/control from debian/control
    # (simplified - real implementation would parse properly)
    cat > pkg/DEBIAN/control << EOF
    Package: ${pname}
    Version: ${version}
    Architecture: $(dpkg --print-architecture)
    Maintainer: Your Name <your.email@example.com>
    Description: Short description
    EOF

    # Build the .deb
    fakeroot dpkg-deb --build pkg
    mv pkg.deb $out/${pname}_${version}_$(dpkg --print-architecture).deb

    runHook postInstall
  '';

  # Output is a directory containing the .deb file
  # Access via: result/PACKAGE-NAME_0.1.0_amd64.deb

  meta = with lib; {
    description = "Short description of PACKAGE-NAME";
    homepage = "https://example.com/PACKAGE-NAME";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
