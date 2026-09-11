# Offline Gateway payload preparation tests. Only the two helper functions are
# loaded; VM guards, appliance setup, executable downloads, and services never run.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$gatewayChecks = 0
$gatewayPayloadNames = @(
    'GATEWAYSETUPINSTALLER.EXE', 'MICROSOFTAZUREGATEWAYSERVICE.MSI',
    'VCREDIST_X64_2012.EXE', 'VCREDIST_X64_2013.EXE', 'VCREDIST_X64_V14.EXE'
)
$tokens = $null
$parseErrors = $null
$helperPath = Join-Path $PSScriptRoot '../scripts/Expand-LabApplianceGateway.ps1'
$helperAst = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Cannot test a Gateway helper with PowerShell parse errors.' }
foreach ($functionName in @('Assert-LabGatewaySignature', 'Expand-LabGatewayPayload')) {
    $definitions = @($helperAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $functionName function in the Gateway helper." }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

function Assert-GatewayFixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Expect-GatewayFailure {
    param([scriptblock]$Action, [string]$MessagePattern)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    if ($null -eq $failure) { throw 'Gateway preparation accepted a rejected fixture.' }
    if ($failure.Exception.Message -notmatch $MessagePattern) {
        throw "Wrong failure. Expected '$MessagePattern'; received '$($failure.Exception.Message)'."
    }
    $failure.Exception.Message
}
function New-GatewaySignature {
    param([string]$Status = 'Valid', [string]$Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US')
    [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
}

# These script-local functions shadow process and signature cmdlets. Unexpected
# launches fail the test instead of falling through to a real executable.
function Get-AuthenticodeSignature {
    [CmdletBinding()]
    param([string]$LiteralPath)
    Assert-GatewayFixture (Test-Path -LiteralPath $LiteralPath -PathType Leaf) 'Signature validation used a missing file.'
    $script:signaturePaths += $LiteralPath
    if ($script:signatureOverride -and $LiteralPath -like $script:signatureOverridePattern) {
        return $script:signatureOverride
    }
    New-GatewaySignature
}
function Get-Process {
    [CmdletBinding()]
    param([string[]]$Name)
    Assert-GatewayFixture ($Name.Count -eq 2 -and $Name -contains 'MicrosoftAzureGatewayService' -and $Name -contains 'GATEWAYSETUPINSTALLER') 'Unexpected process inspection.'
    if ($script:activeGateway) { [pscustomobject]@{ Id = 4567; ProcessName = 'GATEWAYSETUPINSTALLER' } }
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$WorkingDirectory, [string]$ArgumentList, [switch]$PassThru)
    Assert-GatewayFixture ($FilePath -eq (Join-Path $script:fixtureDirectory 'MicrosoftAzureGatewayService.exe')) 'Only the Gateway extractor may be launched.'
    Assert-GatewayFixture ($WorkingDirectory -eq $script:fixtureDirectory -and $PassThru) 'Extraction must retain its process and use the package working directory.'
    Assert-GatewayFixture ($ArgumentList -cmatch '^/q /x:"([^"]+)"$') 'Only quiet extraction is allowed; never installation or AzureMigrateInstaller.ps1.'
    $script:lastStage = $Matches[1]
    Assert-GatewayFixture ((Split-Path -Path $script:lastStage -Parent) -eq $script:fixtureDirectory) 'Extraction must use a stage inside the package directory.'
    Assert-GatewayFixture ((Split-Path -Path $script:lastStage -Leaf) -match '^GatewayPayload-[0-9a-f]{32}$') 'Extraction did not use an isolated stage.'
    Assert-GatewayFixture ((@(Get-ChildItem -LiteralPath $script:lastStage -Force)).Count -eq 0) 'Extraction stage was not fresh.'
    $script:launches += [pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList; Stage = $script:lastStage }
    foreach ($name in $script:extractedNames) {
        $extractedPath = Join-Path $script:lastStage $name
        if ($name -eq $script:emptyExtractedName) {
            [IO.File]::WriteAllBytes($extractedPath, [byte[]]@())
        } else {
            Set-Content -LiteralPath $extractedPath -Value ('fresh-' + $name) -Encoding UTF8
        }
    }
    $process = [pscustomobject]@{ Handle = [IntPtr]123; Id = 7890; ExitCode = $script:extractorExitCode }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param([int]$Milliseconds)
        $script:waitCalls++
        if ($script:extractorTimeout) {
            Start-Sleep -Milliseconds $Milliseconds
            return $false
        }
        return $true
    }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:processDisposed = $true }
    $process
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CES Gateway tests ' + [guid]::NewGuid().ToString('N'))
$rootCreated = $false
function Test-GatewayCase {
    param([string]$Name, [scriptblock]$Action)
    $script:fixtureDirectory = Join-Path $testRoot ('Extracted appliance ' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:fixtureDirectory
    Set-Content -LiteralPath (Join-Path $script:fixtureDirectory 'AzureMigrateInstaller.ps1') -Value 'throw "The appliance installer must never execute in tests."'
    Set-Content -LiteralPath (Join-Path $script:fixtureDirectory 'MicrosoftAzureGatewayService.exe') -Value 'fixture wrapper; not executable'
    $script:signaturePaths = @()
    $script:signatureOverride = $null
    $script:signatureOverridePattern = '*'
    $script:activeGateway = $false
    $script:extractedNames = $gatewayPayloadNames
    $script:emptyExtractedName = $null
    $script:extractorExitCode = 0
    $script:extractorTimeout = $false
    $script:processDisposed = $false
    $script:waitCalls = 0
    $script:lastStage = $null
    $script:launches = @()
    & $Action
    $script:gatewayChecks++
    Write-Host "PASS appliance Gateway: $Name"
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $rootCreated = $true
    Test-GatewayCase 'missing package wrapper fails before extraction' {
        Remove-Item -LiteralPath (Join-Path $fixtureDirectory 'MicrosoftAzureGatewayService.exe')
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'Missing MicrosoftAzureGatewayService\.exe'
        Assert-GatewayFixture ($launches.Count -eq 0) 'A missing wrapper caused a process launch.'
    }
    Test-GatewayCase 'missing appliance script fails before extraction' {
        Remove-Item -LiteralPath (Join-Path $fixtureDirectory 'AzureMigrateInstaller.ps1')
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'Missing AzureMigrateInstaller\.ps1'
        Assert-GatewayFixture ($launches.Count -eq 0) 'An incomplete package caused a process launch.'
    }
    Test-GatewayCase 'a file cannot be used as the package directory' {
        $file = Join-Path $fixtureDirectory 'AzureMigrateInstaller.ps1'
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $file } 'extracted package folder'
        Assert-GatewayFixture ($launches.Count -eq 0) 'An invalid directory caused a process launch.'
    }
    Test-GatewayCase 'unsigned or tampered wrapper fails before extraction' {
        foreach ($status in @('NotSigned', 'HashMismatch')) {
            $script:signatureOverride = New-GatewaySignature -Status $status
            $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'Microsoft signature validation failed'
        }
        Assert-GatewayFixture ($launches.Count -eq 0) 'An unverified wrapper was launched.'
    }
    Test-GatewayCase 'missing certificate and spoofed publisher are rejected' {
        foreach ($signature in @(
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $null },
            (New-GatewaySignature -Subject 'CN=Microsoft Corporation, O=Other Publisher, C=US'),
            (New-GatewaySignature -Subject 'CN=Other Publisher, O=Microsoft Corporation Spoof, C=US')
        )) {
            $script:signatureOverride = $signature
            $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'Microsoft signature validation failed'
        }
        Assert-GatewayFixture ($launches.Count -eq 0) 'An untrusted publisher caused a process launch.'
    }
    Test-GatewayCase 'active Gateway process prevents a conflicting extraction' {
        $script:activeGateway = $true
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'process is still running'
        Assert-GatewayFixture ($launches.Count -eq 0) 'Concurrent Gateway extraction was started.'
    }
    Test-GatewayCase 'nonzero extraction exit reports failure and preserves evidence' {
        $script:extractorExitCode = 1603
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'exit code 1603'
        Assert-GatewayFixture ($processDisposed -and (Test-Path -LiteralPath $lastStage -PathType Container)) 'Failed extraction lost its stage or process handle.'
        Assert-GatewayFixture (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE'))) 'A failed extraction published a payload.'
    }
    Test-GatewayCase 'missing fresh EXE cannot be masked by a stale destination' {
        $script:extractedNames = @('MICROSOFTAZUREGATEWAYSERVICE.MSI')
        $stale = Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE'
        Set-Content -LiteralPath $stale -Value 'stale setup'
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'did not produce GATEWAYSETUPINSTALLER\.EXE'
        Assert-GatewayFixture ((Get-Content -LiteralPath $stale -Raw).Trim() -eq 'stale setup') 'Incomplete extraction modified the old setup payload.'
    }
    Test-GatewayCase 'missing fresh MSI prevents publishing the extracted EXE' {
        $script:extractedNames = @('GATEWAYSETUPINSTALLER.EXE')
        $stale = Join-Path $fixtureDirectory 'MICROSOFTAZUREGATEWAYSERVICE.MSI'
        Set-Content -LiteralPath $stale -Value 'stale MSI'
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'did not produce MICROSOFTAZUREGATEWAYSERVICE\.MSI'
        Assert-GatewayFixture (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE'))) 'Partial payload was published before all required files were validated.'
    }
    Test-GatewayCase 'missing runtime prerequisites prevent publishing an incomplete payload' {
        foreach ($runtime in @('VCREDIST_X64_2012.EXE', 'VCREDIST_X64_2013.EXE', 'VCREDIST_X64_V14.EXE')) {
            $script:extractedNames = @($gatewayPayloadNames | Where-Object { $_ -ne $runtime })
            $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } ('did not produce ' + [regex]::Escape($runtime))
            Assert-GatewayFixture (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE'))) 'A payload missing a runtime prerequisite was published.'
        }
    }
    Test-GatewayCase 'empty extracted payload prevents publishing any file' {
        $script:emptyExtractedName = 'MICROSOFTAZUREGATEWAYSERVICE.MSI'
        $null = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory } 'empty.*MICROSOFTAZUREGATEWAYSERVICE\.MSI|MICROSOFTAZUREGATEWAYSERVICE\.MSI.*empty'
        Assert-GatewayFixture (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE'))) 'An empty payload was published.'
        Assert-GatewayFixture (Test-Path -LiteralPath $lastStage -PathType Container) 'Failed payload verification lost the extraction evidence.'
    }
    Test-GatewayCase 'success copies fresh payloads from a signed wrapper and removes only its own stage' {
        $unrelatedStage = Join-Path $fixtureDirectory 'GatewayPayload-previous-attempt'
        $null = New-Item -ItemType Directory -Path $unrelatedStage
        foreach ($name in $extractedNames) { Set-Content -LiteralPath (Join-Path $fixtureDirectory $name) -Value 'stale destination' }
        $result = @(Expand-LabGatewayPayload -Directory $fixtureDirectory)
        Assert-GatewayFixture ($result.Count -eq 1 -and $result[0].Status -eq 'PayloadReady') 'Success did not return exactly one PayloadReady result.'
        Assert-GatewayFixture ($result[0].InstallerDirectory -eq $fixtureDirectory -and $result[0].GatewaySetup -eq (Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE')) 'Success returned an incorrect package path.'
        foreach ($name in $extractedNames) {
            $destination = Join-Path $fixtureDirectory $name
            Assert-GatewayFixture ((Get-Content -LiteralPath $destination -Raw).Trim() -eq ('fresh-' + $name)) 'A stale destination was accepted as fresh payload.'
        }
        Assert-GatewayFixture ($signaturePaths.Count -eq 1 -and $signaturePaths[0] -eq (Join-Path $fixtureDirectory 'MicrosoftAzureGatewayService.exe')) 'Signature validation must verify the outer Microsoft wrapper; the real inner payload is not independently signed.'
        Assert-GatewayFixture ($launches.Count -eq 1 -and $waitCalls -eq 1 -and $processDisposed) 'Success did not await and dispose exactly one extraction process.'
        Assert-GatewayFixture (-not (Test-Path -LiteralPath $lastStage)) 'Successful extraction left its staging directory behind.'
        Assert-GatewayFixture (Test-Path -LiteralPath $unrelatedStage -PathType Container) 'Cleanup removed evidence from a previous attempt.'
    }
    Test-GatewayCase 'timeout preserves staging and warns that the process may still run' {
        $script:extractorTimeout = $true
        $message = Expect-GatewayFailure { Expand-LabGatewayPayload -Directory $fixtureDirectory -TimeoutSeconds 1 } 'exceeded 1 seconds.*Process 7890 may still be running'
        Assert-GatewayFixture ($message.Contains($lastStage)) 'Timeout did not identify its preserved extraction stage.'
        Assert-GatewayFixture ($launches.Count -eq 1 -and $waitCalls -ge 1 -and $processDisposed) 'Timeout did not dispose its process observation handle.'
        Assert-GatewayFixture (Test-Path -LiteralPath $lastStage -PathType Container) 'Timeout deleted files that the extractor could still be using.'
        Assert-GatewayFixture (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'GATEWAYSETUPINSTALLER.EXE'))) 'Timeout published a payload before extraction completed.'
    }
} finally {
    # This root contains only simulated processes and test-owned files, including
    # the timeout fixture's stage. No real process can still be using them.
    if ($rootCreated) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
}
Write-Host "Appliance Gateway checks passed: $gatewayChecks. No installer, executable, or Azure operation was run."
