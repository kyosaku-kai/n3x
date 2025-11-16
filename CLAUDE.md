# CLAUDE.md - Project Memory and Rules

This file provides project-specific rules and task tracking for Claude Code when working with the n3x repository.

## Critical Rules

### Git Commit Practices

1. **ALWAYS commit relevant changes after making them** - This is a high priority rule. Stage and commit changes that are part of the long-term solution immediately after completing work.

2. **NEVER include AI/Claude attributions in commits**:
   - Do NOT add "Co-Authored-By: Claude" or "Generated with Claude"
   - Do NOT mention Anthropic, AI, or Claude in commit messages
   - Keep commit messages professional and attribution-free
   - Focus on describing WHAT changed and WHY, not who/what created it

3. **Do NOT commit temporary files** - Never stage or commit files created for temporary or short-term purposes.

## Project Status and Next Tasks

### Current Status
- **Phase**: Implementation complete
- **Repository State**: All core modules, configurations, and testing framework implemented
- **Implementation**: Complete - Ready for hardware deployment testing

### Completed Implementation Tasks

All core implementation tasks have been completed:

1. **Flake Structure Creation** ✅
   - Initialized flake.nix with proper inputs (nixpkgs, disko, sops-nix, nixos-anywhere, jetpack-nixos)
   - Created modular structure under modules/ directory
   - Set up hosts/ directory for per-node configurations (5 hosts: 3 N100, 2 Jetson)

2. **Hardware Modules** ✅
   - Created N100-specific hardware module with optimizations
   - Created Jetson Orin Nano module using jetpack-nixos
   - Configured kernel parameters and performance tuning

3. **Network Configuration** ✅
   - Implemented dual-IP bonding module
   - Configured Multus CNI NetworkAttachmentDefinition
   - Set up VLAN support for traffic separation
   - Created storage network configuration for k3s and Longhorn

4. **K3s Setup** ✅
   - Created server and agent role modules with secure variants
   - Configured token management with sops-nix
   - Implemented Kyverno PATH patching for Longhorn
   - Created common k3s configuration module

5. **Storage Configuration** ✅
   - Implemented disko partition layouts (standard and ZFS options)
   - Configured Longhorn module with storage network
   - Created k3s-storage integration module
   - Ready for PVC creation and replica management testing

6. **Secrets Management** ✅
   - Configured sops-nix integration
   - Created secrets module with age key support
   - Set up encryption for K3s tokens
   - Documented secrets workflow

7. **Testing Framework** ✅
   - Created comprehensive VM testing configurations
   - Configured test VMs for server, agent, and multi-node clusters
   - Implemented NixOS integration tests using `nixosTest` framework
   - Added automated test runner script for manual testing
   - Integrated tests into `checks` output for CI/CD
   - Documented testing procedures

### Remaining Tasks

#### Phase 1: VM Testing and Validation

**Testing Approach:**
- Use NixOS integration tests (`nixosTest`) for automated validation
- Use shell script (`./tests/run-vm-tests.sh`) for manual/interactive debugging
- All tests are integrated into `nix flake check` for CI/CD

**Automated Tests (Primary):**
1. **Run Integration Tests**
   ```bash
   # Run all checks including tests
   nix flake check

   # Run specific test
   nix build .#checks.x86_64-linux.k3s-single-server

   # Interactive debugging
   nix build .#checks.x86_64-linux.k3s-single-server.driverInteractive
   ./result/bin/nixos-test-driver
   ```

2. **Current Tests**
   - ✅ `k3s-single-server` - K3s server boots and initializes cluster
   - ⏳ `k3s-agent-join` - Agent joins server cluster (TODO)
   - ⏳ `k3s-multi-node` - Multi-node cluster formation (TODO)
   - ⏳ `network-bonding` - Network bonding validation (TODO)
   - ⏳ `longhorn-storage` - Longhorn deployment and PVC provisioning (TODO)

**Manual Testing (For Debugging):**
   ```bash
   # Build and run VMs manually
   ./tests/run-vm-tests.sh interactive

   # Or directly:
   nix build .#nixosConfigurations.vm-k3s-server.config.system.build.vm
   ./result/bin/run-vm-k3s-server-vm
   ```

