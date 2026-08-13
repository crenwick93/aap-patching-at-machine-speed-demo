#!/usr/bin/env bash
set -euo pipefail

# Remove demo CIs, Incidents, and Change Requests from ServiceNow.
# Run this to reset ServiceNow state between demo runs.
#
# Usage: ./scripts/cleanup-servicenow.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
fi

SN_HOST="${SERVICENOW_INSTANCE_URL:?Set SERVICENOW_INSTANCE_URL in .env}"
SN_USER="${SERVICENOW_USERNAME:?Set SERVICENOW_USERNAME in .env}"
SN_PASS="${SERVICENOW_PASSWORD:?Set SERVICENOW_PASSWORD in .env}"

NODES=("rhel-dev-01" "rhel-dev-02" "rhel-dev-03" "rhel-prod-01" "rhel-prod-02" "rhel-prod-03")

echo "Cleaning up ServiceNow demo artefacts..."
echo ""

echo "=== Removing demo CIs ==="
for node in "${NODES[@]}"; do
  sys_id=$(curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/cmdb_ci_linux_server?sysparm_query=name=${node}&sysparm_fields=sys_id" \
    -H "Accept: application/json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['result'][0]['sys_id'] if d.get('result') else '')
" 2>/dev/null)

  if [[ -n "$sys_id" ]]; then
    curl -s -o /dev/null -w "  ${node}: HTTP %{http_code}\n" -u "${SN_USER}:${SN_PASS}" \
      -X DELETE "${SN_HOST}/api/now/table/cmdb_ci_linux_server/${sys_id}" \
      -H "Accept: application/json"
  else
    echo "  ${node}: not found"
  fi
done

echo ""
echo "=== Removing demo Incidents (short_description contains 'CVE') ==="
curl -s -u "${SN_USER}:${SN_PASS}" \
  "${SN_HOST}/api/now/table/incident?sysparm_query=short_descriptionLIKECVE^short_descriptionLIKEkernel&sysparm_fields=sys_id,number,short_description" \
  -H "Accept: application/json" | python3 -c "
import json,sys,subprocess
d=json.load(sys.stdin)
for r in d.get('result',[]):
    print(f\"  Deleting {r['number']}: {r['short_description'][:60]}\")
    subprocess.run(['curl','-s','-o','/dev/null','-w','  -> HTTP %{http_code}\n',
      '-u','${SN_USER}:${SN_PASS}','-X','DELETE',
      '${SN_HOST}/api/now/table/incident/'+r['sys_id'],
      '-H','Accept: application/json'], check=False)
if not d.get('result'):
    print('  None found')
"

echo ""
echo "=== Removing demo Change Requests (kpatch or kernel related) ==="
curl -s -u "${SN_USER}:${SN_PASS}" \
  "${SN_HOST}/api/now/table/change_request?sysparm_query=short_descriptionLIKEkernel^ORshort_descriptionLIKEkpatch^ORshort_descriptionLIKEKpatch&sysparm_fields=sys_id,number,short_description" \
  -H "Accept: application/json" | python3 -c "
import json,sys,subprocess
d=json.load(sys.stdin)
for r in d.get('result',[]):
    print(f\"  Deleting {r['number']}: {r['short_description'][:60]}\")
    subprocess.run(['curl','-s','-o','/dev/null','-w','  -> HTTP %{http_code}\n',
      '-u','${SN_USER}:${SN_PASS}','-X','DELETE',
      '${SN_HOST}/api/now/table/change_request/'+r['sys_id'],
      '-H','Accept: application/json'], check=False)
if not d.get('result'):
    print('  None found')
"

echo ""
echo "ServiceNow cleanup complete."
