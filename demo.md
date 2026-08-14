# Patching at Machine Speed — Demo Runbook

This is a guided walkthrough for delivering the demo. Each section is a beat in the narrative. Open the tabs/windows listed before you start so transitions are smooth.

---

## Pre-flight

Have these open and ready:

| Tab | URL / Tool |
|-----|-----------|
| ServiceNow — Trading Service (Dev) | Favourited service in ServiceNow |
| ServiceNow — Trading Service (Prod) | Favourited service in ServiceNow |
| Red Hat Insights — Systems | console.redhat.com > Insights > Inventory |
| Red Hat Insights — Vulnerabilities | console.redhat.com > Insights > Vulnerability > CVEs |
| AAP — Workflow Jobs | AAP > Jobs (filtered to Workflow Jobs) |
| AAP — Workflow Visualizer | AAP > Templates > Trading Service: CVE Kpatch Response > Visualizer |
| Terminal | SSH ready: `ssh -i colombo-demo.pem ec2-user@rhel-dev-01.trading-demo.chrislab.dev` |
| Terminal | Local shell in the repo root for running the simulate script |

Make sure the demo has been reset (`scripts/reset-demo.sh`), ServiceNow is clean (`scripts/cleanup-servicenow.sh --all`), and the EDA rulebook activation is running.

The reset script automatically updates `/etc/hosts` with the current IPs for `rhel-dev-01` and `rhel-prod-01`, so you can SSH using their FQDNs:

```bash
ssh -i colombo-demo.pem ec2-user@rhel-dev-01.trading-demo.chrislab.dev
ssh -i colombo-demo.pem ec2-user@rhel-prod-01.trading-demo.chrislab.dev
```

---

## Act 1: The Environment

**Narrative:** "Here's our Trading Service — a business-critical financial services application running across six RHEL 9 nodes, split into dev and prod."

### 1.1 — Show the services in ServiceNow

- Open **Trading Service (Dev)** in ServiceNow
  - Show the 3 dev CIs: `rhel-dev-01`, `rhel-dev-02`, `rhel-dev-03`
  - Point out they're healthy Linux Servers
- Switch to **Trading Service (Prod)**
  - Show the 3 prod CIs: `rhel-prod-01`, `rhel-prod-02`, `rhel-prod-03`
  - "These are the production nodes — this is what we really care about."

### 1.2 — Show the systems in Insights

- Switch to **Red Hat Insights — Systems**
  - Show all 6 nodes registered and reporting
  - "Red Hat Insights is continuously monitoring these systems for vulnerabilities, compliance, and drift."

### 1.3 — Show the vulnerability in Insights

- Navigate to **Vulnerabilities** in Insights
  - Find a kernel-related CVE on one of the nodes
  - Click into it to show the severity, CVSS score, affected systems
  - "This CVE affects our trading platform nodes. In a traditional workflow, someone would notice this, raise a ticket, schedule a maintenance window... that could take days or weeks."

### 1.4 — Prove it on the node itself

- Switch to the **Terminal** (SSH into `rhel-dev-01.trading-demo.chrislab.dev`)

```bash
# Show the running kernel
uname -r

# Show the specific CVE is present
sudo dnf updateinfo info --security kernel 2>/dev/null | grep -A2 "CVE-2026-43037"

# Show no kpatch modules are loaded (unpatched)
sudo kpatch list
```

- "You can see the same vulnerability Insights is reporting — CVE-2026-43037, CVSS 8.8, sitting unpatched on this node right now. And no kpatch modules are loaded — this kernel is exposed."

---

## Act 2: The Event

**Narrative:** "In a real environment, Insights would fire an event the moment a new critical CVE is detected. We're going to simulate that."

### 2.1 — Simulate the CVE event

- Switch to the **local terminal**

```bash
./scripts/simulate-cve-event.sh
```

- The script will echo the payload details — pause here and talk through it:
  - "This is a Critical CVE, CVSS 8.8, detected on rhel-dev-01"
  - "Insights has sent this event to Event-Driven Ansible"
  - "EDA is now going to trigger our entire response workflow — no human intervention needed to start the process"

### 2.2 — Show the workflow kick off

- Switch to **AAP — Workflow Jobs**
  - A new "Trading Service: CVE Kpatch Response" workflow should appear within seconds
  - Click into it to show the **Visualizer**
  - "10 nodes in this workflow — assessment, pre-checks, dev canary, governed production deployment, and full ITIL audit trail. All automated."

---

## Act 3: The Automated Response

**Narrative:** Walk through each phase as it executes. The workflow takes a few minutes — use the time to explain what each step is doing.

### 3.1 — Assess & SBOM Baseline

- The first node is "Assess & SBOM Baseline" — watch it run in the **Workflow Visualizer**
- "Before anything else, it scans every node — kernel version, outstanding CVEs, kpatch eligibility, and captures a Software Bill of Materials. We need to know what we're dealing with before raising any tickets."

### 3.2 — Open Incident

- As soon as "Open Incident" completes, switch to **ServiceNow**
- Show the **Dev service** — a new Incident has appeared
  - "Now that we know which machines are exposed, the automation opens an incident with the full assessment findings baked in. Not a generic alert — it contains the kernel version, CVE list, and SBOM confirmation."
- Show the **Prod service** — another Incident
  - "Both environments get their own incident — proper ITIL governance."
