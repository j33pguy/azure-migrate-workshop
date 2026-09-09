# Module 2 · Hyper-V replication and test migration

**TD SYNNEX | Cloud Enablement Services**

Use the Hyper-V migration workflow for **all four workloads**. Here, “agentless” means no Mobility Service installed inside each guest. The Hyper-V host still needs Microsoft's replication provider and Recovery Services agent. The discovery appliance does not stream Hyper-V guest disks to Azure. [Hyper-V migration architecture](https://learn.microsoft.com/azure/migrate/hyper-v-migration-architecture)

## 1. Prepare the host replication provider

Complete Module 1 and keep HyperVHost running throughout replication.

1. Open the project's migration/execute flow and select the **Hyper-V** source. In the newer experience, use discovered inventory if the appliance is registered; **From replication provider (Hyper-V)** is also a supported source when proceeding without assessment inventory.
2. Follow the Hyper-V provider preparation step. Download the **Microsoft Azure Site Recovery provider installer** and registration key from this project onto HyperVHost.
3. Install the provider and associated Recovery Services agent **on HyperVHost**, then complete registration using this project's key. Do not install the provider on `MigrateAppl` or install Mobility Service in the four guests.
4. Wait until the Hyper-V host appears as a registered migration source. Verify its outbound access using the current URL list in the support matrix.
5. If the host or any workload is already protected by Site Recovery or Hyper-V Replica, stop and resolve that conflict before enrolling it in this lab's migration flow.

