#!/usr/bin/env bash
# Deploy entire n3x cluster using nixos-anywhere or colmena
# This script orchestrates deployment of all nodes in the correct order

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-nixos-anywhere.sh"

# Default node configuration
declare -A NODES=(
    ["n100-1"]="192.168.1.10"
    ["n100-2"]="192.168.1.11"
    ["n100-3"]="192.168.1.12"
    ["jetson-1"]="192.168.1.20"
    ["jetson-2"]="192.168.1.21"
)

# Node deployment order (servers first, then agents)
DEPLOYMENT_ORDER=("n100-1" "n100-2" "n100-3" "jetson-1" "jetson-2")

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy the entire n3x cluster in the correct order.

Options:
  -h, --help          Show this help message
  -c, --config        Custom node configuration file
  -m, --method        Deployment method: 'nixos-anywhere' or 'colmena' (default: nixos-anywhere)
  -s, --skip          Skip specific nodes (comma-separated)
  -o, --only          Deploy only specific nodes (comma-separated)
  -k, --ssh-key       SSH key to use for deployment (default: ~/.ssh/id_ed25519)
  --parallel          Deploy nodes in parallel (colmena only)
  --dry-run           Show what would be done without making changes
  --verify            Verify cluster after deployment

Node Configuration:
  Default node IPs can be overridden with a configuration file:

  # nodes.conf
  n100-1=10.0.0.10
  n100-2=10.0.0.11
  n100-3=10.0.0.12
  jetson-1=10.0.0.20
  jetson-2=10.0.0.21

Examples:
  # Deploy entire cluster with default settings
  $(basename "$0")

  # Deploy only control plane nodes
  $(basename "$0") --only n100-1,n100-2

  # Skip jetson nodes
  $(basename "$0") --skip jetson-1,jetson-2

  # Deploy using colmena in parallel
  $(basename "$0") --method colmena --parallel

  # Dry run to see deployment plan
  $(basename "$0") --dry-run

  # Deploy and verify cluster health
  $(basename "$0") --verify

EOF
}

# Parse command line arguments
CONFIG_FILE=""
METHOD="nixos-anywhere"
SKIP_NODES=""
ONLY_NODES=""
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
PARALLEL=""
DRY_RUN=""
VERIFY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -m|--method)
            METHOD="$2"
            shift 2
            ;;
        -s|--skip)
            SKIP_NODES="$2"
            shift 2
            ;;
        -o|--only)
            ONLY_NODES="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        --verify)
            VERIFY="true"
            shift
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            usage
            exit 1
            ;;
    esac
done

# Function to print colored messages
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

