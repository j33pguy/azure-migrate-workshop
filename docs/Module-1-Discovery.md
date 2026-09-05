# Module 1 · Discovery and assessment

**TD SYNNEX | Cloud Enablement Services**

Discover the four workload VMs and build an Azure VM assessment. Keep the discovery appliance separate from the host replication provider introduced in Module 2.

## 1. Create the project

From the Azure portal, search for **Azure Migrate** and create a project in the **source resource group**, for example `ces-migrate-01`. Select the intended subscription and permitted project geography. Project metadata location and migration target region are separate settings; do not use a hard-coded geography mapping. Record the actual resource names the service creates.

Portal labels vary as Azure Migrate rolls out its newer **Explore / Decide / Execute** experience. Follow the operation described here if the portal places it under a different heading. The classic equivalent is **Servers, databases and web apps**. [Create and manage projects](https://learn.microsoft.com/azure/migrate/create-manage-projects)

## 2. Prepare the Hyper-V host

Inside HyperVHost, use the host-preparation script linked from Microsoft's [Hyper-V discovery tutorial](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v). Verify the current published hash/signature before running it in elevated Windows PowerShell. Follow its prompts to configure the discovery account, PowerShell remoting and required permissions. Restrict access to the internal lab network; do not expose WinRM publicly.

For this single-host lab, use `HyperVHost\labadmin` (or your chosen host user) when adding host credentials. Guest Windows credentials are different: `Administrator`, with the lab password. Do not enable CredSSP solely because it appears in a cluster example: this lab stores guest disks locally, not on remote SMB shares.

## 3. Install the appliance on MigrateAppl

1. In the project, open discovery and select **Hyper-V** as the source. Generate a project key for `MigrateAppl`. Keep the key out of Git and screenshots.
2. Connect to `MigrateAppl` through Hyper-V Manager on the host. Sign in as `Administrator` with the lab password.
3. Verify the guest has eight processors, 16 GB RAM, approximately 100 GB disk capacity, address `192.168.0.20`, gateway `192.168.0.1`, working DNS, internet access and correct time.
4. Download the current **AzureMigrateInstaller.zip** using the project download option or the link in Microsoft's installation article. Verify it using the article's current integrity instructions.
5. Extract the installer inside `MigrateAppl`. Open elevated Windows PowerShell, change into the extracted directory, and run:

```powershell
.\AzureMigrateInstaller.ps1
```

6. Select **Hyper-V**, **Azure public cloud**, and the connectivity option matching this lab. Complete prerequisite checks and updates.

The deployment has already created the appliance's Windows OS VM; do not import a second VHD appliance or run the installer on HyperVHost. Production prerequisites document an external switch. This nested lab uses one NIC with NAT/DHCP for both host reachability and egress; its end-to-end operation must be proven in the instructor rehearsal. [Script-based appliance setup](https://learn.microsoft.com/azure/migrate/deploy-appliance-script)

## 4. Register and discover

Use the appliance configuration manager shortcut inside `MigrateAppl`, or its documented HTTPS endpoint from the host browser: `https://192.168.0.20:44368`. Verify you are connecting to your own appliance before accepting its initial certificate prompt.

1. Finish connectivity, time and update checks.
2. Paste the project key and sign in to the correct Azure tenant/subscription.
3. Add the Hyper-V host credentials and host address `192.168.0.1`.
4. Validate the source, resolve every failed prerequisite, then start discovery.
5. Add guest credentials only for the software inventory/dependency features being demonstrated. Confirm their guest-side prerequisites in the support matrix.
6. Return to the project and verify the four **workload names**, OS details, CPU and memory. Do not accept a raw count of four machines as proof: the appliance itself can appear in inventory.

| Workload | Expected source OS | Expected address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 22.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 22.04 | 192.168.0.13 |

Exclude `MigrateAppl` from workload migration. Discovery takes time and runs continuously; diagnose appliance/host validation failures before simply waiting longer. [Hyper-V assessment support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v)

## 5. Create the assessment

Create an **Azure VM** assessment for a group containing exactly the four workload VMs. Use the target region chosen in Module 0, the relevant currency/pricing agreement, no commitment discounts for this short lab, and no Azure Hybrid Benefit unless the instructor has confirmed entitlement.

For a just-created lab, first use **as-on-premises** sizing. Then compare a performance-based assessment after data has accumulated. Record the collection period, confidence rating and idle nature of the samples. A few minutes of idle telemetry cannot justify a production right-sizing recommendation. [Assess Hyper-V servers](https://learn.microsoft.com/azure/migrate/tutorial-assess-hyper-v)

Record for each machine: readiness, any unsupported configuration, selected Azure size, OS disk, target network, and estimated compute/storage cost. Resolve readiness warnings against the migration support matrix before replication.

## 6. Discuss dependencies honestly

The sample IIS site, Nginx site and Node API do **not** call SQL or each other. An empty application dependency view can be correct. Do not ask learners to locate a connection string or a `/api/products` endpoint that does not exist. Agentless dependency discovery also requires supported guest credentials and time to collect observations. Do not install the retired Microsoft Monitoring Agent to make a diagram appear.

Optional instructor extension: implement and document a real database-consuming application in a separate exercise, then repeat discovery with generated traffic.

**Pass gate:** the appliance is registered, host validation succeeds, the four named workloads are visible, and the assessment exists with reviewed readiness. Continue to [Module 2](Module-2-Agentless-Migration.md).
