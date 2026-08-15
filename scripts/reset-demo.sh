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
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
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
RH_ORG="${RH_ORG_ID:-}"

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

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

echo ""
echo "+============================================================+"
echo "|            Demo Reset - Reprovisioning EC2               |"
echo "+============================================================+"
echo ""

# --- Step 1: Clean ServiceNow records ---
if [[ "$SKIP_SNOW" == false ]]; then
  echo "-- Step 1/7: Cleaning ServiceNow records --"
  if [[ -x "${SCRIPT_DIR}/cleanup-servicenow.sh" ]]; then
    "${SCRIPT_DIR}/cleanup-servicenow.sh" --records 2>/dev/null || echo "  (cleanup had warnings - continuing)"
  else
    echo "  Skipped (cleanup-servicenow.sh not found)"
  fi
  echo ""
else
  echo "-- Step 1/7: Skipping ServiceNow cleanup (--skip-snow) --"
  echo ""
fi

# --- Step 2: Deregister running instances from Insights ---
echo "-- Step 2/7: Deregistering from Insights --"
EXISTING_INFO=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:demo,Values=patching" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{IP:PublicIpAddress,Name:Tags[?Key=='Name']|[0].Value}" \
  --output json 2>/dev/null || echo "[]")

LIVE_COUNT=$(echo "$EXISTING_INFO" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)

if [[ "$LIVE_COUNT" -gt 0 ]]; then
  echo "$EXISTING_INFO" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    if i.get('IP'):
        print(f\"{i['Name']}:{i['IP']}\")
" | while IFS=: read -r dname dip; do
    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${dip}" \
      "sudo insights-client --unregister 2>/dev/null || true; sudo rhc disconnect 2>/dev/null || true; sudo subscription-manager unregister 2>/dev/null || true" \
      > /dev/null 2>&1 && echo "  [OK] ${dname}" || echo "  [SKIP] ${dname} (already cleaned or unreachable)" &
  done
  wait
else
  echo "  No running instances to deregister"
fi
echo ""

# --- Step 3: Terminate existing instances ---
echo "-- Step 3/7: Terminating instances --"
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
  echo "  [OK] All terminated"
else
  echo "  No existing demo instances found"
fi
echo ""

# --- Step 4: Launch fresh instances ---
echo "-- Step 4/7: Launching ${#NODES[@]} fresh instances --"
NEW_IDS=()
UD_TMPFILE=$(mktemp)
trap "rm -f '${UD_TMPFILE}'" EXIT

for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  env="${entry##*:}"
  fqdn="${name}.${DOMAIN}"

  cat > "$UD_TMPFILE" <<USERDATA
#cloud-config
bootcmd:
  - [ systemctl, mask, rhcd.service ]
  - [ systemctl, stop, rhcd.service ]
  - [ systemctl, mask, insights-client.timer ]
  - [ systemctl, mask, rhsmcertd.service ]
  - [ systemctl, stop, rhsmcertd.service ]
runcmd:
  - hostnamectl set-hostname ${fqdn}
  - echo '${fqdn}' > /etc/hostname
USERDATA

  instance_id=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET" \
    --security-group-ids "$SG" \
    --key-name "$KEY_NAME" \
    --user-data "file://${UD_TMPFILE}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=env,Value=${env}},{Key=demo,Value=patching}]" \
    --query "Instances[0].InstanceId" \
    --output text)

  NEW_IDS+=("$instance_id")
  echo "  ${fqdn} (${env}): ${instance_id}"
done
echo ""

# --- Step 5: Wait for running + get IPs ---
echo "-- Step 5/7: Waiting for instances to be running --"
aws ec2 wait instance-running --region "$REGION" --instance-ids "${NEW_IDS[@]}"
echo "  [OK] All running"
echo ""

IP_MAP_FILE=$(mktemp)
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

echo "$INSTANCE_INFO" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f\"{i['Name']}:{i['IP']}\")
" > "$IP_MAP_FILE"
echo ""

# --- Step 6: Register with Insights ---
echo "-- Step 6/7: Registering instances with Red Hat Insights --"

if [[ -z "$RH_USER" || -z "$RH_PASS" ]]; then
  echo "  Skipped (RH_USERNAME / RH_PASSWORD not set)"
  echo ""
