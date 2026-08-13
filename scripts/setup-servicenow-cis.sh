#!/usr/bin/env bash
set -euo pipefail

# Register demo CMDB structure in ServiceNow:
#   Trading Platform (Business Service)
#   ├── Trading Platform (Dev)  — rhel-dev-01, rhel-dev-02, rhel-dev-03
#   └── Trading Platform (Prod) — rhel-prod-01, rhel-prod-02, rhel-prod-03
#
# Run this once before the demo to establish the CI baseline.
#
# Usage: ./scripts/setup-servicenow-cis.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
fi

SN_HOST="${SERVICENOW_INSTANCE_URL:?Set SERVICENOW_INSTANCE_URL in .env}"
SN_USER="${SERVICENOW_USERNAME:?Set SERVICENOW_USERNAME in .env}"
SN_PASS="${SERVICENOW_PASSWORD:?Set SERVICENOW_PASSWORD in .env}"

DEPENDS_ON="1a9cb166f1571100a92eb60da2bce5c5"
RUNS_ON="60bc4e22c0a8010e01f074cbe6bd73c3"

# Helper: look up CI by name and table, return sys_id or empty string
lookup_ci() {
  local table="$1" name="$2"
  curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/${table}?sysparm_query=name=${name}&sysparm_fields=sys_id" \
    -H "Accept: application/json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['result'][0]['sys_id'] if d.get('result') else '')
" 2>/dev/null
}

# Helper: create CI, return sys_id
create_ci() {
  local table="$1" payload="$2"
  curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/${table}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -X POST -d "${payload}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['sys_id'])" 2>/dev/null
}

# Helper: create relationship
create_rel() {
  local parent="$1" child="$2" rel_type="$3"
  curl -s -o /dev/null -w "%{http_code}" \
    -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/cmdb_rel_ci" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -X POST -d "{\"parent\": \"${parent}\", \"child\": \"${child}\", \"type\": \"${rel_type}\"}"
}

echo "Setting up ServiceNow CMDB for demo..."
echo ""

# --- Business Service ---
echo "=== Business Service ==="
biz_id=$(lookup_ci "cmdb_ci_service" "Trading Platform")
if [[ -n "$biz_id" ]]; then
  echo "  Trading Platform: already exists (${biz_id})"
else
  biz_id=$(create_ci "cmdb_ci_service" '{
    "name": "Trading Platform",
    "short_description": "Core trading platform — equities, FX, and derivatives",
    "operational_status": "1"
  }')
  echo "  Trading Platform: created (${biz_id})"
fi

# --- Application Services ---
echo ""
echo "=== Application Services ==="
for entry in "Trading Platform (Dev):Development" "Trading Platform (Prod):Production"; do
  app_name="${entry%%:*}"
  app_env="${entry##*:}"

  app_id=$(lookup_ci "cmdb_ci_appl" "${app_name}")
  if [[ -n "$app_id" ]]; then
    echo "  ${app_name}: already exists (${app_id})"
  else
    app_id=$(create_ci "cmdb_ci_appl" "{
      \"name\": \"${app_name}\",
      \"short_description\": \"${app_env} environment — trading services\",
      \"operational_status\": \"1\",
      \"environment\": \"${app_env}\"
    }")
    echo "  ${app_name}: created (${app_id})"
    http=$(create_rel "${biz_id}" "${app_id}" "${DEPENDS_ON}")
    echo "    -> linked to Trading Platform (HTTP ${http})"
  fi

  # Store app IDs for server linking
  if [[ "$app_env" == "Development" ]]; then app_dev_id="$app_id"; fi
  if [[ "$app_env" == "Production" ]]; then app_prod_id="$app_id"; fi
done

# --- Linux Server CIs ---
echo ""
echo "=== Linux Servers ==="
NODES="rhel-dev-01:Development rhel-dev-02:Development rhel-dev-03:Development rhel-prod-01:Production rhel-prod-02:Production rhel-prod-03:Production"

for entry in $NODES; do
  node="${entry%%:*}"
  env_label="${entry##*:}"

  node_id=$(lookup_ci "cmdb_ci_linux_server" "${node}")
  if [[ -n "$node_id" ]]; then
    echo "  ${node} (${env_label}): already exists (${node_id})"
    continue
  fi

  node_id=$(create_ci "cmdb_ci_linux_server" "{
    \"name\": \"${node}\",
    \"short_description\": \"RHEL 9.8 demo node — ${env_label} environment\",
    \"os\": \"Linux Red Hat\",
    \"os_version\": \"9.8\",
    \"classification\": \"${env_label}\",
    \"category\": \"Server\",
    \"subcategory\": \"Virtual\",
    \"environment\": \"${env_label}\",
    \"operational_status\": \"1\",
    \"install_status\": \"1\"
  }")
  echo "  ${node} (${env_label}): created (${node_id})"

  if [[ "$env_label" == "Development" ]]; then parent_id="$app_dev_id"; else parent_id="$app_prod_id"; fi
  http=$(create_rel "${parent_id}" "${node_id}" "${RUNS_ON}")
  echo "    -> linked to Trading Platform (${env_label}) (HTTP ${http})"
done

echo ""
echo "CMDB setup complete."
echo "Open 'Trading Platform' in ServiceNow CMDB to see the full service hierarchy."
