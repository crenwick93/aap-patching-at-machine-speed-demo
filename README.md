# Patching at Machine Speed

An end-to-end demo showing how Red Hat Ansible Automation Platform, Event-Driven Ansible, Red Hat Insights, and ServiceNow work together to detect, triage, and remediate a critical kernel CVE across a fleet of RHEL systems — in minutes, not days.

The workflow applies live kernel patches (kpatch) with zero downtime, staged dev-then-prod deployment, full ITIL governance, and a complete ServiceNow audit trail.

## What the Demo Shows

1. **Red Hat Insights** detects a critical kernel CVE on monitored RHEL systems
2. **Event-Driven Ansible** picks up the event and triggers an AAP workflow
3. **AAP Workflow** runs a 10-step response:
   - Assess all systems and capture a Software Bill of Materials (SBOM)
   - Open ServiceNow Incidents (one per environment)
   - Pre-check system readiness
   - Apply kpatch to dev (canary deployment)
   - Validate the canary, then raise an Emergency Change Request
   - **Pause for human approval** in ServiceNow
   - Apply kpatch to production (after CR approval)
   - Post-checks, CMDB CI updates, SBOM diff
   - Post-Implementation Review: resolve incidents, mark CVE as mitigated in Insights, log a follow-up CR for the full kernel update

## Architecture

```
Red Hat Insights  ──▶  Event-Driven Ansible  ──▶  AAP Workflow
                                                       │
                           ┌───────────────────────────┘
                           ▼
                   ┌───────────────┐
                   │  Assess &     │
                   │  SBOM Baseline│
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │ Open Incident │──▶ ServiceNow (Dev + Prod)
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │  Pre-checks   │
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │ Canary: Dev   │──▶ kpatch (zero downtime)
                   │ + Post-checks │
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │  Emergency CR │──▶ ServiceNow Change Request
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │  ⏸ Awaiting   │──▶ Human approves in ServiceNow
                   │  CR Approval  │◀── EDA bridges approval to AAP
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │ Prod: kpatch  │──▶ kpatch (zero downtime)
                   │ + Post-checks │
                   └──────┬────────┘
                          ▼
                   ┌───────────────┐
                   │  Post-Impl    │──▶ Resolve incidents, update
                   │  Review       │    Insights API, follow-up CR
                   └───────────────┘
```

## Prerequisites

| Component | Details |
|-----------|---------|
| **Ansible Automation Platform** | 2.5+ with Event-Driven Ansible enabled |
| **Red Hat Insights** | Systems registered under your Red Hat account |
| **ServiceNow** | A PDI (Personal Developer Instance) or lab instance |
| **AWS Account** | For provisioning EC2 demo instances |
| **Red Hat Account** | With subscription-manager credentials and an offline API token |
| **Ansible Collections** | `infra.aap_configuration`, `servicenow.itsm`, `ansible.eda` |

## Repository Structure

```
├── playbooks/
│   ├── assess.yml                 # Kernel assessment + SBOM baseline
│   ├── precheck.yml               # System readiness checks
│   ├── patch.yml                  # Apply kpatch + incident work notes
│   ├── validate.yml               # Post-checks, SBOM diff, CI updates
│   ├── snow_open_incident.yml     # Create ServiceNow incidents
│   ├── snow_open_cr.yml           # Create emergency change request
│   ├── snow_close_out.yml         # PIR: resolve, Insights API, follow-up CR
│   └── approve_pending_workflow.yml # Bridge ServiceNow approval to AAP
├── rulebooks/
│   └── cve_response.yml           # EDA rulebook (CVE events + CR polling)
├── ansible_deployment/
│   ├── cac/
│   │   ├── vars.yml               # All AAP/EDA objects defined as code
│   │   ├── apply.yml              # CaC apply playbook
│   │   └── requirements.yml       # Required Ansible collections
│   └── scripts/
│       └── cac-apply.sh           # Convenience wrapper for CaC apply
├── scripts/
│   ├── reset-demo.sh              # Full demo reset (EC2 + Insights + AAP)
│   ├── simulate-cve-event.sh      # Simulate a Lightspeed CVE event
│   ├── setup-servicenow-cis.sh    # Register CIs + services in ServiceNow
│   ├── cleanup-servicenow.sh      # Remove demo records from ServiceNow
│   └── setup-aws.sh               # One-time AWS infrastructure setup
├── demo.md                        # Step-by-step demo runbook
├── .env.example                   # Environment variable template
└── README.md                      # This file
```

## Setup

### 1. Clone and configure environment

```bash
git clone https://github.com/crenwick93/aap-patching-at-machine-speed-demo.git
cd aap-patching-at-machine-speed-demo

cp .env.example .env
# Edit .env with your credentials (see below)
```

### 2. Fill in `.env`

