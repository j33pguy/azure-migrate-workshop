<#
.SYNOPSIS
Guide: Hyper-V replication for the Hyper-V workshop.
.DESCRIPTION
This entry point prints the supported portal runbook. It does not start,
validate, or claim completion of an Azure operation. The former automation
used incompatible migration cmdlets. See review/REVIEW.md for evidence.
#>
[CmdletBinding()]
param(
    [string]$SourceResourceGroup,
    [string]$TargetResourceGroup,
    [string]$MigrateProjectName
)
$ErrorActionPreference = 'Stop'
$guide = Join-Path $PSScriptRoot '../docs/Module-2-Agentless-Migration.md'
if (-not (Test-Path $guide)) { throw "Runbook not found: $guide" }
Write-Host 'TD SYNNEX - Cloud Enablement Services'
Write-Host 'Hyper-V replication: portal action required.'
Write-Host 'Install and register the replication provider on HyperVHost before configuring replication. Use the Hyper-V source for all four workloads.'
Write-Host "Source group: $SourceResourceGroup | Target group: $TargetResourceGroup | Project: $MigrateProjectName"
Write-Host "Runbook: $((Resolve-Path $guide).Path)"
Write-Host 'No Azure resources have been changed or verified by this guide.'
