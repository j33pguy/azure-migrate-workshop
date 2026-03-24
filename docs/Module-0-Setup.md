# Module 0: Preparing the Migration Landing Zone

> **Cloud Adoption Framework Phase:** [Ready](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/) · **Estimated Duration:** 30–60 minutes · **Complexity:** Foundational

## 1. Module Overview

In a real-world migration engagement, this phase corresponds to **preparing the landing zone** — the target Azure environment that will host migrated workloads. Enterprise projects use [Azure Landing Zones (ALZ)](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/) with management groups, policy-driven governance, hub-spoke networking, and identity integration. That level of infrastructure is out of scope for a hands-on migration lab.

Instead, this module deploys a **self-contained simulation of an on-premises datacenter** inside a single Azure VM using nested Hyper-V virtualization. The entire environment — host VM, virtual networking, and four guest workloads — is provisioned by a single automated script (`deploy-lab.ps1`) using `Invoke-AzVMRunCommand`. No manual RDP session is required during setup.

**Why this approach?** It gives every participant an isolated, reproducible "datacenter" with realistic workloads (IIS, SQL Server, Nginx, Node.js) while keeping cost and complexity low. The trade-off is that it does not exercise subscription-level governance, which you would address through ALZ in a production engagement.

### What Gets Deployed

| VM Name | OS | Role | IP Address | Memory | vCPUs |
|---|---|---|---|---|---|
| OnPrem-Web | Windows Server 2022 | IIS Web Server | 192.168.0.10 | 4 GB | 2 |
| OnPrem-SQL | Windows Server 2022 | SQL Server 2019 Express | 192.168.0.11 | 4 GB | 2 |
| OnPrem-Linux-Web | Ubuntu 22.04 | Nginx Web Server | 192.168.0.12 | 2 GB | 2 |
| OnPrem-Linux-App | Ubuntu 22.04 | Node.js Express App | 192.168.0.13 | 2 GB | 2 |

All four guests run on an internal Hyper-V switch (`intSwitch`) with NAT on the `192.168.0.0/24` subnet. The host is reachable from the guests at `192.168.0.1`.

---

## 2. Architecture Decisions Record (ADR)

Every infrastructure choice in this lab was made deliberately. The table below documents the key decisions and their rationale — a practice you should carry into every production engagement.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Host VM Size** | `Standard_E4s_v5` | 4 vCPUs, 32 GB RAM. The Esv5 series is memory-optimized and supports nested virtualization. 32 GB is the minimum comfortable headroom for running 4 guests (2×4 GB + 2×2 GB = 12 GB allocated, leaving ~18 GB for the host OS, Hyper-V overhead, and disk caching). Smaller sizes like `Standard_D4s_v5` also support nesting but have only 16 GB RAM — too tight for reliable operation. |
| **OS Disk** | 256 GB Premium SSD (P15) | The host OS, Hyper-V role, and four guest VHDs must all fit on a single disk. Windows Server 2022 consumes ~20 GB; each Windows guest VHD is ~15–20 GB; each Linux cloud image is ~2–3 GB. Premium SSD provides the IOPS (1,100 baseline for P15) needed when four guests perform simultaneous disk I/O. Standard SSD would work but introduces noticeable latency during guest provisioning. |
| **Guest Network** | `192.168.0.0/24` with NAT | Simulates an isolated on-premises network. NAT provides outbound internet access (required for package downloads during provisioning) without exposing guests to inbound traffic from the Azure VNet. This mirrors how many on-prem datacenters sit behind a NAT gateway with no direct internet-facing exposure. |
| **VM Generation** | Gen 2 | UEFI-based boot, vTPM support, and larger OS disk support. Gen 2 is required for several Azure features post-migration (Trusted Launch, Confidential VMs). Starting with Gen 2 avoids a generation conversion step later. |
| **Windows Guest Memory** | 4 GB | SQL Server 2019 Express recommends a minimum of 2 GB; pairing it with Windows Server overhead means 4 GB is the practical minimum. IIS is lighter but keeping both Windows guests at 4 GB simplifies the configuration. |
| **Linux Guest Memory** | 2 GB | Nginx and Node.js 18 are lightweight. 2 GB is sufficient for the sample workloads and keeps total host memory consumption within the 32 GB budget. |
| **Deployment Method** | PowerShell + `Invoke-AzVMRunCommand` | No ARM templates or Bicep — the entire deployment is imperative PowerShell. `Invoke-AzVMRunCommand` executes scripts on the host VM through the Azure VM agent, which means no public endpoint or RDP session is needed during setup. The command payload travels over the secure Azure control plane. |

