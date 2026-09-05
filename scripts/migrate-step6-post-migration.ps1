<#
.SYNOPSIS
Inspect migrated VMs and print the post-migration runbook.
.DESCRIPTION
Read-only Azure inventory. Does not enable paid Defender plans, create
backup vaults, replace NSG rules, or claim that monitoring has been enabled.
Complete the observable acceptance checks in Module 5.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TargetResourceGroup
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$null = Assert-LabContext $SubscriptionId
$null = Assert-LabResourceGroup $TargetResourceGroup
$expected = @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')
foreach ($name in $expected) {
    $vm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $name -ErrorAction Stop
    [pscustomobject]@{ Name=$vm.Name; Size=$vm.HardwareProfile.VmSize; OS=$vm.StorageProfile.OsDisk.OsType; Location=$vm.Location }
}
Write-Host 'Inventory only. Run Test-MigratedWorkloads.ps1 and then docs/Module-5-Post-Migration.md.'
Write-Host 'Monitoring, backup and security configuration require the separate checks in that runbook.'