- Once complete, go to **ServiceNow** and check the dev incident's **Work Notes**
  - "See? The automation has written the assessment findings directly into the incident. Every node, kernel version, CVE count — full transparency."

### 3.3 — Pre-checks & Dev Canary

- "Pre-checks confirm it's safe to patch — disk space, memory, services all healthy."
- "Now watch — it's applying the kpatch to dev first. This is our canary deployment. Zero downtime, the kernel is patched live."
- After "Canary: Post-checks" completes:
  - "Post-checks confirmed: kpatch loaded, all services healthy, Trading Service service is UP. SBOM diff captured — we know exactly what changed."

### 3.4 — Open Emergency CR + Approval

- The workflow reaches **"Open Emergency CR"** then pauses at **"Awaiting CR Approval"**
- Switch to **ServiceNow**
  - Show the new **Change Request** — it's an emergency CR
  - "The automation has raised a governed change request. Dev canary passed, but production needs human approval. This is the governance gate."
  - Show the CR details — linked to the Trading Service service, canary evidence in the description
- **Approve the CR** in ServiceNow and click **Implement**
  - "The moment we approve and implement, EDA picks up the state change and automatically approves the paused workflow node in AAP."
- Switch back to **AAP** — the workflow should resume within ~10 seconds

### 3.5 — Production Deployment

- "Now it's applying the same kpatch to production — governed, approved, audited."
- Watch "Apply Kpatch (Prod)" and "Post-checks (Prod)" complete
  - "Same post-checks on prod — kpatch loaded, services healthy, Trading Service UP."

### 3.6 — Post-Implementation Review

- The final node runs
- Switch to **ServiceNow**:
  - **Dev Incident** — resolved, work notes show the full timeline
  - **Prod Incident** — resolved, same audit trail
  - **Emergency CR** — moved to Review, detailed review notes with SBOM diff
  - **Follow-up CR** — a new standard change has been created
    - "The automation knows kpatch is a stop-gap. It's already logged a follow-up CR for the full kernel update during the next maintenance window. That's enterprise governance baked in."

---

## Act 4: The Proof

**Narrative:** "Let me prove the vulnerability is actually gone."

### 4.1 — Prove it on the node

- SSH back into `rhel-dev-01.trading-demo.chrislab.dev`

```bash
# Show kpatch is now loaded (the fix is active)
sudo kpatch list

# Show the kernel is still running (same version — zero reboot)
uname -r

# The CVE advisory still shows in dnf (kpatch doesn't change RPM state)
# but the kpatch module is what provides the live fix
sudo dnf updateinfo info --security kernel 2>/dev/null | grep -A2 "CVE-2026-43037"

# Show the kpatch RPMs that were installed
rpm -qa | grep kpatch
```

- "Same kernel version — there was no reboot. But look at `kpatch list` — the module is loaded and the vulnerability is mitigated live in memory. The advisory still shows in dnf because the base kernel RPM hasn't changed, but that's expected — the kpatch is a live in-memory fix. Red Hat Insights understands this and will mark the CVE as remediated."

### 4.2 — Insights update (talk-through)

- "Red Hat Insights will reflect this remediation after the next check-in cycle — typically within 30 minutes. The insights-client on each node will upload the updated system state, and the CVE will be marked as remediated in the console."
- If enough time has passed during the demo, refresh Insights to check
- If not, this is fine to narrate: "In a real environment, your security team would see this CVE disappear from their dashboard without ever having to touch a terminal."

---

## Key Talking Points

Use these throughout the demo as the workflow progresses:

- **Speed**: "From CVE detection to full remediation across 6 nodes — minutes, not days."
- **Zero downtime**: "kpatch applies live kernel patches. No reboot, no maintenance window, no service interruption."
- **Governance**: "Every step is audited. Incidents, change requests, SBOM diffs, work notes — all automated, all ITIL-compliant."
- **Dev-first canary**: "We never touch production without proving it works on dev first."
- **Human in the loop**: "Production deployment requires an approved change request. The automation pauses and waits — governance is not optional."
- **SBOM**: "We capture a full Software Bill of Materials before and after every patch. You know exactly what changed on every system."
- **Follow-up CR**: "The automation knows kpatch is temporary. It automatically schedules the full kernel update for the next maintenance window."
- **Scale**: "This same workflow works whether you have 6 nodes or 6,000. The only thing that changes is how many hosts Ansible targets."

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Workflow doesn't start after simulate script | Check EDA rulebook activation is running and event stream is not in test mode |
| ServiceNow CR approval doesn't resume workflow | Check EDA rulebook is polling (look at EDA audit logs). Verify `remote_servicenow_timezone` matches your PDI |
| Insights not showing systems | Run `sudo insights-client --status` on a node. If not reporting, run `sudo insights-client` to force upload |
| SSH timeouts to nodes | Your local IP may have changed — update the AWS Security Group |
| Post-checks fail on Trading Service service check | This is simulated and always returns UP. If it fails, check the node is reachable |

---

## Reset for Next Demo

```bash
# Clean ServiceNow records
./scripts/cleanup-servicenow.sh --all

# Reprovision fresh EC2 instances (full reset)
./scripts/reset-demo.sh

# Re-run CaC if needed
source .env && ansible-playbook ansible_deployment/cac/apply.yml
```