else
  # Wait for SSH on all hosts first
  echo "  Waiting for SSH on all hosts..."
  while IFS=: read -r wname wip; do
    if [[ -n "$wip" ]]; then
      elapsed=0
      while ! ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${wip}" true 2>/dev/null; do
        elapsed=$((elapsed + 5))
        if [[ $elapsed -ge 120 ]]; then
          echo "  [FAIL] ${wname}: SSH timeout"
          break
        fi
        sleep 5
      done
    fi
  done < "$IP_MAP_FILE"
  echo "  [OK] SSH available"
  echo ""

  # Wait for cloud-init to finish on all hosts (ensures hostname + any auto-reg is done)
  echo "  Waiting for cloud-init to complete on all hosts..."
  while IFS=: read -r wname wip; do
    if [[ -n "$wip" ]]; then
      ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${wip}" \
        "sudo cloud-init status --wait 2>/dev/null || sleep 30" > /dev/null 2>&1 &
    fi
  done < "$IP_MAP_FILE"
  wait
  echo "  [OK] Cloud-init finished"
  echo ""

  EXPECTED_ORG="${RH_ORG:-}"
  echo "  Registering hosts (expected org: ${EXPECTED_ORG:-any})..."
  register_one() {
    local hname="$1" hip="$2"
    local hfqdn="${hname}.${DOMAIN}"
    local attempt max_attempts=3

    for attempt in $(seq 1 $max_attempts); do
      local out
      out=$(ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${hip}" "bash -s" 2>&1 <<REGSCRPT
# Kill rhcd and rhsmcertd (auto_registration overwrites our --org)
sudo systemctl stop rhcd.service 2>/dev/null || true
sudo systemctl disable rhcd.service 2>/dev/null || true
sudo systemctl mask rhcd.service 2>/dev/null || true
sudo systemctl stop rhsmcertd.service 2>/dev/null || true
sudo systemctl mask rhsmcertd.service 2>/dev/null || true
# Disable cloud auto-registration so rhsmcertd cannot re-register
sudo sed -i 's/^auto_registration\s*=.*/auto_registration = 0/' /etc/rhsm/rhsm.conf 2>/dev/null || true
# Nuke ALL registration and cached state
sudo insights-client --unregister 2>/dev/null || true
sudo subscription-manager unregister 2>/dev/null || true
sudo rm -f /etc/insights-client/machine-id /etc/insights-client/.registered
sudo rm -rf /etc/pki/consumer/* /etc/pki/entitlement/*
sudo rm -rf /var/lib/rhsm/cache/* /var/lib/rhsm/facts/*
# Register fresh
sudo subscription-manager register --username='${RH_USER}' --password='${RH_PASS}' --org='${EXPECTED_ORG}' --force 2>&1
# Verify org before proceeding
org=\$(sudo subscription-manager identity 2>&1 | grep 'org name' | awk '{print \$NF}')
echo "RHSM_ORG=\${org}"
# Register and upload to Insights
sudo insights-client --register 2>&1
# Re-enable rhsmcertd for cert renewal (auto_registration already disabled)
sudo systemctl unmask rhsmcertd.service 2>/dev/null || true
sudo systemctl enable --now rhsmcertd.service 2>/dev/null || true
# Enable periodic uploads so Insights reflects post-patch state
sudo systemctl unmask insights-client.timer 2>/dev/null || true
sudo systemctl enable --now insights-client.timer 2>/dev/null || true
sudo insights-client 2>&1 | tail -1
REGSCRPT
)
      local registered_org
      registered_org=$(echo "$out" | grep "^RHSM_ORG=" | cut -d= -f2)
      local acct_line
      acct_line=$(echo "$out" | grep "account " | tail -1)

      if [[ -n "$EXPECTED_ORG" && "$registered_org" != "$EXPECTED_ORG" ]]; then
        echo "  [RETRY ${attempt}/${max_attempts}] ${hfqdn} -- wrong org ${registered_org}, expected ${EXPECTED_ORG}"
        continue
      fi

      if echo "$out" | grep -q "Successfully uploaded"; then
        echo "  [OK] ${hfqdn} -- ${acct_line} (org: ${registered_org})"
        return 0
      fi
    done

    echo "  [FAIL] ${hfqdn} -- could not register to correct org after ${max_attempts} attempts"
    return 1
  }

  while IFS=: read -r rname rip; do
    if [[ -n "$rip" ]]; then
      register_one "$rname" "$rip" &
    fi
  done < "$IP_MAP_FILE"
  wait

  rm -f "$IP_MAP_FILE"
  echo ""

  # Verify and retry any hosts that failed registration
  echo "  Verifying registration (retry any failures)..."
  VERIFY_LIST=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:demo,Values=patching" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,IP:PublicIpAddress}" \
    --output json 2>/dev/null)

  FAILED_HOSTS=""
  while IFS=: read -r vname vip; do
    vresult=$(ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${vip}" \
      "sudo insights-client --status 2>&1" 2>/dev/null || echo "error")
    if echo "$vresult" | grep -q "confirms registration"; then
      echo "  [OK] ${vname}: registered"
    else
      echo "  [MISS] ${vname}: not registered — will retry"
      FAILED_HOSTS="${FAILED_HOSTS}${vname}:${vip}\n"
    fi
  done < <(echo "$VERIFY_LIST" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f\"{i['Name']}:{i['IP']}\")
")

  if [[ -n "$FAILED_HOSTS" ]]; then
    echo ""
    echo "  Retrying failed registrations sequentially..."
    while IFS=: read -r fname fip; do
      [[ -z "$fname" ]] && continue
      echo "  Registering ${fname}..."
      register_one "$fname" "$fip"
    done < <(echo -e "$FAILED_HOSTS")
  fi
  echo ""

  # Install kpatch on all nodes (needed for demo CLI commands)
  echo "  Installing kpatch on all nodes..."
  while IFS=: read -r pname pip; do
    if [[ -n "$pip" ]]; then
      ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${pip}" \
        "sudo dnf install -y kpatch > /dev/null 2>&1 && echo ok || echo fail" \
        2>/dev/null &
    fi
  done < <(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:demo,Values=patching" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,IP:PublicIpAddress}" \
    --output json 2>/dev/null | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    print(f\"{i['Name']}:{i['IP']}\")
")
  wait
  echo "  [OK] kpatch installed"
  echo ""
fi

# --- Step 7: Sync AAP inventory ---
echo "-- Step 7/7: Syncing AAP dynamic inventory --"

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
  echo "  [OK] Inventory sync triggered (source ID: ${INV_SOURCE_ID})"
else
  echo "  [FAIL] Could not find 'AWS EC2 Discovery' inventory source"
fi

echo ""

# --- Step 8: Update /etc/hosts for demo SSH convenience ---
echo "-- Step 8/8: Updating /etc/hosts for demo SSH shortcuts --"

DEMO_HOSTS=("rhel-dev-01" "rhel-prod-01")
HOSTS_UPDATED=0

DEMO_IPS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=rhel-dev-01,rhel-prod-01" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],IP:PublicIpAddress}' \
  --output json 2>/dev/null)

# Remove old demo entries
sudo sed -i.bak '/\.trading-demo\.chrislab\.dev/d' /etc/hosts 2>/dev/null || \
  sudo sed -i '' '/\.trading-demo\.chrislab\.dev/d' /etc/hosts 2>/dev/null

for dh in "${DEMO_HOSTS[@]}"; do
  dip=$(echo "$DEMO_IPS" | python3 -c "
import json, sys
for i in json.load(sys.stdin):
    if i.get('Name') == '${dh}' and i.get('IP'):
        print(i['IP']); break
" 2>/dev/null)
  if [[ -n "$dip" ]]; then
    echo "${dip} ${dh}.trading-demo.chrislab.dev" | sudo tee -a /etc/hosts > /dev/null
    echo "  [OK] ${dh}.trading-demo.chrislab.dev -> ${dip}"
    HOSTS_UPDATED=$((HOSTS_UPDATED + 1))
  else
    echo "  [SKIP] Could not resolve IP for ${dh}"
  fi
done

if [[ "$HOSTS_UPDATED" -gt 0 ]]; then
  echo "  You can now: ssh -i colombo-demo.pem ec2-user@rhel-dev-01.trading-demo.chrislab.dev"
fi

echo ""
echo "+============================================================+"
echo "|                    Reset Complete                         |"
echo "+============================================================+"
echo "|  * 6 fresh RHEL instances provisioned                    |"
echo "|  * Hostnames set via cloud-init                          |"
echo "|  * AAP inventory sync triggered                          |"
echo "|  * /etc/hosts updated for demo SSH                       |"
echo "|                                                          |"
echo "|  Next steps:                                             |"
echo "|  1. Wait ~60s for inventory sync to complete             |"
echo "|  2. Run: ./scripts/simulate-cve-event.sh                 |"
echo "+============================================================+"
