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
    [ValidateNotNullOrEmpty()][string]$ConfigPath,
    [ValidateNotNullOrEmpty()][string]$RunDirectory,
    [switch]$Interactive,
    [switch]$ApproveProvisioning,
    [switch]$ApproveCleanup,
    [switch]$RetryFailed,
    [SecureString]$AdminPassword
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach ($relative in @('common.ps1','rehearsal/engine.ps1','rehearsal/actions.ps1')) {
    $required=Join-Path $PSScriptRoot $relative
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Workshop file missing: '$required'. Extract or clone the complete workshop and keep its folders together; do not run a single downloaded script or run it from inside a ZIP."
    }
}
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/rehearsal/engine.ps1"
. "$PSScriptRoot/rehearsal/actions.ps1"

if ($Mode -eq 'Plan') {
    Get-RehearsalPlan | Select-Object Id,Kind,Title | Format-Table -AutoSize
    Write-Host 'Plan only. Run executes automatic stages and pauses for instructor evidence. No Azure access or resources were requested.'
    return
}
if ($Mode -eq 'Validate') { Invoke-RehearsalLocalChecks $root; return }
# Windows PowerShell can evaluate parameter defaults before PSScriptRoot is
# populated. Build script-relative defaults only after entering the script body.
if (-not $PSBoundParameters.ContainsKey('ConfigPath')) { $ConfigPath=Join-Path $root 'rehearsal.local.json' }
if (-not $PSBoundParameters.ContainsKey('RunDirectory')) { $RunDirectory=Join-Path $root 'rehearsal-evidence/current' }
$ConfigPath=Resolve-RehearsalFileSystemPath $ConfigPath
$RunDirectory=Resolve-RehearsalFileSystemPath $RunDirectory
if ($Mode -eq 'Status') {
    $statePath=Join-Path $RunDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "No rehearsal results found at '$statePath'. Start with -Mode Run -Interactive, or supply the -RunDirectory used by the existing rehearsal."
    }
    $state=Read-RehearsalJson $statePath
    Write-Host "Run: $($state.RunId) / $($state.Status)"
    $state.Results | Select-Object Id,Status,Message | Format-Table -AutoSize
    return
}
if (-not (Test-Path -LiteralPath $ConfigPath) -and $Interactive) {
    $templatePath=Join-Path $root 'rehearsal.example.json'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Example settings missing: '$templatePath'. Extract or clone the complete workshop before starting interactive setup."
    }
    Write-Host 'First-run configuration. These settings are saved locally; passwords are never saved.'
    $config=Read-RehearsalJson $templatePath
    foreach ($property in $config.PSObject.Properties) {
        $answer=Read-Host "$($property.Name) [$($property.Value)]"
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $property.Value=$answer }
    }
    Write-RehearsalJson $ConfigPath $config
}
Write-Host "Settings: $ConfigPath"
Write-Host "Results directory: $RunDirectory"
$config=Read-RehearsalConfiguration $ConfigPath
$state=Invoke-RehearsalEngine -Root $root -Config $config -Directory $RunDirectory -Interactive:$Interactive `
    -ApproveProvisioning:$ApproveProvisioning -ApproveCleanup:$ApproveCleanup -RetryFailed:$RetryFailed -AdminPassword $AdminPassword
Write-Host "Rehearsal status: $($state.Status). Report: $(Join-Path $RunDirectory 'report.html')"
if ($Interactive) {
    try { Start-Process -FilePath (Join-Path $RunDirectory 'report.html') | Out-Null }
    catch { Write-Warning 'Could not open the report automatically. Open the report path printed above.' }
}
if ($state.Status -eq 'CompletedWithInstructorEvidence') { exit 0 }
if ($state.Status -in @('Failed','NeedsReview')) { exit 1 }
exit 2 # Paused is explicitly not success in an unattended invocation.
