# Console-only regression tests. No Azure resources or external processes are accessed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../scripts/common.ps1"
. "$PSScriptRoot/../scripts/health.ps1"
$progressChecks = 0
$script:capturedProgress = [Collections.Generic.List[object]]::new()
$script:capturedEvents = [Collections.Generic.List[object]]::new()
$script:failProgressRenderer = $false

# Shadow the rendering commands, preserving their parameter names and success stream behavior.
function Write-Progress {
    [CmdletBinding()]
    param([int]$Id, [string]$Activity, [string]$Status, [string]$CurrentOperation,
        [int]$PercentComplete = -1, [int]$SecondsRemaining = -1, [int]$ParentId = -1,
        [switch]$Completed)
    if ($script:failProgressRenderer) { throw 'Fixture terminal does not support progress.' }
    $null = $script:capturedProgress.Add([pscustomobject]@{
        Id=$Id; Activity=$Activity; Status=$Status; CurrentOperation=$CurrentOperation;
        PercentComplete=$PercentComplete; SecondsRemaining=$SecondsRemaining; Completed=[bool]$Completed
    })
}
function Write-Host {
    [CmdletBinding()]
    param([Parameter(Position=0,ValueFromRemainingArguments)][object[]]$Object,
        [ConsoleColor]$ForegroundColor, [ConsoleColor]$BackgroundColor, [switch]$NoNewline,
        [object]$Separator = ' ')
    $null = $script:capturedEvents.Add([pscustomobject]@{
        Text=($Object -join [string]$Separator);
        HasColor=$PSBoundParameters.ContainsKey('ForegroundColor'); Color=[string]$ForegroundColor
    })
}
function Reset-ProgressCapture {
    Complete-LabProgress
    $script:capturedProgress.Clear()
    $script:capturedEvents.Clear()
    $script:failProgressRenderer = $false
}
function Test-ProgressCase {
    param([string]$Name,[scriptblock]$Action)
    Reset-ProgressCapture
    $savedNoColor = [Environment]::GetEnvironmentVariable('NO_COLOR')
    try {
        # Make explicit color assertions independent of the developer/CI preference.
        [Environment]::SetEnvironmentVariable('NO_COLOR',$null)
        & $Action
    } finally {
        Complete-LabProgress
        [Environment]::SetEnvironmentVariable('NO_COLOR',$savedNoColor)
    }
    $script:progressChecks++
    Microsoft.PowerShell.Utility\Write-Host "PASS progress: $Name"
}

