# agenix secrets configuration for n3x build runners
#
# This file maps encrypted .age files to the SSH public keys authorized
# to decrypt them. Each host's SSH host key must be listed to allow
# decryption during NixOS activation.
#
# Usage:
#   cd infra/nixos-runner/secrets
#   agenix -e cache-signing-key.age  # encrypt/edit a secret
#   agenix -r                         # rekey all secrets after key changes
#
# To add a new host:
#   1. Get its SSH host public key: ssh-keyscan <host> | grep ed25519
#   2. Add the key below
#   3. Run: agenix -r (to rekey all secrets for the new host)
let
  # SSH host public keys for each runner node.
  # These are populated when hosts are deployed via nixos-anywhere.
  # TODO: Replace with actual host SSH public keys after deployment (Task 8+)

  # Placeholder keys — replace with real ed25519 host keys
  # Get with: ssh-keyscan -t ed25519 <host> | awk '{print $3}'
  ec2-x86_64 = "ssh-ed25519 AAAA_PLACEHOLDER_ec2_x86_64";
  ec2-graviton = "ssh-ed25519 AAAA_PLACEHOLDER_ec2_graviton";
  zfs-proto-1 = "ssh-ed25519 AAAA_PLACEHOLDER_zfs_proto_1";
  zfs-proto-2 = "ssh-ed25519 AAAA_PLACEHOLDER_zfs_proto_2";
  zfs-proto-3 = "ssh-ed25519 AAAA_PLACEHOLDER_zfs_proto_3";
  on-prem-runner = "ssh-ed25519 AAAA_PLACEHOLDER_on_prem_runner";

  # Admin keys (for encrypting secrets locally)
  # TODO: Replace with actual admin SSH public keys
  admin = "ssh-ed25519 AAAA_PLACEHOLDER_admin";

  allHosts = [ ec2-x86_64 ec2-graviton zfs-proto-1 zfs-proto-2 zfs-proto-3 on-prem-runner ];
  allKeys = [ admin ] ++ allHosts;
in
{
  # Nix binary cache signing private key
  # All build runner hosts need this to sign store paths
  "cache-signing-key.age".publicKeys = allKeys;
}