# Load custom node configuration if provided
load_node_config() {
    if [[ -n "$CONFIG_FILE" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Configuration file not found: $CONFIG_FILE"
            exit 1
        fi

        log_info "Loading node configuration from $CONFIG_FILE"
        while IFS='=' read -r node ip; do
            # Skip comments and empty lines
            [[ "$node" =~ ^#.*$ || -z "$node" ]] && continue
            NODES["$node"]="$ip"
        done < "$CONFIG_FILE"
    fi
}

# Build list of nodes to deploy
build_deployment_list() {
    local deployment_list=()

    if [[ -n "$ONLY_NODES" ]]; then
        # Deploy only specified nodes
        IFS=',' read -ra only_array <<< "$ONLY_NODES"
        for node in "${only_array[@]}"; do
            if [[ -n "${NODES[$node]:-}" ]]; then
                deployment_list+=("$node")
            else
                log_warning "Node $node not found in configuration"
            fi
        done
    else
        # Deploy all nodes except skipped ones
        IFS=',' read -ra skip_array <<< "$SKIP_NODES"
        for node in "${DEPLOYMENT_ORDER[@]}"; do
            local skip=false
            for skip_node in "${skip_array[@]}"; do
                if [[ "$node" == "$skip_node" ]]; then
                    skip=true
                    break
                fi
            done

            if [[ "$skip" == false ]] && [[ -n "${NODES[$node]:-}" ]]; then
                deployment_list+=("$node")
            fi
        done
    fi

    echo "${deployment_list[@]}"
}

# Deploy using nixos-anywhere
deploy_with_nixos_anywhere() {
    local nodes=($1)

    for node in "${nodes[@]}"; do
        local ip="${NODES[$node]}"

        echo ""
        echo "=========================================="
        echo "Deploying $node at $ip"
        echo "=========================================="

        if [[ -n "$DRY_RUN" ]]; then
            log_info "DRY RUN: Would deploy $node to $ip"
        else
            if "$DEPLOY_SCRIPT" -k "$SSH_KEY" $DRY_RUN "$node" "$ip"; then
                log_success "Successfully deployed $node"

                # Wait before deploying next node
                if [[ "$node" != "${nodes[-1]}" ]]; then
                    log_info "Waiting 30 seconds before next deployment..."
                    sleep 30
                fi
            else
                log_error "Failed to deploy $node"
                read -p "Continue with remaining nodes? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        fi
    done
}

# Deploy using colmena
deploy_with_colmena() {
    local nodes=($1)
    local node_list=$(IFS=','; echo "${nodes[*]}")

    log_info "Deploying nodes with colmena: $node_list"

    cd "$PROJECT_ROOT"

    # Build colmena command
    local cmd="colmena apply"

    if [[ -n "$PARALLEL" ]]; then
        cmd="$cmd --parallel"
    fi

    if [[ -n "$DRY_RUN" ]]; then
        cmd="$cmd --dry-run"
    fi

    cmd="$cmd --on $node_list"

    log_info "Executing: $cmd"

    if eval "$cmd"; then
        log_success "Colmena deployment completed"
    else
        log_error "Colmena deployment failed"
        exit 1
    fi
}

# Verify cluster health
verify_cluster() {
    log_info "Verifying cluster health..."

    # Get first server node
    local server_node=""
    for node in n100-1 n100-2; do
        if [[ -n "${NODES[$node]:-}" ]]; then
            server_node="${NODES[$node]}"
            break
        fi
    done

    if [[ -z "$server_node" ]]; then
        log_warning "No server nodes found, skipping verification"
        return
    fi

    # Check k3s cluster status
    log_info "Checking k3s cluster status..."
    if ssh -i "$SSH_KEY" "root@$server_node" "kubectl get nodes" 2>/dev/null; then
        log_success "Cluster nodes are accessible"
    else
        log_warning "Unable to verify cluster status"
        return
    fi

    # Check system pods
    log_info "Checking system pods..."
    if ssh -i "$SSH_KEY" "root@$server_node" "kubectl get pods -A" 2>/dev/null; then
        log_success "System pods status retrieved"
    fi

    # Check Longhorn if deployed
    log_info "Checking Longhorn storage..."
    if ssh -i "$SSH_KEY" "root@$server_node" "kubectl get nodes -n longhorn-system" 2>/dev/null; then
        log_success "Longhorn is deployed"
    fi
}

# Show deployment summary
show_deployment_summary() {
    local nodes=($1)

    echo ""
    echo "=========================================="
    echo "         DEPLOYMENT PLAN"
    echo "=========================================="
    echo "  Method:         $METHOD"
    echo "  SSH Key:        $SSH_KEY"

    if [[ -n "$PARALLEL" ]]; then
        echo "  Mode:           Parallel"
    else
        echo "  Mode:           Sequential"
    fi

    if [[ -n "$DRY_RUN" ]]; then
        echo "  Type:           DRY RUN (no changes)"
    else
        echo "  Type:           LIVE DEPLOYMENT"
    fi

    echo ""
    echo "  Nodes to deploy:"
    for node in "${nodes[@]}"; do
        echo "    - $node (${NODES[$node]})"
    done

    echo "=========================================="
    echo ""

    if [[ -z "$DRY_RUN" ]]; then
        log_warning "This will deploy NixOS to the listed nodes"
        read -p "Continue with deployment? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            log_info "Deployment cancelled by user"
            exit 0
        fi
    fi
}

# Main execution
main() {
    # Load custom configuration if provided
    load_node_config

    # Build deployment list
    local nodes=($(build_deployment_list))

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_error "No nodes to deploy"
        exit 1
    fi

    # Show deployment summary
    show_deployment_summary "${nodes[*]}"

    # Deploy based on selected method
    case "$METHOD" in
        nixos-anywhere)
            deploy_with_nixos_anywhere "${nodes[*]}"
            ;;
        colmena)
            deploy_with_colmena "${nodes[*]}"
            ;;
        *)
            log_error "Unknown deployment method: $METHOD"
            exit 1
            ;;
    esac

    # Verify cluster if requested
    if [[ -n "$VERIFY" ]]; then
        log_info "Waiting 60 seconds for cluster to stabilize..."
        sleep 60
        verify_cluster
    fi

    log_success "Cluster deployment completed!"

    # Show next steps
    echo ""
    echo "Next steps:"
    echo "1. SSH into a server node: ssh root@${NODES[n100-1]}"
    echo "2. Check cluster status: kubectl get nodes"
    echo "3. Deploy storage stack: ${SCRIPT_DIR}/deploy-storage-stack.sh"
}

# Run main function
main