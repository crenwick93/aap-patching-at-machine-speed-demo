#!/usr/bin/env bash
set -euo pipefail

# Register the 6 demo RHEL nodes as Configuration Items in the ServiceNow CMDB.
# Creates Linux Server CIs with appropriate dev/prod environment labels.
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

declare -A NODE_ENV=(
  ["rhel-dev-01"]="Development"
  ["rhel-dev-02"]="Development"
  ["rhel-dev-03"]="Development"
  ["rhel-prod-01"]="Production"
  ["rhel-prod-02"]="Production"
  ["rhel-prod-03"]="Production"
)

echo "Registering demo CIs in ServiceNow CMDB..."
echo ""

for node in "${!NODE_ENV[@]}"; do
  env_label="${NODE_ENV[$node]}"

  existing=$(curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/cmdb_ci_linux_server?sysparm_query=name=${node}&sysparm_fields=sys_id,name" \
    -H "Accept: application/json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('result'):
    print(d['result'][0]['sys_id'])
else:
    print('')
" 2>/dev/null)

  if [[ -n "$existing" ]]; then
    echo "  ${node} (${env_label}): already exists (sys_id: ${existing})"
    continue
  fi

  result=$(curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/cmdb_ci_linux_server" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{
      \"name\": \"${node}\",
      \"short_description\": \"RHEL 9.8 demo node — ${env_label} environment\",
      \"os\": \"Red Hat Enterprise Linux\",
      \"os_version\": \"9.8\",
      \"classification\": \"${env_label}\",
      \"category\": \"Server\",
      \"subcategory\": \"Virtual\",
      \"environment\": \"${env_label}\",
      \"operational_status\": \"1\",
      \"install_status\": \"1\"
    }")

  sys_id=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['sys_id'])" 2>/dev/null)
  echo "  ${node} (${env_label}): created (sys_id: ${sys_id})"
done

echo ""
echo "CMDB setup complete. CIs are ready for the demo."