---

## 3. Prerequisites

### 3.1 — Subscription Governance

- **Subscription selection.** Use a non-production subscription (Dev/Test, Sandbox, or Visual Studio Enterprise). Avoid subscriptions with restrictive Azure Policy assignments that may block VM creation or NSG modifications.
- **RBAC requirements.** You need **Contributor** role (minimum) on the target resource group, or **Owner** if you want to assign RBAC roles during the workshop. Verify with:

```powershell
Get-AzRoleAssignment -SignInName (Get-AzContext).Account.Id | Select-Object RoleDefinitionName, Scope
```

### 3.2 — Quota Verification

The lab requires 4 vCPUs from the `Standard_ESv5` family. Quota exhaustion is the #1 cause of deployment failure. **Check before you deploy:**

```powershell
# Check ESv5 family quota in your target region
Get-AzVMUsage -Location "eastus" | Where-Object { $_.Name.Value -like "*StandardESv5*" } |
    Select-Object @{N='Family';E={$_.Name.LocalizedValue}}, CurrentValue, Limit
```

If `CurrentValue` is close to `Limit`, either deallocate other VMs in that family, request a quota increase via the Azure portal, or choose a different region.

### 3.3 — Region Selection

Choose a region based on these criteria:

| Criterion | Guidance |
|-----------|----------|
| **Proximity** | Select a region close to your physical location to minimize RDP latency. |
| **ESv5 Availability** | Not all regions offer ESv5 VMs. Verify: `Get-AzComputeResourceSku -Location "eastus" \| Where-Object { $_.Name -eq "Standard_E4s_v5" }` |
| **Nested Virtualization** | ESv5 supports nesting in all regions where the SKU is available. |
| **Cost** | Pricing varies by region. US regions (East US, West US 2) are typically cost-effective. |
| **Fallback regions** | `eastus`, `westus2`, `westeurope`, `northeurope` are reliable choices. |

### 3.4 — Local Tooling

| Requirement | Details |
|---|---|
| **PowerShell 7+** | Windows PowerShell 5.1 also works, but PowerShell 7+ is recommended. |
| **Az PowerShell Module** | Install: `Install-Module -Name Az -Repository PSGallery -Force -AllowClobber` |
| **RDP Client** | Built into Windows. On macOS, use Microsoft Remote Desktop. On Linux, use `xfreerdp` or Remmina. |

### 3.5 — Network Requirements

Your local network must allow **outbound TCP 3389** (RDP) to Azure public IPs. If you are behind a corporate firewall that blocks RDP:

- **Option A:** Use [Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-overview) — browser-based RDP over HTTPS (port 443). This adds ~$5/day in cost.
- **Option B:** Configure a site-to-site VPN or Azure VPN Gateway.
- **Option C:** Ask your network team to allowlist outbound 3389 for the duration of the workshop.

---

## 4. Deployment Steps

### Step 1: Clone the Repository

```powershell
git clone https://github.com/your-org/azure-migrate-workshop.git
cd azure-migrate-workshop
```

Verify the structure includes `scripts\deploy-lab.ps1`:

```powershell
Get-ChildItem -Recurse -Depth 1
```

![Repository structure](../images/module-0-step-1.png)

### Step 2: Install Az PowerShell Module

```powershell
Install-Module -Name Az -Repository PSGallery -Force -AllowClobber
```

Verify:

```powershell
Get-Module -Name Az -ListAvailable
```

> **Tip:** If the module is already installed, update it: `Update-Module -Name Az`.

### Step 3: Authenticate to Azure

```powershell
Connect-AzAccount
```

After interactive login, confirm the active subscription:

```powershell
Get-AzContext
```

If you have multiple subscriptions, select the correct one:

```powershell
Set-AzContext -SubscriptionId "<your-subscription-id>"
```

### Step 4: Deploy the Lab Environment

This single command provisions the entire environment — host VM, Hyper-V configuration, guest VMs, and all workloads:

```powershell
.\scripts\deploy-lab.ps1 `
    -ResourceGroupName "rg-migrate-workshop" `
    -Location "eastus" `
    -AdminUsername "azureuser" `
    -AdminPassword (ConvertTo-SecureString "YourP@ssw0rd!" -AsPlainText -Force)
```

> ⚠️ **Password requirements.** Azure enforces complexity: 12+ characters, with uppercase, lowercase, digit, and special character. Store this password securely — you will need it to RDP into the host and to access guest VMs.
>
> 🔐 **Production note.** Passing passwords as script parameters (even as `SecureString`) exposes them in shell history and process listings. In production, store credentials in **Azure Key Vault** and retrieve them at deployment time:
> ```powershell
> $secret = Get-AzKeyVaultSecret -VaultName "kv-migrations" -Name "lab-admin-password"
> ```

#### What the Script Does

The `deploy-lab.ps1` script executes five phases, all fully automated:

| Phase | What Happens | Mechanism |
|-------|-------------|-----------|
| 1. Infrastructure | Creates resource group, VNet, NSG, Public IP, NIC, and the host VM | Azure PowerShell cmdlets (`New-AzVM`, etc.) |
| 2. Hyper-V Installation | Installs the Hyper-V role on the host VM | `Invoke-AzVMRunCommand` — executes through the Azure VM agent over the secure control plane. No public endpoint needed. |
| 3. Restart | Reboots the host to complete Hyper-V installation | `Restart-AzVM` |
| 4. Network Setup | Creates the internal virtual switch and NAT configuration | `Invoke-AzVMRunCommand` |
| 5. Guest Provisioning | Downloads OS images, creates VHDs, deploys all 4 guest VMs, installs workloads (IIS, SQL, Nginx, Node.js) | `Invoke-AzVMRunCommand` with embedded provisioning scripts |

> ⏱️ **Estimated time: 30–60 minutes.** The script outputs progress as each phase completes. No interaction is needed.
>
> 💡 **Tip:** Detailed logs are written to `C:\AzMigrateLab\setup-log.txt` on the host VM.

![Deployment script running](../images/module-0-step-4.png)

### Step 5: Connect to the Hyper-V Host

Once the script completes, it outputs the host VM's public IP address.

1. Open your RDP client.
2. Connect to the public IP on port 3389.
3. Log in with **`azureuser`** and the password from Step 4.

```powershell
# Retrieve the public IP if needed
Get-AzPublicIpAddress -ResourceGroupName "rg-migrate-workshop" | Select-Object Name, IpAddress
```

> **Firewall note.** If your corporate network blocks outbound RDP, add your client IP to the NSG or deploy Azure Bastion (see Section 3.5).

![RDP connection to Hyper-V host](../images/module-0-step-5.png)

---

## 5. Verification

Verification goes beyond "can I ping it?" — as a solutions architect, you need to confirm that the environment matches the expected architecture and that every workload is functional.

### 5.1 — Verify Hyper-V Infrastructure

Open **Hyper-V Manager** on the host and confirm all four guests are listed and running:

| VM Name | Expected State | Memory | vCPUs |
|---|---|---|---|
| OnPrem-Web | Running | 4096 MB | 2 |
| OnPrem-SQL | Running | 4096 MB | 2 |
| OnPrem-Linux-Web | Running | 2048 MB | 2 |
| OnPrem-Linux-App | Running | 2048 MB | 2 |

![Hyper-V Manager showing all VMs](../images/module-0-step-6a.png)

If any VM shows `Off`, right-click → **Start**. If it fails to start, check available memory on the host:

```powershell
Get-Counter '\Memory\Available MBytes'
```

### 5.2 — Network Connectivity

From a PowerShell session on the Hyper-V host, verify L3 reachability to every guest:

```powershell
# Test connectivity to all guest VMs
Test-Connection -ComputerName 192.168.0.10 -Count 2   # OnPrem-Web
Test-Connection -ComputerName 192.168.0.11 -Count 2   # OnPrem-SQL
Test-Connection -ComputerName 192.168.0.12 -Count 2   # OnPrem-Linux-Web
Test-Connection -ComputerName 192.168.0.13 -Count 2   # OnPrem-Linux-App
```

### 5.3 — Workload Readiness

Confirming ICMP is not sufficient. Validate that each application-layer service is responding on its expected port:

```powershell
# IIS on OnPrem-Web — expect HTTP 200
Invoke-WebRequest -Uri http://192.168.0.10 -UseBasicParsing | Select-Object StatusCode

# Nginx on OnPrem-Linux-Web — expect HTTP 200
Invoke-WebRequest -Uri http://192.168.0.12 -UseBasicParsing | Select-Object StatusCode

# Node.js Express API on OnPrem-Linux-App — expect HTTP 200
Invoke-WebRequest -Uri http://192.168.0.13:3000 -UseBasicParsing | Select-Object StatusCode

# Node.js health endpoint — expect JSON response
Invoke-WebRequest -Uri http://192.168.0.13:3000/api/health -UseBasicParsing | Select-Object StatusCode, Content

# SQL Server on OnPrem-SQL — expect TcpTestSucceeded: True
Test-NetConnection -ComputerName 192.168.0.11 -Port 1433
```

**Expected results:** All HTTP requests return `200`. The SQL Server port check returns `TcpTestSucceeded: True`.

![Connectivity test results](../images/module-0-step-6b.png)

### 5.4 — Architecture Validation Checklist

Use this checklist to confirm the environment matches the intended architecture:

- [ ] Host VM is `Standard_E4s_v5` with 32 GB RAM
- [ ] OS disk is 256 GB Premium SSD
- [ ] Hyper-V role is installed and operational
- [ ] Internal switch `intSwitch` exists with NAT on `192.168.0.0/24`
- [ ] All 4 guest VMs are running and assigned correct IPs
- [ ] IIS serves the sample dashboard page
- [ ] SQL Server accepts TCP connections on port 1433
- [ ] Nginx serves the sample dashboard page
- [ ] Node.js API responds on port 3000 (including `/api/health` and `/api/info`)
- [ ] Guests can reach the internet through NAT (verify: `Invoke-Command` → `curl ifconfig.me` from a guest)

### 5.5 — Review Setup Logs

If any check fails, review the deployment log:

```powershell
Get-Content C:\AzMigrateLab\setup-log.txt -Tail 50
```

This log records every provisioning step, including error messages.

---

## 6. Troubleshooting

### Quota Exhaustion

**Symptom:** `deploy-lab.ps1` fails with `OperationNotAllowed` or `QuotaExceeded` error.

**Resolution:**
1. Check current usage: `Get-AzVMUsage -Location "eastus" | Where-Object { $_.Name.Value -like "*StandardESv5*" }`
2. If at quota limit, either:
   - Deallocate unused VMs in the same family.
   - Request a quota increase via **Azure Portal → Subscriptions → Usage + quotas → Request increase**.
   - Switch to a fallback region with available capacity (see Section 3.3).

### Nested Virtualization Not Supported

**Symptom:** Hyper-V role fails to install, or guest VMs don't start.

**Cause:** The VM size doesn't support nested virtualization, or the region doesn't offer the SKU.

**Resolution:**
1. Verify SKU support: `Get-AzComputeResourceSku -Location "eastus" | Where-Object { $_.Name -eq "Standard_E4s_v5" -and $_.Capabilities.Name -contains "HyperVGenerations" }`
2. Ensure you're using `Standard_E4s_v5` (default) or another [nested-virt-capable size](https://learn.microsoft.com/en-us/azure/virtual-machines/acu).

### Region Fallback Strategy

If your primary region lacks capacity or quota:

| Priority | Region | Notes |
|----------|--------|-------|
| 1 | `eastus` | Largest Azure region, broadest SKU availability |
| 2 | `westus2` | Good capacity, lower latency from western US |
| 3 | `westeurope` | Primary European region |
| 4 | `northeurope` | European fallback |

### Guest VM Not Starting

**Symptom:** One or more guest VMs show `Off` and fail to start.

