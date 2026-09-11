# Local orchestration only. Azure operations are defined in actions.ps1.
Set-StrictMode -Version Latest

function Get-RehearsalPlan {
    $rows = @(
        @('local-checks','Check workshop scripts','Automatic','','Run the local PowerShell regression suite.','Safe'),
        @('azure-preflight','Check Azure subscription and source capacity','Automatic','Module-0-Setup.md','Check the exact tenant/subscription, modules, providers, unused group names and source-host quota.','Safe'),
        @('environment-review','Record instructor preparation','Checkpoint','Module-0-Setup.md','Record the selected host size and Microsoft series documentation confirming nested virtualization with Standard security, pricing estimate, spending alert and cleanup deadline, licensing, policy/RDP/download access and target/test capacity review.','Safe'),
        @('deploy-source','Deploy Hyper-V host and five guests','Provision','Module-0-Setup.md','Creates billable source resources and waits for source workload readiness.','Unsafe'),
        @('source-review','Record source image and network evidence','Checkpoint','Module-0-Setup.md','Record setup-complete.json, guest/image/package versions, DHCP, source endpoint checks and free host disk/RAM.','Safe'),
        @('target-networks','Create isolated target and test networks','Provision','Module-0-Setup.md','Creates billable target resources including two NAT gateways and public IPs.','Unsafe'),
        @('discovery','Register appliance, discover and assess','Checkpoint','Module-1-Discovery.md','Inside MigrateAppl, follow Module 1 to prepare Gateway, run the interactive appliance installer and verify its configuration page. Then complete project/host preparation, appliance sign-in, four named workloads and reviewed assessment. Deployment created the appliance OS only.','Safe'),
        @('pretest-baseline','Preserve source SQL baseline','Checkpoint','Module-2-HyperV-Migration.md','Stop sample-data edits. Copy the reviewed SQL helper into the source SQL VM, capture source-pretest.baseline.json and retain an independent local copy. Set BaselinePath below to that copy.','Safe'),
        @('replication','Register host provider and replicate','Checkpoint','Module-2-HyperV-Migration.md','Register the Hyper-V host provider to this project. Record all four healthy replication jobs and completed initial synchronization.','Safe'),
        @('test-migration','Create test VMs through Azure Migrate','Checkpoint','Module-2-HyperV-Migration.md','Run all four test migrations into the isolated test VNet. Record successful jobs and fill VMNames with the actual four Azure test names.','Safe'),
        @('test-workloads','Test four running test workloads','Automatic','Module-2-HyperV-Migration.md','Use VM Run Command to check IIS, Nginx, Node API and SQL integrity.','Safe'),
        @('test-network','Test isolated VM networking','Automatic','Module-2-HyperV-Migration.md','Verify all four VMs use the test subnet without public NIC IPs; probe SQL, Nginx and Node ports from the Windows web VM.','Safe'),
        @('test-sql','Compare test SQL data with source','Automatic','Module-2-HyperV-Migration.md','Verify the replicated baseline and SQL helper hashes, then compare all defined sample-table columns.','Safe'),
        @('test-cleanup','Clean up test migration in Azure Migrate','Checkpoint','Module-2-HyperV-Migration.md','Use service-managed test cleanup for every workload; record job completion and absence of test VM/disks.','Safe'),
        @('test-absence','Verify test VMs are removed','Automatic','Module-2-HyperV-Migration.md','Verify the recorded test VM names no longer appear in the target group. Disk/service cleanup evidence is recorded separately.','Safe'),
        @('precutover-baseline','Prepare SQL baseline, backup and cutover','Checkpoint','Module-3-Stateful-Migration.md','Stop writers, capture source-precutover.baseline.json, preserve an independent copy, and record backup/VERIFYONLY, maintenance window and rollback decision. Set BaselinePath below.','Safe'),
        @('cutover','Perform planned cutover in Azure Migrate','Checkpoint','Module-3-Stateful-Migration.md','Perform planned source shutdown/final synchronization and migration for all four workloads. Record job results, timings and actual final VMNames. Do not complete migration until acceptance passes.','Safe'),
        @('source-off','Verify all four source workloads are off','Automatic','Module-3-Stateful-Migration.md','Check the actual nested Hyper-V workload power states.','Safe'),
        @('final-workloads','Test four migrated workloads','Automatic','Module-3-Stateful-Migration.md','Repeat service, HTTP, API and database integrity checks in the final VMs.','Safe'),
        @('final-network','Test final VM networking','Automatic','Module-3-Stateful-Migration.md','Verify final subnet placement and private cross-VM TCP access.','Safe'),
        @('final-sql','Compare final SQL data with source','Automatic','Module-3-Stateful-Migration.md','Compare against the independent precutover baseline, never a target-generated baseline.','Safe'),
        @('complete-migration','Accept and complete migration','Checkpoint','Module-3-Stateful-Migration.md','Review automated results and remaining business acceptance checks, then complete migration in the portal for each workload.','Safe'),
        @('asr-discussion','Complete the migration/DR comparison','Checkpoint','Module-4-ASR-Comparison.md','Record the Module 4 discussion. If an optional ASR demonstration was run, retain its separate validation and teardown evidence.','Safe'),
        @('post-inventory','Inventory the final VMs','Automatic','Module-5-Post-Migration.md','Record the names, OS and sizes of the actual four migrated VMs.','Safe'),
        @('operations','Record post-migration operations','Checkpoint','Module-5-Post-Migration.md','State which monitoring/backup/restore exercises were hands-on, demonstrated or omitted. Retain query/recovery/restore evidence for any claimed hands-on checks.','Safe'),
        @('service-cleanup','Complete migration and vault cleanup','Checkpoint','Cleanup.md','Complete service cleanup, unregister/remove vault dependencies using the runbook, preserve evidence/backups outside the lab, and account for resources outside the two groups. Do not bypass locks or backup retention.','Safe'),
        @('cleanup-preview','Preview remaining resource deletion','Automatic','Cleanup.md','Run guarded cleanup with WhatIf. Vaults and locks must already be resolved.','Safe'),
        @('cleanup','Delete the two dedicated lab groups','Cleanup','Cleanup.md','Requires separate explicit deletion approval. Verify both named groups are absent.','Safe')
    )
    foreach ($row in $rows) {
        [pscustomobject]@{ Id=$row[0]; Title=$row[1]; Kind=$row[2]; Guide=$row[3]; Instructions=$row[4]; RetrySafe=($row[5] -eq 'Safe') }
    }
}

