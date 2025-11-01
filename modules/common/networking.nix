{ config, lib, pkgs, ... }:

{
  # Basic networking configuration
  networking = {
    # Enable NetworkManager or systemd-networkd based on preference
    # Using systemd-networkd for server environments (more lightweight)
    useDHCP = false; # Disable global DHCP, configure per-interface
    useNetworkd = true; # Use systemd-networkd instead of NetworkManager

    # Enable IPv6 support
    enableIPv6 = true;

    # Set domain for the cluster
    domain = "k3s.local";

    # Search domains
    search = [ "k3s.local" ];

    # Configure name servers (can be overridden per-host)
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
      "2606:4700:4700::1111" # Cloudflare IPv6
      "2001:4860:4860::8888" # Google IPv6
    ];

    # Host entries for cluster nodes (will be expanded per-host)
    extraHosts = ''
      # Cluster nodes will be added here by host-specific configs
    '';

    # Firewall defaults (k3s specific ports will be added by role modules)
    firewall = {
      enable = true;

      # Allow ping
      allowPing = true;

      # Log dropped packets for debugging
      logReversePathDrops = true;
      logRefusedConnections = false; # Reduce log spam

      # Connection tracking
      connectionTrackingModules = [ ];
      autoLoadConntrackHelpers = false;

      # Rate limiting for SSH (prevent brute force)
      extraCommands = ''
        # Rate limit SSH connections
        iptables -A nixos-fw -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH --rsource
        iptables -A nixos-fw -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j DROP

        # Allow established connections
        iptables -A nixos-fw -m state --state ESTABLISHED,RELATED -j ACCEPT

        # Drop invalid packets
        iptables -A nixos-fw -m state --state INVALID -j DROP
      '';

      extraStopCommands = ''
        iptables -D nixos-fw -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH --rsource || true
        iptables -D nixos-fw -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j DROP || true
        iptables -D nixos-fw -m state --state ESTABLISHED,RELATED -j ACCEPT || true
        iptables -D nixos-fw -m state --state INVALID -j DROP || true
      '';
    };
  };

  # Systemd-networkd configuration
  systemd.network = {
    enable = true;

    # Wait for network to be online before starting services
    wait-online = {
      enable = true;
      anyInterface = true; # Continue if any interface is online
      timeout = 60; # Timeout after 60 seconds
      extraArgs = [ "--operational-state=routable" ];
    };

    # Global network settings
    config = {
      networkConfig = {
        SpeedMeter = true; # Enable speed metering
        SpeedMeterIntervalSec = "10s";
        ManageForeignRoutes = true;
        ManageForeignRoutingPolicyRules = true;
      };
    };

    # Default network configuration for unconfigured interfaces
    networks = {
      # Catch-all for unconfigured ethernet interfaces
      "99-ethernet-default" = {
        matchConfig = {
          Name = "en* eth*";
        };
        # Don't configure these by default, let specific configs handle them
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig = {
          RequiredForOnline = false;
        };
      };

      # Catch-all for wireless (shouldn't exist on servers but just in case)
      "99-wireless-default" = {
        matchConfig = {
          Name = "wl*";
        };
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig = {
          RequiredForOnline = false;
        };
      };
    };
  };

  # Network optimization
  boot.kernel.sysctl = {
    # TCP optimization for k3s
    "net.core.somaxconn" = 32768;
    "net.ipv4.tcp_max_syn_backlog" = 8192;
    "net.core.netdev_max_backlog" = 5000;
    "net.ipv4.tcp_fin_timeout" = 30;
    "net.ipv4.tcp_keepalive_time" = 600;
    "net.ipv4.tcp_keepalive_intvl" = 30;
    "net.ipv4.tcp_keepalive_probes" = 5;
    "net.ipv4.tcp_tw_reuse" = 1;

    # Increase network buffer sizes
    "net.core.rmem_default" = 31457280;
    "net.core.wmem_default" = 31457280;
    "net.core.rmem_max" = 67108864;
    "net.core.wmem_max" = 67108864;
    "net.ipv4.tcp_rmem" = "4096 87380 67108864";
    "net.ipv4.tcp_wmem" = "4096 65536 67108864";

    # Enable BBR congestion control (better for WAN links)
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";

    # Connection tracking for k3s
    "net.netfilter.nf_conntrack_max" = 131072;
    "net.nf_conntrack_max" = 131072;
    "net.netfilter.nf_conntrack_tcp_timeout_established" = 86400;
    "net.netfilter.nf_conntrack_tcp_timeout_close_wait" = 3600;

    # IPv6 settings
    "net.ipv6.conf.all.use_tempaddr" = 0;
    "net.ipv6.conf.default.use_tempaddr" = 0;

    # Security settings
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
  };

  # Enable systemd-resolved for DNS management
  services.resolved = {
    enable = true;
    dnssec = "allow-downgrade"; # Use DNSSEC when available
    dnsovertls = "opportunistic"; # Use DNS over TLS when available
    fallbackDns = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    # Don't use ISP DNS servers
    extraConfig = ''
      DNSStubListener=no
      ReadEtcHosts=yes
      Cache=yes
      CacheFromLocalhost=yes
    '';
  };

  # Network utilities
  environment.systemPackages = with pkgs; [
    iproute2
    iputils
    ethtool
    tcpdump
    nettools
    nmap
    iperf3
    mtr
    wireguard-tools
    bridge-utils
    conntrack-tools
  ];

  # Enable packet forwarding for k3s
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Disable NetworkManager (using systemd-networkd)
  networking.networkmanager.enable = false;

  # Enable STP for bridges (if using bonding/bridges)
  systemd.network.netdevs = {
    # Bridge configuration will be added by bonding module if needed
  };

  # MTU discovery
  networking.usePredictableInterfaceNames = true; # Use predictable names (enpXsY format)

  # Disable IPv6 if not needed (uncomment to disable)
  # boot.kernelParams = [ "ipv6.disable=1" ];

  # Quality of Service (QoS) - optional, can be configured per-interface
  # This would be added by specific hardware modules if needed
}