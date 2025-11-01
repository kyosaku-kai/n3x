{ config, lib, pkgs, ... }:

{
  # Intel N100 specific hardware configuration

  # Boot configuration optimized for N100
  boot = {
    # Use the latest kernel for best hardware support
    kernelPackages = pkgs.linuxPackages_latest;

    # Intel-specific kernel modules
    initrd.availableKernelModules = [
      # Storage
      "xhci_pci"    # USB 3.0
      "ahci"        # SATA
      "nvme"        # NVMe SSD
      "usbhid"      # USB HID devices
      "sd_mod"      # SCSI disk
      "sr_mod"      # SCSI CDROM

      # Intel specific
      "intel_agp"
      "i915"        # Intel graphics (if using)

      # Network (for dual NIC models)
      "igc"         # Intel 2.5Gb Ethernet
      "e1000e"      # Intel Gigabit Ethernet
      "r8169"       # Realtek Ethernet (common on mini PCs)
    ];

    kernelModules = [
      # CPU
      "kvm-intel"           # Intel virtualization
      "intel_rapl"          # Power monitoring
      "intel_powerclamp"    # Power management

      # Performance
      "coretemp"            # Temperature monitoring
      "intel_pstate"        # CPU frequency scaling

      # Required for k3s/Longhorn
      "br_netfilter"
      "overlay"
      "iscsi_tcp"
      "dm_crypt"
    ];

    # Kernel parameters optimized for N100
    kernelParams = [
      # Intel specific optimizations
      "intel_pstate=active"                 # Enable Intel P-State driver
      "intel_idle.max_cstate=1"             # Limit C-states for lower latency
      "processor.max_cstate=1"              # Consistent performance

      # Disable mitigations for better performance (acceptable in edge environment)
      "mitigations=off"

      # IOMMU for better device isolation (if supported)
      "intel_iommu=on"
      "iommu=pt"                           # Pass-through mode for better performance

      # Power management
      "pcie_aspm=off"                      # Disable PCIe power management for stability

      # CPU frequency governor
      "cpufreq.default_governor=performance"

      # Disable watchdogs for better performance
      "nowatchdog"
      "nmi_watchdog=0"

      # Network optimizations
      "net.ifnames=0"                      # Use traditional interface names (eth0, eth1)
    ];

    # Bootloader configuration
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
        consoleMode = "auto";
        editor = false;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
      timeout = 3;
    };

    # Enable all firmware
    hardware.enableAllFirmware = true;
  };

  # Hardware configuration
  hardware = {
    # Intel CPU microcode updates
    cpu.intel.updateMicrocode = true;

    # Enable GPU support (Intel UHD Graphics)
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver # VA-API
        intel-compute-runtime # OpenCL
        vaapiVdpau
        libvdpau-va-gl
      ];
    };

    # Enable hardware video acceleration
    graphics.enable32Bit = false; # Don't need 32-bit on server

    # Bluetooth (usually not needed on servers)
    bluetooth.enable = false;

    # Sound (not needed on headless servers)
    pulseaudio.enable = false;
  };

  # Power management optimized for always-on operation
  powerManagement = {
    enable = true;

    # CPU frequency scaling
    cpuFreqGovernor = "performance"; # Maximum performance

    # Don't suspend/hibernate
    powertop.enable = false; # Disable powertop auto-tuning

    # Disable power management features that could affect stability
    scsiLinkPolicy = "max_performance";
  };

  # Thermal management
  services.thermald = {
    enable = true; # Intel thermal daemon for temperature management
    configFile = pkgs.writeText "thermald-config.xml" ''
      <?xml version="1.0"?>
      <ThermalConfiguration>
        <Platform>
          <Name>Intel N100 MiniPC</Name>
          <ProductName>*</ProductName>
          <Preference>PERFORMANCE</Preference>
          <ThermalZones>
            <ThermalZone>
              <Type>cpu</Type>
              <TripPoints>
                <TripPoint>
                  <Temperature>85000</Temperature>
                  <Type>passive</Type>
                </TripPoint>
                <TripPoint>
                  <Temperature>95000</Temperature>
                  <Type>critical</Type>
                </TripPoint>
              </TripPoints>
            </ThermalZone>
          </ThermalZones>
        </Platform>
      </ThermalConfiguration>
    '';
  };

  # I/O Scheduler optimization for NVMe
  services.udev.extraRules = ''
    # NVMe: use none scheduler (NVMe has its own queueing)
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

    # SATA SSD: use mq-deadline
    ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

    # Set read ahead for better sequential performance
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{bdi/read_ahead_kb}="256"
    ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{bdi/read_ahead_kb}="256"

    # Network interface optimizations
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*", RUN+="${pkgs.ethtool}/bin/ethtool -G $name rx 4096 tx 4096"
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*", RUN+="${pkgs.ethtool}/bin/ethtool -K $name gso on gro on tso on"
  '';

  # Memory and swap configuration
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25; # Use 25% of RAM for zram swap
  };

  # File system optimizations
  fileSystems = {
    "/".options = [ "noatime" "nodiratime" ];
    "/nix".options = [ "noatime" "nodiratime" ];
    "/var".options = [ "noatime" "nodiratime" ];
    "/var/lib/longhorn".options = [ "noatime" "nodiratime" "discard" ];
  };

  # System-specific kernel tuning
  boot.kernel.sysctl = {
    # Memory management
    "vm.swappiness" = 10; # Prefer RAM over swap
    "vm.vfs_cache_pressure" = 50;
    "vm.dirty_ratio" = 15;
    "vm.dirty_background_ratio" = 5;
    "vm.min_free_kbytes" = 131072; # 128MB reserve

    # Network performance (for dual NIC setups)
    "net.core.netdev_max_backlog" = 5000;
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";

    # Increase network buffers for better throughput
    "net.core.rmem_max" = 134217728;
    "net.core.wmem_max" = 134217728;
    "net.ipv4.tcp_rmem" = "4096 87380 134217728";
    "net.ipv4.tcp_wmem" = "4096 65536 134217728";

    # File system
    "fs.inotify.max_user_watches" = 524288; # For k3s
    "fs.inotify.max_user_instances" = 8192;
    "fs.file-max" = 2097152;
    "fs.nr_open" = 1048576;

    # Intel specific
    "kernel.sched_energy_aware" = 0; # Disable energy aware scheduling
  };

  # Intel-specific packages
  environment.systemPackages = with pkgs; [
    intel-gpu-tools     # Intel GPU debugging tools
    powertop           # Power consumption analysis
    cpufrequtils       # CPU frequency utilities
    lm_sensors         # Hardware sensors
    smartmontools      # Disk health monitoring
    nvme-cli           # NVMe management
    pciutils           # PCI utilities
    usbutils           # USB utilities
  ];

  # Hardware monitoring
  services = {
    # Smart monitoring for SSDs
    smartd = {
      enable = true;
      defaults.monitored = "-a -o on -S on -n standby,q -s (S/../.././02|L/../../7/03) -W 4,45,55";
      notifications = {
        mail.enable = false; # Configure if needed
        wall.enable = true;
      };
    };

    # Hardware sensors
    lm-sensors = {
      enable = true;
      sensorsConfig = ''
        # Intel N100 sensor configuration
        chip "coretemp-*"
          label temp1 "CPU Package"
          label temp2 "Core 0"
          label temp3 "Core 1"
          label temp4 "Core 2"
          label temp5 "Core 3"
      '';
    };
  };

  # CPU governor settings
  systemd.services.cpu-performance = {
    description = "Set CPU Governor to Performance";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'";
      RemainAfterExit = true;
    };
  };

  # MSR module for CPU features
  boot.kernelModules = [ "msr" ];

  # Disable unnecessary features for mini PCs
  services.xserver.enable = false;
  sound.enable = false;

  # Serial console (useful for debugging)
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];

  # Enable serial console
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
  };
}