**Cause:** Insufficient memory or disk space on the host.

**Resolution:**
1. Check available memory: `Get-Counter '\Memory\Available MBytes'`
2. Check disk space: `Get-PSDrive C`
3. Review the Hyper-V event log: `Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-Worker-Admin" -MaxEvents 10`
4. Check `C:\AzMigrateLab\setup-log.txt` for provisioning errors.

### Cannot RDP to Hyper-V Host

**Symptom:** RDP connection times out or is refused.

**Resolution:**
1. Verify the VM is running: `Get-AzVM -ResourceGroupName "rg-migrate-workshop" -Status`
2. Verify the NSG allows inbound 3389 from your IP: `Get-AzNetworkSecurityGroup -ResourceGroupName "rg-migrate-workshop" | Get-AzNetworkSecurityRuleConfig`
3. Test port reachability from your machine: `Test-NetConnection -ComputerName <public-ip> -Port 3389`
4. If your network blocks RDP, deploy Azure Bastion (see Section 3.5).

### Network Connectivity Debugging

If guest VMs are running but unreachable:

```powershell
# Verify the virtual switch exists
Get-VMSwitch

# Verify NAT configuration
Get-NetNat

# Verify host IP on the internal switch
Get-NetIPAddress -InterfaceAlias "vEthernet (intSwitch)"

# Trace route from host to guest (Windows)
Test-NetConnection -ComputerName 192.168.0.10 -TraceRoute

# Check if guest has an IP assigned (from Hyper-V host)
Get-VM -Name "OnPrem-Web" | Get-VMNetworkAdapter | Select-Object IPAddresses
```

### Deployment Script Fails Midway

If the script fails after the host VM was created, you can often resume manually:

1. Check which phase failed by reviewing the script output and `C:\AzMigrateLab\setup-log.txt`.
2. Delete the resource group and re-run: `Remove-AzResourceGroup -Name "rg-migrate-workshop" -Force`
3. If only guest provisioning failed, RDP into the host and review the log for the specific error.

---

## 7. Security Baseline

This section documents the security posture of the lab environment and highlights what you would do differently in production.

### 7.1 — Network Security Group (NSG) Rules

The deployment creates a single NSG with one inbound rule:

| Priority | Name | Direction | Protocol | Source | Destination | Port | Action |
|----------|------|-----------|----------|--------|-------------|------|--------|
| 1000 | Allow-RDP | Inbound | TCP | `*` (any) | `*` | 3389 | Allow |

> ⚠️ **Lab-only configuration.** Opening RDP to `*` (any source) is acceptable for a short-lived workshop environment. **Never do this in production.**

### 7.2 — Production Alternatives for Remote Access

| Approach | How It Works | When to Use |
|----------|-------------|-------------|
| **Azure Bastion** | Browser-based RDP/SSH over HTTPS (443). No public IP on the VM. | Default recommendation for all production VMs. |
| **JIT VM Access** | Microsoft Defender for Cloud opens NSG ports on-demand for a limited time window. | When you need direct RDP but want time-bounded access. |
| **VPN Gateway** | Site-to-site or point-to-site VPN. Access VMs via private IPs. | When you need persistent, network-level connectivity. |
| **Restrict NSG Source** | Allowlist your specific public IP: `Set-AzNetworkSecurityRuleConfig -SourceAddressPrefix "203.0.113.42/32"` | Quick hardening for known, static client IPs. |

### 7.3 — Credential Management

| Lab Approach | Risk | Production Alternative |
|---|---|---|
| Password passed as `-AdminPassword` parameter | Visible in shell history, process listings, and script logs. | Store secrets in **Azure Key Vault**. Retrieve at deployment time with `Get-AzKeyVaultSecret`. |
| Same password used for host VM and all guest VMs | Credential reuse — compromise of one VM exposes all. | Use unique credentials per VM. Automate rotation with Key Vault. |
| Windows guests provisioned via `unattend.xml` with embedded password | Password stored in clear text inside the VHD. | Use Azure AD (Entra ID) join or domain join with managed service accounts. |
| Linux guests provisioned via cloud-init with password | Password in user-data metadata. | Use SSH key pairs. Disable password authentication entirely. |

