# n3x Secrets Management Setup Guide

This guide explains how to set up and manage secrets for the n3x infrastructure using sops-nix and age encryption.

## Overview

The n3x framework uses [sops-nix](https://github.com/Mic92/sops-nix) for secrets management, which provides:
- Encrypted secrets stored in git
- Automatic decryption at runtime
- Per-host and per-secret access control
- Integration with NixOS services

## Prerequisites

Before setting up secrets, ensure you have the following tools installed:
- `age` - Modern encryption tool
- `sops` - Secrets operations tool
- `ssh-to-age` - Convert SSH keys to age keys (optional)

Install these tools:
```bash
nix-shell -p age sops ssh-to-age
```

## Directory Structure

```
secrets/
├── .sops.yaml           # SOPS configuration
├── keys/                # Age private keys (DO NOT COMMIT)
│   ├── admin.age        # Admin key for managing secrets
│   ├── n100-1.age       # Host-specific keys
│   ├── n100-2.age
│   └── n100-3.age
├── k3s/                 # K3s related secrets
│   └── tokens.yaml      # Cluster join tokens (encrypted)
├── hosts/               # Host-specific secrets
│   ├── n100-1/
│   ├── n100-2/
│   └── n100-3/
├── network/             # Network credentials
└── apps/                # Application secrets
```

## Step 1: Generate Age Keys

### Option A: Generate New Age Keys

Run the provided script to generate age keys for all hosts:

```bash
./scripts/generate-age-keys.sh
```

This creates:
- Admin key for managing all secrets
- Individual keys for each host
- Public keys summary file

### Option B: Manual Key Generation

Generate keys manually for each host:

```bash
# Generate admin key
age-keygen -o secrets/keys/admin.age

# Generate host keys
age-keygen -o secrets/keys/n100-1.age
age-keygen -o secrets/keys/n100-2.age
age-keygen -o secrets/keys/n100-3.age
```

### Option C: Convert SSH Keys

Convert existing SSH host keys to age format:

```bash
ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > secrets/keys/host.age
```

## Step 2: Configure SOPS

Update `secrets/.sops.yaml` with your actual public keys:

```yaml
keys:
  # Replace these with your actual age public keys
  - &admin age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  - &n100-1 age1yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
  - &n100-2 age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
  - &n100-3 age1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

creation_rules:
  # K3s tokens - all nodes need access
  - path_regex: "k3s/.*\.yaml$"
    key_groups:
      - age:
          - *admin
          - *n100-1
          - *n100-2
          - *n100-3
```

Get public keys from your age key files:
```bash
grep "public key:" secrets/keys/admin.age | cut -d' ' -f3
```

## Step 3: Create and Encrypt Secrets

### K3s Tokens

1. Generate secure tokens:
```bash
# Generate server token
openssl rand -hex 32

# Generate agent token (can be same as server token)
openssl rand -hex 32
```

2. Create the tokens file:
```bash
cp secrets/k3s/tokens.yaml.example secrets/k3s/tokens.yaml
```

3. Edit with your tokens:
```yaml
server-token: "your-generated-server-token"
agent-token: "your-generated-agent-token"
```

4. Encrypt the file:
```bash
cd secrets
sops -e -i k3s/tokens.yaml
```

### Other Secrets

Follow the same pattern for other secrets:

```bash
# Create a new secret file
cat > secrets/network/wifi.yaml <<EOF
ssid: "MyNetwork"
password: "MyPassword"
EOF

# Encrypt it
sops -e -i secrets/network/wifi.yaml
```

## Step 4: Deploy Keys to Hosts

### During Initial Provisioning

When using `nixos-anywhere`, include the age key in the provisioning:

```bash
# Copy key during provisioning
nixos-anywhere \
  --flake .#n100-1 \
  --extra-files secrets/keys/n100-1.age:/var/lib/sops-nix/key.txt \
  root@n100-1.local
```

### Manual Deployment

Copy the age key to each host:

```bash
# Copy to host
scp secrets/keys/n100-1.age root@n100-1:/var/lib/sops-nix/key.txt

# Set proper permissions
ssh root@n100-1 'chmod 600 /var/lib/sops-nix/key.txt'
```

## Step 5: Use Secrets in NixOS Modules

### Basic Usage

In your NixOS configuration:

```nix
{ config, ... }:
{
  # Import the secrets module
  imports = [ ./modules/security/secrets.nix ];

  # Secrets are available at runtime
  services.k3s = {
    tokenFile = config.sops.secrets."k3s-server-token".path;
  };
}
```

### Define New Secrets

Add to your secrets module:

```nix
sops.secrets = {
  "database-password" = {
    sopsFile = ../../secrets/apps/database.yaml;
    key = "password";
    owner = "postgres";
    mode = "0400";
    restartUnits = [ "postgresql.service" ];
  };
};
```

## Step 6: Managing Secrets

### Edit Existing Secrets

```bash
# Edit encrypted file in place
sops secrets/k3s/tokens.yaml

# Or decrypt, edit, encrypt
sops -d secrets/k3s/tokens.yaml > temp.yaml
vim temp.yaml
sops -e temp.yaml > secrets/k3s/tokens.yaml
rm temp.yaml
```

### Rotate Secrets

```bash
# Rotate all keys in a file
sops rotate -i secrets/k3s/tokens.yaml
```

### Add/Remove Access

1. Update `.sops.yaml` with new keys
2. Update existing secrets:
```bash
sops updatekeys secrets/k3s/tokens.yaml
```

## Security Best Practices

### DO:
- ✅ Keep age private keys secure and backed up
- ✅ Use different keys for different environments (dev/prod)
- ✅ Encrypt secrets before committing to git
- ✅ Use file paths for tokens, never inline secrets
- ✅ Rotate secrets regularly
- ✅ Limit secret access to only necessary hosts

### DON'T:
- ❌ Commit unencrypted secrets to git
- ❌ Commit age private keys (*.age files in secrets/keys/)
- ❌ Share admin keys with untrusted parties
- ❌ Use weak or predictable tokens
- ❌ Store secrets in environment variables when files are available

## Troubleshooting

### Secret Not Decrypting

Check that:
1. The age key exists at `/var/lib/sops-nix/key.txt`
2. The key has correct permissions (600)
3. The public key in `.sops.yaml` matches the private key

```bash
# Verify key
age -d -i /var/lib/sops-nix/key.txt secrets/k3s/tokens.yaml
```

### Service Not Starting

Check systemd dependencies:
```bash
systemctl status sops-nix
systemctl status k3s
```

Ensure service waits for secrets:
```nix
systemd.services.myservice = {
  after = [ "sops-nix.service" ];
};
```

### Permission Denied

Verify secret permissions in module:
```nix
sops.secrets."my-secret" = {
  owner = "correct-user";
  group = "correct-group";
  mode = "0600";
};
```

## Example: Complete K3s Token Setup

```bash
# 1. Generate tokens
SERVER_TOKEN=$(openssl rand -hex 32)
AGENT_TOKEN=$SERVER_TOKEN  # Can be same

# 2. Create tokens file
cat > secrets/k3s/tokens.yaml <<EOF
server-token: "$SERVER_TOKEN"
agent-token: "$AGENT_TOKEN"
EOF

# 3. Encrypt
sops -e -i secrets/k3s/tokens.yaml

# 4. Verify encryption
cat secrets/k3s/tokens.yaml  # Should show encrypted content

# 5. Test decryption
sops -d secrets/k3s/tokens.yaml

# 6. Deploy and use
nixos-rebuild switch --flake .#n100-1
```

## GitOps Integration

Add to `.gitignore`:
```
# Ignore private keys
secrets/keys/*.age

# Ignore decrypted files
*.dec
*.decrypted
*.plain

# But track encrypted secrets
!secrets/**/*.yaml
```

## Multi-Deployment Setup (Forking for Work/Personal)

When forking n3x for a separate deployment (e.g., work vs personal), each deployment needs its own set of age keys and re-encrypted secrets. **Keys should NEVER be shared between deployments.**

### Why Separate Keys?

- **Security isolation**: Compromise of one environment doesn't affect others
- **Access control**: Different people/teams manage different deployments
- **Audit trail**: Clear separation of who can access what
- **No key coordination**: Each deployment is fully independent

### Fork Setup Procedure

1. **Fork the repository** (or create a new branch for isolated deployment)

2. **Generate new keys for your deployment**:
   ```bash
   # Create keys directory (gitignored)
   mkdir -p secrets/keys

   # Generate admin key
   age-keygen -o secrets/keys/admin.age

   # Generate host keys (adjust hostnames as needed)
   age-keygen -o secrets/keys/myhost-1.age
   age-keygen -o secrets/keys/myhost-2.age
   age-keygen -o secrets/keys/myhost-3.age
   ```

3. **Extract public keys**:
   ```bash
   for f in secrets/keys/*.age; do
     echo "=== $(basename $f) ==="
     grep "public key:" "$f"
   done
   ```

4. **Update `.sops.yaml` with YOUR public keys**:
   ```yaml
   keys:
     - &admin age1YOUR_ADMIN_PUBLIC_KEY_HERE
     - &myhost-1 age1YOUR_HOST1_PUBLIC_KEY_HERE
     - &myhost-2 age1YOUR_HOST2_PUBLIC_KEY_HERE
     - &myhost-3 age1YOUR_HOST3_PUBLIC_KEY_HERE
   ```

5. **Generate new secrets** (DO NOT reuse upstream tokens):
   ```bash
   # Generate fresh tokens
   SERVER_TOKEN=$(openssl rand -hex 32)
   AGENT_TOKEN=$(openssl rand -hex 32)

   # Create unencrypted tokens file
   cat > secrets/k3s/tokens.yaml <<EOF
   # K3s cluster tokens - encrypted with sops
   server-token: "$SERVER_TOKEN"
   agent-token: "$AGENT_TOKEN"
   EOF

   # Set the key for encryption
   export SOPS_AGE_KEY_FILE=secrets/keys/admin.age

   # Encrypt the file
   sops -e -i secrets/k3s/tokens.yaml
   ```

6. **Verify encryption works**:
   ```bash
   # Should decrypt successfully with your admin key
   export SOPS_AGE_KEY_FILE=secrets/keys/admin.age
   sops -d secrets/k3s/tokens.yaml

   # Should also decrypt with host keys
   export SOPS_AGE_KEY_FILE=secrets/keys/myhost-1.age
   sops -d secrets/k3s/tokens.yaml
   ```

7. **Back up your private keys** to a secure location (password manager, offline storage, etc.)

8. **Commit the encrypted secrets** (but NOT the private keys):
   ```bash
   git add secrets/.sops.yaml secrets/k3s/tokens.yaml
   git commit -m "Initialize secrets for my-deployment environment"
   ```

### Key Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ UPSTREAM (original n3x)                                      │
│   secrets/keys/admin.age    → upstream admin key (PRIVATE)  │
│   secrets/k3s/tokens.yaml   → encrypted to upstream keys    │
│   .sops.yaml                → upstream public keys          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ YOUR FORK                                                    │
│   secrets/keys/admin.age    → YOUR admin key (PRIVATE)      │
│   secrets/k3s/tokens.yaml   → encrypted to YOUR keys        │
│   .sops.yaml                → YOUR public keys              │
│                                                              │
│   ⚠️ NEVER copy upstream private keys!                       │
│   ⚠️ ALWAYS generate fresh keys and tokens!                  │
└─────────────────────────────────────────────────────────────┘
```

### Merging Upstream Changes

When pulling updates from upstream:

1. **Merge everything EXCEPT secrets**:
   ```bash
   git fetch upstream
   git merge upstream/main --no-commit

   # Restore YOUR secrets (don't take upstream's)
   git checkout HEAD -- secrets/.sops.yaml secrets/k3s/tokens.yaml

   git commit -m "Merge upstream, preserve local secrets"
   ```

2. If upstream adds NEW secret files, you'll need to encrypt them with your keys:
   ```bash
   # Check for new secret files from upstream
   git diff upstream/main --name-only -- 'secrets/**/*.yaml'

   # For each new file, decrypt with upstream's example and re-encrypt with your keys
   # (Or create from scratch following the upstream pattern)
   ```

### Testing Without Secrets (nixosTest)

The n3x test infrastructure bypasses sops entirely for CI/CD and local testing:

- `tests/lib/mk-k3s-cluster-test.nix`: Uses inline test tokens
- `tests/emulation/lib/mkInnerVMImage.nix`: Uses hardcoded test tokens

This design means:
- **Tests work without ANY age keys**
- **CI/CD needs no secrets access**
- **Fork testing works immediately** (no key setup required for `nix flake check`)

Only real hardware deployment requires proper sops key setup.

## References

- [sops-nix Documentation](https://github.com/Mic92/sops-nix)
- [age Encryption](https://github.com/FiloSottile/age)
- [SOPS Documentation](https://github.com/mozilla/sops)
- [NixOS Secrets Management](https://nixos.wiki/wiki/Comparison_of_secret_managing_schemes)