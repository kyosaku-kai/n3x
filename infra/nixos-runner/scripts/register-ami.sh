#!/usr/bin/env bash
# register-ami.sh — Build NixOS AMI and register in AWS
#
# Bridges: nix build (VHD output) → S3 upload → EBS snapshot → AMI registration
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials (aws sts get-caller-identity)
#   - S3 bucket for VHD upload (must exist, can be temporary)
#   - VM Import/Export service role (vmimport) configured in AWS account
#     See: https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html
#   - nix with flakes enabled
#
# Usage:
#   ./register-ami.sh --arch x86_64 --region us-east-1 --bucket my-ami-bucket
#   ./register-ami.sh --arch aarch64 --region us-east-1 --bucket my-ami-bucket --pulumi-stack dev
#
# The vmimport service role must trust the S3 bucket. Minimal setup:
#   aws iam create-role --role-name vmimport --assume-role-policy-document file://trust-policy.json
#   aws iam put-role-policy --role-name vmimport --policy-name vmimport --policy-document file://role-policy.json
set -euo pipefail

# --- Argument parsing ---

ARCH=""
REGION=""
BUCKET=""
PULUMI_STACK=""
FLAKE_DIR=""

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --arch <x86_64|aarch64> --region <aws-region> --bucket <s3-bucket> [options]

Required:
  --arch          CPU architecture (x86_64 or aarch64)
  --region        AWS region for AMI registration
  --bucket        S3 bucket for VHD upload (temporary, can delete after)

Optional:
  --pulumi-stack  Set AMI ID in Pulumi config after registration
  --flake-dir     Path to nixos-runner flake (default: script's parent directory)
  --help          Show this help

Examples:
  $(basename "$0") --arch x86_64 --region us-east-1 --bucket n3x-ami-staging
  $(basename "$0") --arch aarch64 --region us-east-1 --bucket n3x-ami-staging --pulumi-stack dev
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)     ARCH="$2";          shift 2 ;;
        --region)   REGION="$2";        shift 2 ;;
        --bucket)   BUCKET="$2";        shift 2 ;;
        --pulumi-stack) PULUMI_STACK="$2"; shift 2 ;;
        --flake-dir) FLAKE_DIR="$2";    shift 2 ;;
        --help|-h)  usage ;;
        *)          echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "$ARCH" || -z "$REGION" || -z "$BUCKET" ]]; then
    echo "Error: --arch, --region, and --bucket are required" >&2
    usage
fi

# Resolve architecture-specific names
case "$ARCH" in
    x86_64)
        SYSTEM="x86_64-linux"
        PKG_NAME="ami-ec2-x86_64"
        AMI_NAME_PREFIX="n3x-nixos-x86_64"
        BOOT_MODE="uefi-preferred"
        PULUMI_KEY="n3x:amiX86"
        AWS_ARCH="x86_64"
        ;;
    aarch64)
        SYSTEM="aarch64-linux"
        PKG_NAME="ami-ec2-graviton"
        AMI_NAME_PREFIX="n3x-nixos-graviton"
        BOOT_MODE="uefi"
        PULUMI_KEY="n3x:amiArm64"
        AWS_ARCH="arm64"  # AWS API uses arm64, not aarch64
        ;;
    *)
        echo "Error: --arch must be x86_64 or aarch64" >&2
        exit 1
        ;;
esac

# Default flake directory: parent of scripts/
if [[ -z "$FLAKE_DIR" ]]; then
    FLAKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

DATE_TAG="$(date +%Y%m%d-%H%M%S)"
AMI_NAME="${AMI_NAME_PREFIX}-${DATE_TAG}"
S3_KEY="ami/${AMI_NAME}.vhd"
S3_UPLOADED=false

# Cleanup on failure: remove S3 object if uploaded, remove nix build symlink
cleanup() {
    if [[ "$S3_UPLOADED" == "true" ]]; then
        echo "Cleaning up: s3://${BUCKET}/${S3_KEY}" >&2
        aws s3 rm "s3://${BUCKET}/${S3_KEY}" --region "$REGION" 2>/dev/null || true
    fi
    rm -f result-ami
}
trap cleanup EXIT

# Check required tools
for cmd in aws nix jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found in PATH" >&2
        exit 1
    fi
done

echo "=== n3x AMI Registration ==="
echo "Architecture: ${ARCH}"
echo "Region:       ${REGION}"
echo "S3 Bucket:    ${BUCKET}"
echo "AMI Name:     ${AMI_NAME}"
echo "Flake Dir:    ${FLAKE_DIR}"
echo ""

# --- Step 1: Build VHD ---

echo "--- Step 1/6: Building NixOS VHD ---"
nix build "${FLAKE_DIR}#packages.${SYSTEM}.${PKG_NAME}" --out-link result-ami

# system.build.images.amazon produces a VHD in the result
VHD_PATH="$(readlink -f result-ami)"
# Find the .vhd file in the output
VHD_FILE="$(find "$VHD_PATH" -name '*.vhd' -type f | head -1)"
if [[ -z "$VHD_FILE" ]]; then
    echo "Error: No .vhd file found in build output: ${VHD_PATH}" >&2
    echo "Contents:" >&2
    ls -la "$VHD_PATH" >&2
    exit 1
