# No Azure calls. Exercise the real runner with simulated adapters, then adapter fixtures.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. "$root/scripts/common.ps1"
. "$root/scripts/rehearsal/engine.ps1"
. "$root/scripts/rehearsal/actions.ps1"
$failures=[Collections.Generic.List[string]]::new()
$count=0
$suite=Join-Path ([IO.Path]::GetTempPath()) ('ces-rehearsal-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $suite
$config=[pscustomobject]@{
    SubscriptionId='11111111-1111-1111-1111-111111111111';TenantId='22222222-2222-2222-2222-222222222222';Location='eastus'
    SourceResourceGroup='source-test';TargetResourceGroup='target-test';AdminUsername='labadmin';AdminSourceCidr='203.0.113.42/32';VMSize='Standard_E8s_v5'
}
$password=ConvertTo-SecureString 'PRIVATE-SENTINEL-Password123!' -AsPlainText -Force
function Check {
    param([string]$Name,[scriptblock]$Action)
    try { & $Action; $script:count++; Write-Host "PASS $Name" }
    catch { $failures.Add("$Name`: $($_.Exception.Message)") }
}
function MustThrow {
    param([scriptblock]$Action)
    $threw=$false
    try { & $Action | Out-Null } catch { $threw=$true }
    if (-not $threw) { throw 'Expected a terminating error.' }
}
function New-TestRun {
    $script:calls=[Collections.Generic.List[string]]::new(); $script:failAt=''
    $directory=Join-Path $suite ([guid]::NewGuid().ToString('N'))
    return $directory
}
function Invoke-RehearsalAction {
    param($Id,$Root,$Config,$State,$Directory,$AdminPassword,[switch]$Interactive)
    $script:calls.Add($Id)
    if ($Id -eq $script:failAt) { throw 'PRIVATE-SENTINEL-Password123! simulated service failure' }
}
function Complete-Checkpoint {
    param([string]$Directory,$State,[string]$Id)
    $path=Join-Path $Directory "checkpoints/$Id.json"
    $data=Read-RehearsalJson $path
    $data.Outcome='Completed'; $data.RecordedBy='Fixture instructor'; $data.ObservedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); $data.Notes='Simulated evidence, not an Azure result.'
    if ($data.PSObject.Properties['VMNames']) {
        $prefix=if ($Id -eq 'test-migration') { 'test' } else { 'final' }
        $data.VMNames=[pscustomobject]@{WindowsWebVM="$prefix-web";SqlVM="$prefix-sql";LinuxWebVM="$prefix-linux-web";LinuxAppVM="$prefix-linux-app"}
    }
    if ($data.PSObject.Properties['BaselinePath']) {
        $data.BaselinePath=Join-Path $Directory "$Id-source.json"
        Write-RehearsalJson $data.BaselinePath ([pscustomobject]@{SchemaVersion=1;Database='ContosoApp';Tables=[pscustomobject]@{Customers=@(1,2,3,4,5);Orders=@(1,2,3,4,5)}})
    }
    Write-RehearsalJson $path $data
}
function Advance-To {
    param([string]$Directory,[string]$StopAt)
    for ($i=0;$i -lt 30;$i++) {
        $state=Invoke-RehearsalEngine $root $config $Directory -ApproveProvisioning -AdminPassword $password
        $pending=@($state.Results | Where-Object { $_.Status -notin @('Passed','Recorded') })
        if (-not $pending.Count -or $pending[0].Id -eq $StopAt -or $state.Status -in @('Failed','NeedsReview','AwaitingApproval')) { return $state }
        if ($pending[0].Kind -ne 'Checkpoint') { throw 'Unexpected stop while advancing the simulated run.' }
        Complete-Checkpoint $Directory $state $pending[0].Id
    }
    throw 'Simulated run did not reach its expected stop.'
}
try {
    Check 'Configuration rejects credentials, placeholder IDs, duplicate groups and wildcard IPs' {
        $path=Join-Path $suite 'config.json'
        Write-RehearsalJson $path $config
        $null=Read-RehearsalConfiguration $path
        foreach ($field in @('SubscriptionId','TargetResourceGroup','AdminSourceCidr','Password')) {
            $bad=Read-RehearsalJson $path
            switch ($field) {
                'SubscriptionId' {$bad.SubscriptionId=[guid]::Empty.ToString()}
                'TargetResourceGroup' {$bad.TargetResourceGroup=$bad.SourceResourceGroup}
                'AdminSourceCidr' {$bad.AdminSourceCidr='*'}
                'Password' {$bad | Add-Member -NotePropertyName Password -NotePropertyValue 'do-not-save'}
            }
            $badPath=Join-Path $suite 'bad-config.json'; Write-RehearsalJson $badPath $bad
            MustThrow { Read-RehearsalConfiguration $badPath }
        }
    }
    Check 'Plan never invokes an Azure adapter and covers all six modules plus cleanup' {
        $directory=New-TestRun
        $plan=@(Get-RehearsalPlan)
        if ($plan.Count -ne 28 -or $calls.Count -ne 0 -or $plan[-1].Id -ne 'cleanup') { throw 'Unexpected plan or side effect.' }
        foreach ($guide in @('Module-0-Setup.md','Module-1-Discovery.md','Module-2-HyperV-Migration.md','Module-3-Stateful-Migration.md','Module-4-ASR-Comparison.md','Module-5-Post-Migration.md','Cleanup.md')) {
            if ($guide -notin $plan.Guide) { throw "Missing guide $guide" }
        }
    }
    Check 'Missing/manual evidence pauses and cannot silently pass or start provisioning' {
        $directory=New-TestRun
        $state=Invoke-RehearsalEngine $root $config $directory
        if ($state.Status -ne 'AwaitingInput' -or ($calls -join ',') -ne 'local-checks,azure-preflight') { throw 'Runner skipped the first checkpoint.' }
        $path=Join-Path $directory 'checkpoints/environment-review.json'
        $data=Read-RehearsalJson $path
        $data.Outcome='Completed'; $data.RecordedBy='Test'; $data.Notes='Old evidence'; $data.ObservedAtUtc='2000-01-01T00:00:00Z'
        Write-RehearsalJson $path $data
        $state=Invoke-RehearsalEngine $root $config $directory
        if ($state.Status -ne 'AwaitingInput' -or $calls.Count -ne 2) { throw 'Old evidence was accepted.' }
        Complete-Checkpoint $directory $state 'environment-review'
        $state=Invoke-RehearsalEngine $root $config $directory
        if ($state.Status -ne 'AwaitingApproval' -or $calls.Count -ne 2) { throw 'Provisioning ran without explicit approval.' }
        if ($state.Results[2].Status -ne 'Recorded') { throw 'Manual completion mislabeled.' }
        $state=Invoke-RehearsalEngine $root $config $directory -ApproveProvisioning
        if ($state.Status -ne 'AwaitingInput' -or $calls.Count -ne 2) { throw 'Deployment ran without a supplied password.' }
    }
    Check 'Full simulated sequence resumes without duplicate actions and separately approves cleanup' {
        $directory=New-TestRun
        $state=Advance-To $directory 'cleanup'
        if ($state.Status -ne 'AwaitingApproval' -or 'cleanup' -in $calls) { throw 'Cleanup was implicitly approved with provisioning.' }
        $state=Invoke-RehearsalEngine $root $config $directory -ApproveCleanup
        if ($state.Status -ne 'CompletedWithInstructorEvidence') { throw 'Expected completed mixed-evidence status.' }
        $expected=@(Get-RehearsalPlan | Where-Object Kind -NE 'Checkpoint' | ForEach-Object Id)
        if (($calls -join ',') -cne ($expected -join ',')) { throw 'Actions were omitted, repeated or out of order.' }
        $null=Invoke-RehearsalEngine $root $config $directory
        if ($calls.Count -ne $expected.Count) { throw 'Completed run executed actions again.' }
        if ((Get-Content (Join-Path $directory 'state.json') -Raw) -match 'PRIVATE-SENTINEL|AdminPassword') { throw 'Credentials appeared in state.' }
        $script:completedRun=$directory
    }
    Check 'Failed validation stops downstream work and retries only on explicit request' {
        $directory=New-TestRun
        $script:failAt='test-workloads'
        $state=Advance-To $directory 'test-workloads'
        if ($state.Status -ne 'Failed' -or 'test-network' -in $calls -or 'cleanup' -in $calls) { throw 'Failure did not stop the run.' }
        $before=$calls.Count
        $state=Invoke-RehearsalEngine $root $config $directory
        if ($state.Status -ne 'NeedsReview' -or $calls.Count -ne $before) { throw 'Failed stage was retried automatically.' }
        $script:failAt=''
        $state=Invoke-RehearsalEngine $root $config $directory -RetryFailed
        if ($state.Status -ne 'AwaitingInput' -or @($calls | Where-Object { $_ -eq 'test-workloads' }).Count -ne 2 -or @($calls | Where-Object { $_ -eq 'deploy-source' }).Count -ne 1) { throw 'Retry did not preserve earlier progress.' }
        foreach ($file in @('state.json','report.html')) {
            if ((Get-Content (Join-Path $directory $file) -Raw) -match 'PRIVATE-SENTINEL') { throw 'Sensitive exception was persisted.' }
        }
    }
    Check 'Failed or interrupted provisioning is never replayed even with RetryFailed' {
        foreach ($status in @('Failed','Running')) {
            $directory=New-TestRun
            $state=Advance-To $directory 'source-review'
            $state.Results[3].Status=$status
            Save-RehearsalState $state $directory
            $before=$calls.Count
            $state=Invoke-RehearsalEngine $root $config $directory -ApproveProvisioning -RetryFailed -AdminPassword $password
            if ($state.Status -ne 'NeedsReview' -or $calls.Count -ne $before) { throw 'Uncertain provisioning was replayed.' }
        }
    }
    Check 'Configuration drift, corrupt state, out-of-order completion and evidence tampering stop resume' {
        $directory=New-TestRun
        $state=Advance-To $directory 'discovery'
        $config.Location='westus2'
        try { MustThrow { Invoke-RehearsalEngine $root $config $directory } } finally { $config.Location='eastus' }
        $state.Results[-1].Status='Passed'; Save-RehearsalState $state $directory
        MustThrow { Invoke-RehearsalEngine $root $config $directory }
        $state.Results[-1].Status='Pending'; Save-RehearsalState $state $directory
        Add-Content -LiteralPath (Join-Path $directory 'artifacts/environment-review.json') -Value 'tampered'
        MustThrow { Invoke-RehearsalEngine $root $config $directory }
        [IO.File]::WriteAllText((Join-Path $directory 'state.json'),'{broken')
        MustThrow { Invoke-RehearsalEngine $root $config $directory }
    }
    Check 'Exclusive lock prevents two runners using the same progress record' {
        $directory=New-TestRun
        $null=New-Item -ItemType Directory -Path $directory
        $lock=[IO.File]::Open((Join-Path $directory '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { MustThrow { Invoke-RehearsalEngine $root $config $directory } }
        finally { $lock.Dispose() }
        if ($calls.Count) { throw 'An action ran while the directory was locked.' }
    }
    Check 'Changed source files invalidate resume and recorded VM maps cannot diverge from evidence' {
        $directory=New-TestRun
        $fakeRoot=Join-Path $suite 'fingerprint-root'
        foreach ($folder in @('scripts','tests','docs')) { $null=New-Item -ItemType Directory -Path (Join-Path $fakeRoot $folder) -Force }
        $code=Join-Path $fakeRoot 'scripts/sample.ps1'
        [IO.File]::WriteAllText($code,'# original')
        $null=Invoke-RehearsalEngine $fakeRoot $config $directory
        [IO.File]::WriteAllText($code,'# changed')
        MustThrow { Invoke-RehearsalEngine $fakeRoot $config $directory }
        $state=Read-RehearsalJson (Join-Path $script:completedRun 'state.json')
        $mapping=@($state.Results | Where-Object Id -EQ 'test-migration')[0]
        $original=$mapping.Evidence.VMNames.SqlVM
        $mapping.Evidence.VMNames.SqlVM='unrecorded-machine'
        Save-RehearsalState $state $script:completedRun
        MustThrow { Invoke-RehearsalEngine $root $config $script:completedRun }
        $mapping.Evidence.VMNames.SqlVM=$original
        Save-RehearsalState $state $script:completedRun
    }
    Check 'Reports HTML-encode arbitrary messages' {
        $directory=New-TestRun
        $state=Invoke-RehearsalEngine $root $config $directory
        $state.Results[0].Message='<script>alert(1)</script>'
        Save-RehearsalState $state $directory
        $html=Get-Content (Join-Path $directory 'report.html') -Raw
        if ($html -match '<script>' -or $html -notmatch '&lt;script&gt;') { throw 'Report permitted HTML injection.' }
    }

    # Test the real Azure adapters with mocked command responses.
    . "$root/scripts/rehearsal/actions.ps1"
    function Assert-LabResourceGroup { param($Name) [pscustomobject]@{ResourceGroupName=$Name} }
    $map=@{WindowsWebVM='test-web';SqlVM='test-sql';LinuxWebVM='test-linux-web';LinuxAppVM='test-linux-app'}
    $script:networkMode='good'; $script:remoteMode='good'; $script:remoteScript=''; $script:remoteCalls=0
    function Get-AzVM {
        param($ResourceGroupName,$Name,$ErrorAction)
        [pscustomobject]@{Name=$Name;Id="/subscriptions/$($config.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$Name";
            NetworkProfile=[pscustomobject]@{NetworkInterfaces=@([pscustomobject]@{Id="/subscriptions/$($config.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$Name-nic"})}}
    }
    function Get-AzNetworkInterface {
        param($ResourceGroupName,$Name,$ErrorAction)
        $network=if ($script:networkMode -eq 'wrong-network') { 'target' } else { 'test' }
        $public=if ($script:networkMode -eq 'public-ip') { [pscustomobject]@{Id='/public-ip'} } else { $null }
        [pscustomobject]@{Id="/subscriptions/$($config.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$Name";
            IpConfigurations=@([pscustomobject]@{PrivateIpAddress='10.2.0.4';PublicIpAddress=$public;Subnet=[pscustomobject]@{Id="/subscriptions/$($config.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$ResourceGroupName-$network-vnet/subnets/default"}})}
    }
    function Invoke-AzVMRunCommand {
        param($ResourceGroupName,$VMName,$CommandId,$ScriptString,$ErrorAction)
        $script:remoteScript=$ScriptString; $script:remoteCalls++
        $message=if ($script:remoteMode -eq 'good') { "LAB_NETWORK_VALIDATED`nSQL_DATA_MATCHED`nSQL_BASELINE_VALIDATED" } else { 'NOT_LAB_NETWORK_VALIDATED' }
        [pscustomobject]@{Value=@([pscustomobject]@{Code='ComponentStatus/StdOut/succeeded';Message=$message},[pscustomobject]@{Code='ComponentStatus/StdErr/succeeded';Message=''})}
    }
    Check 'Network adapter refuses wrong subnets/public IPs and failed remote probes' {
        Test-RehearsalNetwork $config $map test
        if ($remoteScript -notmatch 'Port 1433' -or $remoteScript -notmatch 'Port 80' -or $remoteScript -notmatch 'Port 3000') { throw 'Missing cross-VM port probes.' }
        foreach ($bad in @('wrong-network','public-ip')) {
            $script:networkMode=$bad; $before=$remoteCalls
            MustThrow { Test-RehearsalNetwork $config $map test }
            if ($remoteCalls -ne $before) { throw 'Probe ran before placement check passed.' }
        }
        $script:networkMode='good'; $script:remoteMode='failed'
        MustThrow { Test-RehearsalNetwork $config $map test }
        $script:remoteMode='good'
    }
    Check 'SQL adapter uses separate source baselines, verifies helper hash and requires both success markers' {
        $state=Read-RehearsalJson (Join-Path $script:completedRun 'state.json')
        Test-RehearsalSql $root $config $state $script:completedRun $map test
        $testHash=(Get-RehearsalEvidence $state 'pretest-baseline').BaselineSha256
        if ($remoteScript -notmatch 'source-pretest.baseline.json' -or -not $remoteScript.Contains($testHash) -or $remoteScript -notmatch 'SQL helper does not match') { throw 'Test baseline/hash guard missing.' }
        Test-RehearsalSql $root $config $state $script:completedRun $map final
        if ($remoteScript -notmatch 'source-precutover.baseline.json') { throw 'Final check used wrong baseline.' }
        $script:remoteMode='failed'
        MustThrow { Test-RehearsalSql $root $config $state $script:completedRun $map test }
        $script:remoteMode='good'
        $baseline=Join-Path $script:completedRun (Get-RehearsalEvidence $state 'pretest-baseline').BaselinePath
        Add-Content -LiteralPath $baseline -Value 'tampered'
        MustThrow { Test-RehearsalSql $root $config $state $script:completedRun $map test }
    }
    Check 'Cleanup adapter preserves preview, handles partial deletion and never accepts failed verification' {
        $fakeRoot=Join-Path $suite 'cleanup-root'
        $null=New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'scripts') -Force
        $fixture=@'
[CmdletBinding(SupportsShouldProcess)]
param($SubscriptionId,$ResourceGroupName)
$global:cesRehearsalCleanupCalls++
$global:cesRehearsalCleanupPreview=[bool]$WhatIfPreference
$global:cesRehearsalCleanupNames=@($ResourceGroupName)
if (-not $WhatIfPreference -and -not $global:cesRehearsalRetainGroup) { $global:cesRehearsalRemaining=@() }
'@
        [IO.File]::WriteAllText((Join-Path $fakeRoot 'scripts/cleanup-lab.ps1'),$fixture)
        function Get-LabResourceGroup {
            param($Name,[switch]$AllowMissing)
            if ($global:cesRehearsalLookupFails) { throw 'Simulated authorization failure, not absence.' }
            if ($Name -in $global:cesRehearsalRemaining) { [pscustomobject]@{ResourceGroupName=$Name} }
        }
        $global:cesRehearsalCleanupCalls=0; $global:cesRehearsalCleanupPreview=$false; $global:cesRehearsalCleanupNames=@()
        $global:cesRehearsalRetainGroup=$false; $global:cesRehearsalLookupFails=$false
        $global:cesRehearsalRemaining=@($config.SourceResourceGroup,$config.TargetResourceGroup)
        Invoke-RehearsalCleanup $fakeRoot $config -Preview
        if (-not $global:cesRehearsalCleanupPreview -or $global:cesRehearsalRemaining.Count -ne 2) { throw 'Preview changed resources.' }
        $global:cesRehearsalRemaining=@($config.TargetResourceGroup)
        Invoke-RehearsalCleanup $fakeRoot $config
        if ($global:cesRehearsalCleanupPreview -or ($global:cesRehearsalCleanupNames -join ',') -ne $config.TargetResourceGroup -or $global:cesRehearsalRemaining.Count) { throw 'Explicit partial-deletion retry failed.' }
        $before=$global:cesRehearsalCleanupCalls
        $global:cesRehearsalLookupFails=$true
        MustThrow { Invoke-RehearsalCleanup $fakeRoot $config }
        if ($global:cesRehearsalCleanupCalls -ne $before) { throw 'Deletion followed an unverified lookup.' }
        $global:cesRehearsalLookupFails=$false; $global:cesRehearsalRetainGroup=$true; $global:cesRehearsalRemaining=@($config.SourceResourceGroup)
        MustThrow { Invoke-RehearsalCleanup $fakeRoot $config }
    }
} finally { Remove-Item -LiteralPath $suite -Recurse -Force }
if ($failures.Count) { $failures | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }
Write-Host "$count rehearsal checks passed using simulated Azure adapters. No Azure deployment or migration was performed."
