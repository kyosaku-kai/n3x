# n3x AWS Build Runner Infrastructure

Pulumi project (Go) for provisioning n3x build runner infrastructure on AWS.

## Architecture

![AWS Infrastructure](architecture.drawio.svg)

Two identical runner nodes (x86_64 + Graviton), each with three EBS volumes,
inside a shared security group. NixOS is baked into custom AMIs; Pulumi
provisions instances directly from these AMIs.

### Per-Runner Resources

- **EC2 Instance**: c6i.2xlarge (x86_64 Runner) / c7g.2xlarge (Graviton Runner)
- **Root EBS**: 50 GB gp3 (NixOS system, `/dev/nvme0n1`) — from custom AMI
- **Cache EBS**: 500 GB gp3 (ZFS pool for `/nix/store`, `/dev/nvme1n1`) — formatted on first boot
- **Yocto EBS**: 100 GB gp3 (`DL_DIR` + `SSTATE_DIR`, `/dev/nvme2n1`) — formatted on first boot

### Shared Resources

- **Security Group** (`n3x-runner-sg`): Inbound SSH (22) + HTTPS (443) + apt-cacher-ng (3142), all egress
- **SSH Key Pair** (`n3x-runner-key`): For remote management

### NixOS Runner Services

Each runner node runs the same NixOS configuration with these services:

![Runner Node Services](runner-services.drawio.svg)

| Service | Port | Purpose |
|---------|------|---------|
| GitLab Runner | - | Shell executor for CI jobs |
| Podman | - | OCI runtime (kas-container) |
| Caddy | :443 | TLS reverse proxy for Harmonia |
| Harmonia | :5000 | Nix binary cache server |
| apt-cacher-ng | :3142 | Debian package proxy |
| systemd-networkd | - | Network configuration |
| agenix | - | Secrets (runner token, cache-signing key) |
| first-boot-format | - | One-time ZFS/ext4 volume setup |

NixOS modules: `../nixos-runner/modules/`

### EBS to NVMe Device Mapping

On Nitro instances (c6i, c7g), EBS device names map to NVMe devices:

| Pulumi device | NVMe device  | Purpose | NixOS module |
|---------------|-------------|---------|-------------|
| (root)        | /dev/nvme0n1 | OS | amazon-image.nix (AMI) |
| /dev/sdf      | /dev/nvme1n1 | ZFS cache pool | first-boot-format + disko-zfs |
| /dev/sdg      | /dev/nvme2n1 | Yocto downloads + sstate | first-boot-format + yocto-cache |

## Prerequisites

- [Pulumi CLI](https://www.pulumi.com/docs/install/)
- AWS credentials configured (`aws configure` or env vars)
- Custom NixOS AMI registered (see AMI Build below)

### AMI Build Prerequisites

- S3 bucket for temporary VHD upload
- VM Import/Export service role (`vmimport`) in AWS account
  ([setup guide](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html))
- nix with flakes enabled

## AMI Build and Registration

Build a custom NixOS AMI with all runner configuration baked in:

```bash
# Build x86_64 AMI image
cd ../nixos-runner
nix build '.#packages.x86_64-linux.ami-ec2-x86_64'

# Register in AWS (uploads VHD, imports snapshot, creates AMI)
./scripts/register-ami.sh \
  --arch x86_64 \
  --region us-east-1 \
  --bucket my-ami-staging-bucket

# Optional: build + register Graviton AMI
nix build '.#packages.aarch64-linux.ami-ec2-graviton'
./scripts/register-ami.sh \
  --arch aarch64 \
  --region us-east-1 \
  --bucket my-ami-staging-bucket
```

The script outputs the AMI ID. Set it in Pulumi config before deploying.

## Deployment

```bash
# Initialize stack (first time)
pulumi stack init dev

# Set required config
pulumi config set n3x:amiX86 "ami-0123456789abcdef0"  # from register-ami.sh
pulumi config set n3x:sshPublicKey "ssh-ed25519 AAAA..."

# Optional: Graviton runner (omit to deploy x86_64 only)
pulumi config set n3x:amiArm64 "ami-0fedcba9876543210"

# Optional: restrict access (recommended for production)
pulumi config set n3x:sshCidrBlocks "203.0.113.0/24"

# Preview changes
pulumi preview

# Deploy infrastructure
pulumi up

# Get connection info
pulumi stack output x86PublicIp
```

### Post-Deployment

1. First boot automatically formats ZFS and Yocto EBS volumes
2. Wire agenix secrets (gitlab-runner token, cache-signing key)
3. Register runners with GitLab: `gitlab-runner register`

### Alternative: nixos-anywhere (bare metal / recovery)

For bare-metal hosts or recovery scenarios, nixos-anywhere is still available:

```bash
nixos-anywhere --flake '../nixos-runner#ec2-x86_64' root@<public-ip>
```

This replaces the OS entirely (including disko-managed disk formatting).
Use for on-prem hosts or when AMI-based deployment isn't suitable.

## Configuration

All config options with defaults:

```bash
pulumi config set n3x:amiX86 "ami-..."                  # required
pulumi config set n3x:sshPublicKey "ssh-ed25519 ..."     # required
pulumi config set n3x:amiArm64 "ami-..."                 # optional (Graviton)
pulumi config set n3x:sshCidrBlocks "10.0.0.0/8"        # default: 0.0.0.0/0
pulumi config set n3x:instanceTypeX86 "c6i.4xlarge"      # default: c6i.2xlarge
pulumi config set n3x:instanceTypeGraviton "c7g.4xlarge"  # default: c7g.2xlarge
pulumi config set n3x:rootVolumeSize 100                  # default: 50
pulumi config set n3x:cacheVolumeSize 1000                # default: 500
pulumi config set n3x:yoctoVolumeSize 200                 # default: 100
pulumi config set aws:region "eu-west-1"                  # default: us-east-1
```

## Outputs

| Output | Description |
|--------|-------------|
| securityGroupId | Security group ID (`n3x-runner-sg`) |
| keyPairName | SSH key pair name (`n3x-runner-key`) |
| x86InstanceId | x86_64 Runner EC2 instance ID |
| x86PublicIp | x86_64 Runner public IP |
| x86PublicDns | x86_64 Runner public DNS |
| x86SshCommand | Ready-to-use SSH command |
| gravitonInstanceId | Graviton Runner EC2 instance ID (if configured) |
| gravitonPublicIp | Graviton Runner public IP (if configured) |
| gravitonPublicDns | Graviton Runner public DNS (if configured) |
| gravitonSshCommand | Ready-to-use SSH command (if configured) |

## Cost Estimate

Per-runner monthly (us-east-1, on-demand):

| Resource | x86_64 Runner | Graviton Runner |
|----------|--------------|----------------|
| EC2 instance | ~$245/mo (c6i.2xlarge) | ~$196/mo (c7g.2xlarge) |
| Cache EBS (500 GB gp3) | ~$40/mo | ~$40/mo |
| Yocto EBS (100 GB gp3) | ~$8/mo | ~$8/mo |
| Root EBS (50 GB gp3) | ~$4/mo | ~$4/mo |
| **Subtotal** | **~$297/mo** | **~$248/mo** |

**Total: ~$545/mo both runners.** Consider reserved instances or savings plans
for long-running workloads.

> Note: Cache EBS uses ZFS with zstd compression, providing 750-1000 GB
> effective capacity from 500 GB physical.
