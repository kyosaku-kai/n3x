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
- **Phase**: Documentation and planning complete
- **Repository State**: Comprehensive README.md created, documentation consolidated
- **Implementation**: Not yet started

### Upcoming Implementation Tasks

When implementation begins, these tasks should be tracked:

1. **Flake Structure Creation**
   - Initialize flake.nix with proper inputs (nixpkgs, disko, sops-nix, colmena)
   - Create modular structure under modules/ directory
   - Set up hosts/ directory for per-node configurations

2. **Hardware Modules**
   - Create N100-specific hardware module with optimizations
   - Create Jetson Orin Nano module using jetpack-nixos
   - Configure kernel parameters and performance tuning

3. **Network Configuration**
   - Implement dual-IP bonding module
   - Configure Multus CNI NetworkAttachmentDefinition
   - Set up traffic separation for k3s and storage

4. **K3s Setup**
   - Create server and agent role modules
   - Configure token management with sops-nix
   - Implement Kyverno PATH patching for Longhorn

5. **Storage Configuration**
   - Implement disko partition layout for 512GB NVMe
   - Configure Longhorn with storage network
   - Test PVC creation and replica management

6. **Deployment Automation**
   - Set up nixos-anywhere scripts
   - Configure colmena for parallel deployment
   - Create VM testing configurations

7. **Validation and Testing**
   - Test in VMs before hardware deployment
   - Validate network bonding and failover
   - Verify Longhorn storage operations
   - Test GitOps integration

## Development Guidelines

### Code Organization
- Keep configurations modular and composable
- Use generator functions to reduce duplication
- Separate concerns between hardware, networking, and services
- Maintain clear separation between secrets and configuration

### Testing Approach
- Always test in VMs first using `nixos-rebuild build-vm`
- Use interactive testing where possible
- Validate each layer independently before integration
- Document any hardware-specific quirks discovered

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