# K3s Manifests for n3x

This directory contains Kubernetes manifests for the n3x storage stack.

## Deployment Order

The manifests must be deployed in the following order for proper operation:

### 1. Install Kyverno (Required for Longhorn on NixOS)

```bash
# Install Kyverno from official release
kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml

# Wait for Kyverno to be ready
kubectl wait --for=condition=available --timeout=300s \
  deployment/kyverno-admission-controller -n kyverno

# Apply NixOS-specific policies for Longhorn
kubectl apply -f kyverno-policies.yaml
```

### 2. Install Multus CNI (Optional - for storage network separation)

```bash
# Install Multus CNI
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

# Wait for Multus to be ready
kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=300s

# Apply storage network configuration
kubectl apply -f storage-network.yaml
```

### 3. Install Longhorn

```bash
# Add Longhorn Helm repository
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --version 1.5.3 \
  --set defaultSettings.defaultReplicaCount=3 \
  --set defaultSettings.dataLocality="best-effort"

# Wait for Longhorn to be ready
kubectl wait --for=condition=available --timeout=600s \
  deployment/longhorn-ui -n longhorn-system
```

## Verification

### Check Kyverno Policies

```bash
# List all cluster policies
kubectl get clusterpolicies

# Verify Longhorn PATH patching policy
kubectl describe clusterpolicy add-path-to-longhorn
```

### Check Longhorn Status

```bash
# Check Longhorn components
kubectl get all -n longhorn-system

# Check if Longhorn pods have correct PATH
kubectl exec -n longhorn-system deployment/longhorn-manager -- printenv PATH

# Verify storage class
kubectl get storageclass longhorn
```

### Test Storage

```bash
# Create a test PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF

# Check PVC status
kubectl get pvc test-pvc

# Clean up
kubectl delete pvc test-pvc
```

## Troubleshooting

### Kyverno Issues

```bash
# Check Kyverno logs
kubectl logs -n kyverno deployment/kyverno-admission-controller

# Check policy violations
kubectl get polr -A
```

### Longhorn Issues

```bash
# Check Longhorn manager logs
kubectl logs -n longhorn-system deployment/longhorn-manager

# Check node status
kubectl get nodes.longhorn.io -n longhorn-system

# Check volume status
kubectl get volumes.longhorn.io -n longhorn-system
```

### Storage Network Issues

```bash
# Check Multus configuration
kubectl get network-attachment-definitions -A

# Check pod network interfaces
kubectl exec -n longhorn-system deployment/longhorn-manager -- ip addr
```

## Important Notes

1. **NixOS Compatibility**: The Kyverno policies are essential for Longhorn to work on NixOS. Without them, Longhorn pods will fail to find required binaries.

2. **Kernel Modules**: Ensure the following kernel modules are loaded on all nodes:
   - `iscsi_tcp`
   - `dm_crypt`
   - `overlay`

3. **Storage Path**: By default, Longhorn uses `/var/lib/longhorn` for storage. Ensure this path exists and has sufficient space on all nodes.

4. **Network Separation**: The storage network configuration is optional but recommended for production deployments to isolate storage traffic from cluster traffic.

## Files in this Directory

- `kyverno-policies.yaml` - Kyverno policies for NixOS compatibility
- `storage-network.yaml` - Multus NetworkAttachmentDefinition for storage network
- `README.md` - This documentation file