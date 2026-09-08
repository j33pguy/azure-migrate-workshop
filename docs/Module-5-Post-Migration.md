# Module 5 · Post-migration operations

**TD SYNNEX | Cloud Enablement Services**

Finish with observable operational checks. Read-only inspection is the base exercise. Monitoring ingestion, backup, Bastion and Defender plans can add cost; enable only the extensions of the workshop the instructor has planned.

## 1. Inventory and application acceptance

Run from your Azure PowerShell session:

```powershell
.\scripts\migrate-step6-post-migration.ps1 -SubscriptionId $subscriptionId -TargetResourceGroup $targetRg
.\scripts\Test-MigratedWorkloads.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg -WindowsWebVM OnPrem-Web -SqlVM OnPrem-SQL `
    -LinuxWebVM OnPrem-Linux-Web -LinuxAppVM OnPrem-Linux-App
```

The first script lists VMs. It does not turn on monitoring, backup or Defender. Confirm the SQL baseline comparison and migration completion from Module 3; neither command replaces those steps.

## 2. Configure and prove monitoring

If included in your session:

1. Create a Log Analytics workspace in the target resource group and intended region; record retention and ingestion settings.
2. Use Azure Monitor's Data Collection Rule creation flow. Configure a Windows rule and a Linux rule separately, with only the required sources (for example Windows events and Linux syslog).
3. Add the appropriate migrated VMs to each rule. Ensure the supported managed identity is enabled, Azure Monitor Agent is installed and healthy, and a **DCR association** exists for each selected VM.
4. Generate a small test event/log on each OS and query for it. An installed agent with no data sources or associations is not a completed monitoring setup.
5. Save the rule/workspace names, query results and collection time in the evidence record.

```kusto
Heartbeat
| where TimeGenerated > ago(30m)
| summarize LastSeen=max(TimeGenerated) by Computer, _ResourceId
```

```kusto
Event
| where TimeGenerated > ago(30m)
| take 20
```

```kusto
Syslog
| where TimeGenerated > ago(30m)
| take 20
```

Expected evidence is heartbeat plus the events actually configured in the rules, not a claim that every metric/log is automatically collected. Allow for ingestion delay and verify identity, agent and DCR association if data is absent. [AMA requirements](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-requirements), [collect Windows events and Linux syslog](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection)

The retired Microsoft Monitoring Agent must not be introduced for dependency discovery. Azure Monitor Agent is also not a blanket replacement for every dependency-map feature; enable only a supported collection scenario.

## 3. Optional backup and restore exercise

Use a dedicated Recovery Services vault in the target region/group. Before creating it, read the [cleanup instructions](Cleanup.md): protected items, soft delete, immutable retention and locks can prevent immediate teardown.

1. Configure Azure VM Backup through the portal with an appropriate policy and retention for the demonstration.
2. Select a migrated lab VM, start **Backup now**, and wait for a successful backup job/recovery point.
3. Perform an actual restore into a disposable location, validate it, then track the restore's VM/disks/network resources for cleanup.
4. Record the recovery point and restore evidence. A configured policy or queued job alone is insufficient.

Windows VM backups can be application-consistent when guest VSS conditions are met; do not label every VM backup “crash-consistent.” Verify the recovery point's actual consistency. SQL-native backup/restore has separate requirements and recovery granularity; use Module 3's sample database for a database-level recovery exercise. SQL Express does not provide SQL Server Agent, so do not require an Agent service to be running.

[Back up an Azure VM](https://learn.microsoft.com/azure/backup/backup-azure-vms-first-look-arm), [restore Azure VMs](https://learn.microsoft.com/azure/backup/backup-azure-arm-restore-vms), [SQL in Azure VM backup support](https://learn.microsoft.com/azure/backup/sql-support-matrix)

## 4. Review network access and security

Inspect the host RDP rule and the target/test subnet NSGs. The base lab uses private workload NICs, no Internet inbound allow rules, and NAT for outbound traffic. No TLS website is installed merely because a rule permits port 443.

```powershell
Get-AzNetworkSecurityGroup -ResourceGroupName $targetRg | ForEach-Object {
    $_.SecurityRules | Select-Object Name,Direction,Access,Protocol,SourceAddressPrefix,DestinationPortRange,Priority
}
```

Azure's default NSG rules allow traffic within the virtual network. If demonstrating segmentation, use narrowly scoped workload rules followed by an explicit lower-priority deny for other traffic, review NIC **and** subnet effective rules, and retest the intended connections. Preserve existing rules unless the exercise explicitly changes them. Never fall back to `*` when a required source IP lookup fails.

For an interactive private connection, configure an appropriate Bastion option and its network prerequisites before promising it to learners. Do not open management ports to the entire Internet to work around missing connectivity.

For traffic analysis, use **virtual network flow logs**. New NSG flow logs cannot be created after June 30, 2025. [Flow-log transition](https://learn.microsoft.com/azure/network-watcher/network-watcher-nsg-flow-logging-overview), [VNet flow logs](https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview)

Inspect Defender for Cloud recommendations. Enabling a paid Defender for Servers plan at subscription scope affects other resources too. Review plan/feature prerequisites and pricing for the chosen scope before enabling a plan. [Defender for Servers overview](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-servers-overview)

## 5. Costs, patching and handover

Review Cost Analysis for both resource groups, including NAT gateways, public IPs, disks and optional services. Use the pricing calculator for a forward estimate. Tags on a resource group do not automatically propagate to every resource; tag the individual resources when resource-level reporting is needed.

Use Azure Update Manager's supported assessment workflow for the selected Windows/Linux images. An assessment reports missing updates; it does not schedule or install them by itself. Confirm maintenance timing and rehearse updates separately from migration. [Azure Update Manager](https://learn.microsoft.com/azure/update-manager/overview)

Record the owners, resource IDs, new private IPs, monitoring evidence, backups/restore evidence (if enabled), required updates and cleanup deadline. Do not buy reservations or savings plans for this disposable lab based on idle measurements.

**Pass gate:** the base validation and security/cost review are recorded; every optional service is either verified or explicitly marked not performed. Finish with [Cleanup](Cleanup.md).
