#!/usr/bin/env bash
# Generate K3s tokens for cluster setup

set -euo pipefail

# Generate random tokens
SERVER_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
AGENT_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

# Create the tokens YAML file
cat > /data/data/com.termux/files/home/termux-src/n3x/secrets/k3s/tokens-plain.yaml << EOF
# K3s cluster tokens
# These tokens are used for secure node joining
# Server token is shared between all server nodes
# Agent token is used by agent nodes to join the cluster

server-token: "$SERVER_TOKEN"
agent-token: "$AGENT_TOKEN"
EOF

echo "K3s tokens generated successfully!"
echo ""
echo "Tokens saved to: secrets/k3s/tokens-plain.yaml"
echo ""
echo "Server token (first 20 chars): ${SERVER_TOKEN:0:20}..."
echo "Agent token (first 20 chars): ${AGENT_TOKEN:0:20}..."
echo ""
echo "Next step: Encrypt the tokens file with sops"