function Resolve-RehearsalFileSystemPath {
    param([Parameter(Mandatory)][string]$Path)
    $provider=$null; $drive=$null
    try { $resolved=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive) }
    catch { throw "Cannot resolve workshop path '$Path'. Use a valid filesystem path on this workstation. $($_.Exception.Message)" }
    if ($provider.Name -ne 'FileSystem') { throw "Workshop path '$Path' must use the filesystem, not the $($provider.Name) provider." }
    return $resolved
}

function Read-RehearsalJson {
    param([string]$Path)
    $Path=Resolve-RehearsalFileSystemPath $Path
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $json -DateKind String }
    return ConvertFrom-Json -InputObject $json
}

function Write-RehearsalJson {
    param([string]$Path, $Value)
    $Path=Resolve-RehearsalFileSystemPath $Path
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Read-RehearsalConfiguration {
    param([string]$Path)
    $Path=Resolve-RehearsalFileSystemPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file not found: '$Path'. Start with -Mode Run -Interactive to create it, or copy rehearsal.example.json to this path and fill in the settings."
    }
    $config = Read-RehearsalJson $Path
    $required = @('SubscriptionId','TenantId','Location','SourceResourceGroup','TargetResourceGroup','AdminUsername','AdminSourceCidr','VMSize')
    if ($null -eq $config -or @($config.PSObject.Properties).Count -ne $required.Count) { throw 'Use the exact rehearsal.example.json fields; do not store credentials or extra settings in this file.' }
    foreach ($name in $required) {
        if (-not $config.PSObject.Properties[$name] -or $config.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($config.$name)) { throw "Missing text setting: $name" }
    }
    foreach ($name in @('SubscriptionId','TenantId')) {
        if ($config.$name -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or [guid]$config.$name -eq [guid]::Empty) { throw "Supply the real $name GUID." }
    }
    foreach ($name in @('SourceResourceGroup','TargetResourceGroup')) {
        if ($config.$name -notmatch '^[a-zA-Z0-9_-]{1,60}$') { throw 'Use new literal resource-group names of 1-60 letters, digits, underscores or hyphens.' }
    }
    if ($config.SourceResourceGroup -eq $config.TargetResourceGroup) { throw 'Source and target groups must be different.' }
    if ($config.Location -notmatch '^[a-z][a-z0-9]+$') { throw 'Use the Azure region identifier, for example eastus.' }
    if ($config.AdminUsername -notmatch '^[a-z][a-z0-9]{2,18}$' -or $config.AdminUsername -in @('admin','administrator','root','guest','user','test')) { throw 'Choose a non-reserved lab administrator name, such as labadmin.' }
    Assert-LabAdminSource $config.AdminSourceCidr
    Assert-LabHostSizeName $config.VMSize
    return $config
}