**Debug and Fix Issues:**
   - Address any boot failures or configuration errors
   - Fix networking issues discovered in VM testing
   - Resolve K3s cluster formation problems
   - Document workarounds and solutions
   - Expand test coverage as issues are discovered

#### Phase 2: Secrets Preparation
1. **Generate Encryption Keys**
   - Generate age keys for admin and all physical hosts
   - Document public keys in secrets/public-keys.txt
   - Securely backup private keys

2. **Create and Encrypt Secrets**
   - Generate strong K3s server and agent tokens
   - Encrypt tokens using sops
   - Validate decryption works with age keys

#### Phase 3: Hardware Deployment
1. **Initial Provisioning**
   - Deploy first N100 server node using nixos-anywhere
   - Verify successful boot and SSH access
   - Confirm K3s control plane initialization
   - Validate secrets decryption on real hardware

2. **Cluster Expansion**
   - Deploy second and third N100 nodes
   - Deploy Jetson nodes (if available)
   - Verify all nodes join cluster successfully
   - Test cross-node communication

#### Phase 4: Kubernetes Stack Deployment
1. **Core Components**
   - Install Kyverno from manifests/
   - Verify PATH patching policy applies to pods
   - Deploy Longhorn via Helm
   - Confirm Longhorn manager starts without errors

2. **Storage Validation**
   - Create test PVC and verify provisioning
   - Test replica distribution across nodes
   - Validate storage network traffic separation
   - Benchmark storage performance

#### Phase 5: Production Hardening
1. **Security**
   - Configure proper TLS certificates for K3s
   - Rotate default tokens to production values
   - Set up RBAC policies
   - Enable audit logging

2. **Operational Readiness**
   - Deploy monitoring stack (Prometheus/Grafana)
   - Configure alerting rules
   - Implement backup strategies for etcd and Longhorn
   - Document operational procedures
   - Create runbooks for common scenarios

## Development Guidelines

### Code Organization
- Keep configurations modular and composable
- Use generator functions to reduce duplication
- Separate concerns between hardware, networking, and services
- Maintain clear separation between secrets and configuration

### Testing Approach

**Automated Testing (Preferred):**
- Use NixOS integration tests (`nixosTest`) for all functional validation
- Tests are declarative Nix derivations that boot VMs and run assertions
- Integrated with `nix flake check` for CI/CD pipelines
- Tests are reproducible and start from clean state every run
- Located in `tests/integration/`

**Manual/Interactive Testing:**
- Use `./tests/run-vm-tests.sh` for quick manual exploration
- Build VMs directly: `nix build .#nixosConfigurations.vm-NAME.config.system.build.vm`
- Interactive test debugging: `nix build .#checks.x86_64-linux.TEST-NAME.driverInteractive`
- Use VMs in `tests/vms/` for manual validation

**General Practices:**
- Always test in VMs before deploying to hardware
- Validate each layer independently before integration
- Write automated tests for critical functionality
- Use interactive mode for debugging failures
- Document any hardware-specific quirks discovered

**Test Structure:**
```nix
# Example test structure
pkgs.testers.runNixOSTest {
  name = "my-test";
  nodes = {
    machine1 = { config, ... }: { /* NixOS config */ };
    machine2 = { config, ... }: { /* NixOS config */ };
  };
  testScript = ''
    start_all()
    machine1.wait_for_unit("service.service")
    machine1.succeed("test command")
  '';
}
```

### Documentation
- Update README.md when implementation decisions are made
- Document any deviations from the plan
- Keep configuration examples minimal and focused
- Add troubleshooting sections as issues are encountered

## Known Constraints

### Hardware Limitations
- Jetson Orin Nano requires serial console (HDMI doesn't work for console)
- N100 miniPCs need specific kernel parameters for stability
- USB boot issues with certain Jetson firmware versions (use 35.2.1, not 35.3.1)

### Software Requirements
- Kyverno MUST be deployed before Longhorn for PATH compatibility
- Token management MUST use file paths, never inline secrets
- K3s manifests deployment requires careful ordering

## References

For detailed architecture and implementation patterns, see README.md

For community examples and working code:
- niki-on-github/nixos-k3s (GitOps integration)
- rorosen/k3s-nix (multi-node examples)
- Skasselbard/NixOS-K3s-Cluster (CSV provisioning)
- anduril/jetpack-nixos (Jetson support)