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

The cleanup script only accepts exact group names tagged `Workshop=TD-SYNNEX-CES-HyperV`. Wildcards such as `rg-ces-*`, resource IDs and names containing whitespace are rejected before any group lookup. For an untagged group, inspect its entire inventory and make an explicit manual cleanup decision; do not blindly tag an existing group just to bypass the guard.

## 2. Remove service-managed state first

1. In Azure Migrate, clean up any outstanding **test migration** through its own operation.
2. Complete accepted migrations or stop replication for abandoned lab workloads using the relevant portal operation. Keep only the intended copy of any writable database online.
3. Resolve migration/ASR replication items and registrations before deleting their service resources.
4. If you enabled backup, inspect vault protected items, retained and soft-deleted data, locks, immutable settings and Resource Guard requirements. Follow Microsoft's vault deletion procedure. Do not disable protection features globally to force teardown.
5. Account for restored VM disks and NICs; they can exist outside the original groups.
6. Confirm any temporary `WinServerBase-temp` disk export is revoked before removing that disk.

A vault can retain data or block deletion because of protected items. The script refuses groups containing either a Recovery Services vault (`Microsoft.RecoveryServices/vaults`) or a Backup vault (`Microsoft.DataProtection/backupVaults`). Complete the appropriate service procedure first; the script does not remove their protection or retained data. [Delete a Recovery Services vault](https://learn.microsoft.com/azure/backup/backup-azure-delete-vault), [Site Recovery vault cleanup](https://learn.microsoft.com/azure/site-recovery/delete-vault), [delete a Backup vault](https://learn.microsoft.com/en-us/azure/backup/create-manage-backup-vault#delete-a-backup-vault)

## 3. Preview and delete

```powershell
.\scripts\cleanup-lab.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg,$sourceRg -WhatIf

# After checking the inventory and completing the preceding steps:
.\scripts\cleanup-lab.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $targetRg,$sourceRg
```

The script lists resources and prompts before deleting each group. It checks the subscription, workshop tags, vault presence and locks for **every supplied group before deleting the first one**. It deliberately has no `-Force` bypass switch. It does not disable Defender plans, remove backup retention, or clear subscription-level policies.

An expired login, denied read, throttling response or network failure stops cleanup. The script only reports a group deleted after Azure returns the specific `ResourceGroupNotFound` response for that exact group in the selected subscription. If the post-delete lookup fails, inspect the portal and resolve the lookup error; deletion may already have occurred, but has not been verified. Do not interpret a read failure as proof that charges have stopped.

## 4. Verify completion

Confirm both groups are absent and inspect any separately recorded resource groups for leftover disks, IPs, NAT gateways, vaults or workspaces. Cost reporting can lag: verify deletion through Azure resource inventory, then review Cost Analysis once reporting catches up. Record retained items with an owner and deletion date rather than declaring complete teardown.
