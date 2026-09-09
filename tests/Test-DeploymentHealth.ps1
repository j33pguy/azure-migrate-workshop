# Local regression tests: simulated Azure responses and short local jobs only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../scripts/common.ps1"
. "$PSScriptRoot/../scripts/health.ps1"
$healthChecks = 0
function Test-HealthCase {
    param([string]$Name,[scriptblock]$Action)
    & $Action
    $script:healthChecks++
    Write-Host "PASS health: $Name"
}
function Expect-HealthFailure {
    param([scriptblock]$Action,[string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if ($message -notlike "*$Pattern*") { throw "Expected '$Pattern'; received '$message'." }
}
function New-SetupStatus {
    param([string]$State='Running',[int]$Code=0,[string]$Output='')
    [pscustomobject]@{ProvisioningState='Succeeded';InstanceView=[pscustomobject]@{ExecutionState=$State;ExitCode=$Code;Output=$Output}}
}
Test-HealthCase 'execution failures stop on the first observation' {
    foreach ($state in @('Failed','TimedOut','Canceled','Cancelled')) {
        $observation=@{}; $calls=@{Count=0}
        Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus { $calls.Count++; New-SetupStatus $state 1 } -Observation $observation -PollSeconds 1 } "reported $state"
        if ($calls.Count -ne 1 -or -not $observation.Terminal) { throw 'Terminal failure was retried or not recorded.' }
    }
}
Test-HealthCase 'provisioning failures stop without assuming the script terminated' {
    $observation=@{}
    Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus { [pscustomobject]@{ProvisioningState='Failed';InstanceView=$null} } -Observation $observation } 'provisioning reported Failed'
    if ($observation.Terminal) { throw 'Provisioning failure was mistaken for confirmed script termination.' }
}
Test-HealthCase 'success still requires zero exit code and exact workload evidence' {
    foreach ($status in @((New-SetupStatus Succeeded 1 LAB_WORKLOADS_READY),(New-SetupStatus Succeeded 0 NOT_LAB_WORKLOADS_READY))) {
        Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus { $status } -Observation @{} } 'did not pass'
    }
    $view=Wait-LabManagedSetup -ReadStatus { New-SetupStatus Succeeded 0 LAB_WORKLOADS_READY } -Observation @{}
    if ($view.ExecutionState -ne 'Succeeded') { throw 'Valid completion was lost.' }
}
Test-HealthCase 'a transient status error recovers without replaying setup' {
    $calls=@{Count=0}
    $view=Wait-LabManagedSetup -ReadStatus {
        $calls.Count++
        if ($calls.Count -eq 1) { throw 'Temporary connection failure' }
        New-SetupStatus Succeeded 0 LAB_WORKLOADS_READY
    } -Observation @{} -StatusFailureSeconds 5 -PollSeconds 1
    if ($calls.Count -ne 2 -or $view.ExitCode -ne 0) { throw 'Status recovery failed.' }
}
Test-HealthCase 'persistent loss of status stops with uncertain termination' {
    $observation=@{}
    Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus { throw 'Offline' } -Observation $observation -StatusFailureSeconds 1 -PollSeconds 1 } 'status has been unavailable'
    if ($observation.Terminal) { throw 'Loss of monitoring was mistaken for cancellation.' }
}
Test-HealthCase 'a missing execution view after Running has a bounded outage' {
    $calls=@{Count=0}
    Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus {
        $calls.Count++
        if ($calls.Count -eq 1) { New-SetupStatus } else { [pscustomobject]@{ProvisioningState='Succeeded';InstanceView=$null} }
    } -Observation @{} -StatusFailureSeconds 1 -PollSeconds 1 } 'status has been unavailable'
}
Test-HealthCase 'a command that never starts cannot wait four hours' {
    Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus { [pscustomobject]@{ProvisioningState='Creating';InstanceView=$null} } -Observation @{} -StartupSeconds 1 -PollSeconds 1 } 'did not report Running'
}
Test-HealthCase 'Running is not completion and has an overall deadline' {
    Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus { New-SetupStatus } -Observation @{} -TimeoutSeconds 1 -PollSeconds 1 } 'monitoring limit'
}
Test-HealthCase 'health files do not copy script output errors passwords or SAS URLs' {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('ces-health-'+[guid]::NewGuid()+'.json')
    try {
        $calls=@{Count=0}
        Expect-HealthFailure { Wait-LabManagedSetup -ReadStatus {
            New-SetupStatus Running 0 "SECRET_PASSWORD https://example.invalid/?sig=SECRET_SAS`nLAB_STAGE|sql"
        } -Observation @{} -TimeoutSeconds 1 -PollSeconds 1 -HealthPath $path } 'monitoring limit'
        $text=Get-Content -LiteralPath $path -Raw
        $record=$text | ConvertFrom-Json
        if ($text -match 'SECRET|sig=' -or $record.State -ne 'NeedsReview' -or $record.Message -notmatch 'Installing SQL') { throw 'Health file exposed output or lost its last phase.' }
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
Test-HealthCase 'background operation results survive progress logging' {
    $job=Start-Job { [pscustomobject]@{Marker='RESULT';Value=42} }
    $result=@(Wait-LabJob $job 'Test result' -TimeoutSeconds 30 -PollSeconds 1)
    if ($result.Count -ne 1 -or $result[0].Marker -ne 'RESULT' -or $result[0].Value -ne 42) { throw 'Progress polluted the operation result.' }
}
Test-HealthCase 'failed and non-terminating job errors stop the stage' {
    $job=Start-Job { throw 'Fixture operation failure' }
    Expect-HealthFailure { Wait-LabJob $job 'Test failed job' -TimeoutSeconds 30 -PollSeconds 1 } 'Fixture operation failure'
    $job=Start-Job { Write-Error 'Fixture non-terminating error'; 'misleading success output' }
    Expect-HealthFailure { Wait-LabJob $job 'Test job error' -TimeoutSeconds 30 -PollSeconds 1 } 'Fixture non-terminating error'
}
Test-HealthCase 'operation timeouts stop the local watcher and remove its job' {
    $job=Start-Job { Start-Sleep -Seconds 120 }
    $id=$job.Id
    Expect-HealthFailure { Wait-LabJob $job 'Test stuck operation' -TimeoutSeconds 1 -PollSeconds 1 } 'may still be running'
    if (Get-Job -Id $id -ErrorAction SilentlyContinue) { throw 'Timed-out watcher was left running.' }
}
Test-HealthCase 'BITS failures and stalled byte counts do not get hidden by a fallback' {
    function Start-BitsTransfer { param($Source,$Destination,[switch]$Asynchronous,$ErrorAction) [pscustomobject]@{JobId='fixture';JobState='Connecting';BytesTransferred=0} }
    function Get-BitsTransfer { param($Id,$ErrorAction) [pscustomobject]@{JobId='fixture';JobState=$script:bitsState;BytesTransferred=0} }
    function Remove-BitsTransfer { param($BitsJob,[switch]$Confirm,$ErrorAction) $script:removedBits++ }
    $script:bitsState='Error'; $script:removedBits=0
    Expect-HealthFailure { Invoke-LabDownload 'https://example.invalid' 'unused' 'Fixture download' -PollSeconds 1 } 'reported Error'
    $script:bitsState='TransientError'
    Expect-HealthFailure { Invoke-LabDownload 'https://example.invalid' 'unused' 'Fixture download' -StallSeconds 1 -PollSeconds 1 } 'no additional bytes'
    if ($script:removedBits -ne 2) { throw 'Failed BITS jobs were not removed.' }
}
Test-HealthCase 'embedded host payload includes the same tested helpers' {
    $payload=Read-LabHostConfiguration "$PSScriptRoot/../scripts/host/configure-host.ps1"
    if ($payload -match '# LAB_HEALTH_HELPERS' -or $payload -notmatch 'function Wait-LabJob' -or $payload -notmatch 'function Invoke-LabProcess') { throw 'Host health functions were not embedded.' }
}
Test-HealthCase 'deployment retains an export disk while setup termination is uncertain' {
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../scripts/deploy-lab.ps1",[ref]$tokens,[ref]$errors)
    $statement=$ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
    $text=$statement.Finally.Extent.Text
    $cleanup=[scriptblock]::Create($text.Substring(1,$text.Length-2))
    function Revoke-AzDiskAccess { param($ResourceGroupName,$DiskName) $script:revokes++ }
    function Remove-AzDisk { param($ResourceGroupName,$DiskName,[switch]$Force) $script:deletes++ }
    function Remove-AzVMRunCommand { param($ResourceGroupName,$VMName,$RunCommandName) $script:runDeletes++ }
    $ResourceGroupName='fixture'; $diskName='fixture'; $vmName='fixture'; $runName='fixture'
    $diskCreated=$true; $runCreated=$true
    foreach ($case in @('unknown','failed','succeeded')) {
        $script:revokes=0; $script:deletes=0; $script:runDeletes=0
        $setupObservation=@{Terminal=($case -ne 'unknown')}; $setupPassed=($case -eq 'succeeded')
        & $cleanup
        $expected=if ($case -eq 'unknown') { 0 } else { 1 }
        if ($script:revokes -ne $expected -or $script:deletes -ne $expected -or $script:runDeletes -ne [int]$setupPassed) { throw "Unsafe cleanup for $case." }
    }
}
Test-HealthCase 'native processes enforce success codes and a deadline' {
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('ces-process-'+[guid]::NewGuid())
    $null=New-Item -ItemType Directory -Path $directory
    try {
        $executable=(Get-Process -Id $PID).Path
        $result=@(Invoke-LabProcess $executable '-NoProfile -Command "exit 0"' 'Native success' $directory -TimeoutSeconds 30)
        if ($result.Count) { throw 'Native progress polluted the result stream.' }
        Expect-HealthFailure { Invoke-LabProcess $executable '-NoProfile -Command "exit 9"' 'Native failure' $directory -TimeoutSeconds 30 } 'exit code 9'
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            function taskkill.exe { $index=[array]::IndexOf($args,'/PID'); Stop-Process -Id ([int]$args[$index+1]) -Force }
        }
        Expect-HealthFailure { Invoke-LabProcess $executable '-NoProfile -Command "Start-Sleep -Seconds 120"' 'Native timeout' $directory -TimeoutSeconds 1 } 'exceeded its 1 second limit'
    } finally { Remove-Item -LiteralPath $directory -Recurse -Force }
}
Write-Host "Deployment health checks passed: $healthChecks. No Azure resources were accessed."