function Get-RehearsalFingerprint {
    param([string]$Root, $Config)
    $entries = @()
    foreach ($property in ($Config.PSObject.Properties | Sort-Object Name)) { $entries += "$($property.Name)=$($property.Value)" }
    foreach ($directory in @('scripts','tests','docs')) {
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $Root $directory) -Recurse -File -ErrorAction Stop | Where-Object { $_.Extension -in @('.ps1','.py','.md','.txt') } | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($Root.TrimEnd('/','\').Length).Replace('\','/')
            $entries += "$relative=$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
        }
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))))).Replace('-','') }
    finally { $algorithm.Dispose() }
}

function Save-RehearsalState {
    param($State,[string]$Directory)
    Write-RehearsalJson (Join-Path $Directory 'state.json') $State
    $rows = foreach ($result in $State.Results) {
        $values = @($result.Id,$result.Kind,$result.Status,$result.Attempts,$result.CompletedUtc,$result.Message) | ForEach-Object { [System.Net.WebUtility]::HtmlEncode([string]$_) }
        '<tr><td>' + ($values -join '</td><td>') + '</td></tr>'
    }
    $summary = [System.Net.WebUtility]::HtmlEncode([string]$State.Status)
    $run = [System.Net.WebUtility]::HtmlEncode([string]$State.RunId)
    $html = @"
<!doctype html><html lang="en"><meta charset="utf-8"><title>TD SYNNEX rehearsal results</title>
<style>body{font:16px system-ui;max-width:1200px;margin:32px auto;padding:0 16px;color:#183547}table{border-collapse:collapse;width:100%}td,th{border:1px solid #cbd5db;padding:8px;text-align:left}th{background:#edf4f6}</style>
<h1>TD SYNNEX | Cloud Enablement Services</h1><h2>Workshop rehearsal: $summary</h2><p>Run: $run</p>
<p>Passed = automated check completed. Recorded = instructor checkpoint evidence, not an automated pass. Pending, paused and failed steps are not complete. Completion does not independently certify manual claims.</p>
<table><thead><tr><th>Stage</th><th>Type</th><th>Status</th><th>Attempts</th><th>Completed UTC</th><th>Result</th></tr></thead><tbody>$($rows -join "`n")</tbody></table>
<p>Detailed evidence and checksums are retained locally in state.json and artifacts. No credentials should be stored in these reports. Local regression tests and hosted CI do not establish live migration success.</p></html>
"@
    [IO.File]::WriteAllText((Join-Path $Directory 'report.html'),$html,[Text.UTF8Encoding]::new($false))
}

function New-RehearsalCheckpoint {
    param($State,$Stage,[string]$Path)
    $checkpoint = [ordered]@{ RunId=$State.RunId; StepId=$Stage.Id; Outcome='NotRun'; RecordedBy=''; ObservedAtUtc=''; Notes=''; Instructions=$Stage.Instructions }
    if ($Stage.Id -in @('pretest-baseline','precutover-baseline')) { $checkpoint.BaselinePath='' }
    if ($Stage.Id -in @('test-migration','cutover')) { $checkpoint.VMNames=[ordered]@{WindowsWebVM='';SqlVM='';LinuxWebVM='';LinuxAppVM=''} }
    Write-RehearsalJson $Path $checkpoint
}

function Complete-RehearsalCheckpointInteractively {
    param([string]$Path)
    $value=Read-RehearsalJson $Path
    Write-Host 'Record only work you actually completed. Keep passwords, registration keys and SAS URLs out of evidence.'
    $value.RecordedBy=Read-Host 'Instructor name'
    $value.Notes=Read-Host 'Observed results, job/evidence references and any optional exercises omitted'
    if ($value.PSObject.Properties['BaselinePath']) { $value.BaselinePath=Read-Host 'Absolute path to the independent source baseline on this workstation' }
    if ($value.PSObject.Properties['VMNames']) {
        foreach ($role in @('WindowsWebVM','SqlVM','LinuxWebVM','LinuxAppVM')) { $value.VMNames.$role=Read-Host "Actual Azure VM name for $role" }
    }
    $value.ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    $value.Outcome='Completed'
    Write-RehearsalJson $Path $value
}

function Read-RehearsalCheckpoint {
    param($State,$Stage,[string]$Path,[string]$Directory)
    $value = Read-RehearsalJson $Path
    if ($value.Outcome -eq 'NotRun') { return $null }
    if ($value.Outcome -cne 'Completed' -or $value.RunId -cne $State.RunId -or $value.StepId -cne $Stage.Id) { throw 'Checkpoint must match this run/stage and have Outcome Completed only after the work was done.' }
    if ([string]::IsNullOrWhiteSpace($value.RecordedBy) -or [string]::IsNullOrWhiteSpace($value.Notes)) { throw 'Record the instructor name and actual observations in Notes.' }
    $observed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$value.ObservedAtUtc,[ref]$observed) -or $observed -lt [DateTimeOffset]::Parse($State.StartedUtc) -or $observed -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { throw 'ObservedAtUtc must be a timestamp from this rehearsal, not old evidence or a future date.' }
    $data = [ordered]@{ CheckpointPath="artifacts/$($Stage.Id).json"; CheckpointSha256=''; BaselinePath=''; BaselineSha256=''; VMNames=$null }
    if ($Stage.Id -in @('test-migration','cutover')) {
        $map = $value.VMNames
        Assert-LabWorkloadNames @($map.WindowsWebVM,$map.SqlVM,$map.LinuxWebVM,$map.LinuxAppVM)
        $data.VMNames=$map
    }
    if ($Stage.Id -in @('pretest-baseline','precutover-baseline')) {
        if (-not [IO.Path]::IsPathRooted($value.BaselinePath)) { throw 'BaselinePath must be the absolute path to the independent source baseline on this workstation.' }
        $baseline = Read-RehearsalJson $value.BaselinePath
        # The full sample schema is checked again by the SQL helper in the VM.
        if ($baseline.SchemaVersion -ne 1 -or $baseline.Database -cne 'ContosoApp' -or $null -eq $baseline.Tables -or @($baseline.Tables.Customers).Count -lt 5 -or @($baseline.Tables.Orders).Count -lt 5) { throw 'Use the independent baseline captured by Test-LabSqlData.ps1 in the source VM.' }
        $data.BaselinePath="artifacts/$($Stage.Id).baseline.json"
        Copy-Item -LiteralPath $value.BaselinePath -Destination (Join-Path $Directory $data.BaselinePath) -Force
        $data.BaselineSha256=(Get-FileHash -LiteralPath (Join-Path $Directory $data.BaselinePath) -Algorithm SHA256).Hash
    }
    Copy-Item -LiteralPath $Path -Destination (Join-Path $Directory $data.CheckpointPath) -Force
    $data.CheckpointSha256=(Get-FileHash -LiteralPath (Join-Path $Directory $data.CheckpointPath) -Algorithm SHA256).Hash
    return [pscustomobject]$data
}

