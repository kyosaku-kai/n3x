#!/usr/bin/env bash
# Extract public keys from age key files

KEYS_DIR="/data/data/com.termux/files/home/termux-src/n3x/secrets/keys"

echo "# n3x Public Age Keys"
echo "# This file contains the public keys for all hosts and admin"
echo "# These keys are used in .sops.yaml for encrypting secrets"
echo ""
echo "# Admin key"
admin_key=$(grep "^# public key:" "$KEYS_DIR/admin.age" | cut -d' ' -f4)
echo "admin: $admin_key"
echo ""
echo "# Host keys"
n100_1_key=$(grep "^# public key:" "$KEYS_DIR/n100-1.age" | cut -d' ' -f4)
echo "n100-1: $n100_1_key"
n100_2_key=$(grep "^# public key:" "$KEYS_DIR/n100-2.age" | cut -d' ' -f4)
echo "n100-2: $n100_2_key"
n100_3_key=$(grep "^# public key:" "$KEYS_DIR/n100-3.age" | cut -d' ' -f4)
echo "n100-3: $n100_3_key"