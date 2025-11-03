#!/usr/bin/env bash

# n3x Storage Stack Deployment Script
# Deploys Kyverno and Longhorn for distributed storage on NixOS k3s clusters

set -euo pipefail

# Configuration
KYVERNO_VERSION="${KYVERNO_VERSION:-latest}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.5.3}"
MULTUS_ENABLED="${MULTUS_ENABLED:-false}"
STORAGE_NETWORK_CIDR="${STORAGE_NETWORK_CIDR:-192.168.20.0/24}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed or not in PATH"
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Is k3s running?"
        exit 1
    fi

    # Check if running on NixOS
    if [ -f /etc/os-release ]; then
        if grep -q "ID=nixos" /etc/os-release; then
            log_success "Running on NixOS - PATH patching will be applied"
        else
            log_warning "Not running on NixOS - PATH patching may not be needed"
        fi
    fi

    log_success "Prerequisites check passed"
}

# Install Kyverno
install_kyverno() {
    log_info "Installing Kyverno..."

    # Check if Kyverno is already installed
    if kubectl get namespace kyverno &> /dev/null; then
        log_warning "Kyverno namespace already exists, skipping installation"
    else
        # Install Kyverno
        kubectl apply -f "https://github.com/kyverno/kyverno/releases/${KYVERNO_VERSION}/download/install.yaml"

        # Wait for Kyverno to be ready
        log_info "Waiting for Kyverno to be ready..."
        kubectl wait --for=condition=available --timeout=300s \
            deployment/kyverno-admission-controller -n kyverno
        kubectl wait --for=condition=available --timeout=300s \
            deployment/kyverno-background-controller -n kyverno
        kubectl wait --for=condition=available --timeout=300s \
            deployment/kyverno-cleanup-controller -n kyverno
        kubectl wait --for=condition=available --timeout=300s \
            deployment/kyverno-reports-controller -n kyverno

        log_success "Kyverno installed successfully"
    fi

    # Apply NixOS-specific policies
    log_info "Applying Kyverno policies for Longhorn on NixOS..."

    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

    if [ -f "${MANIFEST_DIR}/kyverno-policies.yaml" ]; then
        kubectl apply -f "${MANIFEST_DIR}/kyverno-policies.yaml"
        log_success "Kyverno policies applied"
    else
        log_warning "kyverno-policies.yaml not found, creating inline..."
        kubectl apply -f - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-path-to-longhorn
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
EOF
        log_success "Basic Kyverno policy applied"
    fi
}

# Install Multus CNI (optional)
install_multus() {
    if [ "$MULTUS_ENABLED" != "true" ]; then
        log_info "Multus CNI installation skipped (MULTUS_ENABLED=$MULTUS_ENABLED)"
        return
    fi

    log_info "Installing Multus CNI for storage network separation..."

    # Check if Multus is already installed
    if kubectl get daemonset -n kube-system kube-multus-ds &> /dev/null; then
        log_warning "Multus already installed, skipping"
    else
        # Install Multus
        kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

        # Wait for Multus to be ready
        log_info "Waiting for Multus to be ready..."
        kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=300s

        log_success "Multus CNI installed successfully"
    fi

    # Apply storage network configuration
    log_info "Configuring storage network..."
    kubectl apply -f - <<EOF
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
      "master": "bond0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "${STORAGE_NETWORK_CIDR}",
        "rangeStart": "192.168.20.10",
        "rangeEnd": "192.168.20.250"
      }
    }
EOF
    log_success "Storage network configured"
}

