{ config, lib, pkgs, inputs, ... }:

{
  # Import jetpack-nixos modules
  imports = [
    inputs.jetpack-nixos.nixosModules.default
  ];

  # Jetson Orin Nano specific configuration
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nano";
    carrierBoard = "devkit";

    # Use stable firmware version (35.2.1 recommended over 35.3.1 for USB boot)
    flashScriptOverrides = {
      flashArgs = [
        "--no-systemimg"
        "-c" "bootloader/t186ref/cfg/flash_t234_qspi.xml"
      ];
    };
  };

  # Boot configuration
  boot = {
    # Use the extlinux bootloader for Jetson
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
      timeout = 3;
    };

    # Kernel modules for Jetson hardware
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "usbhid"
      "usb_storage"
      "sd_mod"
      "rtc_tegra"
    ];

    kernelModules = [
      "nvidia"
      "nvidia_modeset"
      "nvidia_uvm"
      "tegra_xudc"
    ];

    # Kernel parameters for stability
    kernelParams = [
      "console=ttyTCU0,115200"  # Serial console (HDMI doesn't work for console)
      "earlycon=tegra_comb_uart,mmio32,0x0c168000"
      "mem_encrypt=off"  # Disable memory encryption for compatibility
      "iommu.passthrough=1"  # IOMMU passthrough for better compatibility
    ];

    # Custom kernel configuration
    kernelPatches = [
      {
        name = "jetson-optimizations";
        patch = null;
        extraConfig = ''
          # Power management
          CPU_FREQ_DEFAULT_GOV_ONDEMAND y
          CPU_FREQ_GOV_PERFORMANCE y
          CPU_FREQ_GOV_POWERSAVE y
          CPU_FREQ_GOV_USERSPACE y
          CPU_FREQ_GOV_CONSERVATIVE y

          # Thermal management
          THERMAL_DEFAULT_GOV_STEP_WISE y
          CPU_THERMAL y

          # GPU support
          DRM_TEGRA y
          TEGRA_HOST1X y

          # Container optimizations
          CGROUP_BPF y
          BPF_SYSCALL y
          BPF_JIT y
          BPF_JIT_ALWAYS_ON y
        '';
      }
    ];
  };

  # Hardware-specific services
  services = {
    # Thermal management
    thermald.enable = lib.mkDefault true;

    # Power management
    tlp = {
      enable = lib.mkDefault false;  # Jetson has its own power management
    };

    # Fan control (Jetson has PWM fan control)
    # This will be handled by the Jetson power management daemon
  };

  # Jetson-specific packages
  environment.systemPackages = with pkgs; [
    # Jetson utilities
    jetson-gpio
    jetson-stats
    tegrastats

    # CUDA and AI acceleration (when needed for workloads)
    # cudaPackages.cudatoolkit
    # cudaPackages.cudnn
    # tensorrt

    # Hardware monitoring
    lm_sensors
    nvtop  # NVIDIA GPU monitoring

    # Serial console tools (for debugging via UART)
    minicom
    screen
    picocom
  ];

  # Jetson-specific udev rules
  services.udev.extraRules = ''
    # GPIO access for non-root users
    SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"

    # Tegra devices
    SUBSYSTEM=="nvhost", GROUP="video", MODE="0666"
    SUBSYSTEM=="nvmap", GROUP="video", MODE="0666"

    # Camera devices (if using CSI cameras)
    SUBSYSTEM=="video4linux", GROUP="video", MODE="0666"
  '';

  # Create gpio group for GPIO access
  users.groups.gpio = {};

  # Memory and swap configuration
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;  # Use 25% of RAM for compressed swap
  };

  # Network optimizations for edge computing
  boot.kernel.sysctl = {
    # Network buffer sizes for high throughput
    "net.core.rmem_max" = 134217728;
    "net.core.wmem_max" = 134217728;
    "net.ipv4.tcp_rmem" = "4096 87380 134217728";
    "net.ipv4.tcp_wmem" = "4096 65536 134217728";

    # Increase netdev budget for packet processing
    "net.core.netdev_budget" = 600;
    "net.core.netdev_budget_usecs" = 20000;

    # Enable TCP fastopen
    "net.ipv4.tcp_fastopen" = 3;

    # Optimize for low latency
    "net.ipv4.tcp_low_latency" = 1;

    # Memory management for containers
    "vm.max_map_count" = 262144;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
  };

  # Filesystem support
  boot.supportedFilesystems = [ "ext4" "btrfs" "xfs" "vfat" "ntfs" ];

  # Enable hardware acceleration where applicable
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = false;  # Jetson is ARM64 only
  };

  # Jetson-specific power profiles
  powerManagement = {
    # Let Jetson handle its own CPU frequency scaling
    cpuFreqGovernor = lib.mkDefault "ondemand";

    # Jetson power modes (can be switched via nvpmodel)
    # Mode 0: MAXN (maximum performance, 15W)
    # Mode 1: 10W
    # Mode 2: 5W
  };

  # Serial console configuration
  systemd.services."serial-getty@ttyTCU0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig = {
      Type = "idle";
      Restart = "always";
      RestartSec = "0";
      ExecStart = "${pkgs.util-linux}/bin/agetty -L 115200 ttyTCU0 vt100";
    };
  };

  # Platform assertions
  assertions = [
    {
      assertion = pkgs.stdenv.hostPlatform.isAarch64;
      message = "Jetson Orin Nano requires aarch64-linux architecture";
    }
  ];

  # Documentation
  documentation.doc.enable = lib.mkDefault false;  # Save space on edge device
  documentation.man.enable = lib.mkDefault false;
  documentation.info.enable = lib.mkDefault false;
}