function Get-RehearsalEvidence {
    param($State,[string]$Id)
    $result = @($State.Results | Where-Object Id -EQ $Id)
    if ($result.Count -ne 1 -or $result[0].Status -ne 'Recorded' -or $null -eq $result[0].Evidence) { throw "Missing recorded checkpoint: $Id" }
    return $result[0].Evidence
}

function Assert-RehearsalState {
    param($State,$Plan,[string]$Fingerprint,[string]$Directory)
    if ($State.SchemaVersion -ne 1 -or $State.Fingerprint -cne $Fingerprint -or $State.Results.Count -ne $Plan.Count) { throw 'Configuration or workshop files differ from this run. Restore the pinned checkout/configuration or start a separate reviewed run with new groups. Do not edit state to skip stages.' }
    $incomplete = $false
    for ($i=0; $i -lt $Plan.Count; $i++) {
        $result = $State.Results[$i]
        if ($result.Id -cne $Plan[$i].Id -or $result.Kind -cne $Plan[$i].Kind -or $result.Status -notin @('Pending','Running','Passed','Recorded','AwaitingInput','AwaitingApproval','Failed','Interrupted')) { throw 'Invalid stage ledger.' }
        $complete = $result.Status -in @('Passed','Recorded')
        if ($complete -and $incomplete) { throw 'A later stage cannot be complete while an earlier stage is incomplete.' }
        if ($complete -and (($result.Kind -eq 'Checkpoint') -ne ($result.Status -eq 'Recorded'))) { throw 'Manual checkpoints cannot be marked as automated passes.' }
        if (-not $complete) { $incomplete=$true }
        if ($result.Status -eq 'Recorded') {
            foreach ($pair in @(@('CheckpointPath','CheckpointSha256'),@('BaselinePath','BaselineSha256'))) {
                $relative = [string]$result.Evidence.($pair[0])
                if (-not $relative) { continue }
                if ($relative -cne "artifacts/$($result.Id).json" -and $relative -cne "artifacts/$($result.Id).baseline.json") { throw 'Invalid evidence path in stage ledger.' }
                if ((Get-FileHash -LiteralPath (Join-Path $Directory $relative) -Algorithm SHA256).Hash -cne $result.Evidence.($pair[1])) { throw 'Recorded evidence changed or is missing. Restore the original evidence before resuming.' }
            }
            $snapshot=Read-RehearsalJson (Join-Path $Directory $result.Evidence.CheckpointPath)
            if ($snapshot.RunId -cne $State.RunId -or $snapshot.StepId -cne $result.Id -or $snapshot.Outcome -cne 'Completed') { throw 'Checkpoint snapshot does not match this run.' }
            if ($result.Id -in @('test-migration','cutover')) {
                foreach ($role in @('WindowsWebVM','SqlVM','LinuxWebVM','LinuxAppVM')) {
                    if ($snapshot.VMNames.$role -cne $result.Evidence.VMNames.$role) { throw 'Recorded VM mapping differs from its checkpoint evidence.' }
                }
            }
        }
    }
}

