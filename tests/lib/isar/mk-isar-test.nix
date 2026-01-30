# =============================================================================
# mkISARTest - Create NixOS-style VM tests for ISAR images
# =============================================================================
#
# This wraps the nixos-test-driver to work with ISAR-built .wic images.
# It generates run-*-vm scripts and configures the test driver.
#
# Usage:
#   mkISARTest {
#     name = "k3s-cluster";
#     machines = {
#       server = { image = ./server.wic; };
#       agent1 = { image = ./agent.wic; };
#       agent2 = { image = ./agent.wic; };
#     };
#     testScript = ''
#       server.wait_for_unit("multi-user.target")
#       agent1.wait_for_unit("multi-user.target")
#     '';
#   }
#
# =============================================================================

{ pkgs
, lib ? pkgs.lib
,
}:

{
  # Test name
  name
, # Map of machine name -> { image, memory?, cpus?, extraQemuArgs? }
  machines
, # Python test script (same API as NixOS tests)
  testScript
, # VLAN numbers to create (default: [1])
  vlans ? [ 1 ]
, # Global timeout in seconds
  globalTimeout ? 3600
, # Extra arguments for test driver
  extraDriverArgs ? [ ]
,
}:

let
  # Import the VM script generator
  mkISARVMScript = pkgs.callPackage ./mk-isar-vm-script.nix { };

  # Generate VM scripts for each machine
  vmScripts = lib.mapAttrs
    (machineName: machineConfig:
      mkISARVMScript {
        name = machineName;
        image = machineConfig.image;
        memory = machineConfig.memory or 4096;
        cpus = machineConfig.cpus or 4;
        extraQemuArgs = machineConfig.extraQemuArgs or [ ];
      }
    )
    machines;

  # Build the test driver directly (avoid circular dependency via nixosTests)
  #
  # API CHANGE: The nixpkgs test-driver interface changed in late 2024:
  # - OLD: Accepted individual python3Packages (buildPythonApplication, colorama, etc.)
  # - NEW: Accepts python3Packages module directly, manages dependencies internally
  #
  # This is the correct current API for nixpkgs-unstable (25.x+).
  # If you see "unexpected argument 'python'" or similar errors after nixpkgs updates,
  # check ${pkgs.path}/nixos/lib/test-driver/default.nix for the current interface.
  testDriver = pkgs.callPackage "${pkgs.path}/nixos/lib/test-driver" {
    inherit (pkgs) python3Packages coreutils netpbm socat vde2 ruff;
    qemu_pkg = pkgs.qemu_test;
    qemu_test = pkgs.qemu_test;
    imagemagick_light = pkgs.imagemagick_light;
    tesseract4 = pkgs.tesseract4;
    # Pass null for nixosTests to break the circular dependency
    # The test driver doesn't actually need this at runtime
    nixosTests = null;
  };

  # Collect all VM script paths
  vmStartScripts = lib.mapAttrsToList
    (name: script:
      "${script}/bin/run-${name}-vm"
    )
    vmScripts;

  # Write the test script to a file
  # Note: We pass the testScript directly without manual indentation stripping.
  # The Python code is assembled from interpolated Nix strings at various indentation
  # levels, including code at column 0 (like utils.all function definitions).
  # Manual stripping breaks this - let Python handle any trivial whitespace.
  testScriptFile = pkgs.writeText "test-script" testScript;

  # Create the wrapped test driver
  wrappedDriver = pkgs.runCommand "isar-test-driver-${name}"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      passthru = {
        inherit vmScripts testDriver;
        # Allow running interactively
        driverInteractive = wrappedDriver;
      };
    } ''
    mkdir -p $out/bin

    # Create wrapper with proper command-line arguments
    makeWrapper ${testDriver}/bin/nixos-test-driver $out/bin/nixos-test-driver \
      --add-flags "--start-scripts ${lib.concatStringsSep " " vmStartScripts}" \
      --add-flags "--vlans ${toString vlans}" \
      --add-flags "--global-timeout ${toString globalTimeout}" \
      --add-flags "${testScriptFile}" \
      ${lib.optionalString (extraDriverArgs != [])
        (lib.concatMapStringsSep " " (arg: "--add-flags ${lib.escapeShellArg arg}") extraDriverArgs)}

    # Create convenience script
    cat > $out/bin/run-test <<SCRIPT
    #!${pkgs.bash}/bin/bash
    exec "\$(dirname "\$0")/nixos-test-driver" "\$@"
    SCRIPT
    chmod +x $out/bin/run-test

    # Create interactive script
    cat > $out/bin/run-test-interactive <<SCRIPT
    #!${pkgs.bash}/bin/bash
    exec "\$(dirname "\$0")/nixos-test-driver" --interactive "\$@"
    SCRIPT
    chmod +x $out/bin/run-test-interactive
  '';

  # Create the test derivation (runs the test in a sandbox)
  test = pkgs.runCommand "isar-test-${name}"
    {
      nativeBuildInputs = [ wrappedDriver ];
      # These are needed for QEMU
      requiredSystemFeatures = [ "kvm" ];
    } ''
    mkdir -p $out
    export TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    # Run the test
    nixos-test-driver 2>&1 | tee $out/test.log

    # Mark success
    touch $out/passed
  '';

in
{
  # The test derivation (sandboxed, for CI)
  inherit test;

  # The driver (for interactive use)
  driver = wrappedDriver;

  # Individual VM scripts (for manual testing)
  inherit vmScripts;
}