### 7.4 — Principle of Least Privilege

The lab uses **Contributor** role at the resource group scope, which is broader than necessary. In production:

- Create a **custom RBAC role** with only the permissions needed (VM creation, network management, disk operations).
- Use **managed identities** instead of service principal secrets for automated deployments.
- Apply **resource locks** on critical resources to prevent accidental deletion.

---

## 8. Cost Analysis

Understanding the cost profile is essential for planning workshops at scale and advising customers on migration lab budgets.

### 8.1 — Hourly Cost Breakdown

| Resource | SKU / Tier | Approx. Cost (East US) | Notes |
|----------|-----------|----------------------|-------|
| Host VM Compute | Standard_E4s_v5 | ~$0.252/hr (~$6.05/day) | Pay-as-you-go pricing. Deallocating stops compute charges. |
| OS Disk | P15 Premium SSD (256 GB) | ~$0.05/hr (~$1.18/day) | Charged even when VM is deallocated. |
| Public IP | Standard SKU, Static | ~$0.005/hr (~$0.12/day) | Charged while allocated. |
| Networking (egress) | Standard | Minimal | < 1 GB egress during setup; negligible ongoing. |
| **Total (running)** | | **~$0.31/hr (~$7.35/day)** | |
| **Total (deallocated)** | | **~$0.055/hr (~$1.30/day)** | Disk + IP charges only. |

> **Note:** Guest VMs run inside the host VM and do not incur separate Azure charges. Their compute and storage are consumed from the host's resources.

### 8.2 — Cost Optimization Tips

| Tip | Savings Impact |
|-----|---------------|
| **Deallocate when not in use.** `Stop-AzVM -ResourceGroupName "rg-migrate-workshop" -Name "HyperVHost" -Force` | Eliminates ~$6/day in compute costs. Guest VMs stop automatically. |
| **Set auto-shutdown.** Azure Portal → VM → Auto-shutdown. Set to your end-of-day time. | Prevents overnight charges from forgotten VMs. |
| **Use Azure Dev/Test pricing.** If eligible, dev/test subscriptions offer ~40% discount on Windows VMs. | Reduces compute cost significantly. |
| **Delete when done.** `Remove-AzResourceGroup -Name "rg-migrate-workshop" -Force` | Eliminates all charges. Stops disk and IP charges that persist during deallocation. |
| **Choose a cost-effective region.** East US and West US 2 are generally the cheapest US regions. | Saves 5–15% vs. premium regions. |

### 8.3 — Comparison to Real Migration Lab Costs

In a production migration engagement, the lab infrastructure is more substantial:

| Component | This Workshop | Production Migration Lab |
|-----------|--------------|------------------------|
| Source environment | 1 host VM with 4 nested guests | Dedicated VMs or physical servers per workload |
| Azure Migrate appliance | Runs on nested VM | Dedicated VM (`Standard_D4s_v5`, ~$0.19/hr) |
| Replication storage | Workshop-scale (minimal) | Premium storage accounts for replication data |
| Target VMs | Created during migration modules | Sized to match production workloads |
| **Typical daily cost** | **~$7–8/day** | **$50–200+/day** depending on workload count |

---

## Estimated Deployment Time

| Phase | Duration | Details |
|---|---|---|
| Azure VM provisioning | ~5–10 minutes | Resource group, networking, host VM creation |
| Hyper-V role installation & reboot | ~5–10 minutes | Feature installation, mandatory restart |
| Guest VM creation & workload configuration | ~20–40 minutes | Image downloads, VHD creation, OS provisioning, app installation |
| **Total** | **~30–60 minutes** | Fully automated — no manual steps required |

---

## Next Steps

Your simulated on-premises datacenter is operational and verified. The environment represents a typical mixed-workload estate: Windows web tier, Windows database tier, Linux web server, and a Linux application server — the four most common patterns you'll encounter in enterprise migration engagements.

Proceed to:

➡️ **[Module 1: Discovery & Assessment with Azure Migrate](Module-1-Discovery.md)** — where you'll deploy the Azure Migrate appliance, discover these workloads, and generate migration readiness assessments.
