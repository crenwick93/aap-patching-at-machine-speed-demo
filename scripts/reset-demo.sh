#!/usr/bin/env bash
set -euo pipefail

# Fast demo reset: terminate EC2 instances and reprovision fresh ones.
# Handles hostname setup, RHEL subscription, and Insights registration.
# Triggers AAP inventory sync so new IPs are picked up automatically.
#
# Usage: ./scripts/reset-demo.sh [--skip-snow]
#   --skip-snow  Skip ServiceNow record cleanup (keeps existing CMDB CIs)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_SNOW=false
for arg in "$@"; do
  case "$arg" in
    --skip-snow) SKIP_SNOW=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | grep -v '^\s*$' | xargs -I{} echo {})
fi

REGION="${AWS_REGION:-eu-west-1}"
AMI="${DEMO_AMI_ID:?Set DEMO_AMI_ID in .env}"
INSTANCE_TYPE="${DEMO_INSTANCE_TYPE:-t3.small}"
SUBNET="${DEMO_SUBNET_ID:?Set DEMO_SUBNET_ID in .env}"
SG="${DEMO_SECURITY_GROUP_ID:?Set DEMO_SECURITY_GROUP_ID in .env}"
KEY_NAME="${DEMO_KEY_NAME:-colombo-demo}"
DOMAIN="trading-demo.chrislab.dev"
SSH_KEY="${PROBE_SSH_KEY_PATH:?Set PROBE_SSH_KEY_PATH in .env}"
SSH_USER="ec2-user"

AAP_HOST="${AAP_HOSTNAME:?Set AAP_HOSTNAME in .env}"
AAP_HOST="${AAP_HOST%/}"
AAP_TOKEN_VAL="${AAP_TOKEN:?Set AAP_TOKEN in .env}"

RH_USER="${RH_USERNAME:-}"
RH_PASS="${RH_PASSWORD:-}"

if [[ -z "$RH_USER" || -z "$RH_PASS" ]]; then
  echo "WARNING: RH_USERNAME / RH_PASSWORD not set in .env"
  echo "         Instances will NOT be registered with Insights."
  echo ""
fi

NODES=(
  "rhel-dev-01:dev"
  "rhel-dev-02:dev"
  "rhel-dev-03:dev"
  "rhel-prod-01:prod"
  "rhel-prod-02:prod"
  "rhel-prod-03:prod"
)

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            Demo Reset — Reprovisioning EC2               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Clean ServiceNow records ───────────────────────────────────────
if [[ "$SKIP_SNOW" == false ]]; then
  echo "── Step 1/6: Cleaning ServiceNow records ──"
  if [[ -x "${SCRIPT_DIR}/cleanup-servicenow.sh" ]]; then
    "${SCRIPT_DIR}/cleanup-servicenow.sh" --records 2>/dev/null || echo "  (cleanup had warnings — continuing)"
  else
    echo "  Skipped (cleanup-servicenow.sh not found)"
  fi
  echo ""
else
  echo "── Step 1/6: Skipping ServiceNow cleanup (--skip-snow) ──"
  echo ""
fi

# ─── Step 2: Terminate existing instances ────────────────────────────────────
echo "── Step 2/6: Terminating existing instances ──"
EXISTING_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:demo,Values=patching" "Name=instance-state-name,Values=running,stopped,stopping" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text 2>/dev/null || true)

if [[ -n "$EXISTING_IDS" && "$EXISTING_IDS" != "None" ]]; then
  count=$(echo "$EXISTING_IDS" | wc -w | tr -d ' ')
  echo "  Terminating ${count} instances: ${EXISTING_IDS}"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $EXISTING_IDS > /dev/null
  echo "  Waiting for termination..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $EXISTING_IDS
  echo "  ✓ All terminated"
else
  echo "  No existing demo instances found"
fi
echo ""

# ─── Step 3: Launch fresh instances ──────────────────────────────────────────
echo "── Step 3/6: Launching ${#NODES[@]} fresh instances ──"
NEW_IDS=()

for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  env="${entry##*:}"
  fqdn="${name}.${DOMAIN}"

  USER_DATA="#!/bin/bash
hostnamectl set-hostname ${fqdn}
echo '${fqdn}' > /etc/hostname"

  instance_id=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET" \
    --security-group-ids "$SG" \
    --key-name "$KEY_NAME" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=env,Value=${env}},{Key=demo,Value=patching}]" \
    --query "Instances[0].InstanceId" \
    --output text 2>/dev/null)

  NEW_IDS+=("$instance_id")
  echo "  ${fqdn} (${env}): ${instance_id}"
