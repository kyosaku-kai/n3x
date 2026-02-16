# EC2 x86_64 runner configuration
#
# NixOS configuration for x86_64 EC2 instance running GitLab runner
# with ISAR/Nix build capabilities and Harmonia binary cache.
#
# EBS volumes (provisioned by Pulumi):
#   /dev/nvme0n1  Root    50GB gp3  (managed by amazon-image.nix)
#   /dev/nvme1n1  Cache   500GB gp3 (ZFS pool for /nix/store)
#   /dev/nvme2n1  Yocto   100GB gp3 (DL_DIR/SSTATE_DIR, ephemeral)
#
# Deployment (preferred — custom AMI):
#   1. nix build '.#packages.x86_64-linux.ami-ec2-x86_64'
#   2. scripts/register-ami.sh --arch x86_64 --region us-east-1 --bucket <s3-bucket>
#   3. pulumi config set n3x:amiX86 <ami-id> && pulumi up
#   Secondary volumes formatted on first boot by first-boot-format.nix.
#
# Deployment (alternative — nixos-anywhere):
#   nixos-anywhere --flake '.#ec2-x86_64' root@<public-ip>
#   Disko formats all volumes during installation.
#
# Post-deployment:
#   1. Wire agenix secrets (gitlab-runner token, cache-signing key)
#   2. Register runner with GitLab: `gitlab-runner register`
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")
  ];

  # EC2 instance settings
  ec2.hvm = true;
  networking.hostName = "ec2-x86-64";

  # Enable n3x runner modules
  n3x = {
    gitlab-runner = {
      enable = true;
      tags = [ "nix" "x86_64" "large-disk" ];
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
      extraSubstituters = [
        "https://cache.ec2-graviton.n3x.internal?priority=10"
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
      hostId = "ec286401"; # Override with real value at deployment
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