Test-ProgressCase 'interactive updates reuse one bar without repeating unchanged event lines' {
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host','Install SQL') -Mode Interactive
    $first = @(Write-LabHealth 'Create host' Running 1 'Waiting for Azure.' -TimeoutSeconds 3600)
    $eventCount = $script:capturedEvents.Count
    $second = @(Write-LabHealth 'Create host' Running 31 'Waiting for Azure.' -TimeoutSeconds 3600)
    if ($first.Count -or $second.Count) { throw 'Display output polluted the operation success stream.' }
    if ($eventCount -eq 0 -or $script:capturedEvents.Count -ne $eventCount) { throw 'Unchanged status repeated the persistent event.' }
    $bars = @($script:capturedProgress | Where-Object { -not $_.Completed })
    if ($bars.Count -ne 2 -or @($bars | Where-Object Id -NE 4700).Count) { throw 'Updates did not reuse the owned progress record.' }
    if ($bars[0].Status -eq $bars[1].Status) { throw 'Elapsed time did not update in place.' }
    if ($bars[1].Activity -notmatch '1\s*/\s*2' -or $bars[1].Activity -notmatch 'Create host') { throw 'The current numbered step was not shown.' }
}
Test-ProgressCase 'unknown operation duration has elapsed time and a limit without a fabricated percent or ETA' {
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
    Write-LabHealth 'Create host' Running 65 'Waiting for Azure.' -TimeoutSeconds 3600
    $bar = @($script:capturedProgress | Where-Object { -not $_.Completed })[-1]
    if ($bar.PercentComplete -ne -1 -or $bar.SecondsRemaining -ne -1) { throw 'An indeterminate operation was given fabricated completion or remaining time.' }
    if ($bar.Status -notmatch 'elapsed' -or $bar.Status -notmatch '(?i)limit' -or $bar.Status -match '(?i)\bETA\b') { throw 'Elapsed time and the limit were not clearly separated from an ETA.' }
}
Test-ProgressCase 'numeric download progress updates in place and retries retain their step number' {
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host','Download image') -Mode Interactive
    Write-LabHealth 'Download image' Transferring 1 'Image download.' -PercentComplete 25
    $events = $script:capturedEvents.Count
    Write-LabHealth 'Download image' Transferring 2 'Image download.' -PercentComplete 50
    $bars = @($script:capturedProgress | Where-Object { -not $_.Completed })
    if ($bars[0].PercentComplete -ne 25 -or $bars[1].PercentComplete -ne 50) { throw 'Known download progress was not rendered.' }
    if ($script:capturedEvents.Count -ne $events) { throw 'A percentage update repeated an unchanged event.' }
    Write-LabHealth 'Download image' TransientError 3 'Retrying the transfer.'
    Write-LabHealth 'Download image' Transferring 4 'Image download.' -PercentComplete 50
    foreach ($bar in @($script:capturedProgress | Where-Object { -not $_.Completed })) {
        if ($bar.Activity -notmatch '2\s*/\s*2') { throw 'A retry changed the planned step number.' }
    }
}
Test-ProgressCase 'events include readable state labels with success warning and failure colors' {
    foreach ($case in @(
        @{State='Running';Color='Cyan'}, @{State='Completed';Color='Green'},
        @{State='Succeeded';Color='Green'}, @{State='StatusUnavailable';Color='Yellow'},
        @{State='TransientError';Color='Yellow'}, @{State='Warning';Color='Yellow'},
        @{State='NeedsReview';Color='Red'}, @{State='Failed';Color='Red'}
    )) {
        Complete-LabProgress
        Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
        Write-LabHealth 'Create host' $case.State 10 'Fixture status.'
        $event = $script:capturedEvents[$script:capturedEvents.Count - 1]
        if (-not $event.HasColor -or $event.Color -ne $case.Color -or $event.Text -notmatch [regex]::Escape($case.State)) {
            throw "State $($case.State) lost its readable label or expected color."
        }
    }
}
Test-ProgressCase 'terminal states and explicit cleanup clear the owned bar without producing results' {
    foreach ($state in @('Completed','Succeeded','NeedsReview','Failed')) {
        Reset-ProgressCapture
        Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
        Write-LabHealth 'Create host' Running 1 'Waiting for Azure.'
        Write-LabHealth 'Create host' $state 2 'Fixture terminal status.'
        if (-not @($script:capturedProgress | Where-Object { $_.Completed -and $_.Id -eq 4700 }).Count) { throw "Terminal state $state left the bar active." }
    }
    Reset-ProgressCapture
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
    Write-LabHealth 'Create host' Running 1 'Waiting for Azure.'
    $result = @(Complete-LabProgress)
    if ($result.Count -or -not @($script:capturedProgress | Where-Object { $_.Completed -and $_.Id -eq 4700 }).Count) { throw 'Explicit progress cleanup failed or polluted the success stream.' }
}
Test-ProgressCase 'plain output retains each observation without terminal control or color' {
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Plain
    $before = $script:capturedEvents.Count
    $result = @(Write-LabHealth 'Create host' Running 1 'Waiting for Azure.'; Write-LabHealth 'Create host' Running 31 'Waiting for Azure.'; Complete-LabProgress)
    if ($result.Count -or $script:capturedProgress.Count -or $script:capturedEvents.Count -ne ($before + 2)) { throw 'Plain mode lost observations or attempted terminal rendering.' }
    if (@($script:capturedEvents | Where-Object HasColor).Count) { throw 'Plain output included explicit color.' }
}
Test-ProgressCase 'NO_COLOR preserves state labels and interactive progress without event color' {
    [Environment]::SetEnvironmentVariable('NO_COLOR','1')
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
    Write-LabHealth 'Create host' StatusUnavailable 31 'Waiting for Azure.'
    if (@($script:capturedProgress | Where-Object { -not $_.Completed }).Count -ne 1) { throw 'NO_COLOR disabled the requested interactive progress.' }
    $event = $script:capturedEvents[$script:capturedEvents.Count - 1]
    if ($event.HasColor -or $event.Text -notmatch 'StatusUnavailable') { throw 'NO_COLOR lost the readable state or still requested color.' }
    Complete-LabProgress
}
Test-ProgressCase 'health JSON preserves the original schema and excludes rendering details' {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ces-progress-' + [guid]::NewGuid() + '.json')
    try {
        Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
        Write-LabHealth 'Create host' Running 12 'Safe summary.' $path -PercentComplete 50 -TimeoutSeconds 3600
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $names = @($record.PSObject.Properties.Name | Sort-Object)
        if (($names -join ',') -ne 'ElapsedSeconds,Message,SchemaVersion,Stage,State,UpdatedUtc') { throw 'Progress rendering changed the health JSON contract.' }
        if ($record.SchemaVersion -ne 1 -or $record.Stage -ne 'Create host' -or $record.State -ne 'Running' -or $record.ElapsedSeconds -ne 12 -or $record.Message -ne 'Safe summary.') { throw 'Health content changed while rendering progress.' }
        $null = [DateTimeOffset]::Parse($record.UpdatedUtc)
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
Test-ProgressCase 'a terminal rendering failure falls back to plain output without stopping work' {
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
    $script:failProgressRenderer = $true
    $result = @(Write-LabHealth 'Create host' Running 1 'Waiting for Azure.')
    $script:failProgressRenderer = $false
    $count = $script:capturedProgress.Count
    $events = $script:capturedEvents.Count
    Write-LabHealth 'Create host' Running 31 'Waiting for Azure.'
    if ($result.Count -or $script:capturedProgress.Count -ne $count -or $script:capturedEvents.Count -le $events) { throw 'Rendering failure did not continue with plain observations.' }
    if ($script:capturedEvents[$script:capturedEvents.Count - 1].HasColor) { throw 'Fallback output still requested terminal color.' }
    Complete-LabProgress
}
Test-ProgressCase 'BITS uses observed bytes and caps its percent until the transfer is acknowledged' {
    function Start-BitsTransfer { param($Source,$Destination,[switch]$Asynchronous,$ErrorAction) [pscustomobject]@{JobId='fixture';JobState='Connecting';BytesTransferred=0} }
    function Get-BitsTransfer { param($Id,$ErrorAction) $script:bitsProgressQueue.Dequeue() }
    function Complete-BitsTransfer { param($BitsJob,$ErrorAction) $script:bitsCompleted++; $BitsJob.JobState='Acknowledged' }
    function Remove-BitsTransfer { param($BitsJob,[switch]$Confirm,$ErrorAction) $script:bitsRemoved++ }
    function Wait-LabProgressDelay {
        param($Seconds,$Clock,$Job,$Process)
        $snapshot=$script:LabProgress.Snapshot.Clone()
        $snapshot.ElapsedSeconds++
        Write-LabProgressDisplay @snapshot
    }
    $script:bitsCompleted=0; $script:bitsRemoved=0
    $script:bitsProgressQueue=[Collections.Generic.Queue[object]]::new()
    foreach ($bytes in @(133,200,250)) {
        $script:bitsProgressQueue.Enqueue([pscustomobject]@{JobId='fixture';JobState='Transferring';BytesTransferred=$bytes;BytesTotal=200})
    }
    $script:bitsProgressQueue.Enqueue([pscustomobject]@{JobId='fixture';JobState='Transferred';BytesTransferred=250;BytesTotal=200})
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Download image') -Mode Interactive
    $result = @(Invoke-LabDownload 'https://example.invalid' 'unused' 'Download image' -PollSeconds 1)
    $bars = @($script:capturedProgress | Where-Object { -not $_.Completed })
    $measured=@($bars.PercentComplete | Select-Object -Unique)
    if ($result.Count -or $bars[0].PercentComplete -ne 66 -or ($measured -join ',') -ne '66,99') { throw 'BITS percentage was not derived from bytes or was completed prematurely.' }
    if ($script:bitsCompleted -ne 1 -or $script:bitsRemoved -ne 0 -or -not @($script:capturedProgress | Where-Object Completed).Count) { throw 'Successful BITS completion did not acknowledge the transfer and clear progress.' }
    if (@($script:capturedEvents | Where-Object { $_.Text -match '\[Transferring\]' }).Count -ne 1) { throw 'Repeated BITS byte updates flooded the event log.' }
}
Test-ProgressCase 'BITS leaves unknown totals indeterminate and clears a failed transfer' {
    function Start-BitsTransfer { param($Source,$Destination,[switch]$Asynchronous,$ErrorAction) [pscustomobject]@{JobId='fixture';JobState='Connecting';BytesTransferred=0} }
    function Get-BitsTransfer { param($Id,$ErrorAction) $script:bitsProgressQueue.Dequeue() }
    function Remove-BitsTransfer { param($BitsJob,[switch]$Confirm,$ErrorAction) $script:bitsRemoved++ }
    function Wait-LabProgressDelay {
        param($Seconds,$Clock,$Job,$Process)
        $snapshot=$script:LabProgress.Snapshot.Clone()
        $snapshot.ElapsedSeconds++
        Write-LabProgressDisplay @snapshot
    }
    $script:bitsRemoved=0
    $script:bitsProgressQueue=[Collections.Generic.Queue[object]]::new()
    $script:bitsProgressQueue.Enqueue([pscustomobject]@{JobId='fixture';JobState='Transferring';BytesTransferred=1})
    $script:bitsProgressQueue.Enqueue([pscustomobject]@{JobId='fixture';JobState='Transferring';BytesTransferred=2;BytesTotal=0})
    $script:bitsProgressQueue.Enqueue([pscustomobject]@{JobId='fixture';JobState='Transferring';BytesTransferred=3;BytesTotal=[uint64]::MaxValue})
    $script:bitsProgressQueue.Enqueue([pscustomobject]@{JobId='fixture';JobState='Error';BytesTransferred=3})
    Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Download image') -Mode Interactive
    $message=''
    try { Invoke-LabDownload 'https://example.invalid' 'unused' 'Download image' -PollSeconds 1 }
    catch { $message=$_.Exception.Message }
    $bars=@($script:capturedProgress | Where-Object { -not $_.Completed })
    if ($message -notmatch 'reported Error' -or $bars.Count -lt 3 -or @($bars | Where-Object PercentComplete -NE -1).Count) { throw 'An unknown BITS total produced a fabricated percent or concealed the transfer failure.' }
    if ($script:bitsRemoved -ne 1 -or -not @($script:capturedProgress | Where-Object Completed).Count) { throw 'The failed transfer or its active progress was left behind.' }
}
Test-ProgressCase 'local redraw advances elapsed time without inventing a newer health observation' {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('ces-redraw-'+[guid]::NewGuid()+'.json')
    try {
        Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Install ADK') -Mode Interactive -EmitMarkers
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Write-LabHealth 'Install ADK' Running $clock.Elapsed.TotalSeconds 'Waiting for the installer.' $path -TimeoutSeconds 3600
        $before=Get-Content -LiteralPath $path -Raw
        $events=$script:capturedEvents.Count
        $result=@(Wait-LabProgressDelay -Seconds 2 -Clock $clock)
        $after=Get-Content -LiteralPath $path -Raw
        $bars=@($script:capturedProgress | Where-Object { -not $_.Completed })
        if ($result.Count -or $bars.Count -lt 3 -or $bars[0].Status -eq $bars[$bars.Count-1].Status) { throw 'The console did not redraw elapsed time locally.' }
        if ($before -cne $after -or $script:capturedEvents.Count -ne $events) { throw 'A cosmetic redraw changed the health observation or repeated an event.' }
        Complete-LabProgress
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
Test-ProgressCase 'managed setup relays only safe installer observations and later phases clear stale download progress' {
    function Wait-LabProgressDelay {
        param($Seconds,$Clock,$Job,$Process)
        $script:relayDelayCalls++
        $snapshot=$script:LabProgress.Snapshot.Clone()
        $snapshot.ElapsedSeconds++
        Write-LabProgressDisplay @snapshot
    }
    $path=Join-Path ([IO.Path]::GetTempPath()) ('ces-relay-'+[guid]::NewGuid()+'.json')
    try {
        $script:relayCalls=0; $script:relayDelayCalls=0
        $script:relaySnapshots=[Collections.Generic.List[object]]::new()
        $relayOutput=@'
SECRET_PASSWORD https://example.invalid/?sig=SECRET_SAS
LAB_STAGE|images
LAB_PROGRESS|ubuntu|Transferring|42|10|20260909T180000Z
LAB_PROGRESS|private|Running|99|11|20260909T180001Z
LAB_PROGRESS|qemu|InvalidState|99|11|20260909T180001Z
LAB_PROGRESS|qemu|Running|99|11|20269999T180001Z
LAB_PROGRESS|qemu|Running|101|11|20260909T180001Z
LAB_PROGRESS|qemu|Running|-2|11|20260909T180001Z
'@
        Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Guest setup') -Mode Interactive
        $observation=@{}
        $result=@(Wait-LabManagedSetup -ReadStatus {
            $script:relayCalls++
            if ($script:relayCalls -gt 1) { $null=$script:relaySnapshots.Add((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)) }
            $output=if ($script:relayCalls -eq 1) { $relayOutput } elseif ($script:relayCalls -eq 2) { "$relayOutput`nLAB_STAGE|sql" } else { 'LAB_WORKLOADS_READY' }
            $state=if ($script:relayCalls -lt 3) { 'Running' } else { 'Succeeded' }
            [pscustomobject]@{ProvisioningState='Succeeded';InstanceView=[pscustomobject]@{ExecutionState=$state;ExitCode=0;Output=$output}}
        } -Observation $observation -PollSeconds 1 -HealthPath $path)
        if ($result.Count -ne 1 -or $result[0].ExecutionState -ne 'Succeeded' -or -not $observation.Terminal) { throw 'Display relay changed managed setup success validation.' }
        if ($script:relayCalls -ne 3 -or $script:relayDelayCalls -ne 2) { throw 'Local redraw changed the number of status observations.' }
        $first=$script:relaySnapshots[0]; $second=$script:relaySnapshots[1]
        if ($first.State -ne 'Running' -or $first.Message -notmatch '42% of download' -or $first.Message -notmatch '18:00:00.*UTC') { throw 'The allowed download progress and host timestamp were not relayed.' }
        if ($second.Message -notmatch 'Installing SQL' -or $second.Message -match 'Ubuntu|42%') { throw 'The new host phase did not clear earlier download progress.' }
        $visible=($script:capturedEvents.Text -join "`n")+($script:capturedProgress.CurrentOperation -join "`n")+($script:relaySnapshots | ConvertTo-Json -Depth 5)
        if ($visible -match 'SECRET|sig=|InvalidState|101%|Install QEMU') { throw 'Raw output or an invalid progress marker reached the display or health file.' }
        if (@($script:capturedProgress | Where-Object { -not $_.Completed -and $_.PercentComplete -ne -1 }).Count) { throw 'Download percentage was misrepresented as overall guest setup completion.' }
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
Test-ProgressCase 'an installer warning stays observational while remaining visible in the console' {
    function Wait-LabProgressDelay { param($Seconds,$Clock,$Job,$Process) }
    $path=Join-Path ([IO.Path]::GetTempPath()) ('ces-relay-warning-'+[guid]::NewGuid()+'.json')
    try {
        $script:warningCalls=0; $script:warningObservation=$null
        Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Guest setup') -Mode Interactive
        $observation=@{}
        $null=Wait-LabManagedSetup -ReadStatus {
            $script:warningCalls++
            if ($script:warningCalls -eq 1) {
                [pscustomobject]@{ProvisioningState='Succeeded';InstanceView=[pscustomobject]@{
                    ExecutionState='Running';ExitCode=0;Output='LAB_PROGRESS|signin-web|NeedsReview|-1|60|20260909T180000Z'}}
            } else {
                $script:warningObservation=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($observation.Terminal) { throw 'The installer marker incorrectly established script termination.' }
                [pscustomobject]@{ProvisioningState='Succeeded';InstanceView=[pscustomobject]@{ExecutionState='Succeeded';ExitCode=0;Output='LAB_WORKLOADS_READY'}}
            }
        } -Observation $observation -PollSeconds 1 -HealthPath $path
        if ($script:warningCalls -ne 2 -or $script:warningObservation.State -ne 'Running') { throw 'The installer warning changed the authoritative execution state or stopped status observation.' }
        $warnings=@($script:capturedEvents | Where-Object { $_.Text -match 'Sign in to OnPrem-Web.*NeedsReview' })
        if ($warnings.Count -ne 1 -or $warnings[0].Color -ne 'Yellow') { throw 'The installer warning was not visibly distinguished from normal running output.' }
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
Test-ProgressCase 'PowerShell 7 progress view respects the platform and restores preferences after every completion path when available' {
    $styleVariable=Get-Variable -Name PSStyle -ErrorAction SilentlyContinue
    if ($null -eq $styleVariable -or $null -eq $styleVariable.Value.PSObject.Properties['Progress']) { return }
    $style=$styleVariable.Value.Progress
    if ($null -eq $style.PSObject.Properties['View']) { return }
    $originalView=$style.View
    $activeView=if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Classic' } else { 'Minimal' }
    try {
        foreach ($outcome in @('Completed','NeedsReview','ExplicitCleanup','RendererFailure')) {
            Complete-LabProgress
            $style.View='Minimal'
            Initialize-LabProgress -Activity 'Fixture deployment' -Steps @('Create host') -Mode Interactive
            Write-LabHealth 'Create host' Running 1 'Waiting for Azure.'
            if ([string]$style.View -ne $activeView) { throw 'The active pane did not preserve the supported progress view for this platform.' }
            if ($outcome -eq 'ExplicitCleanup') { Complete-LabProgress }
            elseif ($outcome -eq 'RendererFailure') {
                $script:failProgressRenderer=$true
                try { Write-LabHealth 'Create host' Running 2 'Fixture renderer failure.' }
                finally { $script:failProgressRenderer=$false }
            } else { Write-LabHealth 'Create host' $outcome 2 'Fixture terminal status.' }
            if ([string]$style.View -ne 'Minimal') { throw "The user's progress view was not restored after $outcome." }
        }
    } finally {
        $script:failProgressRenderer=$false
        Complete-LabProgress
        $style.View=$originalView
    }
}
Microsoft.PowerShell.Utility\Write-Host "Install progress checks passed: $progressChecks. No Azure resources were accessed."
