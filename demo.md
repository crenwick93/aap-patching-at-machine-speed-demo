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
# Confirm which node we're on (matches the display name in Insights)
hostname

# Show the running kernel
uname -r

# Show the specific CVE is present
sudo dnf updateinfo info --security kernel 2>/dev/null | grep -A2 "CVE-2026-43037"

# Show no kpatch modules are loaded (unpatched)
sudo kpatch list
```

- "This is `rhel-dev-01.trading-demo.chrislab.dev` — the same system you just saw in Insights. Same hostname, same node."
- "The CVE is right there — CVE-2026-43037, CVSS 8.8, sitting unpatched. And `kpatch list` is empty — this kernel is exposed."

---

## Act 2: The Automation — What's About to Happen

**Narrative:** Before triggering anything, walk the audience through the automation that's waiting to respond.

### 2.1 — Show Event-Driven Ansible

- Switch to **AAP — Event-Driven Ansible > Rulebook Activations**
  - Show the running activation — "This is listening 24/7 for events from Red Hat Insights. The moment a critical CVE is detected on any of our Trading Service nodes, it fires."
  - Click into the rulebook to show the rules:
    - "Rule one: when Insights reports a new CVE, it triggers the full response workflow automatically."
    - "Rule two: it's also polling ServiceNow. When a Change Request is approved, it bridges that approval back into AAP to resume the production deployment."

### 2.2 — Walk through the Workflow

- Switch to **AAP — Templates > Trading Service: CVE Kpatch Response**
  - Open the **Visualizer**
  - Walk through the 10 nodes left to right:
    1. **Assess & SBOM Baseline** — "First, we scan every node. Kernel version, outstanding CVEs, kpatch eligibility, and capture a Software Bill of Materials. We need to know what we're dealing with."
    2. **Open Incident** — "Only after assessment do we raise ServiceNow incidents — one for Dev, one for Prod — with the actual findings baked in."
    3. **Pre-check All Hosts** — "Safety checks. Disk space, memory, critical services running. Make sure it's safe to patch."
    4. **Canary: Apply Kpatch** — "Dev goes first. Live kernel patch — no reboot required."
    5. **Canary: Post-checks** — "Validate the dev canary worked. Kpatch loaded, services still running, SBOM diff captured."
    6. **Open Emergency CR** — "Dev succeeded, so now we raise an emergency Change Request for production. Full ITIL justification, implementation plan, backout plan."
    7. **Awaiting CR Approval** — "The workflow pauses here. It will not touch production until a human approves the CR in ServiceNow."
    8. **Apply Kpatch (Prod)** — "Once approved, production gets the same live patch."
    9. **Post-checks (Prod)** — "Same validation on production nodes."
    10. **Post-Implementation Review** — "Close out the ITIL records — resolve both incidents, move the CR to review, and schedule a follow-up for the full kernel update."
  - "So the key thing here — dev is fully automated, zero human touch. Production has a governance gate. The human only needs to make one decision: approve or reject the Change Request."

---

## Act 3: The Event

**Narrative:** "Now let's trigger it. In a real environment, Insights would fire an event the moment a new critical CVE is detected. We're going to simulate that."

### 3.1 — Simulate the CVE event

- Switch to the **local terminal**

```bash
./scripts/simulate-cve-event.sh
```

- The script will echo the payload details — pause here and talk through it:
  - "This is a Critical CVE, CVSS 8.8, detected on rhel-dev-01"
  - "Insights has sent this event to Event-Driven Ansible"
  - "EDA is now going to trigger our entire response workflow — no human intervention needed to start the process"

### 3.2 — Show the workflow kick off

- Switch to **AAP — Workflow Jobs**
  - A new "Trading Service: CVE Kpatch Response" workflow should appear within seconds
  - Click into it to show the **Visualizer**
  - "You can see it's already executing the same 10-node workflow we just walked through."

---

## Act 4: The Automated Response

**Narrative:** Walk through each phase as it executes. The workflow takes a few minutes — use the time to explain what each step is doing.

### 4.1 — Assess & SBOM Baseline

- Watch "Assess & SBOM Baseline" complete in the **Workflow Visualizer**
- "It's already scanned all 6 nodes and captured the baseline. Now it knows exactly what's exposed."

### 4.2 — Open Incident

- As soon as "Open Incident" completes, switch to **ServiceNow**
- Show the **Dev service** — a new Incident has appeared
  - "Now that we know which machines are exposed, the automation opens an incident with the full assessment findings baked in. Not a generic alert — it contains the kernel version, CVE list, and SBOM confirmation."
- Show the **Prod service** — another Incident
  - "Both environments get their own incident — proper ITIL governance."
- Once complete, go to **ServiceNow** and check the dev incident's **Work Notes**
  - "See? The automation has written the assessment findings directly into the incident. Every node, kernel version, CVE count — full transparency."

### 4.3 — Pre-checks & Dev Canary

- "Pre-checks confirm it's safe to patch — disk space, memory, services all healthy."
- "Now watch — it's applying the kpatch to dev first. This is our canary deployment. Zero downtime, the kernel is patched live."
- After "Canary: Post-checks" completes:
  - "Post-checks confirmed: kpatch loaded, all services healthy, Trading Service is UP. SBOM diff captured — we know exactly what changed."

### 4.4 — Open Emergency CR + Approval

- The workflow reaches **"Open Emergency CR"** then pauses at **"Awaiting CR Approval"**
- Switch to **ServiceNow**
  - Show the new **Change Request** — it's an emergency CR
  - "The automation has raised a governed change request. Dev canary passed, but production needs human approval. This is the governance gate."
  - Show the CR details — linked to the Trading Service, canary evidence in the description
- **Approve the CR** in ServiceNow and click **Implement**
  - "The moment we approve and implement, EDA picks up the state change and automatically approves the paused workflow node in AAP."
- Switch back to **AAP** — the workflow should resume within ~10 seconds

### 4.5 — Production Deployment

- "Now it's applying the same kpatch to production — governed, approved, audited."
- Watch "Apply Kpatch (Prod)" and "Post-checks (Prod)" complete
  - "Same post-checks on prod — kpatch loaded, services healthy, Trading Service UP."

### 4.6 — Post-Implementation Review

- The final node runs
- Switch to **ServiceNow**:
  - **Dev Incident** — resolved, work notes show the full timeline
  - **Prod Incident** — resolved, same audit trail
  - **Emergency CR** — moved to Review, detailed review notes with SBOM diff
  - **Follow-up CR** — a new standard change has been created
    - "The automation knows kpatch is a stop-gap. It's already logged a follow-up CR for the full kernel update during the next maintenance window. That's enterprise governance baked in."

---

## Act 5: The Proof

**Narrative:** "Let me prove the vulnerability is actually gone."

### 5.1 — Prove it on the node

- SSH back into `rhel-dev-01.trading-demo.chrislab.dev`

```bash
# Show kpatch is now loaded (the fix is active)
sudo kpatch list

