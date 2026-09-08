<#
.SYNOPSIS
Delete explicitly named, tagged workshop resource groups.
.DESCRIPTION
Use -WhatIf to preview. Requires the exact subscription and workshop tags.
Lists all resources and requests confirmation. Does not disable vault soft
delete, remove backups, bypass locks, or change subscription-wide services.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string[]]$ResourceGroupName
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$null = Assert-LabContext $SubscriptionId
# Reject every invalid name before querying or deleting any group.
foreach ($name in $ResourceGroupName) { Assert-LabResourceGroupName $name }
$groups = @()
foreach ($name in ($ResourceGroupName | Select-Object -Unique)) {
    $groups += Assert-LabResourceGroup $name
    $resources = @(Get-AzResource -ResourceGroupName $name -ErrorAction Stop)
    $resources | Select-Object Name,ResourceType,ResourceGroupName | Format-Table -AutoSize
    if (@($resources | Where-Object { $_.ResourceType -in @('Microsoft.RecoveryServices/vaults','Microsoft.DataProtection/backupVaults') }).Count) {
        throw "Group '$name' contains a backup or Recovery Services vault. Complete migration/test cleanup and the applicable vault cleanup procedure in docs/Cleanup.md, then rerun."
    }
    if (@(Get-AzResourceLock -ResourceGroupName $name -ErrorAction Stop).Count) { throw "Group '$name' contains resource locks. Review them explicitly before cleanup." }
}
foreach ($group in $groups) {
    if ($PSCmdlet.ShouldProcess("Subscription $SubscriptionId / $($group.ResourceGroupName)", 'Permanently delete resource group and every listed resource')) {
        Remove-AzResourceGroup -Name $group.ResourceGroupName -Force -ErrorAction Stop | Out-Null
        if (Get-LabResourceGroup -Name $group.ResourceGroupName -AllowMissing) { throw "Deletion did not complete for $($group.ResourceGroupName)." }
        Write-Host "Deleted: $($group.ResourceGroupName)"
    }
}
