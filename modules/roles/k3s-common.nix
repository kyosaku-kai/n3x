{ config, lib, pkgs, ... }:

{
  # Common k3s configuration shared between servers and agents

  # System packages required for k3s
  environment.systemPackages = with pkgs; [
    k3s
    kubectl
    kubernetes-helm
    nfs-utils # For NFS storage if needed
    openiscsi # For iSCSI (Longhorn)
    cryptsetup # For encrypted volumes
    util-linux # For mount and other utilities
    cifs-utils # For SMB/CIFS if needed
    jq # For JSON processing in scripts
    yq # For YAML processing
    htop # For monitoring
    iotop # For I/O monitoring
    iftop # For network monitoring
  ];

  # Required kernel modules for k3s and container storage
  boot.kernelModules = [
    # Container runtime
    "overlay"
    "br_netfilter"

    # Networking
    "xt_conntrack"
    "xt_MASQUERADE"
    "xt_nat"
    "xt_tcpudp"
    "xt_comment"
    "xt_multiport"
    "xt_addrtype"
    "xt_mark"

    # Storage
    "dm_thin_pool"
    "dm_crypt"
    "rbd" # Ceph RBD if needed

    # iSCSI for Longhorn
    "iscsi_tcp"
    "libiscsi"
    "scsi_transport_iscsi"

    # NFS support
    "nfs"
    "nfsd"
  ];

  # Kernel parameters for k3s
  boot.kernel.sysctl = {
    # Required for k3s networking
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.bridge.bridge-nf-call-arptables" = 1;

    # Performance tuning
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 8192;

    # Connection tracking
    "net.netfilter.nf_conntrack_max" = 131072;
    "net.nf_conntrack_max" = 131072;
  };

  # Ensure required services are enabled
  services = {
    # Open iSCSI for Longhorn
    openiscsi = {
      enable = true;
      name = "iqn.2020-01.io.longhorn:${config.networking.hostName}";
    };

    # NFS client support
    nfs.server.enable = false; # Disable NFS server by default
    rpcbind.enable = true; # Required for NFS client
  };

  # Create required directories
  system.activationScripts.k3s-common-setup = ''
    # Create k3s directories
    mkdir -p /var/lib/k3s
    mkdir -p /etc/rancher/k3s
    mkdir -p /var/log

    # Create directories for container storage
    mkdir -p /var/lib/containerd
    mkdir -p /var/lib/containers

    # Ensure proper permissions
    chmod 755 /var/lib/k3s
    chmod 755 /etc/rancher/k3s
  '';

  # Configure PATH to include k3s binaries
  environment.variables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    PATH = lib.mkForce "/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin";
  };

  # Shell aliases for convenience
  environment.shellAliases = {
    k = "kubectl";
    kns = "kubectl config set-context --current --namespace";
    kgp = "kubectl get pods";
    kgs = "kubectl get svc";
    kgn = "kubectl get nodes";
    kaf = "kubectl apply -f";
    kdel = "kubectl delete";
    klog = "kubectl logs";
    kexec = "kubectl exec -it";
    kdesc = "kubectl describe";
  };

  # Bash completion for kubectl and helm
  programs.bash.completion.enable = true;
  environment.etc."bash_completion.d/kubectl" = {
    text = ''
      source <(${pkgs.kubectl}/bin/kubectl completion bash)
      complete -F __start_kubectl k
    '';
  };

  environment.etc."bash_completion.d/helm" = {
    text = ''
      source <(${pkgs.kubernetes-helm}/bin/helm completion bash)
    '';
  };

  # Configure systemd to better handle containers
  systemd = {
    # Increase default limits
    settings.Manager = {
      DefaultLimitNOFILE = 1048576;
      DefaultLimitNPROC = 512000;
      DefaultLimitCORE = "infinity";
      DefaultTasksMax = "infinity";
      DefaultTimeoutStartSec = "90s";
      DefaultTimeoutStopSec = "90s";
    };

    # Ensure systemd can track container cgroups properly
    services."user@".serviceConfig = {
      Delegate = true;
    };

    # Create slice for k3s with proper resource limits
    slices.k3s = {
      description = "Slice for k3s";
      sliceConfig = {
        CPUWeight = 200;
        MemoryMax = "infinity";
        TasksMax = "infinity";
      };
    };
  };

  # Security settings for containers
  security = {
    # Unprivileged user namespaces (required for rootless containers)
    unprivilegedUsernsClone = true;

    # AppArmor (optional, can improve container security)
    apparmor.enable = lib.mkDefault false;

    # Audit framework (optional)
    auditd.enable = lib.mkDefault false;
  };

  # Configure logrotate for k3s logs
  services.logrotate = {
    enable = true;
    settings = {
      "/var/log/k3s*.log" = {
        daily = true;
        rotate = 7;
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        create = "0640 root root";
        sharedscripts = true;
        postrotate = "systemctl reload k3s 2>/dev/null || true";
      };

      "/var/log/pods/*/*.log" = {
        daily = true;
        rotate = 3;
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        maxsize = "100M";
      };

      "/var/log/containers/*.log" = {
        daily = true;
        rotate = 3;
        compress = true;
        delaycompress = true;
        missingok = true;
        notifempty = true;
        maxsize = "100M";
      };
    };
  };

  # Configure container registries
  environment.etc."rancher/k3s/registries.yaml" = {
    text = ''
      mirrors:
        docker.io:
          endpoint:
            - "https://registry-1.docker.io"
        k8s.gcr.io:
          endpoint:
            - "https://k8s.gcr.io"
            - "https://registry.k8s.io"
        gcr.io:
          endpoint:
            - "https://gcr.io"
        quay.io:
          endpoint:
            - "https://quay.io"
    '';
    mode = "0644";
  };

  # Helper script for k3s management
  environment.etc."k3s-helpers.sh" = {
    text = ''
      #!/usr/bin/env bash

      # Function to check k3s cluster status
      k3s_status() {
        echo "=== Node Status ==="
        kubectl get nodes -o wide
        echo ""
        echo "=== Pod Status ==="
        kubectl get pods --all-namespaces -o wide
        echo ""
        echo "=== Service Status ==="
        kubectl get svc --all-namespaces
      }

      # Function to get k3s logs
      k3s_logs() {
        journalctl -u k3s --no-pager -n 100
      }

      # Function to check k3s resource usage
      k3s_resources() {
        kubectl top nodes
        echo ""
        kubectl top pods --all-namespaces
      }

      # Export functions
      export -f k3s_status
      export -f k3s_logs
      export -f k3s_resources
    '';
    mode = "0755";
  };

  # Source helper functions in bash
  programs.bash.interactiveShellInit = ''
    source /etc/k3s-helpers.sh
  '';
}
