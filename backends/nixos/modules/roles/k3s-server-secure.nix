{ config, lib, pkgs, ... }:

{
  # K3s server (control plane) configuration with secrets management

  # Import base configurations
  imports = [
    ./k3s-common.nix
    ../security/secrets.nix
  ];

  # K3s server-specific configuration with token from sops
  services.k3s = {
    enable = true;
    role = "server";

    # Use token from sops secret
    tokenFile = config.sops.secrets."k3s-server-token".path;

    # Server configuration
    extraFlags = toString [
      # Cluster configuration
      "--cluster-init" # Initialize new cluster (first server only)
      "--disable-cloud-controller" # We're not in a cloud
      "--disable-network-policy" # Use Kyverno instead

      # Embedded components to disable (we'll deploy better alternatives)
      "--disable=traefik" # Will use nginx-ingress or similar
      "--disable=servicelb" # Will use MetalLB
      "--disable=local-storage" # Will use Longhorn

      # Etcd configuration
      "--etcd-arg=quota-backend-bytes=8589934592" # 8GB etcd quota
      "--etcd-arg=auto-compaction-retention=1h" # Auto-compact every hour
      "--etcd-arg=heartbeat-interval=500" # 500ms heartbeat
      "--etcd-arg=election-timeout=5000" # 5s election timeout

      # API server configuration
      "--kube-apiserver-arg=max-requests-inflight=800"
      "--kube-apiserver-arg=max-mutating-requests-inflight=200"
      "--kube-apiserver-arg=audit-log-maxage=30"
      "--kube-apiserver-arg=audit-log-maxbackup=10"
      "--kube-apiserver-arg=audit-log-maxsize=100"
      "--kube-apiserver-arg=event-ttl=24h"

      # Controller configuration
      "--kube-controller-manager-arg=node-cidr-mask-size=24"
      "--kube-controller-manager-arg=node-monitor-period=5s"
      "--kube-controller-manager-arg=node-monitor-grace-period=40s"
      "--kube-controller-manager-arg=pod-eviction-timeout=5m"

      # Scheduler configuration
      "--kube-scheduler-arg=leader-elect=true"

      # Kubelet configuration
      "--kubelet-arg=max-pods=250"
      "--kubelet-arg=eviction-hard=memory.available<5%"
      "--kubelet-arg=eviction-soft=memory.available<10%"
      "--kubelet-arg=eviction-soft-grace-period=memory.available=2m"
      "--kubelet-arg=system-reserved=cpu=500m,memory=1Gi"
      "--kubelet-arg=kube-reserved=cpu=500m,memory=1Gi"

      # Network configuration (will be overridden by per-host config)
      "--cluster-cidr=10.42.0.0/16" # Pod network
      "--service-cidr=10.43.0.0/16" # Service network
      "--cluster-dns=10.43.0.10" # CoreDNS service IP

      # TLS configuration
      "--tls-san=k3s.local" # Add cluster domain to cert

      # Data directory
      "--data-dir=/var/lib/k3s"

      # Write kubeconfig with proper permissions
      "--write-kubeconfig-mode=0640"

      # Logging
      "--log=/var/log/k3s.log"
      "--alsologtostderr"
      "--v=2"
    ];

    # Server-specific environment variables
    # Note: Token is provided via tokenFile, not environment
    environmentFile = pkgs.writeText "k3s-server.env" ''
      K3S_DATASTORE_ENDPOINT="etcd"
      K3S_DATASTORE_CAFILE="/var/lib/k3s/server/tls/etcd/server-ca.crt"
      K3S_DATASTORE_CERTFILE="/var/lib/k3s/server/tls/etcd/server-client.crt"
      K3S_DATASTORE_KEYFILE="/var/lib/k3s/server/tls/etcd/server-client.key"
    '';
  };

  # Firewall rules for k3s server
  networking.firewall = {
    allowedTCPPorts = [
      6443 # Kubernetes API server
      2379 # etcd client
      2380 # etcd peer
      10250 # kubelet API
      10251 # kube-scheduler
      10252 # kube-controller-manager
      10257 # kube-controller-manager secure
      10259 # kube-scheduler secure
    ];

    allowedUDPPorts = [
      8472 # Flannel VXLAN
      51820 # Flannel WireGuard
      51821 # Flannel WireGuard IPv6
    ];

    # Allow all traffic from cluster nodes (configure per deployment)
    extraCommands = ''
      # Allow all traffic from pod network
      iptables -A nixos-fw -s 10.42.0.0/16 -j ACCEPT

      # Allow all traffic from service network
      iptables -A nixos-fw -s 10.43.0.0/16 -j ACCEPT

      # Allow NodePort range
      iptables -A nixos-fw -p tcp --dport 30000:32767 -j ACCEPT
      iptables -A nixos-fw -p udp --dport 30000:32767 -j ACCEPT
    '';

    extraStopCommands = ''
      iptables -D nixos-fw -s 10.42.0.0/16 -j ACCEPT || true
      iptables -D nixos-fw -s 10.43.0.0/16 -j ACCEPT || true
      iptables -D nixos-fw -p tcp --dport 30000:32767 -j ACCEPT || true
      iptables -D nixos-fw -p udp --dport 30000:32767 -j ACCEPT || true
    '';
  };

  # Systemd service configuration for k3s server
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
      CPUWeight = 200; # Higher priority
      MemoryMax = "8G"; # Limit memory usage
      MemorySwapMax = "2G"; # Limit swap usage
    };

    # Pre-start script
    preStart = ''
      # Wait for sops secrets to be available
      while [ ! -f "${config.sops.secrets."k3s-server-token".path}" ]; do
        echo "Waiting for k3s-server-token secret..."
        sleep 2
      done

      # Create necessary directories
      mkdir -p /var/lib/k3s/server/manifests
      mkdir -p /var/lib/k3s/server/logs
      mkdir -p /var/log

      # Set up log rotation if needed
      if [ ! -f /etc/logrotate.d/k3s ]; then
        cat > /etc/logrotate.d/k3s <<EOF
      /var/log/k3s.log {
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
      # Wait for k3s to be ready
      echo "Waiting for k3s to be ready..."
      for i in {1..60}; do
        if ${pkgs.k3s}/bin/k3s kubectl get nodes >/dev/null 2>&1; then
          echo "k3s is ready"
          break
        fi
        sleep 2
      done

      # Export kubeconfig for admin use
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        mkdir -p /root/.kube
        cp /etc/rancher/k3s/k3s.yaml /root/.kube/config || true
        chmod 600 /root/.kube/config || true
      fi
    '';
  };

  # Additional sops secrets specific to k3s server
  sops.secrets = {
    # Optional: etcd encryption key
    # "etcd-encryption-key" = {
    #   sopsFile = ../../secrets/k3s/etcd.yaml;
    #   key = "encryption-key";
    #   owner = "root";
    #   mode = "0600";
    #   restartUnits = [ "k3s.service" ];
    # };

    # Optional: API server certificates
    # "api-server-cert" = {
    #   sopsFile = ../../secrets/k3s/certs.yaml;
    #   key = "api-server-cert";
    #   owner = "root";
    #   mode = "0644";
    # };

    # "api-server-key" = {
    #   sopsFile = ../../secrets/k3s/certs.yaml;
    #   key = "api-server-key";
    #   owner = "root";
    #   mode = "0600";
    # };
  };

  # Create systemd timer for etcd defragmentation
  systemd.timers.etcd-defrag = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      AccuracySec = "1h";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.services.etcd-defrag = {
    description = "Defragment etcd database";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "etcd-defrag" ''
        # Check if k3s is running
        if ! systemctl is-active --quiet k3s; then
          echo "k3s is not running, skipping defragmentation"
          exit 0
        fi

        # Get etcd endpoints
        ENDPOINTS=$(${pkgs.k3s}/bin/k3s kubectl get endpoints -n kube-system etcd -o json | ${pkgs.jq}/bin/jq -r '.subsets[0].addresses[].ip' | paste -sd,)

        if [ -z "$ENDPOINTS" ]; then
          echo "No etcd endpoints found"
          exit 0
        fi

        # Defragment etcd
        echo "Defragmenting etcd at endpoints: $ENDPOINTS"
        ETCDCTL_API=3 ${pkgs.etcd}/bin/etcdctl \
          --endpoints="https://$ENDPOINTS:2379" \
          --cacert=/var/lib/k3s/server/tls/etcd/server-ca.crt \
          --cert=/var/lib/k3s/server/tls/etcd/server-client.crt \
          --key=/var/lib/k3s/server/tls/etcd/server-client.key \
          defrag

        echo "etcd defragmentation completed"
      '';
      User = "root";
    };
  };

  # Create systemd service for etcd backup
  systemd.services.etcd-backup = {
    description = "Backup etcd database";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "etcd-backup" ''
        # Check if k3s is running
        if ! systemctl is-active --quiet k3s; then
          echo "k3s is not running, skipping backup"
          exit 0
        fi

        # Create backup directory
        BACKUP_DIR="/var/backups/etcd"
        mkdir -p "$BACKUP_DIR"

        # Create backup
        TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        BACKUP_FILE="$BACKUP_DIR/etcd-snapshot-$TIMESTAMP.db"

        echo "Creating etcd backup: $BACKUP_FILE"
        ${pkgs.k3s}/bin/k3s etcd-snapshot save "$BACKUP_FILE"

        # Compress backup
        ${pkgs.gzip}/bin/gzip "$BACKUP_FILE"

        # Remove backups older than 7 days
        find "$BACKUP_DIR" -name "etcd-snapshot-*.db.gz" -mtime +7 -delete

        echo "etcd backup completed"
      '';
      User = "root";
    };
  };

  systemd.timers.etcd-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      AccuracySec = "1h";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  # Additional packages for server management
  environment.systemPackages = with pkgs; [
    etcd # etcd client for management
    sqlite # For viewing k3s database
  ];

  # Create kubeconfig directory
  system.activationScripts.k3s-server-setup = ''
    mkdir -p /root/.kube
    mkdir -p /var/lib/k3s/server/manifests
    mkdir -p /var/backups/etcd
  '';
}
