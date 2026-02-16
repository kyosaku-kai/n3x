# NixOS Runner Configuration

NixOS flake defining build runner and infrastructure node configurations.
Standalone flake (nixpkgs 25.11) with shared modules composed into per-host configs.

## Host Configurations

| Host | File | Purpose |
|------|------|---------|
| `ec2-x86_64` | `hosts/ec2-x86_64.nix` | AWS EC2 CI runner (3 EBS volumes: root, ZFS cache, Yocto) |
| `ec2-graviton` | `hosts/ec2-graviton.nix` | AWS Graviton aarch64 CI runner (same layout, no x86 cross-compile) |
| `on-prem-runner` | `hosts/on-prem-runner.nix` | Bare metal CI runner (KVM-capable for VM tests + HIL, dual-NIC) |
| `dev-workstation` | `hosts/dev-workstation.nix` | Developer machine template (ISAR builds, no runner/cache services) |
| `zfs-proto-{1,2,3}` | `hosts/zfs-proto-*.nix` | Intel N100 mini PCs forming ZFS binary cache prototype cluster |
| (shared) | `hosts/zfs-proto-common.nix` | Common config for ZFS cluster (10.99.0.0/24 cluster network, MikroTik switch) |

## NixOS Modules

![Runner Node Services](../pulumi/runner-services.drawio.svg)

All hosts import every module via `commonModules`; modules use NixOS options to enable/disable per host.

| Module | File | Purpose |
|--------|------|---------|
| GitLab Runner | `modules/gitlab-runner.nix` | Shell executor, agenix-managed token, Nix daemon + Podman access |
| Harmonia | `modules/harmonia.nix` | Nix binary cache server on `127.0.0.1:5000` (priority 30, behind Caddy) |
| Caddy | `modules/caddy.nix` | HTTPS reverse proxy for Harmonia (port 443, internal CA TLS, cache headers) |
| apt-cacher-ng | `modules/apt-cacher-ng.nix` | Debian package proxy for ISAR builds (port 3142, optional JFrog upstream) |
| disko-zfs | `modules/disko-zfs.nix` | Declarative ZFS pool layout ("dedicated" for EC2, "single-disk" for bare metal) |
| first-boot-format | `modules/first-boot-format.nix` | One-time ZFS + ext4 formatting for AMI-deployed instances |
| Cache signing | `modules/cache-signing.nix` | Nix store signing keys via agenix, optional post-build sign hook |
| Internal CA | `modules/internal-ca.nix` | Root CA trust + optional ACME with internal CA (domain: `n3x.internal`) |
| Nix config | `modules/nix-config.nix` | Flakes, substituters, weekly GC (30d), auto-optimize, sandbox |
| Yocto cache | `modules/yocto-cache.nix` | DL_DIR + SSTATE_DIR directories, optional dedicated volume, env vars |

## AMI Build

Custom NixOS AMIs for EC2 deployment use `system.build.images.amazon` (the
native 25.11 image framework) from nixpkgs. AMI-only config (e.g.,
`first-boot-format`) is injected via `image.modules.amazon` in the flake.
The AMI contains the full NixOS configuration; secondary EBS volumes (ZFS,
Yocto) are formatted on first boot by the `first-boot-format` module.

```bash
# Build x86_64 AMI
nix build '.#packages.x86_64-linux.ami-ec2-x86_64'

# Build Graviton AMI (requires aarch64-linux builder)
nix build '.#packages.aarch64-linux.ami-ec2-graviton'

# Register AMI in AWS and optionally set Pulumi config
./scripts/register-ami.sh --arch x86_64 --region us-east-1 --bucket <s3-bucket>
./scripts/register-ami.sh --arch x86_64 --region us-east-1 --bucket <s3-bucket> --pulumi-stack dev
```

See [`scripts/register-ami.sh`](scripts/register-ami.sh) for prerequisites
(S3 bucket, vmimport service role).

## Secrets

Encrypted secrets managed via [agenix](https://github.com/ryantm/agenix) in `secrets/secrets.nix`.
Currently defines `cache-signing-key.age` mapped to all host SSH public keys (placeholders pending deployment).

## Certificates

`certs/n3x-root-ca.pem` contains the internal root CA certificate installed by the `internal-ca` module.

## Usage

```bash
# Build a specific host configuration
nix build '.#nixosConfigurations.ec2-x86_64.config.system.build.toplevel'

# Deploy to a running machine (requires SSH access)
nixos-rebuild switch --flake '.#ec2-x86_64' --target-host root@<ip>

# Initial deployment via nixos-anywhere (bare metal / recovery)
nix run 'github:nix-community/nixos-anywhere' -- --flake '.#ec2-x86_64' root@<ip>
```

## Related

- [AWS Provisioning (Pulumi)](../pulumi/README.md) -- Creates the EC2 instances these configs deploy to
- [Infrastructure Overview](../README.md)
- [Nix Binary Cache Architecture Decision](../../docs/nix-binary-cache-architecture-decision.md)
- [CI Privileged Build Requirements](../../docs/isar-ci-privileged-build-requirements.md)
