# n3x Secrets Management

This directory contains encrypted secrets for the n3x cluster infrastructure using sops-nix.

## Directory Structure

```
secrets/
├── .sops.yaml          # SOPS configuration with encryption rules
├── README.md           # This file
├── public-keys.txt     # Public age keys for reference
├── keys/               # Private age keys (DO NOT COMMIT)
│   ├── admin.age       # Admin key for management operations
│   ├── n100-1.age      # Host key for n100-1
│   ├── n100-2.age      # Host key for n100-2
│   └── n100-3.age      # Host key for n100-3
├── k3s/                # K3s cluster secrets
│   └── tokens.yaml     # Encrypted server and agent tokens
├── hosts/              # Host-specific secrets
├── network/            # Network credentials (WiFi, VPN)
└── apps/               # Application secrets (API keys, passwords)
```

## Key Management

### Generated Keys

The following age keys have been generated for this cluster:

- **Admin**: `age1recdr08s72v544xsjgw3vdge258c3fu7r53jg03kn66t5acczspshucl4v`
- **n100-1**: `age19n9ck9ka9j7x2tuukyyeatw56n82yc9yg7v74nwlqmmtc5typc8q0wwrrf`
- **n100-2**: `age1vsesxhxjcsnkletkdhncan8cz58qha5s66rgns6d8fdct0vg39dslflypj`
- **n100-3**: `age1argjl8q3kmfh39yyakjhv3zsdjy5pgs2azj7p3pq8wm92nwyuyyqfcfplz`

### Key Distribution

During node provisioning, deploy the appropriate key file to each host:

```bash
# On n100-1
scp secrets/keys/n100-1.age root@n100-1:/var/lib/sops-nix/key.txt

# On n100-2
scp secrets/keys/n100-2.age root@n100-2:/var/lib/sops-nix/key.txt

# On n100-3
scp secrets/keys/n100-3.age root@n100-3:/var/lib/sops-nix/key.txt
```

## Working with Secrets

### Encrypting New Secrets

1. Create your plaintext YAML file
2. Encrypt it using the admin key:

```bash
export SOPS_AGE_KEY_FILE=secrets/keys/admin.age
sops -e secrets/myfile.yaml > secrets/myfile.enc.yaml
```

### Editing Existing Secrets

```bash
export SOPS_AGE_KEY_FILE=secrets/keys/admin.age
sops secrets/k3s/tokens.yaml
```

### Decrypting Secrets

```bash
export SOPS_AGE_KEY_FILE=secrets/keys/admin.age
sops -d secrets/k3s/tokens.yaml
```

## K3s Tokens

The K3s tokens have been generated and encrypted in `k3s/tokens.yaml`:

- **server-token**: Used by all server nodes to form the control plane
- **agent-token**: Used by agent nodes to join the cluster

These tokens are automatically decrypted by sops-nix and made available at:
- `/run/secrets/k3s-server-token`
- `/run/secrets/k3s-agent-token`

## Security Notes

⚠️ **IMPORTANT**:
- NEVER commit the `keys/` directory to version control
- Keep backup copies of the admin.age key in a secure location
- The host keys should only exist on their respective nodes
- Regularly rotate tokens and secrets
- Use strong, randomly generated tokens (as done by the generation script)

## Scripts

Helper scripts are available in the `scripts/` directory:

- `generate-age-keys.sh`: Generate age keys for admin and all hosts
- `extract-public-keys.sh`: Extract public keys from age key files
- `generate-k3s-tokens.sh`: Generate random K3s tokens

## Integration with NixOS

The secrets are integrated with NixOS through the `modules/security/secrets.nix` module, which:

1. Configures sops-nix with the age key location
2. Defines secret paths and permissions
3. Automatically restarts services when secrets change
4. Provides templates for generating config files with secrets

## Troubleshooting

### Cannot decrypt secrets

1. Ensure the age key file exists at `/var/lib/sops-nix/key.txt`
2. Check that the key has correct permissions (600)
3. Verify the key is listed in `.sops.yaml` for the file you're trying to decrypt

### Secrets not available in NixOS

1. Check systemd journal: `journalctl -u sops-nix`
2. Verify the sops file path in the module configuration
3. Ensure the secret key name matches between YAML and Nix config

### Adding new hosts

1. Generate a new age key: `age-keygen -o secrets/keys/new-host.age`
2. Extract the public key and add it to `.sops.yaml`
3. Re-encrypt all shared secrets with the new key
4. Update the NixOS module configuration for the new host