#!/usr/bin/env bash
# Deploy NixOS to bare-metal nodes using nixos-anywhere
# This script provides automated provisioning of nodes with proper disk partitioning

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
FLAKE="${PROJECT_ROOT}"

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <hostname> <target-ip>

Deploy NixOS configuration to a bare-metal node using nixos-anywhere.

Arguments:
  hostname      Node hostname (e.g., n100-1, jetson-1)
  target-ip     Target node IP address or hostname

Options:
  -h, --help          Show this help message
  -k, --ssh-key       SSH key to use for deployment (default: ~/.ssh/id_ed25519)
  -p, --port          SSH port (default: 22)
  -u, --user          SSH user for initial connection (default: root)
  --kexec-url         Custom kexec tarball URL (uses nixos-anywhere default if not specified)
  --no-reboot         Don't reboot after installation
  --debug             Enable debug output
  --dry-run           Show what would be done without making changes

Examples:
  # Deploy to n100-1 node
  $(basename "$0") n100-1 192.168.1.10

  # Deploy to jetson-1 with custom SSH key
  $(basename "$0") -k ~/.ssh/deploy_key jetson-1 jetson-1.local

  # Deploy with debug output
  $(basename "$0") --debug n100-2 192.168.1.11

  # Dry run to see what would be deployed
  $(basename "$0") --dry-run n100-3 192.168.1.12

Prerequisites:
  - Target node must be accessible via SSH
  - Target node should be booted into a live environment or existing Linux system
  - SSH key must be configured for passwordless access
  - nixos-anywhere must be installed (available in devShell)

Notes:
  - This script will COMPLETELY WIPE the target disk
  - Ensure you have backups of any important data
  - The deployment process takes approximately 10-20 minutes
  - Network configuration will be applied immediately after deployment

EOF
}

# Parse command line arguments
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PORT="22"
SSH_USER="root"
KEXEC_URL=""
NO_REBOOT=""
DEBUG=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -k|--ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        --kexec-url)
            KEXEC_URL="$2"
            shift 2
            ;;
        --no-reboot)
            NO_REBOOT="--no-reboot"
            shift
            ;;
        --debug)
            DEBUG="--debug"
            set -x
            shift
            ;;
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        -*)
            echo -e "${RED}Error: Unknown option $1${NC}"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Check remaining arguments
