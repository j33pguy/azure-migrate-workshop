<#
.SYNOPSIS
Run or resume the ordered TD SYNNEX Hyper-V workshop rehearsal.
.DESCRIPTION
Plan/Validate/Status do not contact Azure. Run performs automated stages and
pauses at instructor checkpoints. Provisioning and cleanup require explicit
approval. Reports distinguish automated passes from recorded manual evidence.
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan','Validate','Run','Status')][string]$Mode='Plan',
    [string]$ConfigPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'rehearsal.local.json'),
    [string]$RunDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'rehearsal-evidence/current'),
    [switch]$Interactive,
    [switch]$ApproveProvisioning,
    [switch]$ApproveCleanup,
    [switch]$RetryFailed,
    [SecureString]$AdminPassword
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/rehearsal/engine.ps1"
. "$PSScriptRoot/rehearsal/actions.ps1"

if ($Mode -eq 'Plan') {
    Get-RehearsalPlan | Select-Object Id,Kind,Title | Format-Table -AutoSize
    Write-Host 'Plan only. Run executes automatic stages and pauses for instructor evidence. No Azure access or resources were requested.'
    return
}
if ($Mode -eq 'Validate') { Invoke-RehearsalLocalChecks $root; return }
if ($Mode -eq 'Status') {
    $state=Read-RehearsalJson (Join-Path $RunDirectory 'state.json')
    Write-Host "Run: $($state.RunId) / $($state.Status)"
    $state.Results | Select-Object Id,Status,Message | Format-Table -AutoSize
    return
}
if (-not (Test-Path -LiteralPath $ConfigPath) -and $Interactive) {
    Write-Host 'First-run configuration. These settings are saved locally; passwords are never saved.'
    $config=Read-RehearsalJson (Join-Path $root 'rehearsal.example.json')
    foreach ($property in $config.PSObject.Properties) {
        $answer=Read-Host "$($property.Name) [$($property.Value)]"
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $property.Value=$answer }
    }
    Write-RehearsalJson ([IO.Path]::GetFullPath($ConfigPath)) $config
}
$config=Read-RehearsalConfiguration $ConfigPath
$state=Invoke-RehearsalEngine -Root $root -Config $config -Directory $RunDirectory -Interactive:$Interactive `
    -ApproveProvisioning:$ApproveProvisioning -ApproveCleanup:$ApproveCleanup -RetryFailed:$RetryFailed -AdminPassword $AdminPassword
Write-Host "Rehearsal status: $($state.Status). Report: $(Join-Path ([IO.Path]::GetFullPath($RunDirectory)) 'report.html')"
if ($Interactive) {
    try { Start-Process -FilePath (Join-Path ([IO.Path]::GetFullPath($RunDirectory)) 'report.html') | Out-Null }
    catch { Write-Warning 'Could not open the report automatically. Open the report path printed above.' }
}
if ($state.Status -eq 'CompletedWithInstructorEvidence') { exit 0 }
if ($state.Status -in @('Failed','NeedsReview')) { exit 1 }
exit 2 # Paused is explicitly not success in an unattended invocation.
