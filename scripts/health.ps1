# Shared by the deployment client and the embedded Windows host payload.
# Progress is observational: a running process is not proof of workload health.
function Get-LabProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Write-LabHealth {
    param([string]$Stage, [string]$State, [double]$ElapsedSeconds, [string]$Message, [string]$Path = '')
    $record = [ordered]@{ SchemaVersion=1; UpdatedUtc=[DateTimeOffset]::UtcNow.ToString('o'); Stage=$Stage;
        State=$State; ElapsedSeconds=[int]$ElapsedSeconds; Message=$Message }
    Write-Host ("[{0:HH:mm:ss}] {1}: {2} ({3:hh\:mm\:ss} elapsed). {4}" -f (Get-Date),$Stage,$State,([TimeSpan]::FromSeconds($ElapsedSeconds)),$Message)
    if ($Path) {
        # Only caller-supplied, non-secret stage/status summaries go in this file.
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolved))
        $temporary = $resolved + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $resolved -Force -ErrorAction Stop
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
}

function Wait-LabJob {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$Stage,
        [ValidateRange(1,18000)][int]$TimeoutSeconds = 3600,
        [ValidateRange(1,60)][int]$PollSeconds = 30, [string]$HealthPath = '')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ([string]$Job.State -notin @('Completed','Failed','Stopped','Suspended','Disconnected','Blocked')) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "$Stage exceeded its $TimeoutSeconds second limit. The underlying operation may still be running; inspect it before retrying." }
            Write-LabHealth $Stage ([string]$Job.State) $clock.Elapsed.TotalSeconds "Waiting for the result; limit $([int]($TimeoutSeconds / 60)) minutes. This is not an application health check." $HealthPath
            $remaining = [math]::Max(1,[math]::Ceiling($TimeoutSeconds - $clock.Elapsed.TotalSeconds))
            $null = Wait-Job -Job $Job -Timeout ([math]::Min($PollSeconds,$remaining))
        }
        if ([string]$Job.State -ne 'Completed') {
            try { $null = Receive-Job -Job $Job -ErrorAction Stop }
            catch { throw "$Stage failed: $($_.Exception.Message)" }
            throw "$Stage job ended in state $($Job.State). Inspect the Azure operation or host setup logs for the underlying error."
        }
        # A Completed job can still contain non-terminating PowerShell errors.
        $result = @(Receive-Job -Job $Job -ErrorAction Stop)
        Write-LabHealth $Stage Completed $clock.Elapsed.TotalSeconds 'Operation returned; its result is checked by the next validation.' $HealthPath
        return $result
    } catch {
        Write-LabHealth $Stage NeedsReview $clock.Elapsed.TotalSeconds 'Operation failed or exceeded its limit. Inspect service/host diagnostics before retrying.' $HealthPath
        throw
    } finally {
        if ([string]$Job.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Wait-LabManagedSetup {
    param([Parameter(Mandatory)][scriptblock]$ReadStatus, [Parameter(Mandatory)][hashtable]$Observation,
        [ValidateRange(1,18000)][int]$TimeoutSeconds = 15000,
        [ValidateRange(1,3600)][int]$StatusFailureSeconds = 300,
        [ValidateRange(1,3600)][int]$StartupSeconds = 900,
        [ValidateRange(1,60)][int]$PollSeconds = 30, [string]$HealthPath = '')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $unavailableSince = $null
    $started = $false
    $phase = 'Waiting for host phase information'
    $Observation.Terminal = $false
    $phaseNames = @{network='Host networking';images='Downloading and converting images';guests='Creating nested VMs';
        boot='Guest first boot';workloads='Installing workloads';iis='Installing IIS';sql='Installing SQL';validation='Validating sample applications'}
    try {
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $command = $null; $readFailed = $false
            try { $command = & $ReadStatus } catch { $readFailed = $true }
            $view = Get-LabProperty $command InstanceView
            $provisioning = [string](Get-LabProperty $command ProvisioningState '')
            $execution = [string](Get-LabProperty $view ExecutionState '')
            if ($provisioning -in @('Failed','Canceled','Cancelled')) {
                # Extension provisioning failure does not prove that an already-started script stopped.
                throw "Guest setup provisioning reported $provisioning. Inspect ConfigureWorkshop and the VM agent now."
            }
            if ($execution -in @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
                $Observation.Terminal = $true
                if ($execution -ne 'Succeeded') { throw "Guest setup reported $execution (exit code $(Get-LabProperty $view ExitCode 'unknown')). Inspect ConfigureWorkshop and C:\AzMigrateLab\setup-log.txt." }
                Assert-LabManagedRunResult $view
                Write-LabHealth 'Guest setup' Succeeded $clock.Elapsed.TotalSeconds 'All required workload evidence was returned.' $HealthPath
                return $view
            }
            if ($readFailed -or $null -eq $command -or ($started -and $execution -ne 'Running')) {
                if ($null -eq $unavailableSince) { $unavailableSince = $clock.Elapsed.TotalSeconds }
                if ($clock.Elapsed.TotalSeconds - $unavailableSince -ge $StatusFailureSeconds) {
                    throw "Setup status has been unavailable for $StatusFailureSeconds seconds. Monitoring stopped; the Azure script may still be running. Check sign-in, network, VM agent and ConfigureWorkshop before taking action."
                }
                Write-LabHealth 'Guest setup' StatusUnavailable $clock.Elapsed.TotalSeconds 'Unable to read Azure status; retrying within the five-minute default monitoring limit.' $HealthPath
            } else {
                $unavailableSince = $null
                if ($execution -in @('Running','Succeeded')) { $started = $true }
                if (-not $started -and $clock.Elapsed.TotalSeconds -ge $StartupSeconds) { throw "Guest setup did not report Running within $StartupSeconds seconds. Check the VM agent and ConfigureWorkshop provisioning; the script may still start later." }
                $output = [string](Get-LabProperty $view Output '')
                $markers = [regex]::Matches($output, '(?m)^LAB_STAGE\|([a-z]+)\r?$')
                foreach ($marker in $markers) { if ($phaseNames.ContainsKey($marker.Groups[1].Value)) { $phase = $phaseNames[$marker.Groups[1].Value] } }
                $state = if ($execution) { $execution } else { 'WaitingForInstanceView' }
                Write-LabHealth 'Guest setup' $state $clock.Elapsed.TotalSeconds "$phase. Azure output can be delayed; Running alone does not verify progress or application health." $HealthPath
            }
            Start-Sleep -Seconds $PollSeconds
        }
        throw "Guest setup exceeded its $TimeoutSeconds second monitoring limit. Inspect ConfigureWorkshop before retrying; the remote operation may still be running."
    } catch {
        Write-LabHealth 'Guest setup' NeedsReview $clock.Elapsed.TotalSeconds "$phase. Inspect ConfigureWorkshop instance view and the host setup log; no later stage will run." $HealthPath
        throw
    }
}

function Invoke-LabDownload {
    param([string]$Uri, [string]$Destination, [string]$Stage,
        [ValidateRange(1,14400)][int]$TimeoutSeconds = 3600,
        [ValidateRange(1,3600)][int]$StallSeconds = 300,
        [ValidateRange(1,60)][int]$PollSeconds = 30)
    $transfer = Start-BitsTransfer -Source $Uri -Destination $Destination -Asynchronous -ErrorAction Stop
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastBytes = [long]0; $lastProgress = 0.0
    try {
        while ($true) {
            $transfer = Get-BitsTransfer -Id $transfer.JobId -ErrorAction Stop
            if ($transfer.JobState -eq 'Transferred') { Complete-BitsTransfer -BitsJob $transfer -ErrorAction Stop; return }
            if ($transfer.JobState -in @('Error','Cancelled','Acknowledged','Suspended')) { throw "$Stage transfer reported $($transfer.JobState). Inspect BITS and network access." }
            if ($transfer.BytesTransferred -gt $lastBytes) { $lastBytes = $transfer.BytesTransferred; $lastProgress = $clock.Elapsed.TotalSeconds }
            if ($clock.Elapsed.TotalSeconds - $lastProgress -ge $StallSeconds) { throw "$Stage transferred no additional bytes for $StallSeconds seconds. Check outbound connectivity before retrying." }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "$Stage exceeded its $TimeoutSeconds second download limit." }
            Write-LabHealth $Stage ([string]$transfer.JobState) $clock.Elapsed.TotalSeconds ("{0:N1} MiB downloaded; the checksum is checked after completion." -f ($lastBytes / 1MB))
            Start-Sleep -Seconds $PollSeconds
        }
    } finally {
        # BITS jobs survive their creating PowerShell process unless completed/removed.
        if ($transfer.JobState -ne 'Acknowledged') { Remove-BitsTransfer -BitsJob $transfer -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Invoke-LabProcess {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$LogDirectory,
        [ValidateRange(1,14400)][int]$TimeoutSeconds = 3600, [int[]]$SuccessCodes = @(0))
    $log = Join-Path $LogDirectory ('process-' + [guid]::NewGuid().ToString('N'))
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -ErrorAction Stop `
        -RedirectStandardOutput ($log + '.out.log') -RedirectStandardError ($log + '.err.log')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $process.HasExited) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                # Stop this process tree, not unrelated installers or cloud resources.
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
                throw "$Stage exceeded its $TimeoutSeconds second limit. Inspect the host and installer logs before retrying."
            }
            Write-LabHealth $Stage Running $clock.Elapsed.TotalSeconds 'Process is present; completion and exit code are still required.'
            $null = $process.WaitForExit([int]([math]::Min(30,[math]::Max(1,$TimeoutSeconds - $clock.Elapsed.TotalSeconds)) * 1000))
            $process.Refresh()
        }
        # Ensure redirected streams are drained before checking the exit code.
        $process.WaitForExit()
        if ($process.ExitCode -notin $SuccessCodes) { throw "$Stage failed with exit code $($process.ExitCode). Inspect $log.*.log locally; redact credentials and URLs before sharing." }
        Write-LabHealth $Stage Completed $clock.Elapsed.TotalSeconds "Exit code $($process.ExitCode); the next check verifies the installed files/service."
    } finally { $process.Dispose() }
}
