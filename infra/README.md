# n3x Infrastructure

Infrastructure-as-code for build runners, CI/CD, and supporting services.

## Components

### [AWS Runner Provisioning (Pulumi)](pulumi/README.md)

Pulumi project (Go) provisioning EC2 instances for CI build runners.
Two nodes: x86_64 (c6i.2xlarge) + Graviton aarch64 (c7g.2xlarge), each with
ZFS-backed Nix store, Yocto cache volumes, deployed from custom NixOS AMIs.

### [NixOS Runner Configuration](nixos-runner/README.md)

NixOS flake defining runner node configurations and custom AMI outputs. Covers:
- EC2 runners (x86_64 + Graviton) — custom AMI build + first-boot volume formatting
- On-prem bare metal runner — deployed via nixos-anywhere
- ZFS prototype cluster (3x Intel N100 mini PCs)
- Dev workstation profile

Shared NixOS modules for: GitLab Runner, Harmonia (Nix cache), Caddy (TLS),
apt-cacher-ng, ZFS/disko, cache signing, internal CA, first-boot volume formatting.

## Architecture

![AWS Infrastructure](pulumi/architecture.drawio.svg)

![Runner Node Services](pulumi/runner-services.drawio.svg)

See also: [CI Pipeline Diagram](../docs/diagrams/ci-pipeline.drawio.svg) — pipeline stages, runner infrastructure, cache topology

## Deployment Workflows

### EC2 Runners (Custom AMI — preferred)

1. Build AMI: `nix build '.#packages.x86_64-linux.ami-ec2-x86_64'`
2. Register in AWS: `scripts/register-ami.sh --arch x86_64 --region us-east-1 --bucket <bucket>`
3. Deploy: `pulumi config set n3x:amiX86 <ami-id> && pulumi up`
4. First boot formats ZFS + Yocto volumes automatically

### Bare Metal / Recovery (nixos-anywhere)

For on-prem hosts or recovery: `nixos-anywhere --flake '.#on-prem-runner' root@<ip>`

## Related Documentation

- [Nix Binary Cache Architecture Decision](../docs/nix-binary-cache-architecture-decision.md)
- [CI Privileged Build Requirements](../docs/isar-ci-privileged-build-requirements.md)
- [CI Validation Plan](../docs/plans/CI-VALIDATION-PLAN.md)
