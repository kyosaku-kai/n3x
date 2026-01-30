{ config, lib, pkgs, ... }:

{
  # K3s agent (worker node) configuration

  # Import k3s common configuration
  imports = [
    ./k3s-common.nix
  ];

  # K3s agent-specific configuration
  services.k3s = {
    enable = true;
    role = "agent";

    # Placeholder token file to suppress "Token or tokenFile should be set" evaluation warning.
    # At deployment, sops-nix overrides this with the real secret at /run/secrets/k3s-token.
    # The placeholder path doesn't need to exist during evaluation.
    tokenFile = lib.mkDefault "/run/secrets/k3s-token";

    # Server URL will be set per-host
    # serverAddr = "https://k3s-server:6443";

    # Agent configuration
    extraFlags = lib.mkDefault [
      # Kubelet configuration
      "--kubelet-arg=max-pods=250"
      "--kubelet-arg=eviction-hard=memory.available<5%"
      "--kubelet-arg=eviction-soft=memory.available<10%"
      "--kubelet-arg=eviction-soft-grace-period=memory.available=2m"
      "--kubelet-arg=system-reserved=cpu=200m,memory=500Mi"
      "--kubelet-arg=kube-reserved=cpu=200m,memory=500Mi"
      "--kubelet-arg=image-gc-high-threshold=85"
      "--kubelet-arg=image-gc-low-threshold=80"

      # Container runtime
      "--kubelet-arg=container-log-max-size=10Mi"
      "--kubelet-arg=container-log-max-files=5"

      # Node labels (will be customized per-host)
      # "--node-label=node-role.kubernetes.io/worker=true"
      # "--node-label=node.longhorn.io/create-default-disk=true"

      # Data directory
      "--data-dir=/var/lib/k3s"

      # Logging
      "--log=/var/log/k3s-agent.log"
      "--alsologtostderr"
      "--v=2"

      # Disable unnecessary components on agents
      "--disable-cloud-controller"
      "--disable-network-policy"
    ];

    # Agent-specific environment variables
    environmentFile = pkgs.writeText "k3s-agent.env" ''
      # Token will be provided via sops-nix secret
      # K3S_TOKEN_FILE=/run/secrets/k3s-token
    '';
  };

  # Firewall rules for k3s agent
  networking.firewall = {
    allowedTCPPorts = [
      10250 # kubelet API
      10255 # kubelet read-only API (deprecated but sometimes needed)
    ];

    allowedTCPPortRanges = [
      { from = 30000; to = 32767; } # NodePort range
    ];

    allowedUDPPorts = [
      8472 # Flannel VXLAN
      51820 # Flannel WireGuard
      51821 # Flannel WireGuard IPv6
    ];

    allowedUDPPortRanges = [
      { from = 30000; to = 32767; } # NodePort range
    ];

    # Allow all traffic from cluster networks
    extraCommands = ''
      # Allow all traffic from pod network
      iptables -A nixos-fw -s 10.42.0.0/16 -j ACCEPT

      # Allow all traffic from service network
      iptables -A nixos-fw -s 10.43.0.0/16 -j ACCEPT

      # Allow traffic from other cluster nodes (will be configured per-deployment)
      # iptables -A nixos-fw -s 192.168.10.0/24 -j ACCEPT
    '';

    extraStopCommands = ''
      iptables -D nixos-fw -s 10.42.0.0/16 -j ACCEPT || true
      iptables -D nixos-fw -s 10.43.0.0/16 -j ACCEPT || true
    '';
  };

  # Systemd service configuration for k3s agent
  systemd.services.k3s = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    # Restart configuration
    unitConfig = {
      StartLimitIntervalSec = lib.mkDefault "10min";
      StartLimitBurst = lib.mkDefault 6;
    };

    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkDefault "10s";

      # Resource limits (NixOS k3s module sets LimitNPROC="infinity" by default)
      LimitNOFILE = lib.mkDefault 1048576;
      LimitCORE = lib.mkDefault "infinity";
      TasksMax = lib.mkDefault "infinity";
      LimitMEMLOCK = lib.mkDefault "infinity";

      # CPU and Memory limits (agents can use more resources)
      CPUWeight = 100; # Normal priority
      MemoryMax = "90%"; # Can use most of the memory
      MemorySwapMax = "4G"; # Limit swap usage
    };

    # Pre-start script
    preStart = ''
      # Create necessary directories
      mkdir -p /var/lib/k3s/agent
      mkdir -p /var/lib/k3s/kubelet
      mkdir -p /var/lib/k3s/containers
      mkdir -p /var/log

      # Clean up old pods if needed
      if [ -d /var/lib/k3s/kubelet/pods ]; then
        find /var/lib/k3s/kubelet/pods -type d -empty -delete 2>/dev/null || true
      fi

      # Set up log rotation
      if [ ! -f /etc/logrotate.d/k3s-agent ]; then
        cat > /etc/logrotate.d/k3s-agent <<EOF
      /var/log/k3s-agent.log {
        daily
        rotate 7
        compress
        delaycompress
        missingok
        notifempty
        create 0640 root root
        postrotate
          systemctl reload k3s || true
        endscript
      }
      EOF
      fi

      # Wait for server to be reachable (if serverAddr is set)
      if [ -n "$K3S_URL" ]; then
        echo "Waiting for k3s server at $K3S_URL..."
        for i in {1..60}; do
          if ${pkgs.curl}/bin/curl -ksf "$K3S_URL" >/dev/null 2>&1; then
            echo "k3s server is reachable"
            break
          fi
          sleep 2
        done
      fi
    '';

    # Post-start script
    postStart = ''
      # Wait for kubelet to be ready
      echo "Waiting for kubelet to be ready..."
      for i in {1..60}; do
        if ${pkgs.curl}/bin/curl -sf http://localhost:10255/healthz >/dev/null 2>&1; then
          echo "kubelet is ready"
          break
        fi
        sleep 2
      done

      # Ensure Longhorn directories exist (if using Longhorn)
      mkdir -p /var/lib/longhorn
      chmod 700 /var/lib/longhorn
    '';
  };

  # System tuning for container workloads
  boot.kernel.sysctl = {
    # Note: fs.inotify.* settings are in modules/roles/k3s-common.nix
    # Note: fs.file-max and fs.nr_open are in modules/hardware/n100.nix

    # Network tuning for container networking (higher than k3s-common for agents)
    "net.netfilter.nf_conntrack_max" = lib.mkForce 262144;
    "net.nf_conntrack_max" = lib.mkForce 262144;

    # Memory overcommit for containers
    "vm.overcommit_memory" = 1;
    "vm.panic_on_oom" = 0;
    "vm.overcommit_ratio" = 50;

    # Better performance for containers
    "kernel.pid_max" = 4194304;
  };

  # Container-specific kernel modules
  boot.kernelModules = [
    "overlay"
    "br_netfilter"
    "nf_conntrack"
    "xt_conntrack"
    "nf_nat"
    "xt_nat"
    "xt_REDIRECT"
    "xt_owner"
    "iptable_nat"
    "iptable_filter"
  ];

  # Ensure container directories have proper permissions
  system.activationScripts.k3s-agent-setup = ''
    # Create directories for k3s agent
    mkdir -p /var/lib/k3s/agent
    mkdir -p /var/lib/k3s/kubelet
    mkdir -p /var/lib/k3s/containers

    # Create directory for Longhorn if it will be used
    mkdir -p /var/lib/longhorn
    chmod 700 /var/lib/longhorn

    # Create containerd directories
    mkdir -p /var/lib/containerd
    mkdir -p /run/containerd
  '';

  # Additional packages for agent nodes
  environment.systemPackages = with pkgs; [
    containerd # Container runtime (for debugging)
    cri-tools # CRI debugging tools
    runc # Low-level container runtime
  ];

  # Monitoring and cleanup services
  systemd.services.k3s-cleanup = {
    description = "Clean up unused k3s resources";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "k3s-cleanup" ''
        # Clean up old container logs
        find /var/log/pods -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
        find /var/log/containers -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true

        # Clean up empty directories
        find /var/lib/k3s/kubelet/pods -type d -empty -delete 2>/dev/null || true

        # Clean up orphaned volumes
        if [ -d /var/lib/k3s/storage ]; then
          find /var/lib/k3s/storage -type d -empty -delete 2>/dev/null || true
        fi

        echo "k3s cleanup completed"
      '';
      User = "root";
    };
  };

  systemd.timers.k3s-cleanup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      AccuracySec = "1h";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
