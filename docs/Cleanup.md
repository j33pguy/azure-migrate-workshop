# Workshop cleanup

**TD SYNNEX | Cloud Enablement Services**

Complete this exercise even when setup or migration fails. Deallocation alone does not remove storage, IP, NAT gateway, backup or other service costs.

## 1. Account for all resources

Use the exact subscription ID and source/target resource group names from your session. Include any separately created Bastion, restore, monitoring or DR resources. Do not infer ownership from a similar name.

```powershell
Set-AzContext -SubscriptionId $subscriptionId
Get-AzResource -ResourceGroupName $sourceRg | Select-Object Name,ResourceType,ResourceId
Get-AzResource -ResourceGroupName $targetRg | Select-Object Name,ResourceType,ResourceId
```

The cleanup script only accepts groups tagged `Workshop=TD-SYNNEX-CES-HyperV`. An old lab created by the original scripts lacks this tag. Inspect its entire inventory and use an explicit manual cleanup decision; do not blindly tag an existing group just to bypass the guard.

## 2. Remove service-managed state first

1. In Azure Migrate, clean up any outstanding **test migration** through its own operation.
2. Complete accepted migrations or stop replication for abandoned lab workloads using the relevant portal operation. Keep only the intended copy of any writable database online.
3. Resolve migration/ASR replication items and registrations before deleting their service resources.
4. If you enabled backup, inspect vault protected items, retained and soft-deleted data, locks, immutable settings and Resource Guard requirements. Follow Microsoft's vault deletion procedure. Do not disable protection features globally to force teardown.
5. Account for restored VM disks and NICs; they can exist outside the original groups.
6. Confirm any temporary `WinServerBase-temp` disk export is revoked before removing that disk.

A Recovery Services vault can remain billable or block deletion because of retained state. The script refuses any group containing a vault until you handle and remove the vault through its documented procedure. [Delete a Recovery Services vault](https://learn.microsoft.com/azure/backup/backup-azure-delete-vault), [Site Recovery vault cleanup](https://learn.microsoft.com/azure/site-recovery/delete-vault)

## 3. Preview and delete

```powershell
.\scripts\cleanup-lab.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg,$sourceRg -WhatIf

# After checking the inventory and completing the preceding steps:
.\scripts\cleanup-lab.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg,$sourceRg
```

The script lists resources and prompts before deleting each group. It checks the subscription, workshop tags, vault presence and locks first. It deliberately has no `-Force` bypass switch. It does not disable Defender plans, remove backup retention, or clear subscription-level policies.

## 4. Verify completion

Confirm both groups are absent and inspect any separately recorded resource groups for leftover disks, IPs, NAT gateways, vaults or workspaces. Cost reporting can lag: verify deletion through Azure resource inventory, then review Cost Analysis once reporting catches up. Record retained items with an owner and deletion date rather than declaring complete teardown.
