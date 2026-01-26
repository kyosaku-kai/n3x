{ config, lib, pkgs, inputs, ... }:

{
  # Import jetpack-nixos modules
  imports = [
    inputs.jetpack-nixos.nixosModules.default
  ];

  # Allow unfree packages (required for NVIDIA CUDA and proprietary firmware)
  nixpkgs.config.allowUnfree = true;

  # Jetson Orin Nano specific configuration
  hardware.nvidia-jetpack = {
    enable = true;
    som = "orin-nano";
    carrierBoard = "devkit";

    # Jetson Orin Nano specific settings
    # 8GB RAM variant with NVIDIA Ampere GPU (1024 CUDA cores)
    # Note: modesetting disabled for now due to evaluation issues
    modesetting.enable = false;

    # Use stable firmware version (35.2.1 recommended over 35.3.1 for USB boot)
    flashScriptOverrides = {
      flashArgs = [
        "--no-systemimg"
        "-c"
        "bootloader/t186ref/cfg/flash_t234_qspi.xml"
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
      # NVIDIA modules
      "nvidia"
      "nvidia_modeset"
      "nvidia_uvm"
      "nvidia_drm"

      # Tegra specific modules
      "tegra_xudc"
      "tegra_bpmp_thermal"

      # Required for K3s
      "br_netfilter"
      "overlay"
      "iscsi_tcp"

      # Container runtime support
      "veth"
      "xt_conntrack"
      "nf_nat"
      "nf_conntrack_netlink"
    ];

    # Kernel parameters for stability
    kernelParams = [
      "console=ttyTCU0,115200" # Serial console (HDMI doesn't work for console)
      "earlycon=tegra_comb_uart,mmio32,0x0c168000"
      "mem_encrypt=off" # Disable memory encryption for compatibility
      "iommu.passthrough=1" # IOMMU passthrough for better compatibility

      # Performance tuning
      "isolcpus=5" # Isolate CPU core 5 for critical workloads
      "rcu_nocbs=5" # Offload RCU callbacks from isolated core
      "nohz_full=5" # Disable timer ticks on isolated core

      # Container and k3s optimizations
      "cgroup_enable=cpuset"
      "cgroup_memory=1"
      "cgroup_enable=memory"

      # Memory compression
      "zswap.enabled=1"
      "zswap.compressor=zstd"

      # Disable unnecessary debugging
      "quiet"
      "loglevel=3"
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
    # Thermal management (Jetson uses Tegra thermal management, not thermald)
    # thermald is Intel-specific and not available on ARM64
    thermald.enable = false;

    # Power management
    tlp = {
      enable = lib.mkDefault false; # Jetson has its own power management
    };

    # Fan control (Jetson has PWM fan control)
    # This will be handled by the Jetson power management daemon
  };

  # Jetson-specific packages
  environment.systemPackages = with pkgs; [
    # Jetson utilities (provided by jetpack-nixos or need custom packaging)
    # jetson-gpio
    # jetson-stats
    # tegrastats
    # nvpmodel  # Power mode management
    # jtop  # Jetson system monitor

    # CUDA and AI acceleration (when needed for workloads)
    # cudaPackages.cudatoolkit
    # cudaPackages.cudnn
    # tensorrt

    # Hardware monitoring
    lm_sensors

    # Serial console tools (for debugging via UART)
    minicom
    screen
    picocom

    # Storage management
    nvme-cli
    smartmontools

    # Network tools
    ethtool
    iw # Wireless tools if using WiFi module
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

    # NVMe optimization
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/nr_requests}="2048"
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{bdi/read_ahead_kb}="256"

    # SD card optimization (if using for boot)
    ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/scheduler}="mq-deadline"
    ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{bdi/read_ahead_kb}="128"
  '';

  # Create gpio group for GPIO access
  users.groups.gpio = { };

  # Memory and swap configuration
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25; # Use 25% of RAM for compressed swap
  };

  # Network and system optimizations for edge computing
  boot.kernel.sysctl = {
    # Network buffer sizes for high throughput
    # Note: netdev_max_backlog is configured in modules/common/networking.nix
    "net.core.netdev_budget" = 600;
    "net.core.netdev_budget_usecs" = 20000;

    # TCP optimizations
    "net.ipv4.tcp_fastopen" = 3;
    "net.ipv4.tcp_low_latency" = 1;
    # Note: tcp_congestion_control and default_qdisc are in modules/common/networking.nix

    # Memory management for containers
    "vm.max_map_count" = 262144;
    # Note: vm.swappiness configured in base.nix
    "vm.min_free_kbytes" = 65536; # 64MB minimum free memory

    # Note: fs.inotify.*, fs.file-max, fs.nr_open are configured in k3s-common.nix

    # ARM64 specific optimizations
    "kernel.perf_event_paranoid" = -1; # Allow performance monitoring
  };

  # Filesystem support
  boot.supportedFilesystems = [ "ext4" "btrfs" "xfs" "vfat" "ntfs" ];

  # Enable hardware acceleration where applicable
  hardware.graphics = {
    enable = true;
    enable32Bit = false; # Jetson is ARM64 only
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
  documentation.doc.enable = lib.mkDefault false; # Save space on edge device
  documentation.man.enable = lib.mkDefault false;
  documentation.info.enable = lib.mkDefault false;

  # Note: Filesystem mount options are configured in host-specific configuration
  # See hosts/jetson-*/configuration.nix for filesystem definitions

  # Power profile management service
  # Note: nvpmodel requires jetpack-nixos or custom packaging
  # Uncomment when nvpmodel is available
  # systemd.services.jetson-power-profile = {
  #   description = "Configure Jetson Power Profile";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "multi-user.target" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     RemainAfterExit = true;
  #     # Default to 10W mode for balanced performance/power
  #     # Mode 0: MAXN (15W), Mode 1: 10W, Mode 2: 5W
  #     ExecStart = "${pkgs.bash}/bin/bash -c 'nvpmodel -m 1 || true'";
  #   };
  # };

  # Hardware watchdog configuration
  # NOTE: Using systemd.extraConfig instead of systemd.settings.Manager because
  # systemd.settings was introduced in nixpkgs ~24.05+, and n3x's current nixpkgs
  # revision doesn't have this option.
  # TODO: Convert to systemd.settings.Manager = { WatchdogDevice = "/dev/watchdog"; ... }
  #       when nixpkgs is updated to a version with the systemd.settings option.
  # ERROR being worked around: "The option `systemd.settings' does not exist"
  systemd.extraConfig = ''
    WatchdogDevice=/dev/watchdog
    RuntimeWatchdogSec=30s
    RebootWatchdogSec=10min
    KExecWatchdogSec=10min
  '';
}