fi

VHD_SIZE_BYTES="$(stat -c%s "$VHD_FILE")"
VHD_SIZE_GB=$(( (VHD_SIZE_BYTES + 1073741823) / 1073741824 ))
echo "VHD: ${VHD_FILE} (${VHD_SIZE_GB} GB)"

# --- Step 2: Upload VHD to S3 ---

echo "--- Step 2/6: Uploading VHD to s3://${BUCKET}/${S3_KEY} ---"
aws s3 cp "$VHD_FILE" "s3://${BUCKET}/${S3_KEY}" --region "$REGION"
S3_UPLOADED=true
echo "Upload complete"

# --- Step 3: Import snapshot ---

echo "--- Step 3/6: Importing EBS snapshot from S3 ---"
IMPORT_TASK_ID="$(aws ec2 import-snapshot \
    --region "$REGION" \
    --description "n3x NixOS ${ARCH} ${DATE_TAG}" \
    --disk-container '{
        "Description": "n3x NixOS '"${ARCH}"'",
        "Format": "VHD",
        "UserBucket": {
            "S3Bucket": "'"${BUCKET}"'",
            "S3Key": "'"${S3_KEY}"'"
        }
    }' \
    --query 'ImportTaskId' --output text)"
echo "Import task: ${IMPORT_TASK_ID}"

# --- Step 4: Poll until complete ---

echo "--- Step 4/6: Waiting for snapshot import ---"
while true; do
    STATUS_JSON="$(aws ec2 describe-import-snapshot-tasks \
        --region "$REGION" \
        --import-task-ids "$IMPORT_TASK_ID" \
        --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' \
        --output json)"

    STATUS="$(echo "$STATUS_JSON" | jq -r '.Status // "unknown"')"
    PROGRESS="$(echo "$STATUS_JSON" | jq -r '.Progress // ""')"

    case "$STATUS" in
        completed)
            SNAPSHOT_ID="$(echo "$STATUS_JSON" | jq -r '.SnapshotId')"
            echo "Snapshot ready: ${SNAPSHOT_ID}"
            break
            ;;
        active)
            echo "  importing... ${PROGRESS}%"
            sleep 30
            ;;
        deleting|deleted|error)
            echo "Error: import failed with status: ${STATUS}" >&2
            echo "$STATUS_JSON" >&2
            exit 1
            ;;
        *)
            echo "  status: ${STATUS} ${PROGRESS}"
            sleep 15
            ;;
    esac
done

# --- Step 5: Register AMI ---

echo "--- Step 5/6: Registering AMI ---"
AMI_ID="$(aws ec2 register-image \
    --region "$REGION" \
    --name "$AMI_NAME" \
    --description "n3x NixOS runner ${ARCH} ${DATE_TAG}" \
    --architecture "$AWS_ARCH" \
    --root-device-name /dev/xvda \
    --boot-mode "$BOOT_MODE" \
    --virtualization-type hvm \
    --ena-support \
    --block-device-mappings "[{
        \"DeviceName\": \"/dev/xvda\",
        \"Ebs\": {
            \"SnapshotId\": \"${SNAPSHOT_ID}\",
            \"VolumeSize\": ${VHD_SIZE_GB},
            \"VolumeType\": \"gp3\",
            \"DeleteOnTermination\": true
        }
    }]" \
    --query 'ImageId' --output text)"
echo "AMI registered: ${AMI_ID}"

# --- Step 6: Tag AMI ---

echo "--- Step 6/6: Tagging AMI ---"
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$AMI_ID" "$SNAPSHOT_ID" \
    --tags \
        "Key=Project,Value=n3x" \
        "Key=NixOS,Value=true" \
        "Key=Architecture,Value=${ARCH}" \
        "Key=Created,Value=${DATE_TAG}" \
        "Key=Name,Value=${AMI_NAME}"
echo "Tags applied"

# --- Optional: Set Pulumi config ---

if [[ -n "$PULUMI_STACK" ]]; then
    echo ""
    echo "--- Setting Pulumi config ---"
    PULUMI_DIR="$(cd "$(dirname "$0")/../../pulumi" && pwd)"
    (cd "$PULUMI_DIR" && pulumi config set --stack "$PULUMI_STACK" "$PULUMI_KEY" "$AMI_ID")
    echo "Set ${PULUMI_KEY}=${AMI_ID} on stack ${PULUMI_STACK}"
fi

# --- Cleanup ---
# S3 object and result-ami symlink cleaned up by EXIT trap

# --- Summary ---

echo ""
echo "=== AMI Registration Complete ==="
echo "AMI ID:     ${AMI_ID}"
echo "Snapshot:   ${SNAPSHOT_ID}"
echo "Region:     ${REGION}"
echo "Arch:       ${ARCH}"
echo "Name:       ${AMI_NAME}"
echo ""
echo "Next steps:"
echo "  pulumi config set ${PULUMI_KEY} ${AMI_ID}"
echo "  pulumi up"
