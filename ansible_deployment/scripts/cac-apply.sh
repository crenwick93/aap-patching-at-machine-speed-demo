#!/usr/bin/env bash
set -euo pipefail

# Apply AAP Controller + EDA objects for Patching at Machine Speed.
# Sources the repo-root .env for AAP, AWS, and ServiceNow credentials.
#
# Usage:
#   ./ansible_deployment/scripts/cac-apply.sh
#
# Prerequisites:
#   ansible-galaxy collection install -r ansible_deployment/cac/requirements.yml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLAYBOOK="${REPO_ROOT}/ansible_deployment/cac/apply.yml"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  echo "Loading environment from ${REPO_ROOT}/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
fi

ansible-playbook "${PLAYBOOK}" "$@"
