{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.n3x.kyverno;

  # Kyverno ClusterPolicy for patching Longhorn pods with NixOS paths
  longhornPathPolicy = ''
    apiVersion: kyverno.io/v1
    kind: ClusterPolicy
    metadata:
      name: add-path-to-longhorn
      annotations:
        policies.kyverno.io/title: Add PATH to Longhorn System Pods
        policies.kyverno.io/category: NixOS Compatibility
        policies.kyverno.io/severity: high
        policies.kyverno.io/subject: Pod
        policies.kyverno.io/description: |
          This policy adds the NixOS PATH environment variable to all pods
          in the longhorn-system namespace. This is required because Longhorn
          expects FHS paths like /usr/bin/env, but NixOS uses /nix/store paths.
          Without this patch, Longhorn pods will fail to execute required binaries.
    spec:
      background: false
      rules:
        - name: add-nixos-path
          match:
            any:
            - resources:
                kinds:
                - Pod
                namespaces:
                - longhorn-system
          mutate:
            patchStrategicMerge:
              spec:
                containers:
                - name: "*"
                  env:
                  - name: PATH
                    value: "/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
  '';

  # Additional policy for ensuring Longhorn has access to required kernel modules
  longhornKernelModulesPolicy = ''
    apiVersion: kyverno.io/v1
    kind: ClusterPolicy
    metadata:
      name: longhorn-kernel-modules
      annotations:
        policies.kyverno.io/title: Ensure Longhorn Kernel Module Access
        policies.kyverno.io/category: Storage
        policies.kyverno.io/severity: high
        policies.kyverno.io/subject: Pod
        policies.kyverno.io/description: |
          Ensures Longhorn pods have the necessary volume mounts and
          security context to access kernel modules required for iSCSI
          and other storage operations on NixOS.
    spec:
      background: false
      rules:
        - name: add-kernel-module-access
          match:
            any:
            - resources:
                kinds:
                - Pod
                namespaces:
                - longhorn-system
                selector:
                  matchLabels:
                    app: longhorn-manager
          mutate:
            patchStrategicMerge:
              spec:
                containers:
                - name: "longhorn-manager"
                  volumeMounts:
                  - name: kernel-modules
                    mountPath: /lib/modules
                    readOnly: true
                volumes:
                - name: kernel-modules
                  hostPath:
                    path: /run/current-system/kernel-modules/lib/modules
                    type: Directory
  '';

  # Kyverno installation manifest
  kyvernoManifest = pkgs.writeTextFile {
    name = "kyverno-manifest.yaml";
    text = ''
      # This manifest should be applied before Longhorn installation
      # kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
      ---
      ${longhornPathPolicy}
      ---
      ${longhornKernelModulesPolicy}
    '';
  };

in
{
  options.services.n3x.kyverno = {
    enable = mkEnableOption "Kyverno policy engine for Longhorn compatibility";

    autoApply = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Automatically apply Kyverno policies during k3s startup.
        This ensures policies are in place before Longhorn installation.
      '';
    };

    policies = mkOption {
      type = types.listOf types.str;
      default = [ longhornPathPolicy longhornKernelModulesPolicy ];
      description = ''
        List of additional Kyverno policies to apply.
        Default includes Longhorn PATH patching and kernel module access.
      '';
    };

    namespace = mkOption {
      type = types.str;
      default = "kyverno";
      description = "Namespace for Kyverno installation";
    };
  };

  config = mkIf cfg.enable {
    # Ensure k3s is configured
    assertions = [
      {
        assertion = config.services.k3s.enable;
        message = "Kyverno requires k3s to be enabled";
      }
    ];

    # Add Kyverno manifests to k3s
    services.k3s.manifests = mkIf cfg.autoApply {
      # Install Kyverno first
      "00-kyverno-install" = {
        enable = true;
        content = ''
          apiVersion: v1
          kind: Namespace
          metadata:
            name: ${cfg.namespace}
          ---
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: kyverno-installer
            namespace: kube-system
          ---
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRoleBinding
          metadata:
            name: kyverno-installer
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: cluster-admin
          subjects:
          - kind: ServiceAccount
            name: kyverno-installer
            namespace: kube-system
          ---
          apiVersion: batch/v1
          kind: Job
          metadata:
            name: kyverno-installer
            namespace: kube-system
          spec:
            template:
              spec:
                serviceAccountName: kyverno-installer
                containers:
                - name: installer
                  image: bitnami/kubectl:latest
                  command:
                  - /bin/sh
                  - -c
                  - |
                    # Wait for k3s API to be ready
                    until kubectl get nodes; do
                      echo "Waiting for k3s API..."
                      sleep 5
                    done

                    # Install Kyverno
                    echo "Installing Kyverno..."
                    kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml

                    # Wait for Kyverno to be ready
                    echo "Waiting for Kyverno deployment..."
                    kubectl wait --for=condition=available --timeout=300s deployment/kyverno-admission-controller -n ${cfg.namespace}
                    kubectl wait --for=condition=available --timeout=300s deployment/kyverno-background-controller -n ${cfg.namespace}
                    kubectl wait --for=condition=available --timeout=300s deployment/kyverno-cleanup-controller -n ${cfg.namespace}
                    kubectl wait --for=condition=available --timeout=300s deployment/kyverno-reports-controller -n ${cfg.namespace}

                    echo "Kyverno installation complete"
                restartPolicy: OnFailure
        '';
      };

      # Apply Longhorn compatibility policies
      "01-kyverno-longhorn-policies" = {
        enable = true;
        content = ''
          ${concatStringsSep "\n---\n" cfg.policies}
        '';
      };
    };

    # Create a script for manual policy application
    environment.systemPackages = [
      (pkgs.writeScriptBin "apply-kyverno-policies" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Applying Kyverno policies for Longhorn..."

        # Check if kubectl is available
        if ! command -v kubectl &> /dev/null; then
          echo "kubectl not found. Please ensure k3s is running."
          exit 1
        fi

        # Check if Kyverno is installed
        if ! kubectl get deployment -n ${cfg.namespace} kyverno-admission-controller &> /dev/null; then
          echo "Kyverno not found. Installing..."
          kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml

          echo "Waiting for Kyverno to be ready..."
          kubectl wait --for=condition=available --timeout=300s deployment/kyverno-admission-controller -n ${cfg.namespace}
        fi

        # Apply policies
        cat <<'EOF' | kubectl apply -f -
        ${concatStringsSep "\n---\n" cfg.policies}
        EOF

        echo "Kyverno policies applied successfully"

        # Verify policies
        echo "Verifying policies..."
        kubectl get clusterpolicies
      '')

      (pkgs.writeScriptBin "verify-longhorn-compatibility" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Verifying Longhorn compatibility on NixOS..."

        # Check kernel modules
        echo "Checking required kernel modules..."
        for module in iscsi_tcp dm_crypt overlay; do
          if lsmod | grep -q "^$module"; then
            echo "✓ $module loaded"
          else
            echo "✗ $module not loaded - run: sudo modprobe $module"
          fi
        done

        # Check Kyverno policies
        echo ""
        echo "Checking Kyverno policies..."
        if kubectl get clusterpolicy add-path-to-longhorn &> /dev/null; then
          echo "✓ PATH patching policy exists"
        else
          echo "✗ PATH patching policy missing"
        fi

        if kubectl get clusterpolicy longhorn-kernel-modules &> /dev/null; then
          echo "✓ Kernel modules policy exists"
        else
          echo "✗ Kernel modules policy missing"
        fi

        # Check if Longhorn pods have correct PATH
        if kubectl get pods -n longhorn-system &> /dev/null; then
          echo ""
          echo "Checking Longhorn pod environment..."
          for pod in $(kubectl get pods -n longhorn-system -o name); do
            podname=$(basename $pod)
            if kubectl exec -n longhorn-system $podname -- printenv PATH | grep -q "/run/current-system/sw/bin"; then
              echo "✓ $podname has NixOS PATH"
            else
              echo "✗ $podname missing NixOS PATH"
            fi
          done
        else
          echo ""
          echo "ℹ Longhorn not yet installed"
        fi
      '')
    ];

    # Documentation
    environment.etc."n3x/kyverno-policies.yaml".source = kyvernoManifest;
  };
}