# Show the kernel is still running (same version — zero reboot)
uname -r
```

- "Before the workflow, `kpatch list` was empty — nothing loaded. Now look — the CVE module is loaded and active. The vulnerability is mitigated live in memory."
- "And the kernel version is identical — there was no reboot. Zero downtime."

### 5.2 — Insights resolution

- Navigate to **Red Hat Insights — Vulnerabilities** and refresh
- "Notice the CVE status has been updated to **Resolved via Mitigation** for all 6 systems. The Post-Implementation Review step didn't just close out ServiceNow — it called the Red Hat Insights API to mark the CVE as mitigated."
- "This is critical for two reasons:"
  1. "It stops Insights from re-firing vulnerability events for this CVE — no duplicate workflows."
  2. "It gives your security team an accurate picture: the vulnerability is mitigated *now*, with a follow-up CR logged for the permanent kernel update."
- Show the incident work notes — they include the Insights status update confirmation
- "The follow-up CR also explicitly states that the CVE is marked as Resolved via Mitigation in Insights. When the full kernel update is applied later, Insights will automatically clear the advisory entirely."

### 5.3 — The full audit trail

- Walk through ServiceNow:
  - **Incidents**: Dev and Prod — both resolved with detailed work notes showing the full timeline
  - **Emergency CR**: In Review state — ready for human sign-off
  - **Follow-up CR**: Standard change logged for the full kernel update within 30 days
- "Every step from detection to resolution, including the Insights API update, is documented in ServiceNow. This is a complete ITIL audit trail, generated automatically."

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
- **Insights closed-loop**: "The automation doesn't just patch — it tells Red Hat Insights the CVE is mitigated. No duplicate events, no manual status updates, no noise for the SOC team."
  - **If asked "why doesn't Insights know automatically?":** "Insights uses OVAL scanning which checks installed RPM versions. Kpatch patches the running kernel live in memory — it doesn't change the kernel RPM. So the scanner still sees the old version and flags the CVE. That's why we call the Insights API to mark it as Resolved via Mitigation. Without this, your SOC team would see a false positive and EDA would keep firing. A full kernel update clears it automatically — that's what the follow-up CR is for."
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
