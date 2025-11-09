#!/usr/bin/env bash
# VM Testing Script for n3x
# This script helps run various VM tests for the n3x cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to run a test
run_test() {
    local test_name=$1
    local test_command=$2

    print_status "$YELLOW" "Running test: $test_name"

    if eval "$test_command"; then
        print_status "$GREEN" "✓ Test passed: $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        print_status "$RED" "✗ Test failed: $test_name"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Function to build VM configuration
build_vm() {
    local vm_name=$1
    print_status "$YELLOW" "Building VM: $vm_name"

    if nix build ".#nixosConfigurations.$vm_name.config.system.build.vm" --no-link --print-out-paths; then
        print_status "$GREEN" "✓ Successfully built VM: $vm_name"
        return 0
    else
        print_status "$RED" "✗ Failed to build VM: $vm_name"
        return 1
    fi
}

# Main test execution
main() {
    print_status "$GREEN" "==================================="
    print_status "$GREEN" "n3x VM Testing Suite"
    print_status "$GREEN" "==================================="

    # Check if we're in the right directory
    if [[ ! -f "flake.nix" ]]; then
        print_status "$RED" "Error: flake.nix not found. Please run this script from the n3x root directory."
        exit 1
    fi

    # Parse command line arguments
    case "${1:-all}" in
        server)
            print_status "$YELLOW" "Testing K3s server VM..."
            run_test "K3s Server VM Build" "build_vm vm-k3s-server"
            ;;

        agent)
            print_status "$YELLOW" "Testing K3s agent VM..."
            run_test "K3s Agent VM Build" "build_vm vm-k3s-agent"
            ;;

        cluster)
            print_status "$YELLOW" "Testing multi-node cluster..."
            run_test "Control Plane VM Build" "build_vm vm-control-plane"
            run_test "Worker 1 VM Build" "build_vm vm-worker-1"
            run_test "Worker 2 VM Build" "build_vm vm-worker-2"
            ;;

        interactive)
            print_status "$YELLOW" "Starting interactive VM session..."
            print_status "$YELLOW" "Choose VM to run:"
            echo "1) K3s Server"
            echo "2) K3s Agent"
            echo "3) Basic Test VM"
            read -p "Enter choice (1-3): " choice

            case $choice in
                1)
                    VM_PATH=$(nix build ".#nixosConfigurations.vm-k3s-server.config.system.build.vm" --no-link --print-out-paths)
                    print_status "$GREEN" "Starting K3s server VM..."
                    print_status "$YELLOW" "Access with: ssh -p 2222 root@localhost (password: test)"
                    "$VM_PATH/bin/run-vm-k3s-server-vm"
                    ;;
                2)
                    VM_PATH=$(nix build ".#nixosConfigurations.vm-k3s-agent.config.system.build.vm" --no-link --print-out-paths)
                    print_status "$GREEN" "Starting K3s agent VM..."
                    print_status "$YELLOW" "Access with: ssh -p 2222 root@localhost (password: test)"
                    "$VM_PATH/bin/run-vm-k3s-agent-vm"
                    ;;
                3)
                    VM_PATH=$(nix build ".#nixosConfigurations.vm-test.config.system.build.vm" --no-link --print-out-paths)
                    print_status "$GREEN" "Starting basic test VM..."
                    print_status "$YELLOW" "Access with: ssh -p 2222 root@localhost (password: test)"
                    "$VM_PATH/bin/run-vm-test-vm"
                    ;;
                *)
                    print_status "$RED" "Invalid choice"
                    exit 1
                    ;;
            esac
            ;;

        all|*)
            print_status "$YELLOW" "Running all VM tests..."
            run_test "K3s Server VM Build" "build_vm vm-k3s-server" || true
            run_test "K3s Agent VM Build" "build_vm vm-k3s-agent" || true
            run_test "Basic Test VM Build" "build_vm vm-test" || true
            ;;
    esac

    # Print test summary
    echo
    print_status "$GREEN" "==================================="
    print_status "$GREEN" "Test Results Summary"
    print_status "$GREEN" "==================================="
    print_status "$GREEN" "Tests passed: $TESTS_PASSED"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        print_status "$RED" "Tests failed: $TESTS_FAILED"
        exit 1
    else
        print_status "$GREEN" "All tests passed!"
    fi
}

# Show usage information
usage() {
    cat << EOF
Usage: $0 [OPTION]

Run VM tests for the n3x cluster configuration.

Options:
    server       Build and test K3s server VM
    agent        Build and test K3s agent VM
    cluster      Build and test multi-node cluster VMs
    interactive  Start an interactive VM session
    all          Run all tests (default)
    help         Show this help message

Examples:
    $0                  # Run all tests
    $0 server           # Test only the server VM
    $0 interactive      # Start an interactive VM session

EOF
}

# Handle help flag
if [[ "${1:-}" == "help" ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

# Run main function
main "$@"