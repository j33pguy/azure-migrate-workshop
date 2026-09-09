<#
.SYNOPSIS
Preview the installation display locally. All steps and outcomes are simulated.
.DESCRIPTION
Does not sign in, download, install, create files, or access Azure. Use a normal
PowerShell console to see the updating pane. Redirected output uses plain text.
#>
[CmdletBinding()]
param([switch]$Plain)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/health.ps1"
$mode = if ($Plain) { 'Plain' } else { 'Auto' }
Initialize-LabProgress -Activity 'TD SYNNEX | SIMULATED preview' -Mode $mode -Steps @(
    'Create Azure host', 'Download Ubuntu image', 'Install SQL sample'
)
Write-Host 'LOCAL PREVIEW: all statuses are simulated; no Azure access or installation.'
try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-LabHealth 'Create Azure host' Running 0 'Waiting for Azure; percentage unknown.' -TimeoutSeconds 3600
    Wait-LabProgressDelay -Seconds 3 -Clock $clock
    Write-LabHealth 'Create Azure host' Completed $clock.Elapsed.TotalSeconds 'Simulated host creation finished.'
    foreach ($percent in @(10,35,70,99)) {
        Write-LabHealth 'Download Ubuntu image' Transferring ($percent / 10) 'Simulated byte-based download progress.' -PercentComplete $percent -TimeoutSeconds 3600
        Start-Sleep -Milliseconds 650
    }
    Write-LabHealth 'Download Ubuntu image' Completed 10 'Simulated download finished; checksum check follows.' -PercentComplete 100
    Write-LabHealth 'Install SQL sample' StatusUnavailable 3 'Simulated status interruption; waiting for the next observation.' -TimeoutSeconds 4500
    Start-Sleep -Seconds 2
    Write-LabHealth 'Install SQL sample' Running 5 'Simulated status recovered; waiting for installer completion.' -TimeoutSeconds 4500
    Start-Sleep -Seconds 2
    Write-LabHealth 'Install SQL sample' NeedsReview 7 'Simulated failure for the red message preview. Nothing was installed.'
} finally { Complete-LabProgress }
Write-Host 'Preview complete. The warning and failure above were demonstration messages.'
