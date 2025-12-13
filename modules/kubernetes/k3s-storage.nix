{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.n3x.k3s-storage;
in
{
  options.services.n3x.k3s-storage = {
    enable = mkEnableOption "K3s storage stack with Kyverno and Longhorn";

    enableLonghorn = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Longhorn distributed storage";
    };

    enableStorageNetwork = mkOption {
      type = types.bool;
      default = false;
      description = "Enable dedicated storage network for Longhorn traffic";
    };

    storageNetworkCIDR = mkOption {
      type = types.str;
      default = "192.168.20.0/24";
      description = "CIDR for storage network";
    };
  };

  config = mkIf cfg.enable {
    # Enable Kyverno for Longhorn PATH patching
    services.n3x.kyverno = {
      enable = true;
      autoApply = true;
    };

    # Enable Longhorn if requested
    services.n3x.longhorn = mkIf cfg.enableLonghorn {
      enable = true;
      defaultStorageClass = true;
      defaultReplicaCount = 3;

      # Configure storage network if enabled
      storageNetwork = mkIf cfg.enableStorageNetwork {
        enable = true;
        cidr = cfg.storageNetworkCIDR;
      };

      # Performance settings for edge deployments
      performance = {
        guaranteedEngineManagerCPU = 12; # 0.12 CPU
        guaranteedReplicaManagerCPU = 12; # 0.12 CPU
      };

      # Data locality for edge performance
      dataLocality = "best-effort";
    };

    # Add manifest for installing Multus CNI if storage network is enabled
    services.k3s.manifests = mkIf cfg.enableStorageNetwork {
      "00-multus-install" = {
        enable = true;
        content = ''
          apiVersion: v1
          kind: Namespace
          metadata:
            name: kube-system
          ---
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: multus-installer
            namespace: kube-system
          ---
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRoleBinding
          metadata:
            name: multus-installer
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: cluster-admin
          subjects:
          - kind: ServiceAccount
            name: multus-installer
            namespace: kube-system
          ---
          apiVersion: batch/v1
          kind: Job
          metadata:
            name: multus-installer
            namespace: kube-system
          spec:
            template:
              spec:
                serviceAccountName: multus-installer
                containers:
                - name: installer
                  image: bitnami/kubectl:latest
                  command:
                  - /bin/sh
                  - -c
                  - |
                    # Install Multus CNI
                    echo "Installing Multus CNI..."
                    kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

                    # Wait for Multus to be ready
                    echo "Waiting for Multus DaemonSet..."
                    kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=300s

                    echo "Multus CNI installation complete"
                restartPolicy: OnFailure
        '';
      };
    };

    # Helper scripts for storage management
    environment.systemPackages = [
      (pkgs.writeScriptBin "k3s-storage-status" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "K3s Storage Stack Status"
        echo "========================"
        echo ""

        # Check Kyverno
        echo "Kyverno Status:"
        echo "---------------"
        if kubectl get deployment -n kyverno kyverno-admission-controller &> /dev/null; then
          echo "✓ Kyverno is installed"
          kubectl get clusterpolicies | grep longhorn || echo "  ⚠ No Longhorn policies found"
        else
          echo "✗ Kyverno not installed"
        fi
        echo ""

        # Check Multus if enabled
        ${optionalString cfg.enableStorageNetwork ''
        echo "Multus CNI Status:"
        echo "-----------------"
        if kubectl get daemonset -n kube-system multus &> /dev/null; then
          echo "✓ Multus is installed"
          kubectl get network-attachment-definitions -A 2>/dev/null || echo "  ⚠ No network attachments found"
        else
          echo "✗ Multus not installed"
        fi
        echo ""
        ''}

        # Check Longhorn
        echo "Longhorn Status:"
        echo "----------------"
        if kubectl get namespace longhorn-system &> /dev/null; then
          echo "✓ Longhorn namespace exists"

          # Check deployments
          echo "  Deployments:"
          kubectl get deployments -n longhorn-system --no-headers | while read line; do
            name=$(echo $line | awk '{print $1}')
            ready=$(echo $line | awk '{print $2}')
            echo "    - $name: $ready"
          done

          # Check storage class
          echo "  Storage Classes:"
          kubectl get storageclass | grep longhorn || echo "    ⚠ No Longhorn storage class found"

          # Check volumes
          volumeCount=$(kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l)
          echo "    - Volumes: $volumeCount"
        else
          echo "✗ Longhorn not installed"
        fi
      '')

      (pkgs.writeScriptBin "k3s-storage-test" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Testing K3s Storage Stack"
        echo "========================="
        echo ""

        # Test Kyverno policy
        echo "1. Testing Kyverno PATH patching..."
        cat <<EOF | kubectl apply -f - --dry-run=server
        apiVersion: v1
        kind: Pod
        metadata:
          name: test-pod
          namespace: longhorn-system
        spec:
          containers:
          - name: test
            image: busybox
            command: ["sleep", "3600"]
        EOF

        if [ $? -eq 0 ]; then
          echo "✓ Kyverno policy validation passed"
        else
          echo "✗ Kyverno policy validation failed"
        fi
        echo ""

        # Test Longhorn volume creation
        echo "2. Testing Longhorn volume creation..."
        cat <<EOF | kubectl apply -f -
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: test-storage-pvc
          namespace: default
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: longhorn
          resources:
            requests:
              storage: 100Mi
        EOF

        echo "Waiting for PVC to be bound..."
        kubectl wait --for=condition=bound pvc/test-storage-pvc -n default --timeout=60s

        if [ $? -eq 0 ]; then
          echo "✓ Storage volume created successfully"
        else
          echo "✗ Failed to create storage volume"
        fi

        # Cleanup
        echo ""
        echo "Cleaning up test resources..."
        kubectl delete pvc test-storage-pvc -n default
        echo "Test complete!"
      '')
    ];
  };
}