# Install Longhorn
install_longhorn() {
    log_info "Installing Longhorn distributed storage..."

    # Add Longhorn Helm repository
    helm repo add longhorn https://charts.longhorn.io
    helm repo update

    # Check if Longhorn is already installed
    if helm list -n longhorn-system | grep -q longhorn; then
        log_warning "Longhorn already installed, upgrading..."
        HELM_COMMAND="upgrade"
    else
        HELM_COMMAND="install"
    fi

    # Prepare Helm values
    HELM_VALUES=""

    # Add storage network configuration if Multus is enabled
    if [ "$MULTUS_ENABLED" == "true" ]; then
        HELM_VALUES="$HELM_VALUES --set defaultSettings.storageNetwork=${STORAGE_NETWORK_CIDR}"
    fi

    # Install/Upgrade Longhorn
    helm $HELM_COMMAND longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --create-namespace \
        --version ${LONGHORN_VERSION} \
        --wait \
        --timeout 10m \
        --set defaultSettings.defaultReplicaCount=3 \
        --set defaultSettings.dataLocality="best-effort" \
        --set csi.kubeletRootDir="/var/lib/kubelet" \
        --set defaultSettings.guaranteedEngineManagerCPU=12 \
        --set defaultSettings.guaranteedReplicaManagerCPU=12 \
        $HELM_VALUES

    log_success "Longhorn installed successfully"
}

# Verify installation
verify_installation() {
    log_info "Verifying storage stack installation..."

    # Check Kyverno policies
    echo ""
    log_info "Kyverno Policies:"
    kubectl get clusterpolicies | grep longhorn || log_warning "No Longhorn policies found"

    # Check Longhorn status
    echo ""
    log_info "Longhorn Status:"
    kubectl get deployments -n longhorn-system

    # Check storage class
    echo ""
    log_info "Storage Classes:"
    kubectl get storageclass | grep longhorn || log_warning "No Longhorn storage class found"

    # Test volume creation
    echo ""
    log_info "Testing volume creation..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-storage-stack-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 100Mi
EOF

    # Wait for PVC to be bound
    if kubectl wait --for=condition=bound pvc/test-storage-stack-pvc -n default --timeout=60s &> /dev/null; then
        log_success "Test PVC created and bound successfully"
        kubectl delete pvc test-storage-stack-pvc -n default
    else
        log_error "Test PVC failed to bind"
        kubectl describe pvc test-storage-stack-pvc -n default
        kubectl delete pvc test-storage-stack-pvc -n default
    fi
}

# Uninstall function
uninstall_storage_stack() {
    log_warning "Uninstalling storage stack..."

    read -p "This will remove Longhorn and all data. Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        exit 0
    fi

    # Uninstall Longhorn
    log_info "Uninstalling Longhorn..."
    helm uninstall longhorn -n longhorn-system || true
    kubectl delete namespace longhorn-system || true
    kubectl get crd | grep longhorn | awk '{print $1}' | xargs kubectl delete crd || true

    # Remove Kyverno policies
    log_info "Removing Kyverno policies..."
    kubectl delete clusterpolicy add-path-to-longhorn || true
    kubectl delete clusterpolicy longhorn-kernel-modules || true
    kubectl delete clusterpolicy longhorn-host-binaries || true

    # Optionally remove Kyverno
    read -p "Remove Kyverno as well? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete -f "https://github.com/kyverno/kyverno/releases/${KYVERNO_VERSION}/download/install.yaml" || true
    fi

    log_success "Storage stack uninstalled"
}

# Main function
main() {
    echo "================================================"
    echo "n3x Storage Stack Deployment"
    echo "================================================"
    echo ""

    # Parse command line arguments
    case "${1:-install}" in
        install)
            check_prerequisites
            install_kyverno
            install_multus
            install_longhorn
            verify_installation
            echo ""
            log_success "Storage stack deployment complete!"
            ;;
        uninstall)
            uninstall_storage_stack
            ;;
        verify)
            verify_installation
            ;;
        *)
            echo "Usage: $0 [install|uninstall|verify]"
            echo ""
            echo "Environment variables:"
            echo "  KYVERNO_VERSION    - Kyverno version (default: latest)"
            echo "  LONGHORN_VERSION   - Longhorn version (default: 1.5.3)"
            echo "  MULTUS_ENABLED     - Enable Multus CNI (default: false)"
            echo "  STORAGE_NETWORK_CIDR - Storage network CIDR (default: 192.168.20.0/24)"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"