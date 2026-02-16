# EC2 Graviton (aarch64) runner configuration
#
# NixOS configuration for aarch64 Graviton EC2 instance running GitLab runner
# with ISAR/Nix build capabilities and Harmonia binary cache.
#
# EBS volumes (provisioned by Pulumi):
#   /dev/nvme0n1  Root    50GB gp3  (managed by amazon-image.nix)
#   /dev/nvme1n1  Cache   500GB gp3 (ZFS pool for /nix/store)
#   /dev/nvme2n1  Yocto   100GB gp3 (DL_DIR/SSTATE_DIR, ephemeral)
#
# Deployment (preferred — custom AMI):
#   1. nix build '.#packages.aarch64-linux.ami-ec2-graviton'
#   2. scripts/register-ami.sh --arch aarch64 --region us-east-1 --bucket <s3-bucket>
#   3. pulumi config set n3x:amiArm64 <ami-id> && pulumi up
#   Secondary volumes formatted on first boot by first-boot-format.nix.
#
# Deployment (alternative — nixos-anywhere):
#   nixos-anywhere --flake '.#ec2-graviton' root@<public-ip>
#   Disko formats all volumes during installation.
#
# Post-deployment:
#   1. Wire agenix secrets (gitlab-runner token, cache-signing key)
#   2. Register runner with GitLab: `gitlab-runner register`
#
# Note: Graviton runs aarch64 natively. ISAR cross-compilation for x86_64
# targets is NOT supported here — use the x86_64 EC2 runner for x86_64 images.
# This runner handles aarch64-native builds and architecture-independent tasks.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")
  ];

  # EC2 instance settings
  ec2.hvm = true;
  networking.hostName = "ec2-graviton";

  # Enable n3x runner modules
  n3x = {
    gitlab-runner = {
      enable = true;
      tags = [ "nix" "aarch64" "large-disk" ];
      concurrent = 4; # EC2 instances have enough resources for parallel jobs
      # registrationConfigFile = config.age.secrets.gitlab-runner-token.path;
    };

    apt-cacher-ng = {
      enable = true;
      openFirewall = true; # Allow cluster nodes to use this proxy
    };

    yocto-cache = {
      enable = true;
      cacheDevice = "/dev/nvme2n1"; # 100GB gp3 EBS volume
    };

    nix-config = {
      enable = true;
      # Fetch from peer caches before building locally
      # x86_64 caches included: Nix ignores store paths for wrong architecture
      extraSubstituters = [
        "https://cache.ec2-x86-64.n3x.internal?priority=10"
        "https://cache.on-prem-runner.n3x.internal?priority=10"
      ];
    };

    harmonia.enable = true;

    cache-signing = {
      enable = true;
      # TODO: Wire to agenix after deployment:
      #   privateKeyFile = config.age.secrets.cache-signing-key.path;
      #   secretsFile = ../../secrets/cache-signing-key.age;
      privateKeyFile = "/run/agenix/cache-signing-key";
      publicKey = "cache.n3x.example.com-1:REPLACE_WITH_REAL_PUBLIC_KEY";
    };

    internal-ca = {
      enable = true;
      rootCertFile = ../certs/n3x-root-ca.pem;
      # TODO: Set acmeServer after step-ca deployment:
      #   acmeServer = "https://ca.n3x.internal/acme/acme/directory";
    };

    caddy.enable = true;

    # ZFS-backed /nix/store on dedicated EBS volume (500GB gp3)
    disko-zfs = {
      enable = true;
      device = "/dev/nvme1n1"; # Second EBS volume
      hostId = "ec2a6401"; # Override with real value at deployment
    };
  };

  # Podman for ISAR/kas-container builds
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  # SSH for remote management and nixos-anywhere
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Administration tools
  environment.systemPackages = with pkgs; [
    git
    vim
    tmux
    htop
    iotop
    lsof
    iproute2
    tcpdump
  ];

  system.stateVersion = "24.11";
}
