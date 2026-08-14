#!/usr/bin/env bash
set -euo pipefail

# Remove demo artefacts from ServiceNow.
# Safe for shared instances — scoped to exact CI names and records opened by
# the service account only.
#
# Usage:
#   ./scripts/cleanup-servicenow.sh              # clean incidents + CRs only
#   ./scripts/cleanup-servicenow.sh --all         # clean everything (CIs + incidents + CRs)
#   ./scripts/cleanup-servicenow.sh --cmdb        # clean CMDB CIs only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
fi

SN_HOST="${SERVICENOW_INSTANCE_URL:?Set SERVICENOW_INSTANCE_URL in .env}"
SN_HOST="${SN_HOST%/}"
SN_USER="${SERVICENOW_USERNAME:?Set SERVICENOW_USERNAME in .env}"
SN_PASS="${SERVICENOW_PASSWORD:?Set SERVICENOW_PASSWORD in .env}"

MODE="${1:---records}"

# Helper: delete CI by exact name from a table
delete_ci() {
  local table="$1" name="$2"
  local sys_id
  sys_id=$(curl -s -u "${SN_USER}:${SN_PASS}" \
    -G "${SN_HOST}/api/now/table/${table}" \
    --data-urlencode "sysparm_query=name=${name}" \
    --data-urlencode "sysparm_fields=sys_id" \
    -H "Accept: application/json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['result'][0]['sys_id'] if d.get('result') else '')
" 2>/dev/null)

  if [[ -n "$sys_id" ]]; then
    curl -s -o /dev/null -w "  ${name}: HTTP %{http_code}\n" -u "${SN_USER}:${SN_PASS}" \
      -X DELETE "${SN_HOST}/api/now/table/${table}/${sys_id}" \
      -H "Accept: application/json"
  else
    echo "  ${name}: not found"
  fi
}

delete_incidents() {
  echo "=== Removing demo Incidents (opened by ${SN_USER} with 'CVE' in description) ==="
  curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/incident?sysparm_query=opened_by.user_name=${SN_USER}^short_descriptionLIKECVE&sysparm_fields=sys_id,number,short_description" \
    -H "Accept: application/json" | python3 -c "
import json,sys,subprocess,os
d=json.load(sys.stdin)
user=os.environ['SERVICENOW_USERNAME']
pw=os.environ['SERVICENOW_PASSWORD']
host=os.environ.get('SN_HOST', os.environ['SERVICENOW_INSTANCE_URL'].rstrip('/'))
for r in d.get('result',[]):
    print(f\"  Deleting {r['number']}: {r['short_description'][:60]}\")
    subprocess.run(['curl','-s','-o','/dev/null','-w','  -> HTTP %{http_code}\n',
      '-u',f'{user}:{pw}','-X','DELETE',
      f'{host}/api/now/table/incident/'+r['sys_id'],
      '-H','Accept: application/json'], check=False)
if not d.get('result'):
    print('  None found')
"
}

delete_change_requests() {
  echo "=== Removing demo Change Requests (opened by ${SN_USER} with 'kpatch' or 'kernel') ==="
  curl -s -u "${SN_USER}:${SN_PASS}" \
    "${SN_HOST}/api/now/table/change_request?sysparm_query=opened_by.user_name=${SN_USER}^short_descriptionLIKEkpatch^ORshort_descriptionLIKEkernel&sysparm_fields=sys_id,number,short_description" \
    -H "Accept: application/json" | python3 -c "
import json,sys,subprocess,os
d=json.load(sys.stdin)
user=os.environ['SERVICENOW_USERNAME']
pw=os.environ['SERVICENOW_PASSWORD']
host=os.environ.get('SN_HOST', os.environ['SERVICENOW_INSTANCE_URL'].rstrip('/'))
for r in d.get('result',[]):
    print(f\"  Deleting {r['number']}: {r['short_description'][:60]}\")
    subprocess.run(['curl','-s','-o','/dev/null','-w','  -> HTTP %{http_code}\n',
      '-u',f'{user}:{pw}','-X','DELETE',
      f'{host}/api/now/table/change_request/'+r['sys_id'],
      '-H','Accept: application/json'], check=False)
if not d.get('result'):
    print('  None found')
"
}

delete_cmdb() {
  echo "=== Removing demo Linux Server CIs ==="
  DOMAIN="trading-demo.chrislab.dev"
  for node in rhel-dev-01.${DOMAIN} rhel-dev-02.${DOMAIN} rhel-dev-03.${DOMAIN} rhel-prod-01.${DOMAIN} rhel-prod-02.${DOMAIN} rhel-prod-03.${DOMAIN}; do
    delete_ci "cmdb_ci_linux_server" "$node"
  done

  echo ""
  echo "=== Removing demo Application Services ==="
  delete_ci "cmdb_ci_appl" "Trading Service (Dev)"
  delete_ci "cmdb_ci_appl" "Trading Service (Prod)"

  echo ""
  echo "=== Removing demo Business Service ==="
  delete_ci "cmdb_ci_service" "Trading Service"
}

echo "Cleaning up ServiceNow demo artefacts..."
echo "(scoped to exact demo names + records opened by ${SN_USER})"
echo ""

case "${MODE}" in
  --all)
    delete_cmdb
    echo ""
    delete_incidents
    echo ""
    delete_change_requests
    ;;
  --cmdb)
    delete_cmdb
    ;;
  --records|*)
    delete_incidents
    echo ""
    delete_change_requests
    ;;
esac

echo ""
echo "ServiceNow cleanup complete."
