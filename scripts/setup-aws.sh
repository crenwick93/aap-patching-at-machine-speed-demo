#!/usr/bin/env bash
set -euo pipefail

# Bootstrap AWS infrastructure for the patching demo.
# Idempotent — reuses existing resources if they already exist.
#
# Creates:
#   - Security group (SSH from your IP)
#   - EC2 key pair + PEM file
#   - Looks up the RHEL 9.8 AMI
#
# Uses:
#   - Default VPC + first public subnet (every AWS account has these)
#
# Writes DEMO_* values into .env (creates from .env.example if missing).
#
# Usage: ./scripts/setup-aws.sh [--region eu-west-1]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGION="eu-west-1"
PROJECT_TAG="patching-demo"
SG_NAME="patching-demo-sg"
KEY_NAME="patching-demo-key"

for arg in "$@"; do
  case "$arg" in
    --region) shift; REGION="$1"; shift ;;
    --region=*) REGION="${arg#*=}" ;;
  esac
done

# ─── Preflight ───────────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found. Install it first."; exit 1; }

if ! aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1; then
  echo "ERROR: AWS credentials not configured."
  echo "  Run: aws configure"
  echo "  Or set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in your environment."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              AWS Infrastructure Setup                     ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Account:  ${ACCOUNT_ID}                              ║"
echo "║  Region:   ${REGION}                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ─── VPC + Subnet ────────────────────────────────────────────────────────────
echo "── VPC + Subnet ──"
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=is-default,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "  No default VPC found — looking for any VPC tagged ${PROJECT_TAG}..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null)
  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "  ERROR: No VPC available. Create a default VPC:"
    echo "    aws ec2 create-default-vpc --region ${REGION}"
    exit 1
  fi
fi
echo "  VPC: ${VPC_ID}"

SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
  --query "Subnets[0].SubnetId" \
  --output text 2>/dev/null)

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[0].SubnetId" \
    --output text 2>/dev/null)
fi

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  echo "  ERROR: No subnet found in VPC ${VPC_ID}"
  exit 1
fi
echo "  Subnet: ${SUBNET_ID}"
echo ""

# ─── Security Group ─────────────────────────────────────────────────────────
echo "── Security Group ──"
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null)

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  echo "  ${SG_NAME}: already exists (${SG_ID})"
else
  SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "SSH access for patching demo instances" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" \
    --output text)

  MY_IP=$(curl -s https://checkip.amazonaws.com)
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "${MY_IP}/32" > /dev/null

  aws ec2 create-tags --region "$REGION" --resources "$SG_ID" \
    --tags "Key=Project,Value=${PROJECT_TAG}" > /dev/null

  echo "  ${SG_NAME}: created (${SG_ID})"
  echo "  SSH allowed from: ${MY_IP}/32"
fi
echo ""

# ─── Key Pair ────────────────────────────────────────────────────────────────
echo "── Key Pair ──"
PEM_FILE="${REPO_ROOT}/${KEY_NAME}.pem"

EXISTING_KEY=$(aws ec2 describe-key-pairs \
  --region "$REGION" \
  --key-names "$KEY_NAME" \
  --query "KeyPairs[0].KeyName" \
  --output text 2>/dev/null || true)

if [[ "$EXISTING_KEY" == "$KEY_NAME" ]]; then
  echo "  ${KEY_NAME}: already exists in AWS"
  if [[ -f "$PEM_FILE" ]]; then
    echo "  PEM file: ${PEM_FILE} (exists)"
  else
    echo "  WARNING: PEM file not found at ${PEM_FILE}"
    echo "  If you've lost the key, delete it and re-run:"
    echo "    aws ec2 delete-key-pair --key-name ${KEY_NAME} --region ${REGION}"
  fi
else
  aws ec2 create-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME" \
    --query "KeyMaterial" \
    --output text > "$PEM_FILE"
  chmod 600 "$PEM_FILE"
  echo "  ${KEY_NAME}: created"
  echo "  PEM file: ${PEM_FILE}"
fi
echo ""

# ─── RHEL 9 AMI ─────────────────────────────────────────────────────────────
echo "── RHEL 9 AMI ──"
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 309956199498 \
  --filters \
    "Name=name,Values=RHEL-9.8*_HVM-*-x86_64-*-Hourly2-GP3" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text 2>/dev/null)

if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 309956199498 \
    --filters \
      "Name=name,Values=RHEL-9*_HVM-*-x86_64-*-Hourly2-GP3" \
      "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}" \
    --output text 2>/dev/null)
  echo "  No RHEL 9.8 AMI found, using latest RHEL 9: ${AMI_ID}"
else
  echo "  RHEL 9.8 AMI: ${AMI_ID}"
fi
echo ""

# ─── Write to .env ──────────────────────────────────────────────────────────
echo "── Updating .env ──"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "${REPO_ROOT}/.env.example" ]]; then
    cp "${REPO_ROOT}/.env.example" "$ENV_FILE"
    echo "  Created .env from .env.example"
  else
    touch "$ENV_FILE"
    echo "  Created empty .env"
  fi
fi

update_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Use a different delimiter since values may contain /
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

update_env "AWS_REGION" "$REGION"
update_env "DEMO_AMI_ID" "$AMI_ID"
update_env "DEMO_INSTANCE_TYPE" "t3.small"
update_env "DEMO_SUBNET_ID" "$SUBNET_ID"
update_env "DEMO_SECURITY_GROUP_ID" "$SG_ID"
update_env "DEMO_KEY_NAME" "$KEY_NAME"
update_env "PROBE_SSH_KEY_PATH" "./${KEY_NAME}.pem"

echo "  ✓ DEMO_AMI_ID=${AMI_ID}"
echo "  ✓ DEMO_SUBNET_ID=${SUBNET_ID}"
echo "  ✓ DEMO_SECURITY_GROUP_ID=${SG_ID}"
echo "  ✓ DEMO_KEY_NAME=${KEY_NAME}"
echo "  ✓ PROBE_SSH_KEY_PATH=./${KEY_NAME}.pem"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  Setup Complete                           ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Still needed in .env (manual):                          ║"
echo "║    • AAP_TOKEN                                           ║"
echo "║    • AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY            ║"
echo "║    • SERVICENOW_PASSWORD                                 ║"
echo "║    • RH_USERNAME / RH_PASSWORD                           ║"
echo "║    • EDA_EVENT_STREAM_URL / EDA_EVENT_STREAM_TOKEN       ║"
echo "║                                                          ║"
echo "║  Next:                                                   ║"
echo "║    ./scripts/reset-demo.sh   (provision 6 instances)     ║"
echo "╚════════════════════════════════════════════════════════════╝"
