#!/usr/bin/env bash
# n3x test validation script
#
# This script ALWAYS re-runs tests by using --rebuild on test derivations.
# NixOS VM dependencies remain cached (only the test runner rebuilds).
#
# Usage:
#   ./runtests.sh           # Run all tests
#   ./runtests.sh k3s       # Run only k3s tests
#   ./runtests.sh emulation # Run only emulation tests

set -euo pipefail

LOG_FILE="/tmp/n3x-validation-$(date +%Y%m%d-%H%M%S).log"
FAILED=0
PASSED=0
FILTER="${1:-all}"

log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"
}

run_test() {
    local name="$1"
    local derivation="$2"
    log "START: $name"
    log "  (--rebuild forces test re-execution, VMs still cached)"

    # --rebuild: forces this derivation to rebuild (test runs again)
    # Dependencies (NixOS VMs) remain cached - only test runner rebuilds
    if nix build "$derivation" --rebuild --print-build-logs >> "$LOG_FILE" 2>&1; then
        log "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        log "FAIL: $name (see $LOG_FILE for details)"
        FAILED=$((FAILED + 1))
    fi
}

log "=== n3x Test Suite ==="
log "Filter: $FILTER"
log "Log file: $LOG_FILE"
log ""
log "Note: Tests ALWAYS re-run (--rebuild). VM builds use cache."
log ""

# Quick evaluation check (always run)
log "START: flake-eval"
if nix flake check --no-build >> "$LOG_FILE" 2>&1; then
    log "PASS: flake-eval"
    PASSED=$((PASSED + 1))
else
    log "FAIL: flake-eval"
    FAILED=$((FAILED + 1))
fi

# K3s tests
if [[ "$FILTER" == "all" || "$FILTER" == "k3s" ]]; then
    log ""
    log "--- K3s Integration Tests ---"
    run_test "k3s-cluster-formation" '.#checks.x86_64-linux.k3s-cluster-formation'
    run_test "k3s-storage" '.#checks.x86_64-linux.k3s-storage'
    run_test "k3s-network" '.#checks.x86_64-linux.k3s-network'
    run_test "k3s-network-constraints" '.#checks.x86_64-linux.k3s-network-constraints'
fi

# Emulation tests
if [[ "$FILTER" == "all" || "$FILTER" == "emulation" ]]; then
    log ""
    log "--- Emulation Tests ---"
    run_test "emulation-vm-boots" '.#checks.x86_64-linux.emulation-vm-boots'
    run_test "network-resilience" '.#checks.x86_64-linux.network-resilience'
fi

log ""
log "=== Summary ==="
log "Passed: $PASSED"
log "Failed: $FAILED"
log "Log: $LOG_FILE"

exit $FAILED
