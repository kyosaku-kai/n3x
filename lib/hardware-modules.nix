# Hardware detection and module selection helpers
{ lib, pkgs, ... }:

{
  # Detect hardware type based on system information
  detectHardware =
    { cpuinfo ? "/proc/cpuinfo"
    , dmiinfo ? "/sys/class/dmi/id/product_name"
    , ...
    }:
    let
      # Read CPU information
      cpuModel = lib.optionalString (builtins.pathExists cpuinfo)
        (builtins.readFile cpuinfo);

      # Read DMI information
      productName = lib.optionalString (builtins.pathExists dmiinfo)
        (lib.removeSuffix "\n" (builtins.readFile dmiinfo));

      # Detect if running on Intel N100
      isN100 = lib.strings.hasInfix "N100" cpuModel ||
        lib.strings.hasInfix "N95" cpuModel ||
        lib.strings.hasInfix "N200" cpuModel ||
        lib.strings.hasInfix "N305" cpuModel;

      # Detect if running on Jetson
      isJetson = lib.strings.hasInfix "NVIDIA Jetson" productName ||
        lib.strings.hasInfix "Orin" productName ||
        builtins.pathExists "/proc/device-tree/compatible";

      # Detect virtualization
      isVM = lib.strings.hasInfix "QEMU" productName ||
        lib.strings.hasInfix "VirtualBox" productName ||
        lib.strings.hasInfix "VMware" productName ||
        lib.strings.hasInfix "KVM" productName;
    in
    {
      inherit isN100 isJetson isVM;
      hardwareType =
        if isN100 then "n100"
        else if isJetson then "jetson"
        else if isVM then "vm"
        else "generic";
    };

  # Select appropriate hardware module based on detection
  selectHardwareModule = hardwareType:
    {
      n100 = ../modules/hardware/n100.nix;
      jetson = ../modules/hardware/jetson.nix;
      vm = ../modules/hardware/vm.nix;
      generic = ../modules/hardware/generic.nix;
    }.${hardwareType} or ../modules/hardware/generic.nix;

  # N100-specific optimizations
  n100Optimizations = {
    # CPU governor for power efficiency
    powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

    # Intel-specific kernel parameters
    boot.kernelParams = [
      "intel_idle.max_cstate=3" # Limit C-states for lower latency
      "processor.max_cstate=3"
      "intel_pstate=active" # Use Intel P-state driver
      "mitigations=off" # Disable mitigations for performance (evaluate security needs)
    ];

    # Enable Intel microcode updates
    hardware.cpu.intel.updateMicrocode = true;

    # Intel GPU support (if using integrated graphics)
    hardware.opengl = {
      enable = true;
      driSupport = true;
      driSupport32Bit = true;
      extraPackages = with pkgs; [
        intel-media-driver
        intel-vaapi-driver
        libva-vdpau-driver
        libvdpau-va-gl
      ];
    };

    # Thermal management
    services.thermald.enable = true;

    # Power management
    services.tlp = {
      enable = true;
      settings = {
        CPU_SCALING_GOVERNOR_ON_AC = "performance";
        CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
        CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
        CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";
      };
    };
  };

  # Jetson-specific optimizations
  jetsonOptimizations = {
    # Jetson kernel and bootloader
    boot.kernelPackages = pkgs.linuxPackages_nvidia_jetpack_5;

    # Jetson-specific kernel parameters
    boot.kernelParams = [
      "console=ttyS0,115200"
      "console=tty0"
      "tegraid=194.0.0.0.0"
      "maxcpus=8"
    ];

    # NVIDIA GPU support
    hardware.nvidia = {
      modesetting.enable = true;
      powerManagement.enable = false; # Not supported on Jetson
      open = false;
      package = pkgs.nvidia-jetpack;
    };

    # Jetson power modes
    systemd.services.jetson-power-mode = {
      description = "Set Jetson power mode";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.jetson-gpio}/bin/jetson_clocks --fan";
        RemainAfterExit = true;
      };
    };
  };

  # VM-specific optimizations
  vmOptimizations = {
    # Virtio drivers for better performance
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_scsi"
      "virtio_blk"
      "virtio_net"
      "virtio_balloon"
    ];

    # VM-specific kernel parameters
    boot.kernelParams = [
      "console=ttyS0,115200"
      "console=tty0"
    ];

    # Disable unnecessary services in VMs
    services.fstrim.enable = false;
    services.smartd.enable = false;
    services.thermald.enable = false;
    services.tlp.enable = false;

    # QEMU guest agent for better integration
    services.qemuGuest.enable = true;
  };

  # Generate hardware configuration based on profile
  mkHardwareConfig =
    { profile
    , # "n100", "jetson", "vm", or "generic"
      enableGpu ? true
    , enablePowerManagement ? true
    , kernelModules ? [ ]
    , kernelParams ? [ ]
    , ...
    }@args:
    let
      baseConfig = {
        boot.initrd.kernelModules = kernelModules;
        boot.kernelParams = kernelParams;
      };

      profileConfig = {
        n100 = n100Optimizations;
        jetson = jetsonOptimizations;
        vm = vmOptimizations;
        generic = { };
      }.${profile} or { };
    in
    lib.mkMerge [
      baseConfig
      profileConfig
      (lib.mkIf (!enableGpu && profile == "n100") {
        hardware.opengl.enable = false;
      })
      (lib.mkIf (!enablePowerManagement) {
        services.thermald.enable = false;
        services.tlp.enable = false;
        powerManagement.cpuFreqGovernor = lib.mkForce "performance";
      })
    ];

  # Network interface naming helper
  predictableInterfaceNames =
    { enable ? true
    , customNames ? { }
    , # e.g., { "00:11:22:33:44:55" = "lan0"; }
      ...
    }:
    if enable then {
      # Use predictable network interface names
      networking.usePredictableInterfaceNames = true;

      # Custom udev rules for specific MAC addresses
      services.udev.extraRules = lib.concatStringsSep "\n" (
        lib.mapAttrsToList
          (mac: name:
            ''SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="${mac}", NAME="${name}"''
          )
          customNames
      );
    } else {
      # Use traditional interface names (eth0, eth1, etc.)
      networking.usePredictableInterfaceNames = false;
      boot.kernelParams = [ "net.ifnames=0" "biosdevname=0" ];
    };

  # Storage device helper for different hardware
  storageDevice =
    { profile
    , preferNvme ? true
    , ...
    }:
      {
        n100 = if preferNvme then "/dev/nvme0n1" else "/dev/sda";
        jetson = "/dev/mmcblk0"; # eMMC or SD card
        vm = "/dev/vda"; # VirtIO disk
        generic = "/dev/sda"; # Fallback to SATA
      }.${profile} or "/dev/sda";
}