Use the current portal-supplied installers and keys. Follow the Hyper-V provider setup for this project before enabling replication. [Migration tutorial](https://learn.microsoft.com/azure/migrate/tutorial-migrate-hyper-v), [Hyper-V migration support](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v-migration)

## 2. Review source readiness

From the host, confirm each workload is running and Module 0's endpoint tests still pass. Confirm these points before replication:

- Guest firmware uses the lab's Gen2 configuration with Secure Boot disabled; review current Hyper-V migration limitations.
- Guest OS NICs use DHCP. The source IPs come from host DHCP reservations. Azure assigns different addresses to migrated NICs.
- Linux's persistent Netplan configuration uses DHCP without binding to the source MAC. Review `/etc/netplan/50-cloud-init.yaml`; a copied NIC must work with Azure's new MAC.
- The Linux Azure agent is installed; Windows guest agent availability is verified during test migration.
- The four standalone workload disks are selected; the cloud-init seed DVDs are detached. Do not select the appliance for replication.

Do not alter a source network during active cutover without recording the change. A DHCP reservation on HyperVHost is not an Azure static-IP assignment.

Before enabling replication, copy the single, self-contained [SQL data helper](../scripts/Test-LabSqlData.ps1) from the reviewed checkout to `C:\LabTools\Test-LabSqlData.ps1` **inside OnPrem-SQL**. Stop edits to the sample database and run this in Windows PowerShell as the guest administrator:

```powershell
C:\LabTools\Test-LabSqlData.ps1 -Capture -BaselinePath C:\LabEvidence\source-pretest.baseline.json
Get-FileHash C:\LabEvidence\source-pretest.baseline.json -Algorithm SHA256
```

Keep an independent copy of the baseline and its SHA256 in the instructor's evidence record outside the lab VM and Git. The helper and baseline on the SQL OS disk will also be replicated into the test VM. Leave sample data unchanged until that comparison passes. Existing baseline files are protected from overwrite; use a new filename when deliberately capturing another baseline.

## 3. Configure replication

Select the four workload names and review every target setting:

| Setting | Use |
|---|---|
| Target subscription | The workshop subscription |
| Target resource group | Your `$targetRg`, e.g. `rg-ces-target-01` |
| Target region | The same region used for the target networks |
| Target VNet/subnet | `$targetRg-target-vnet` / `default` |
| Test VNet/subnet | `$targetRg-test-vnet` / `default`, when prompted |
| VM names | Preserve the four workload names |
| VM sizes | Supported, available sizes with adequate RAM and quota; use assessment recommendations as inputs |
| OS disk | The actual boot disk for each workload |
| Replicated disks | All workload disks; no guessed disk IDs |
| Licensing | Select only the benefits/rights actually available |

Start replication and monitor the job. Initial replication must finish before test migration; delta replication continues afterwards. A job being accepted is not proof that replication is healthy. Record healthy status, replication lag/last synchronization and any warnings per VM. The portal may label the stages **Preparation**, **Testing**, and **Completion**, or use the classic **Replicating machines** view.

If initial replication fails, inspect the **host provider** and its Azure URL access, cache storage settings, source disks, quotas and per-VM service errors.

## 4. Run isolated test migrations

1. For each workload whose initial replication has completed, select **Start test migration** or **Test migrate**.
2. Select the **test VNet**, never the source or final target network. Test VMs use the same test VNet if testing their connectivity together.
3. Keep the source workloads running. Watch the migration jobs until the test VM has been created successfully.
4. Record each actual test VM name and private IP from Azure. Do not assume that every portal version appends the same suffix.

The test VNet has no peering to source or target. Its NAT gateway permits outbound internet, so this is **network separation, not an air gap**. For customer workloads, also disable production DNS changes, mail, webhooks, scheduled jobs and other outbound side effects in the copied environment. These lab samples do not implement those integrations.

## 5. Validate from inside the VMs

A private IP is not reachable from an ordinary workstation or unconnected Cloud Shell. Use Azure VM **Run command**, or an instructor-provided Bastion connection. No public IP is added to the test VMs by this lab.

Run the helper from the repository root in your Azure PowerShell session. Copy four distinct, exact VM names from the portal. Duplicate names (even with different capitalization), wildcards and whitespace are rejected before running any VM checks:

```powershell
$testWindowsWeb = Read-Host 'Actual Windows web test VM name'
$testSql = Read-Host 'Actual SQL test VM name'
$testLinuxWeb = Read-Host 'Actual Linux web test VM name'
$testLinuxApp = Read-Host 'Actual Linux app test VM name'
.\scripts\Test-MigratedWorkloads.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg -WindowsWebVM $testWindowsWeb -SqlVM $testSql `
    -LinuxWebVM $testLinuxWeb -LinuxAppVM $testLinuxApp
```

Expect four PASS results. The helper checks IIS, Nginx and the real `/api/health` endpoint. For SQL it checks `SQLEXPRESS`, `ContosoApp`, `DBCC CHECKDB`, and the actual `Customers`/`Orders` tables. Counts of at least five are only a smoke test.

Inside the **SQL test VM**, use Windows PowerShell (or the portal's PowerShell Run command) to verify that the replicated baseline's SHA256 matches the independent source record, then compare the data:

```powershell
Get-FileHash C:\LabEvidence\source-pretest.baseline.json -Algorithm SHA256
C:\LabTools\Test-LabSqlData.ps1 -BaselinePath C:\LabEvidence\source-pretest.baseline.json
```

Expect `SQL_DATA_MATCHED`. This compares every defined column in both sample tables, including `CreatedDate`, `OrderDate`, decimal values, nulls and case-sensitive text. A mismatch stops acceptance even if row counts are unchanged. If the baseline/helper is absent, resolve the replication point or file placement and repeat the test; do not create a new baseline from the test VM to make it pass. This helper uses Windows PowerShell 5.1 or PowerShell 7.5+ and requires the lab SQL permissions described in Module 3.

If Run Command fails because the agent is not healthy, that is a failed test. Inspect boot diagnostics and obtain private interactive access to repair the image; do not mark the VM validated because it appears “Running.”

Also use Run command **inside one test VM** to connect to another test VM's recorded private IP on the intended workload port. For example, from Windows web:

```powershell
# Run inside the Windows test VM; enter the SQL test VM's Azure private IP.
$sqlTestIp = Read-Host 'SQL test VM private IPv4 address'
Test-NetConnection -ComputerName $sqlTestIp -Port 1433
```

For a noninteractive portal Run command pane, set `$sqlTestIp` to the actual address before submitting; `Read-Host` requires an interactive session. Passing the local service checks alone does not validate routing, DNS or NSGs. The SQL TCP probe demonstrates network reachability, not a database relationship in the static website.

## 6. Clean up test migration

After recording results, use the project's **Clean up test migration** operation for each VM. Do not merely delete its Azure VM manually. Wait for cleanup to finish and verify no test VM/disks remain before cutover. Keep the test VNet until all tests are complete.

**Pass gate:** every workload has a healthy replication state, successful application and network test evidence, and completed test cleanup. Continue to [Module 3](Module-3-Stateful-Migration.md).
