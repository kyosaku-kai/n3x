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

    # Jetson Orin Nano specific settings
    # 8GB RAM variant with NVIDIA Ampere GPU (1024 CUDA cores)
    modesetting.enable = true;

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
      "console=ttyTCU0,115200"  # Serial console (HDMI doesn't work for console)
      "earlycon=tegra_comb_uart,mmio32,0x0c168000"
      "mem_encrypt=off"  # Disable memory encryption for compatibility
      "iommu.passthrough=1"  # IOMMU passthrough for better compatibility

      # Performance tuning
      "isolcpus=5"  # Isolate CPU core 5 for critical workloads
      "rcu_nocbs=5"  # Offload RCU callbacks from isolated core
      "nohz_full=5"  # Disable timer ticks on isolated core

      # Container and k3s optimizations
      "cgroup_enable=cpuset"
      "cgroup_memory=1"
      "cgroup_enable=memory"

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
    nvpmodel  # Power mode management

    # CUDA and AI acceleration (when needed for workloads)
    # cudaPackages.cudatoolkit
    # cudaPackages.cudnn
    # tensorrt

    # Hardware monitoring
    lm_sensors
    nvtop  # NVIDIA GPU monitoring
    jtop  # Jetson system monitor

    # Serial console tools (for debugging via UART)
    minicom
    screen
    picocom

    # Storage management
    nvme-cli
    smartmontools

    # Network tools
    ethtool
    iw  # Wireless tools if using WiFi module
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
  users.groups.gpio = {};

  # Memory and swap configuration
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;  # Use 25% of RAM for compressed swap
  };

  # Network and system optimizations for edge computing
  boot.kernel.sysctl = {
    # Network buffer sizes for high throughput
    "net.core.rmem_max" = 134217728;
    "net.core.wmem_max" = 134217728;
    "net.ipv4.tcp_rmem" = "4096 87380 134217728";
    "net.ipv4.tcp_wmem" = "4096 65536 134217728";

    # Increase netdev budget for packet processing
    "net.core.netdev_budget" = 600;
    "net.core.netdev_budget_usecs" = 20000;
    "net.core.netdev_max_backlog" = 5000;

    # TCP optimizations
    "net.ipv4.tcp_fastopen" = 3;
    "net.ipv4.tcp_low_latency" = 1;
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";

    # Memory management for containers
    "vm.max_map_count" = 262144;
    "vm.swappiness" = 10;  # Prefer RAM over swap
    "vm.min_free_kbytes" = 65536;  # 64MB minimum free memory

    # File system limits for k3s
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
    "fs.file-max" = 2097152;
    "fs.nr_open" = 1048576;

    # ARM64 specific optimizations
    "kernel.perf_event_paranoid" = -1;  # Allow performance monitoring
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

  # File system mount options
  fileSystems = {
    "/".options = [ "noatime" "nodiratime" ];
    "/nix".options = [ "noatime" "nodiratime" ];
    "/var".options = [ "noatime" "nodiratime" ];
    "/var/lib/longhorn".options = [ "noatime" "nodiratime" "discard" ];
  };

  # Power profile management service
  systemd.services.jetson-power-profile = {
    description = "Configure Jetson Power Profile";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Default to 10W mode for balanced performance/power
      # Mode 0: MAXN (15W), Mode 1: 10W, Mode 2: 5W
      ExecStart = "${pkgs.bash}/bin/bash -c 'nvpmodel -m 1 || true'";
    };
  };

  # Enable zswap for better memory compression
  boot.kernelParams = [ "zswap.enabled=1" "zswap.compressor=zstd" ];

  # Hardware watchdog
  systemd.watchdog = {
    device = "/dev/watchdog";
    runtimeTime = "30s";
    rebootTime = "10min";
    kexecTime = "10min";
  };
}