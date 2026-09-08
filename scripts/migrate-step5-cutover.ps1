<#
.SYNOPSIS
Guide: Cutover for the Hyper-V workshop.
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
$guide = Join-Path $PSScriptRoot '../docs/Module-3-Stateful-Migration.md'
if (-not (Test-Path $guide)) { throw "Runbook not found: $guide" }
Write-Host 'TD SYNNEX - Cloud Enablement Services'
Write-Host 'Cutover: portal action required.'
Write-Host 'Complete successful test migration and cleanup first. Quiesce writes, select planned shutdown, migrate, validate each workload, and complete migration only after acceptance.'
Write-Host "Source group: $SourceResourceGroup | Target group: $TargetResourceGroup | Project: $MigrateProjectName"
Write-Host "Runbook: $((Resolve-Path $guide).Path)"
Write-Host 'No Azure resources have been changed or verified by this guide.'
