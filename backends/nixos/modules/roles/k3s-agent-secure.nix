{ config, lib, pkgs, ... }:

{
  # K3s agent (worker node) configuration with secrets management

  # Import base configurations
  imports = [
    ./k3s-common.nix
    ../security/secrets.nix
  ];

  # K3s agent-specific configuration with token from sops
  services.k3s = {
    enable = true;
    role = "agent";

    # Server URL - should be configured per-host or via option
    serverAddr = lib.mkDefault "https://n100-1:6443";

    # Use token from sops secret
    tokenFile = config.sops.secrets."k3s-agent-token".path;

    # Agent configuration
    extraFlags = toString [
      # Kubelet configuration
      "--kubelet-arg=max-pods=250"
      "--kubelet-arg=eviction-hard=memory.available<5%"
      "--kubelet-arg=eviction-soft=memory.available<10%"
      "--kubelet-arg=eviction-soft-grace-period=memory.available=2m"
      "--kubelet-arg=system-reserved=cpu=250m,memory=500Mi"
      "--kubelet-arg=kube-reserved=cpu=250m,memory=500Mi"
      "--kubelet-arg=image-gc-high-threshold=85"
      "--kubelet-arg=image-gc-low-threshold=80"

      # Container runtime configuration
      "--container-runtime-endpoint=unix:///run/k3s/containerd/containerd.sock"

      # Data directory
      "--data-dir=/var/lib/k3s"

      # Node labels (can be customized per-node)
      "--node-label=node.n3x.io/role=worker"
      # "--node-label=node.n3x.io/storage=true"    # For storage nodes
      # "--node-label=node.n3x.io/edge=true"       # For edge nodes

      # Node taints (optional, for dedicated nodes)
      # "--node-taint=node.n3x.io/storage=true:NoSchedule"  # Storage-only nodes

      # Logging
      "--log=/var/log/k3s-agent.log"
      "--alsologtostderr"
      "--v=2"
    ];

    # Agent-specific environment variables
    environmentFile = pkgs.writeText "k3s-agent.env" ''
      K3S_NODE_NAME="${config.networking.hostName}"
      CONTAINERD_LOG_LEVEL="info"
    '';
  };

  # Firewall rules for k3s agent
  networking.firewall = {
    allowedTCPPorts = [
      10250 # kubelet API
      10255 # kubelet read-only (deprecated but sometimes needed)
    ];

    allowedUDPPorts = [
      8472 # Flannel VXLAN
      51820 # Flannel WireGuard
      51821 # Flannel WireGuard IPv6
    ];

    # Allow all traffic from cluster networks
    extraCommands = ''
      # Allow all traffic from pod network
      iptables -A nixos-fw -s 10.42.0.0/16 -j ACCEPT

      # Allow all traffic from service network
      iptables -A nixos-fw -s 10.43.0.0/16 -j ACCEPT

      # Allow NodePort range
      iptables -A nixos-fw -p tcp --dport 30000:32767 -j ACCEPT
      iptables -A nixos-fw -p udp --dport 30000:32767 -j ACCEPT

      # Allow metrics-server to scrape kubelet
      iptables -A nixos-fw -p tcp --dport 10250 -j ACCEPT
    '';

    extraStopCommands = ''
      iptables -D nixos-fw -s 10.42.0.0/16 -j ACCEPT || true
      iptables -D nixos-fw -s 10.43.0.0/16 -j ACCEPT || true
      iptables -D nixos-fw -p tcp --dport 30000:32767 -j ACCEPT || true
      iptables -D nixos-fw -p udp --dport 30000:32767 -j ACCEPT || true
      iptables -D nixos-fw -p tcp --dport 10250 -j ACCEPT || true
    '';
  };

  # Systemd service configuration for k3s agent
  systemd.services.k3s = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "sops-nix.service" ]; # Wait for secrets

    # Restart configuration
    unitConfig = {
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 6;
    };

    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "10s";

      # Resource limits
      LimitNOFILE = 1048576;
      LimitNPROC = 512000;
      LimitCORE = "infinity";
      TasksMax = "infinity";
      LimitMEMLOCK = "infinity";

      # CPU and Memory limits (adjust based on hardware)
      CPUWeight = 100; # Normal priority for agents
      MemoryMax = "6G"; # Limit memory usage (less than server)
      MemorySwapMax = "2G"; # Limit swap usage
    };

    # Pre-start script
    preStart = ''
      # Wait for sops secrets to be available
      while [ ! -f "${config.sops.secrets."k3s-agent-token".path}" ]; do
        echo "Waiting for k3s-agent-token secret..."
        sleep 2
      done

      # Create necessary directories
      mkdir -p /var/lib/k3s/agent
      mkdir -p /var/log
      mkdir -p /var/lib/rancher/k3s/agent/images

      # Clean up any stale container state
      if [ -d /var/lib/k3s/agent/containerd ]; then
        echo "Cleaning up stale containerd state..."
        rm -rf /var/lib/k3s/agent/containerd/io.containerd.grpc.v1.cri/sandboxes/* || true
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
    '';

    # Post-start script
    postStart = ''
      # Wait for kubelet to be ready
      echo "Waiting for kubelet to be ready..."
      for i in {1..60}; do
        if ${pkgs.curl}/bin/curl -s http://127.0.0.1:10248/healthz >/dev/null 2>&1; then
          echo "kubelet is ready"
          break
        fi
        sleep 2
      done

      # Wait for node to register with cluster
      echo "Waiting for node to register with cluster..."
      for i in {1..120}; do
        if ${pkgs.k3s}/bin/k3s kubectl get node ${config.networking.hostName} >/dev/null 2>&1; then
          echo "Node registered successfully"
          break
        fi
        sleep 2
      done
    '';
  };

  # Node monitoring service
  systemd.services.k3s-node-monitor = {
    description = "Monitor K3s node health";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = pkgs.writeShellScript "k3s-node-monitor" ''
        while true; do
          # Check if k3s is running
          if ! systemctl is-active --quiet k3s; then
            echo "WARNING: k3s service is not running"
          fi

          # Check kubelet health
          if ! ${pkgs.curl}/bin/curl -s http://127.0.0.1:10248/healthz >/dev/null 2>&1; then
            echo "WARNING: kubelet health check failed"
          fi

          # Check containerd
          if ! ${pkgs.k3s}/bin/k3s crictl version >/dev/null 2>&1; then
            echo "WARNING: containerd is not responding"
          fi

          # Check disk usage
          DISK_USAGE=$(df /var/lib/k3s | awk 'NR==2 {print $5}' | sed 's/%//')
          if [ "$DISK_USAGE" -gt 90 ]; then
            echo "WARNING: Disk usage is above 90%"
          fi

          # Check memory
          MEM_AVAILABLE=$(free -m | awk 'NR==2 {print $7}')
          if [ "$MEM_AVAILABLE" -lt 500 ]; then
            echo "WARNING: Available memory is below 500MB"
          fi

          sleep 60
        done
      '';
      Restart = "always";
      RestartSec = "30s";
    };
  };

  # Container image cleanup service
  systemd.services.k3s-image-cleanup = {
    description = "Clean up unused container images";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "k3s-image-cleanup" ''
        # Check if k3s is running
        if ! systemctl is-active --quiet k3s; then
          echo "k3s is not running, skipping cleanup"
          exit 0
        fi

        echo "Cleaning up unused container images..."

        # Remove unused containers
        ${pkgs.k3s}/bin/k3s crictl rmp -f $(${pkgs.k3s}/bin/k3s crictl pods -q) 2>/dev/null || true

        # Remove unused images
        ${pkgs.k3s}/bin/k3s crictl rmi --prune 2>/dev/null || true

        echo "Container image cleanup completed"
      '';
      User = "root";
    };
  };

  systemd.timers.k3s-image-cleanup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      AccuracySec = "1h";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  # Log cleanup service
  systemd.services.k3s-log-cleanup = {
    description = "Clean up old k3s logs";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "k3s-log-cleanup" ''
        echo "Cleaning up old k3s logs..."

        # Clean up pod logs older than 3 days
        find /var/log/pods -type f -name "*.log" -mtime +3 -delete 2>/dev/null || true

        # Clean up container logs older than 3 days
        find /var/log/containers -type f -name "*.log" -mtime +3 -delete 2>/dev/null || true

        echo "Log cleanup completed"
      '';
      User = "root";
    };
  };

  systemd.timers.k3s-log-cleanup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      AccuracySec = "1h";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  # Additional packages for agent management
  environment.systemPackages = with pkgs; [
    crictl # Container runtime interface (CRI) CLI
  ];

  # Create required directories
  system.activationScripts.k3s-agent-setup = ''
    mkdir -p /var/lib/k3s/agent
    mkdir -p /var/lib/rancher/k3s/agent/images
    mkdir -p /var/log/pods
    mkdir -p /var/log/containers
  '';
}