| Variable | Description |
|----------|-------------|
| `AAP_HOSTNAME` | AAP gateway URL (e.g. `https://aap.example.com`) |
| `AAP_INTERNAL_HOST` | Internal AAP URL if different from gateway |
| `AAP_TOKEN` | AAP OAuth token (generate in AAP > Users > Tokens) |
| `PROBE_SSH_KEY_PATH` | Path to the SSH private key for EC2 instances |
| `AWS_ACCESS_KEY_ID` | AWS access key with EC2 permissions |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_REGION` | AWS region (default: `eu-west-1`) |
| `DEMO_AMI_ID` | RHEL 9.8 AMI ID for your region |
| `DEMO_INSTANCE_TYPE` | EC2 instance type (default: `t3.small`) |
| `DEMO_SUBNET_ID` | VPC subnet for demo instances |
| `DEMO_SECURITY_GROUP_ID` | Security group allowing SSH (port 22) from your IP |
| `DEMO_KEY_NAME` | AWS key pair name |
| `RH_USERNAME` | Red Hat account username |
| `RH_PASSWORD` | Red Hat account password |
| `RH_ORG_ID` | Red Hat org ID (for subscription-manager) |
| `RH_OFFLINE_TOKEN` | Red Hat offline API token ([generate here](https://console.redhat.com/iam/service-accounts)) |
| `SERVICENOW_INSTANCE_URL` | ServiceNow instance URL |
| `SERVICENOW_USERNAME` | ServiceNow admin username |
| `SERVICENOW_PASSWORD` | ServiceNow admin password |
| `EDA_EVENT_STREAM_URL` | EDA event stream webhook URL (created by CaC) |
| `EDA_EVENT_STREAM_TOKEN` | Token for the EDA event stream |

> **Note:** Wrap values containing `$` in single quotes in `.env` to prevent shell interpolation.

### 3. Install Ansible collections

```bash
ansible-galaxy collection install -r ansible_deployment/cac/requirements.yml
ansible-galaxy collection install servicenow.itsm
```

### 4. Set up AWS infrastructure

If this is the first time, create the VPC, security group, and key pair:

```bash
./scripts/setup-aws.sh
```

Make sure the security group allows SSH (port 22) from your current public IP.

### 5. Set up ServiceNow CMDB

Register the demo nodes as CIs and create the Trading Service business/application services:

```bash
./scripts/setup-servicenow-cis.sh
```

This creates:
- A "Trading Service" Business Service
- "Trading Service (Dev)" and "Trading Service (Prod)" Application Services
- 6 Linux Server CIs (one per RHEL node), linked to the appropriate service

### 6. Apply AAP Configuration as Code

This creates all job templates, workflow, credentials, inventories, EDA rulebook activations, and event streams in AAP:

```bash
./ansible_deployment/scripts/cac-apply.sh
```

After this runs, note the EDA Event Stream URL and token from the AAP EDA console and update `EDA_EVENT_STREAM_URL` and `EDA_EVENT_STREAM_TOKEN` in your `.env`.

### 7. Provision demo instances

```bash
./scripts/reset-demo.sh
```

This will:
- Terminate any existing demo EC2 instances
- Launch 6 fresh RHEL 9.8 instances (3 dev, 3 prod)
- Set hostnames via cloud-init
- Register all nodes with Red Hat Subscription Manager and Insights
- Install kpatch on all nodes
- Sync the AAP dynamic inventory
- Update your local `/etc/hosts` for SSH shortcuts

## Running the Demo

See [demo.md](demo.md) for the full step-by-step runbook.

Quick start:

```bash
# 1. Make sure EDA rulebook activation is running (check AAP UI)

# 2. Simulate a CVE event from Insights
./scripts/simulate-cve-event.sh

# 3. Watch the workflow in AAP > Jobs
# 4. Approve the CR in ServiceNow when prompted
# 5. Watch production deployment complete
```

## Resetting Between Demos

```bash
# Clean ServiceNow records (incidents, CRs)
./scripts/cleanup-servicenow.sh --all

# Full reset: reprovision EC2, re-register Insights, sync inventory
./scripts/reset-demo.sh

# Re-apply CaC if AAP objects need updating
./ansible_deployment/scripts/cac-apply.sh
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Workflow doesn't start after simulate script | Check EDA rulebook activation is running and event stream is not in test mode |
| ServiceNow CR approval doesn't resume workflow | Check EDA rulebook is polling. Verify `remote_servicenow_timezone` matches your PDI |
| Insights not showing all 6 systems | Run `sudo insights-client --status` on the missing node. If unregistered, run `sudo subscription-manager register --force` then `sudo insights-client --register` |
| SSH timeouts to nodes | Your public IP may have changed — update the AWS Security Group inbound rule for port 22 |
| `xargs: command line cannot be assembled` during reset | The `.env` sourcing is using an old `xargs` method — pull latest and the `source` fix will resolve it |
| Only 4-5 nodes register during reset | The parallel registration can race. The reset script retries failures automatically, but you may need to manually register stragglers (SSH in and run `sudo subscription-manager register --force && sudo insights-client --register`) |
| Post-checks fail on Trading Service check | This check is simulated and always returns UP. If it fails, verify the node is reachable via SSH |
| EDA event stream in test mode after CaC | The CaC apply playbook includes a post-task to set all event streams to production mode. If it still reverts, manually toggle it in the EDA UI |
