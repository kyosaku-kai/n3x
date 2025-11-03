#!/usr/bin/env bash
# Script to generate age keys for sops-nix secrets management

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$PROJECT_ROOT/secrets"
KEYS_DIR="$SECRETS_DIR/keys"

echo "n3x Age Key Generation Script"
echo "=============================="
echo ""

# Create directories
mkdir -p "$KEYS_DIR"

# Function to generate age key
generate_age_key() {
    local name=$1
    local key_file="$KEYS_DIR/${name}.age"

    if [ -f "$key_file" ]; then
        echo "⚠️  Key already exists for $name, skipping..."
        return
    fi

    echo "Generating age key for $name..."
    age-keygen -o "$key_file" 2>/dev/null
    chmod 600 "$key_file"

    # Extract public key
    local public_key=$(grep "public key:" "$key_file" | cut -d' ' -f3)
    echo "  Public key: $public_key"
}

# Generate keys for admin
echo "Generating admin key..."
generate_age_key "admin"

# Generate keys for each host
echo ""
echo "Generating host keys..."
for host in n100-1 n100-2 n100-3; do
    generate_age_key "$host"
done

# Create a summary file with all public keys
echo ""
echo "Creating public keys summary..."
PUBLIC_KEYS_FILE="$SECRETS_DIR/public-keys.txt"

cat > "$PUBLIC_KEYS_FILE" << EOF
# n3x Public Age Keys
# This file contains the public keys for all hosts and admin
# These keys are used in .sops.yaml for encrypting secrets

EOF

echo "# Admin key" >> "$PUBLIC_KEYS_FILE"
echo -n "admin: " >> "$PUBLIC_KEYS_FILE"
grep "public key:" "$KEYS_DIR/admin.age" | cut -d' ' -f3 >> "$PUBLIC_KEYS_FILE"
echo "" >> "$PUBLIC_KEYS_FILE"

echo "# Host keys" >> "$PUBLIC_KEYS_FILE"
for host in n100-1 n100-2 n100-3; do
    if [ -f "$KEYS_DIR/${host}.age" ]; then
        echo -n "${host}: " >> "$PUBLIC_KEYS_FILE"
        grep "public key:" "$KEYS_DIR/${host}.age" | cut -d' ' -f3 >> "$PUBLIC_KEYS_FILE"
    fi
done

echo ""
echo "✅ Age keys generated successfully!"
echo ""
echo "Public keys have been saved to: $PUBLIC_KEYS_FILE"
echo ""
echo "⚠️  IMPORTANT: "
echo "  - Keep the .age files in $KEYS_DIR secure and backed up!"
echo "  - These are the private keys needed to decrypt secrets"
echo "  - The admin.age key should be kept on your management machine"
echo "  - Host keys should be deployed to their respective nodes during provisioning"
echo ""
echo "Next steps:"
echo "  1. Review the public keys in $PUBLIC_KEYS_FILE"
echo "  2. Use these keys to configure .sops.yaml"
echo "  3. Deploy host keys to /var/lib/sops-nix/key.txt on each node"