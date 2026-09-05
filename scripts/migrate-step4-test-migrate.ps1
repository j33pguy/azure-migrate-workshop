<#
.SYNOPSIS
Guide: Test migration for the Hyper-V workshop.
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
Write-Host 'Test migration: portal action required.'
Write-Host 'Start test migrations into the test VNet in the portal. Validate each test VM using Test-MigratedWorkloads.ps1, record the results, then clean up test migration in the portal.'
Write-Host "Source group: $SourceResourceGroup | Target group: $TargetResourceGroup | Project: $MigrateProjectName"
Write-Host "Runbook: $((Resolve-Path $guide).Path)"
Write-Host 'No Azure resources have been changed or verified by this guide.'