if [[ $# -ne 2 ]]; then
    echo -e "${RED}Error: Incorrect number of arguments${NC}"
    usage
    exit 1
fi

HOSTNAME="$1"
TARGET_IP="$2"

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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if nixos-anywhere is available
    if ! command -v nixos-anywhere &> /dev/null; then
        log_error "nixos-anywhere not found. Please enter the development shell:"
        echo "  nix develop"
        exit 1
    fi

    # Check if SSH key exists
    if [[ ! -f "$SSH_KEY" ]]; then
        log_error "SSH key not found: $SSH_KEY"
        exit 1
    fi

    # Check if flake configuration exists for hostname
    if [[ ! -f "${FLAKE}/hosts/${HOSTNAME}/configuration.nix" ]]; then
        log_error "No configuration found for hostname: ${HOSTNAME}"
        log_info "Available hosts:"
        ls -1 "${FLAKE}/hosts/" | sed 's/^/  - /'
        exit 1
    fi

    # Test SSH connectivity
    log_info "Testing SSH connectivity to ${TARGET_IP}..."
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
         -p "${SSH_PORT}" -i "${SSH_KEY}" \
         "${SSH_USER}@${TARGET_IP}" "echo 'SSH connection successful'" &> /dev/null; then
        log_error "Cannot connect to ${TARGET_IP} via SSH"
        log_info "Please ensure:"
        echo "  - The target node is powered on and accessible"
        echo "  - SSH is enabled on port ${SSH_PORT}"
        echo "  - The SSH key is authorized for user ${SSH_USER}"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Get node hardware type
get_hardware_type() {
    case "$HOSTNAME" in
        n100-*)
            echo "n100"
            ;;
        jetson-*)
            echo "jetson"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Build nixos-anywhere command
build_deploy_command() {
    local cmd="nixos-anywhere"

    # Add basic options
    cmd="$cmd --flake ${FLAKE}#${HOSTNAME}"
    cmd="$cmd --ssh-port ${SSH_PORT}"

    # Add SSH options
    cmd="$cmd --ssh-option StrictHostKeyChecking=no"
    cmd="$cmd --ssh-option UserKnownHostsFile=/dev/null"

    # Add optional parameters
    [[ -n "$KEXEC_URL" ]] && cmd="$cmd --kexec ${KEXEC_URL}"
    [[ -n "$NO_REBOOT" ]] && cmd="$cmd ${NO_REBOOT}"
    [[ -n "$DEBUG" ]] && cmd="$cmd ${DEBUG}"
    [[ -n "$DRY_RUN" ]] && cmd="$cmd ${DRY_RUN}"

    # Add target
    cmd="$cmd ${SSH_USER}@${TARGET_IP}"

    echo "$cmd"
}

# Display deployment summary
show_deployment_summary() {
    local hardware_type=$(get_hardware_type)

    echo ""
    echo "=========================================="
    echo "         DEPLOYMENT SUMMARY"
    echo "=========================================="
    echo "  Hostname:       ${HOSTNAME}"
    echo "  Target:         ${TARGET_IP}"
    echo "  Hardware Type:  ${hardware_type}"
    echo "  SSH User:       ${SSH_USER}"
    echo "  SSH Port:       ${SSH_PORT}"
    echo "  SSH Key:        ${SSH_KEY}"
    echo "  Flake:          ${FLAKE}"

    if [[ -n "$DRY_RUN" ]]; then
        echo "  Mode:           DRY RUN (no changes)"
    else
        echo "  Mode:           LIVE DEPLOYMENT"
    fi

    echo "=========================================="
    echo ""

    if [[ -z "$DRY_RUN" ]]; then
        log_warning "THIS WILL COMPLETELY WIPE THE TARGET DISK!"
        read -p "Are you sure you want to continue? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            log_info "Deployment cancelled by user"
            exit 0
        fi
    fi
}

# Main deployment function
deploy_node() {
    log_info "Starting deployment of ${HOSTNAME} to ${TARGET_IP}..."

    # Build deployment command
    local deploy_cmd=$(build_deploy_command)

    log_info "Deployment command:"
    echo "  $deploy_cmd"
    echo ""

    # Execute deployment
    if eval "$deploy_cmd"; then
        log_success "Deployment completed successfully!"

        if [[ -z "$NO_REBOOT" ]] && [[ -z "$DRY_RUN" ]]; then
            log_info "Node is rebooting into the new NixOS system..."
            log_info "You can monitor the node with:"
            echo "  ssh root@${TARGET_IP}"
        fi

        # Show post-deployment steps
        show_post_deployment_steps
    else
        log_error "Deployment failed!"
        exit 1
    fi
}

# Show post-deployment steps
show_post_deployment_steps() {
    local hardware_type=$(get_hardware_type)

    echo ""
    echo "=========================================="
    echo "       POST-DEPLOYMENT STEPS"
    echo "=========================================="
    echo ""
    echo "1. Wait for the node to complete rebooting (~2-3 minutes)"
    echo ""
    echo "2. Verify node is accessible:"
    echo "   ssh root@${TARGET_IP}"
    echo ""
    echo "3. Check system status:"
    echo "   systemctl status"
    echo ""
    echo "4. Verify k3s installation (if applicable):"

    case "$HOSTNAME" in
        n100-1|n100-2)
            echo "   kubectl get nodes  # Should show this node as Ready"
            echo "   kubectl get pods -A # Should show system pods running"
            ;;
        *)
            echo "   systemctl status k3s-agent"
            echo "   # The node should appear in cluster after server nodes are ready"
            ;;
    esac

    echo ""
    echo "5. Deploy remaining nodes:"
    echo "   Use this script to deploy other nodes in the cluster"
    echo ""

    if [[ "$hardware_type" == "jetson" ]]; then
        echo "Note: Jetson nodes may take longer to boot initially"
        echo "      Console access is via serial only (no HDMI)"
    fi

    echo "=========================================="
}

# Main execution
main() {
    # Change to project root
    cd "$PROJECT_ROOT"

    # Run prerequisite checks
    check_prerequisites

    # Show deployment summary and confirm
    show_deployment_summary

    # Deploy the node
    deploy_node
}

# Run main function
main