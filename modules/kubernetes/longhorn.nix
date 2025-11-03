{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.n3x.longhorn;

  # Longhorn configuration for NixOS with storage network support
  longhornValues = ''
    defaultSettings:
      # Storage network configuration (if enabled)
      ${optionalString (cfg.storageNetwork.enable) ''
      storageNetwork: "${cfg.storageNetwork.cidr}"
      ''}

      # Default replica count
      defaultReplicaCount: ${toString cfg.defaultReplicaCount}

      # Backup target (optional)
      ${optionalString (cfg.backupTarget != null) ''
      backupTarget: "${cfg.backupTarget}"
      ''}

      # Performance optimizations
      guaranteedEngineManagerCPU: ${toString cfg.performance.guaranteedEngineManagerCPU}
      guaranteedReplicaManagerCPU: ${toString cfg.performance.guaranteedReplicaManagerCPU}

      # Data locality settings
      dataLocality: "${cfg.dataLocality}"

      # Auto salvage and deletion settings
      autoSalvage: ${boolToString cfg.autoSalvage}
      autoDeletePodWhenVolumeDetachedUnexpectedly: ${boolToString cfg.autoDeletePodWhenVolumeDetachedUnexpectedly}

      # Node drain policy
      nodeDrainPolicy: "${cfg.nodeDrainPolicy}"

      # Snapshot and backup settings
      snapshotDataIntegrity: "${cfg.snapshotDataIntegrity}"

    persistence:
      # Default storage class configuration
      defaultClass: ${boolToString cfg.defaultStorageClass}
      defaultClassReplicaCount: ${toString cfg.defaultReplicaCount}
      reclaimPolicy: "${cfg.reclaimPolicy}"

    csi:
      # CSI driver configuration
      kubeletRootDir: "/var/lib/kubelet"

    longhornManager:
      # Resource limits for manager
      priorityClass: "system-cluster-critical"
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"

    longhornDriver:
      # Driver configuration
      priorityClass: "system-node-critical"
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
  '';

  # Longhorn installation manifest
  longhornManifest = pkgs.writeTextFile {
    name = "longhorn-manifest.yaml";
    text = ''
      apiVersion: v1
      kind: Namespace
      metadata:
        name: longhorn-system
      ---
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: longhorn-installer
        namespace: kube-system
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: longhorn-installer
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: cluster-admin
      subjects:
      - kind: ServiceAccount
        name: longhorn-installer
        namespace: kube-system
      ---
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: longhorn-installer
        namespace: kube-system
      spec:
        template:
          spec:
            serviceAccountName: longhorn-installer
            containers:
            - name: installer
              image: alpine/helm:latest
              command:
              - /bin/sh
              - -c
              - |
                # Wait for k3s and Kyverno to be ready
                apk add --no-cache curl
                until curl -k https://kubernetes.default.svc/healthz; do
                  echo "Waiting for k3s API..."
                  sleep 5
                done

                # Add Longhorn Helm repository
                helm repo add longhorn https://charts.longhorn.io
                helm repo update

                # Install Longhorn with NixOS-specific values
                helm upgrade --install longhorn longhorn/longhorn \
                  --namespace longhorn-system \
                  --create-namespace \
                  --version ${cfg.version} \
                  --wait \
                  --timeout 10m \
                  --values /etc/longhorn/values.yaml

                echo "Longhorn installation complete"
            volumeMounts:
            - name: values
              mountPath: /etc/longhorn
              readOnly: true
            volumes:
            - name: values
              configMap:
                name: longhorn-values
            restartPolicy: OnFailure
      ---
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: longhorn-values
        namespace: kube-system
      data:
        values.yaml: |
          ${longhornValues}
    '';
  };

  # Storage network configuration for Multus CNI
  storageNetworkAttachment = ''
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
    metadata:
      name: longhorn-storage-network
      namespace: longhorn-system
    spec:
      config: |
        {
          "cniVersion": "0.3.1",
          "type": "macvlan",
          "master": "${cfg.storageNetwork.interface}",
          "mode": "bridge",
          "ipam": {
            "type": "host-local",
            "subnet": "${cfg.storageNetwork.cidr}",
            "rangeStart": "${cfg.storageNetwork.rangeStart}",
            "rangeEnd": "${cfg.storageNetwork.rangeEnd}"
          }
        }
  '';

in
{
  options.services.n3x.longhorn = {
    enable = mkEnableOption "Longhorn distributed block storage for Kubernetes";

    version = mkOption {
      type = types.str;
      default = "1.5.3";
      description = "Longhorn version to install";
    };

    defaultStorageClass = mkOption {
      type = types.bool;
      default = true;
      description = "Make Longhorn the default storage class";
    };

    defaultReplicaCount = mkOption {
      type = types.int;
      default = 3;
      description = "Default number of replicas for Longhorn volumes";
    };

    dataLocality = mkOption {
      type = types.enum [ "disabled" "best-effort" "strict-local" ];
      default = "best-effort";
      description = ''
        Data locality setting:
        - disabled: No data locality
        - best-effort: Try to keep data local
        - strict-local: Always keep data local
      '';
    };

    storageNetwork = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable dedicated storage network for Longhorn traffic";
      };

      interface = mkOption {
        type = types.str;
        default = "bond0";
        description = "Network interface for storage traffic";
      };

      cidr = mkOption {
        type = types.str;
        default = "192.168.20.0/24";
        description = "CIDR for storage network";
      };

      rangeStart = mkOption {
        type = types.str;
        default = "192.168.20.10";
        description = "Start of IP range for storage network";
      };

      rangeEnd = mkOption {
        type = types.str;
        default = "192.168.20.250";
        description = "End of IP range for storage network";
      };
    };

    backupTarget = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "nfs://192.168.1.100:/backup";
      description = "Backup target for Longhorn snapshots";
    };

    reclaimPolicy = mkOption {
      type = types.enum [ "Retain" "Delete" ];
      default = "Delete";
      description = "PersistentVolume reclaim policy";
    };

    autoSalvage = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically salvage failed replicas";
    };

    autoDeletePodWhenVolumeDetachedUnexpectedly = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically delete pods when volume is detached unexpectedly";
    };

    nodeDrainPolicy = mkOption {
      type = types.enum [ "block-if-contains-last-replica" "allow-if-replica-is-stopped" "always-allow" ];
      default = "block-if-contains-last-replica";
      description = "Node drain policy for Longhorn";
    };

    snapshotDataIntegrity = mkOption {
      type = types.enum [ "disabled" "enabled" "fast-check" ];
      default = "fast-check";
      description = "Snapshot data integrity check mode";
    };

    performance = {
      guaranteedEngineManagerCPU = mkOption {
        type = types.int;
        default = 12;
        description = "Guaranteed CPU percentage for engine manager (12 = 0.12 CPU)";
      };

      guaranteedReplicaManagerCPU = mkOption {
        type = types.int;
        default = 12;
        description = "Guaranteed CPU percentage for replica manager (12 = 0.12 CPU)";
      };
    };

    diskPath = mkOption {
      type = types.str;
      default = "/var/lib/longhorn";
      description = "Path where Longhorn stores data";
    };
  };

  config = mkIf cfg.enable {
    # Ensure required kernel modules are loaded
    boot.kernelModules = [ "iscsi_tcp" "dm_crypt" "overlay" ];

    # Ensure k3s and Kyverno are enabled
    assertions = [
      {
        assertion = config.services.k3s.enable;
        message = "Longhorn requires k3s to be enabled";
      }
      {
        assertion = config.services.n3x.kyverno.enable;
        message = "Longhorn on NixOS requires Kyverno for PATH patching";
      }
    ];

    # Enable Kyverno automatically when Longhorn is enabled
    services.n3x.kyverno.enable = true;

    # Create Longhorn data directory
    systemd.tmpfiles.rules = [
      "d ${cfg.diskPath} 0700 root root -"
    ];

    # Add Longhorn manifests to k3s
    services.k3s.manifests = {
      # Install Longhorn after Kyverno
      "02-longhorn-install" = {
        enable = true;
        content = longhornManifest;
      };

      # Configure storage network if enabled
      "03-longhorn-storage-network" = mkIf cfg.storageNetwork.enable {
        enable = true;
        content = storageNetworkAttachment;
      };
    };

    # Install helper scripts
    environment.systemPackages = [
      (pkgs.writeScriptBin "longhorn-status" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Longhorn Status Check"
        echo "===================="

        # Check if Longhorn is installed
        if ! kubectl get namespace longhorn-system &> /dev/null; then
          echo "Longhorn is not installed yet"
          exit 1
        fi

        echo "Deployments:"
        kubectl get deployments -n longhorn-system

        echo ""
        echo "DaemonSets:"
        kubectl get daemonsets -n longhorn-system

        echo ""
        echo "Volumes:"
        kubectl get volumes.longhorn.io -n longhorn-system

        echo ""
        echo "Nodes:"
        kubectl get nodes.longhorn.io -n longhorn-system

        echo ""
        echo "Storage Classes:"
        kubectl get storageclass | grep longhorn || true
      '')

      (pkgs.writeScriptBin "longhorn-test-volume" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Creating test PVC using Longhorn..."

        cat <<EOF | kubectl apply -f -
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: longhorn-test-pvc
          namespace: default
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: longhorn
          resources:
            requests:
              storage: 1Gi
        ---
        apiVersion: v1
        kind: Pod
        metadata:
          name: longhorn-test-pod
          namespace: default
        spec:
          containers:
          - name: test
            image: busybox
            command: ["sleep", "3600"]
            volumeMounts:
            - name: test-volume
              mountPath: /data
          volumes:
          - name: test-volume
            persistentVolumeClaim:
              claimName: longhorn-test-pvc
        EOF

        echo "Waiting for pod to be ready..."
        kubectl wait --for=condition=ready pod/longhorn-test-pod -n default --timeout=60s

        echo "Writing test data..."
        kubectl exec -n default longhorn-test-pod -- sh -c "echo 'Longhorn test successful' > /data/test.txt"

        echo "Reading test data..."
        kubectl exec -n default longhorn-test-pod -- cat /data/test.txt

        echo ""
        echo "Test completed successfully!"
        echo "To clean up, run: kubectl delete pod longhorn-test-pod -n default && kubectl delete pvc longhorn-test-pvc -n default"
      '')

      (pkgs.writeScriptBin "longhorn-uninstall" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Uninstalling Longhorn..."

        # Delete all Longhorn volumes
        kubectl delete volumes.longhorn.io --all -n longhorn-system || true

        # Uninstall using Helm
        helm uninstall longhorn -n longhorn-system || true

        # Delete namespace
        kubectl delete namespace longhorn-system || true

        # Clean up CRDs
        kubectl get crd | grep longhorn | awk '{print $1}' | xargs kubectl delete crd || true

        echo "Longhorn uninstalled"
      '')
    ];

    # Documentation
    environment.etc."n3x/longhorn-values.yaml".text = longhornValues;
  };
}