function Invoke-RehearsalEngine {
    param([string]$Root,$Config,[string]$Directory,[switch]$Interactive,[switch]$ApproveProvisioning,[switch]$ApproveCleanup,[switch]$RetryFailed,[SecureString]$AdminPassword)
    $Root=Resolve-RehearsalFileSystemPath $Root
    $Directory=Resolve-RehearsalFileSystemPath $Directory
    $null=New-Item -ItemType Directory -Path $Directory -Force
    # Keep the lock file: unlinking it after closing would allow a second owner.
    $lock=$null
    try { $lock=[IO.File]::Open((Join-Path $Directory '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'This rehearsal directory is already in use, or cannot be locked.' }
    try {
        $plan=@(Get-RehearsalPlan)
        $fingerprint=Get-RehearsalFingerprint $Root $Config
        $statePath=Join-Path $Directory 'state.json'
        if (Test-Path -LiteralPath $statePath) {
            $state=Read-RehearsalJson $statePath
            Assert-RehearsalState $state $plan $fingerprint $Directory
        } else {
            $results=@(foreach ($stage in $plan) { [pscustomobject]@{Id=$stage.Id;Kind=$stage.Kind;Status='Pending';Attempts=0;CompletedUtc='';Message='';Evidence=$null} })
            $state=[pscustomobject]@{SchemaVersion=1;RunId=[guid]::NewGuid().ToString();StartedUtc=[DateTimeOffset]::UtcNow.ToString('o');Fingerprint=$fingerprint;Config=$Config;Status='Pending';Results=$results}
        }
        foreach ($folder in @('checkpoints','artifacts')) { $null=New-Item -ItemType Directory -Path (Join-Path $Directory $folder) -Force }
        foreach ($stage in $plan) {
            $result=@($state.Results | Where-Object Id -EQ $stage.Id)[0]
            if ($result.Status -in @('Passed','Recorded')) { continue }
            if ($result.Status -eq 'Running') { $result.Status='Interrupted'; $result.Message='Previous process stopped before saving a verified result.' }
            if ($result.Status -in @('Failed','Interrupted')) {
                if ($stage.RetrySafe -and -not $RetryFailed -and $Interactive) {
                    if ((Read-Host "Review and fix $($stage.Id) first. Type RETRY to rerun this safe stage, or Enter to pause") -ceq 'RETRY') { $RetryFailed=$true }
                }
                if (-not $stage.RetrySafe -or -not $RetryFailed) {
                    $state.Status='NeedsReview'; Save-RehearsalState $state $Directory
                    Write-Warning "Stopped at $($stage.Id). Review the failure. Safe checks may be retried with -RetryFailed; provisioning is never replayed after an uncertain result. See the rehearsal guide."
                    return $state
                }
            }
            Write-Host "[$($stage.Id)] $($stage.Title)"
            if ($stage.Kind -eq 'Checkpoint') {
                $path=Join-Path $Directory "checkpoints/$($stage.Id).json"
                if (-not (Test-Path -LiteralPath $path)) { New-RehearsalCheckpoint $state $stage $path }
                while ($true) {
                    $result.Status='AwaitingInput'; $state.Status='AwaitingInput'; Save-RehearsalState $state $Directory
                    $evidence=$null
                    try { $evidence=Read-RehearsalCheckpoint $state $stage $path $Directory }
                    catch { Write-Warning $_.Exception.Message }
                    if ($null -ne $evidence) { $result.Evidence=$evidence; break }
                    Write-Host "$($stage.Instructions)`nGuide: $(Join-Path $Root "docs/$($stage.Guide)")`nEvidence to complete: $path"
                    if (-not $Interactive) { return $state }
                    $choice=Read-Host 'D records a completed checkpoint; Enter reloads its JSON evidence; Q pauses'
                    if ($choice -match '^(?i)q$') { return $state }
                    if ($choice -match '^(?i)d$') { Complete-RehearsalCheckpointInteractively $path }
                }
                $result.Status='Recorded'; $result.Message='Instructor evidence recorded; not an automated test pass.'
            } else {
                if ($stage.Kind -eq 'Provision' -and -not $ApproveProvisioning) {
                    Write-Host "Creates billable resources in $($Config.SubscriptionId), $($Config.Location): $($Config.SourceResourceGroup), $($Config.TargetResourceGroup)."
                    if ($Interactive -and (Read-Host 'Type PROVISION to authorize both deployment stages for this invocation, or Enter to pause') -ceq 'PROVISION') { $ApproveProvisioning=$true }
                    else { $result.Status='AwaitingApproval'; $state.Status='AwaitingApproval'; Save-RehearsalState $state $Directory; return $state }
                }
                if ($stage.Kind -eq 'Cleanup' -and -not $ApproveCleanup) {
                    $expected="DELETE $($Config.SourceResourceGroup),$($Config.TargetResourceGroup)"
                    if ($Interactive -and (Read-Host "Permanently deletes both groups in $($Config.SubscriptionId). Type '$expected' or Enter to pause") -ceq $expected) { $ApproveCleanup=$true }
                    else { $result.Status='AwaitingApproval'; $state.Status='AwaitingApproval'; Save-RehearsalState $state $Directory; return $state }
                }
                if ($stage.Id -eq 'deploy-source' -and $null -eq $AdminPassword) {
                    if ($Interactive) { $AdminPassword=Read-Host 'Lab-only administrator password (not saved)' -AsSecureString }
                    else { $result.Status='AwaitingInput'; $state.Status='AwaitingInput'; $result.Message='Supply AdminPassword as SecureString for source deployment.'; Save-RehearsalState $state $Directory; return $state }
                }
                $result.Status='Running'; $result.Attempts++; $state.Status='Running'; Save-RehearsalState $state $Directory
                try {
                    Invoke-RehearsalAction -Id $stage.Id -Root $Root -Config $Config -State $state -Directory $Directory -AdminPassword $AdminPassword -Interactive:$Interactive | Out-Host
                    $result.Status='Passed'; $result.Message='Automated stage completed without a terminating error.'
                } catch {
                    $result.Status='Failed'; $result.Message='Stage failed. Inspect the terminal and service diagnostics; resources may remain. No later stage or automatic teardown was run.'
                    $state.Status='Failed'; Save-RehearsalState $state $Directory
                    # Do not serialize potentially sensitive exception output into reports.
                    Write-Warning "Stage $($stage.Id) failed: $($_.Exception.Message)"
                    return $state
                } finally { if ($stage.Id -eq 'deploy-source') { $AdminPassword=$null } }
            }
            $result.CompletedUtc=[DateTimeOffset]::UtcNow.ToString('o'); Save-RehearsalState $state $Directory
        }
        $state.Status='CompletedWithInstructorEvidence'; Save-RehearsalState $state $Directory
        return $state
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}
