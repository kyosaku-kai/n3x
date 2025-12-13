{ config, lib, pkgs, ... }:

{
  # SOPS-nix configuration for secrets management

  # Basic sops configuration
  sops = {
    # Age key file location on the host
    # This file must be deployed during provisioning
    age.keyFile = "/var/lib/sops-nix/key.txt";

    # Generate age key from SSH host key if age key doesn't exist
    # This is useful for initial bootstrapping
    age.generateKey = true;

    # SSH host keys to use as fallback
    # Allows using existing SSH keys for decryption
    age.sshKeyPaths = [
      "/etc/ssh/ssh_host_ed25519_key"
    ];

    # Default sops file (optional, can be overridden per-secret)
    # defaultSopsFile = ../../secrets/default.yaml;

    # Validate that age keys are properly configured
    validateSopsFiles = true;

    # Secret definitions
    secrets = {
      # K3s tokens - required for cluster formation
      "k3s-server-token" = {
        # Source file containing the encrypted secret
        sopsFile = ../../secrets/k3s/tokens.yaml;

        # Key within the YAML file
        key = "server-token";

        # Owner and permissions
        owner = "root";
        group = "root";
        mode = "0600";

        # Path where the decrypted secret will be available
        path = "/run/secrets/k3s-server-token";

        # Restart services when secret changes
        restartUnits = [ "k3s.service" ];
      };

      "k3s-agent-token" = {
        sopsFile = ../../secrets/k3s/tokens.yaml;
        key = "agent-token";
        owner = "root";
        group = "root";
        mode = "0600";
        path = "/run/secrets/k3s-agent-token";
        restartUnits = [ "k3s.service" ];
      };

      # Example: Network credentials
      # "wifi-password" = {
      #   sopsFile = ../../secrets/network/wifi.yaml;
      #   key = "password";
      #   owner = "root";
      #   mode = "0600";
      # };

      # Example: Application secrets
      # "database-password" = {
      #   sopsFile = ../../secrets/apps/database.yaml;
      #   key = "password";
      #   owner = "postgres";
      #   mode = "0400";
      # };
    };

    # Templates - for generating config files with secrets
    templates = {
      # Example: Generate k3s config with token
      "k3s-config.yaml" = {
        content = ''
          token: ${config.sops.placeholder."k3s-server-token"}
          cluster-init: true
        '';
        owner = "root";
        mode = "0600";
        path = "/etc/rancher/k3s/config.yaml";
      };
    };
  };

  # System activation script to ensure sops directories exist
  system.activationScripts.sops-setup = ''
    # Create sops-nix directory
    mkdir -p /var/lib/sops-nix
    chmod 700 /var/lib/sops-nix

    # Create secrets runtime directory
    mkdir -p /run/secrets
    chmod 755 /run/secrets
  '';

  # Environment variables for sops usage
  environment.variables = {
    SOPS_AGE_KEY_FILE = "/var/lib/sops-nix/key.txt";
  };

  # Add sops to system packages for manual secret management
  environment.systemPackages = with pkgs; [
    sops
    age
    ssh-to-age
  ];

  # Shell aliases for convenience
  environment.shellAliases = {
    sops-edit = "sops";
    sops-show = "sops -d";
    sops-encrypt = "sops -e";
    sops-decrypt = "sops -d";
    sops-rotate = "sops rotate -i";
  };
}
