{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.n3x.networking.multus;

  # Multus CNI configuration
  multusCniConfig = {
    cniVersion = "0.4.0";
    name = "multus-cni-network";
    type = "multus";
    confDir = "/etc/cni/multus/net.d";
    cniDir = "/var/lib/rancher/k3s/data/current/bin";
    binDir = "/var/lib/rancher/k3s/data/current/bin";
    kubeconfig = "/etc/rancher/k3s/k3s.yaml";
    logLevel = "info";
    logFile = "/var/log/multus.log";
    capabilities = {
      portMappings = true;
      bandwidth = true;
    };
    clusterNetwork = "k3s-flannel";
    defaultNetworks = [];
    systemNamespaces = [ "kube-system" "kube-public" "kube-node-lease" ];
  };

  # Storage network attachment definition
  storageNetworkAttachment = {
    apiVersion = "k8s.cni.cncf.io/v1";
    kind = "NetworkAttachmentDefinition";
    metadata = {
      name = "storage-network";
      namespace = "default";
    };
    spec = {
      config = builtins.toJSON {
        cniVersion = "0.3.1";
        name = "storage-network";
        type = "macvlan";
        master = if cfg.vlanInterface != null then cfg.vlanInterface else cfg.parentInterface;
        mode = "bridge";
        ipam = {
          type = "static";
        };
      };
    };
  };

in
{
  options.n3x.networking.multus = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Multus CNI for multiple network interfaces in K3s";
    };

    parentInterface = mkOption {
      type = types.str;
      default = "bond0";
      description = "Parent interface for additional networks";
    };

    vlanInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "bond0.100";
      description = "VLAN interface for storage network (if using VLANs)";
    };

    storageNetwork = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable dedicated storage network for Longhorn";
      };

      subnet = mkOption {
        type = types.str;
        default = "10.0.100.0/24";
        description = "Subnet for storage network";
      };

      ipRange = mkOption {
        type = types.str;
        default = "10.0.100.128/25";
        description = "IP range for pod allocation in storage network";
      };
    };

    installMethod = mkOption {
      type = types.enum [ "manifest" "helm" ];
      default = "manifest";
      description = "Method to install Multus CNI";
    };
  };

  config = mkIf cfg.enable {
    # Create Multus CNI configuration
    environment.etc."cni/net.d/00-multus.conf" = {
      text = builtins.toJSON multusCniConfig;
      mode = "0644";
    };

    # Create directory for additional CNI configs
    systemd.tmpfiles.rules = [
      "d /etc/cni/multus/net.d 0755 root root -"
      "d /var/log/cni 0755 root root -"
    ];

    # Install Multus CNI binaries
    systemd.services.install-multus = {
      description = "Install Multus CNI plugin";
      after = [ "network.target" ];
      before = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
            # Download Multus CNI binary if not present
            MULTUS_VERSION="v4.0.2"
            CNI_BIN_DIR="/var/lib/rancher/k3s/data/current/bin"

            mkdir -p $CNI_BIN_DIR

            if [ ! -f "$CNI_BIN_DIR/multus" ]; then
              echo "Downloading Multus CNI binary..."
              ${pkgs.curl}/bin/curl -L -o /tmp/multus.tar.gz \
                "https://github.com/containernetworking/plugins/releases/download/$MULTUS_VERSION/cni-plugins-linux-amd64-$MULTUS_VERSION.tgz"

              ${pkgs.gnutar}/bin/tar -xzf /tmp/multus.tar.gz -C $CNI_BIN_DIR ./multus
              chmod +x $CNI_BIN_DIR/multus
              rm /tmp/multus.tar.gz

              echo "Multus CNI binary installed successfully"
            else
              echo "Multus CNI binary already exists"
            fi
          '
        '';
      };
    };

    # Deploy Multus as K3s manifest
    systemd.services.deploy-multus-manifest = mkIf (cfg.installMethod == "manifest") {
      description = "Deploy Multus CNI manifest to K3s";
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
            # Wait for K3s to be ready
            until ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; do
              echo "Waiting for K3s to be ready..."
              sleep 5
            done

            # Create Multus manifest
            cat > /var/lib/rancher/k3s/server/manifests/multus.yaml << EOF
            ---
            apiVersion: v1
            kind: ServiceAccount
            metadata:
              name: multus
              namespace: kube-system
            ---
            apiVersion: rbac.authorization.k8s.io/v1
            kind: ClusterRole
            metadata:
              name: multus
            rules:
              - apiGroups: ["k8s.cni.cncf.io"]
                resources:
                  - "*"
                verbs:
                  - "*"
              - apiGroups: [""]
                resources:
                  - pods
                  - pods/status
                verbs:
                  - get
                  - update
            ---
            apiVersion: rbac.authorization.k8s.io/v1
            kind: ClusterRoleBinding
            metadata:
              name: multus
            roleRef:
              apiGroup: rbac.authorization.k8s.io
              kind: ClusterRole
              name: multus
            subjects:
              - kind: ServiceAccount
                name: multus
                namespace: kube-system
            ---
            apiVersion: apps/v1
            kind: DaemonSet
            metadata:
              name: multus
              namespace: kube-system
              labels:
                app: multus
                name: multus
            spec:
              selector:
                matchLabels:
                  name: multus
              template:
                metadata:
                  labels:
                    app: multus
                    name: multus
                spec:
                  hostNetwork: true
                  hostPID: true
                  serviceAccountName: multus
                  containers:
                  - name: kube-multus
                    image: ghcr.io/k8snetworkplumbingwg/multus-cni:v4.0.2
                    command: ["/usr/src/multus-cni/bin/multus-daemon"]
                    args:
                    - "-cni-version=0.4.0"
                    - "-cni-config-dir=/etc/cni/net.d"
                    - "-multus-autoconfig-dir=/etc/cni/multus/net.d"
                    - "-multus-log-level=info"
                    - "-multus-log-file=/var/log/multus.log"
                    resources:
                      requests:
                        cpu: "100m"
                        memory: "50Mi"
                      limits:
                        cpu: "200m"
                        memory: "100Mi"
                    securityContext:
                      privileged: true
                    volumeMounts:
                    - name: cni
                      mountPath: /etc/cni
                    - name: cnibin
                      mountPath: /opt/cni/bin
                    - name: hostroot
                      mountPath: /hostroot
                      mountPropagation: HostToContainer
                  volumes:
                  - name: cni
                    hostPath:
                      path: /etc/cni
                  - name: cnibin
                    hostPath:
                      path: /var/lib/rancher/k3s/data/current/bin
                  - name: hostroot
                    hostPath:
                      path: /
            EOF

            echo "Multus manifest deployed"
          '
        '';
      };
    };

    # Create storage network attachment definition
    systemd.services.create-storage-network = mkIf cfg.storageNetwork.enable {
      description = "Create storage network attachment definition";
      after = [ "deploy-multus-manifest.service" ];
      requires = [ "deploy-multus-manifest.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
            # Wait for Multus to be ready
            until ${pkgs.kubectl}/bin/kubectl get crd networkattachmentdefinitions.k8s.cni.cncf.io &>/dev/null; do
              echo "Waiting for Multus CRD to be available..."
              sleep 5
            done

            # Create storage network attachment
            cat > /tmp/storage-network.yaml << EOF
            ${builtins.toJSON storageNetworkAttachment}
            EOF

            ${pkgs.kubectl}/bin/kubectl apply -f /tmp/storage-network.yaml
            rm /tmp/storage-network.yaml

            echo "Storage network attachment created"
          '
        '';
      };
    };

    # Add network debugging tools
    environment.systemPackages = with pkgs; [
      bridge-utils
      ethtool
      tcpdump
    ];

    # Aliases for checking Multus status
    environment.shellAliases = {
      multus-logs = "journalctl -u deploy-multus-manifest -f";
      multus-pods = "kubectl get pods -n kube-system -l name=multus";
      multus-nets = "kubectl get network-attachment-definitions -A";
    };
  };
}