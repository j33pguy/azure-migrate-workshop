# Module 3 · Cutover and stateful validation

**TD SYNNEX | Cloud Enablement Services**

Plan and execute the final migration of all four VMs. SQL's data requires stronger validation; it uses the same Hyper-V host provider as the web and Node workloads. This exercise replaces the previous guest-agent module.

## 1. Capture the source baseline

Inside the SQL source VM, run the following in Windows PowerShell as the guest administrator. Save the output in the instructor's evidence record, outside source control if it contains participant information.

```powershell
Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Database ContosoApp -Query @'
SELECT COUNT(*) AS CustomerCount FROM dbo.Customers;
SELECT COUNT(*) AS OrderCount FROM dbo.Orders;
SELECT CustomerID,FirstName,LastName,Email,City FROM dbo.Customers ORDER BY CustomerID;
SELECT OrderID,CustomerID,ProductName,Quantity,UnitPrice FROM dbo.Orders ORDER BY OrderID;
DBCC CHECKDB (N'ContosoApp') WITH NO_INFOMSGS;
'@
```

A fresh deployment contains five Customers and five Orders. Record actual values if learners changed the samples. The database and table names in this exercise match deployment; there is no `Products` table.

Take a separate database backup before the cutover exercise:

```powershell
New-Item C:\LabBackups -ItemType Directory -Force | Out-Null
$sqlServiceAccount = (Get-CimInstance Win32_Service -Filter "Name='MSSQL`$SQLEXPRESS'").StartName
& icacls.exe C:\LabBackups /grant ("{0}:(OI)(CI)M" -f $sqlServiceAccount)
if ($LASTEXITCODE -ne 0) { throw 'Could not grant the SQL service access to its backup folder.' }
Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Query `
    "BACKUP DATABASE ContosoApp TO DISK=N'C:\LabBackups\ContosoApp-precutover.bak' WITH COPY_ONLY, INIT, CHECKSUM;"
Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Query `
    "RESTORE VERIFYONLY FROM DISK=N'C:\LabBackups\ContosoApp-precutover.bak' WITH CHECKSUM;"
```

The SQL service identity needs write access to the destination folder; grant it only for this backup folder if needed. Copy the backup to approved storage outside the source VM before deleting the lab. `RESTORE VERIFYONLY` checks backup readability, not a successful restore; perform an actual restore in a disposable SQL environment for the optional recovery exercise. [SQL backup guidance](https://learn.microsoft.com/sql/relational-databases/backup-restore/create-a-full-database-backup-sql-server)

## 2. Establish the cutover gate

Record the maintenance window, responsible instructor, accepted test results and rollback decision point. Confirm:

- Initial replication is complete and delta replication is healthy for all selected VMs.
- Test migration was successful and cleaned up for every VM.
- Target sizes, disk mappings, network settings and quota are correct.
- Source SQL baseline and backup evidence exist.
- All writers to the database are stopped before the final baseline and planned shutdown.

The Node sample is stateless and has no database connection. Do not invent a multi-tier dependency between it and SQL. In a real multi-tier system, stop ingress and writers, migrate the data tier, validate it, then enable dependent application traffic in a planned order.

## 3. Perform planned migration

For each workload in the project, select **Migrate** under the completion/migration action. Choose the option to **shut down source VMs and perform a planned migration**. Verify the selected VMs, then start the operation.

The provider shuts down the source and synchronizes the remaining changes before creating the final Azure VM. This creates an outage. Planned shutdown with successful final synchronization is the documented path to avoid loss of source writes; it is not a zero-downtime promise. Record start/end times and errors. [Microsoft planned Hyper-V migration](https://learn.microsoft.com/azure/migrate/tutorial-migrate-hyper-v)

Keep the source VMs off after cutover. The host and appliance can remain running while replication state is being completed. Do not rerun `deploy-lab.ps1`, which is designed only for new labs.

## 4. Validate the migrated VMs

From your Azure PowerShell session, using the target names selected in Module 2:

```powershell
.\scripts\Test-MigratedWorkloads.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg -WindowsWebVM OnPrem-Web -SqlVM OnPrem-SQL `
    -LinuxWebVM OnPrem-Linux-Web -LinuxAppVM OnPrem-Linux-App
```

Copy the SQL baseline query from section 1 and run it inside the migrated SQL VM using Run command or private interactive access. Compare **exact rows and counts**, not just database presence. Run `DBCC CHECKDB` and resolve reported errors. The lab grants the VM agent's local SYSTEM identity access to `ContosoApp` for these checks; that is sample-database permission, not a reusable production access design.

Validate the sites and API using each VM's new private IP from another VM in the target VNet. Confirm DHCP addressing, DNS, time, disks and VM agent status. The sample web pages intentionally retain source-environment descriptions; copied HTML text is not authoritative evidence of where a VM is running. Use the Azure resource identity/private IP and `hostname` for that evidence.

There is no DNS zone or application traffic endpoint in this repository. For this standalone lab, record the Azure addresses. For a customer application, update real DNS/connection settings and test the actual business transaction before accepting traffic.

## 5. Accept and complete migration

After successful workload, network and SQL data validation, record instructor acceptance. Use **Complete migration** for each migrated server to stop replication and clean up migration state. Do not equate the Azure VM appearing in the portal with completion of the whole exercise.

## 6. Reversal and data ownership

Azure Migrate is not an automatic failback system. Keep only one writable copy authoritative.

| When a failure occurs | Response |
|---|---|
| Test migration | Clean up the test through Azure Migrate, repair the cause and test again; source continues running |
| Final migration fails before Azure accepts writes | Keep traffic disabled, inspect migration jobs, and make an explicit recovery decision before starting any source |
| Azure has accepted new writes | Stop writers and reconcile those changes before considering a source restart; blindly powering on the old SQL VM loses or forks data |
| Migration is completed | Replication state has been removed; recovery depends on retained source/backup/application procedures, not an automatic Migrate rollback button |

For the lab, stop at the first failed data comparison and preserve both disks for investigation. Do not continue to cleanup.

**Pass gate:** all four final VMs pass, SQL data matches the quiesced source baseline, source VMs remain off, and migration has been completed deliberately. Continue to [Module 4](Module-4-ASR-Comparison.md).
