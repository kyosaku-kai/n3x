{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # Minimal and headless profiles for ~450MB footprint
    "${modulesPath}/profiles/minimal.nix"
    "${modulesPath}/profiles/headless.nix"
  ];

  # Boot configuration
  boot = {
    # Note: Bootloader configuration is in hardware-specific modules
    # (modules/hardware/n100.nix uses systemd-boot, jetson-orin-nano.nix uses extlinux)

    # Kernel modules required for k3s and Longhorn
    kernelModules = [
      "overlay"      # Required for containerd
      "br_netfilter" # Required for Kubernetes networking
      "iscsi_tcp"    # Required for Longhorn iSCSI
      "dm_crypt"     # Required for encrypted volumes
    ];

    # Kernel parameters for better performance
    kernelParams = [
      "mitigations=off" # Disable CPU vulnerability mitigations for better performance (edge environment)
      "quiet"           # Reduce boot verbosity
      "loglevel=3"      # Only show critical messages during boot
    ];

    # Note: K3s-specific kernel settings are in modules/roles/k3s-common.nix
    # Performance tuning
    kernel.sysctl = {
      "vm.swappiness" = 10; # Reduce swap usage
      "vm.vfs_cache_pressure" = 50; # Balance between caching and reclaiming memory
      "vm.dirty_ratio" = 15; # Start writing dirty pages at 15% memory usage
      "vm.dirty_background_ratio" = 5; # Start background writing at 5%
    };

    # Initial RAM disk
    initrd = {
      # Include only necessary modules in initrd
      availableKernelModules = [
        "xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"
      ];

      # Network modules for network boot if needed
      kernelModules = [ ];
    };

    # Use tmpfs for /tmp (RAM-based, auto-cleaned on reboot)
    tmp = {
      useTmpfs = true;
      tmpfsSize = "4G";
    };
  };

  # Minimal system packages
  environment = {
    # Remove default packages for minimal footprint
    defaultPackages = lib.mkForce [];

    # Essential system packages only
    systemPackages = with pkgs; [
      vim           # Editor
      git           # Version control
      htop          # System monitoring
      tmux          # Terminal multiplexer
      curl          # HTTP client
      jq            # JSON processor
      dig           # DNS utilities
      netcat        # Network debugging
      iptables      # Firewall management (required for k3s)
      iproute2      # Network configuration
      util-linux    # System utilities
      coreutils     # Core utilities
    ];

    # Disable command-not-found for smaller footprint
    stub-ld.enable = false;
  };

  # Disable documentation to save space
  documentation = {
    enable = false;
    doc.enable = false;
    info.enable = false;
    man.enable = false;
    nixos.enable = false;
  };

  # Basic system configuration
  time.timeZone = "UTC"; # Use UTC for consistency across nodes

  # Locale settings (minimal)
  i18n = {
    defaultLocale = "en_US.UTF-8";
    supportedLocales = [ "en_US.UTF-8/UTF-8" ]; # Only include necessary locale
  };

  # Console configuration
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # User configuration
  users = {
    # Disable mutable users for immutability
    mutableUsers = false;

    # Root user with SSH access
    users.root = {
      # Password will be set via sops-nix or initial deployment
      hashedPassword = "$6$rounds=424242$VwsNnwb6l6N5GAnK$UpOqDUNYfVnLpLwsM1s8Dpzo8gAcqKcgFWP.BG0emnqX5sBPKvYeeZPW3r8TJFkYYTBj9OrdcsNvjWkToi1Zz1"; # CHANGE THIS - temporary "nixos"
      openssh.authorizedKeys.keys = [
        # Add your SSH public keys here
      ];
    };
  };

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password"; # Root login with key only
      PasswordAuthentication = false; # Disable password auth
      KbdInteractiveAuthentication = false;
      X11Forwarding = false; # No X11 on headless system

      # Security hardening
      Protocol = 2;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      MaxAuthTries = 3;
      MaxSessions = 10;
    };

    # Only allow specific users if needed
    allowSFTP = false; # Disable SFTP if not needed

    # Use only strong ciphers and algorithms
    extraConfig = ''
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
      KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
    '';
  };

  # Firewall configuration (k3s will manage its own rules)
  networking.firewall = {
    enable = true;

    # Allow SSH
    allowedTCPPorts = [ 22 ];

    # k3s will open its required ports
    trustedInterfaces = [ "cni0" "flannel.1" ]; # Trust k3s interfaces
  };

  # System services
  services = {
    # Journal configuration
    journald = {
      extraConfig = ''
        SystemMaxUse=1G
        SystemMaxFileSize=100M
        MaxRetentionSec=7d
        ForwardToSyslog=no
        ForwardToConsole=no
      '';
    };

    # Disable unnecessary services
    udisks2.enable = false;
    power-profiles-daemon.enable = false;
  };

  # Security configuration
  security = {
    # Enable sudo for administrative tasks
    sudo = {
      enable = true;
      wheelNeedsPassword = false; # Passwordless sudo for wheel group
      extraRules = [
        {
          groups = [ "wheel" ];
          commands = [ "ALL" ];
        }
      ];
    };

    # Disable polkit for smaller footprint
    polkit.enable = false;

    # AppArmor for additional security (optional)
    apparmor.enable = false; # Can be enabled if needed
  };

  # Hardware configuration
  hardware = {
    enableRedistributableFirmware = true; # Include firmware for hardware support
    cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  };

  # System state version (don't change after initial deployment)
  system.stateVersion = "24.05";
}