done
echo ""

# ─── Step 4: Wait for running + get IPs ─────────────────────────────────────
echo "── Step 4/6: Waiting for instances to be running ──"
aws ec2 wait instance-running --region "$REGION" --instance-ids "${NEW_IDS[@]}"
echo "  ✓ All running"
echo ""

# Build IP map
declare -A IP_MAP
INSTANCE_INFO=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "${NEW_IDS[@]}" \
  --query "Reservations[].Instances[].{ID:InstanceId,IP:PublicIpAddress,Name:Tags[?Key=='Name']|[0].Value,Env:Tags[?Key=='env']|[0].Value}" \
  --output json 2>/dev/null)

echo "  Instance details:"
echo "$INSTANCE_INFO" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f\"    {i['Name']:20s}  {i['Env']:5s}  {i['IP']:16s}  {i['ID']}\")
"

# Parse IPs into shell associative array
eval "$(echo "$INSTANCE_INFO" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f'IP_MAP[{i[\"Name\"]}]={i[\"IP\"]}')
")"
echo ""

# ─── Step 5: Register with Insights ─────────────────────────────────────────
echo "── Step 5/6: Registering instances with Red Hat Insights ──"

if [[ -z "$RH_USER" || -z "$RH_PASS" ]]; then
  echo "  Skipped (RH_USERNAME / RH_PASSWORD not set)"
  echo ""
else
  wait_for_ssh() {
    local ip="$1" max_wait=120 elapsed=0
    while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
              -i "$SSH_KEY" "${SSH_USER}@${ip}" true 2>/dev/null; do
      elapsed=$((elapsed + 5))
      if [[ $elapsed -ge $max_wait ]]; then
        echo "    SSH timeout after ${max_wait}s"
        return 1
      fi
      sleep 5
    done
    return 0
  }

  register_host() {
    local name="$1" ip="$2"
    local fqdn="${name}.${DOMAIN}"

    if ! wait_for_ssh "$ip"; then
      echo "  ✗ ${fqdn}: SSH not available"
      return 1
    fi

    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "${SSH_USER}@${ip}" \
      "sudo subscription-manager register --username='${RH_USER}' --password='${RH_PASS}' --force 2>&1 && \
       sudo rhc connect 2>&1" > /dev/null 2>&1

    if [[ $? -eq 0 ]]; then
      echo "  ✓ ${fqdn}"
    else
      echo "  ✗ ${fqdn}: registration failed (check credentials)"
    fi
  }

  echo "  Waiting for SSH availability..."
  for entry in "${NODES[@]}"; do
    name="${entry%%:*}"
    ip="${IP_MAP[$name]:-}"
    if [[ -n "$ip" ]]; then
      register_host "$name" "$ip" &
    fi
  done
  wait
  echo ""
fi

# ─── Step 6: Sync AAP inventory ─────────────────────────────────────────────
echo "── Step 6/6: Syncing AAP dynamic inventory ──"

INV_SOURCE_ID=$(curl -sk -H "Authorization: Bearer ${AAP_TOKEN_VAL}" \
  "${AAP_HOST}/api/controller/v2/inventory_sources/?name=AWS+EC2+Discovery" \
  2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['results'][0]['id'] if d.get('results') else '')
" 2>/dev/null)

if [[ -n "$INV_SOURCE_ID" ]]; then
  curl -sk -X POST -H "Authorization: Bearer ${AAP_TOKEN_VAL}" \
    "${AAP_HOST}/api/controller/v2/inventory_sources/${INV_SOURCE_ID}/update/" \
    -H "Content-Type: application/json" > /dev/null 2>&1
  echo "  ✓ Inventory sync triggered (source ID: ${INV_SOURCE_ID})"
else
  echo "  ✗ Could not find 'AWS EC2 Discovery' inventory source"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Reset Complete                         ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  • 6 fresh RHEL instances provisioned                    ║"
echo "║  • Hostnames set via cloud-init                          ║"
echo "║  • AAP inventory sync triggered                          ║"
echo "║                                                          ║"
echo "║  Next steps:                                             ║"
echo "║  1. Wait ~60s for inventory sync to complete             ║"
echo "║  2. Run: ./scripts/simulate-cve-event.sh                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
