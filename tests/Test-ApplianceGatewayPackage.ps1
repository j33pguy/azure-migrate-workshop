<#
.SYNOPSIS
Verify the pinned Microsoft appliance ZIP and perform Gateway extraction only.
.DESCRIPTION
Windows integration check: downloads or reuses the official ZIP, verifies its
SHA256, and extracts only the appliance script and Gateway self-extractor. The
script is an inert sibling required by the helper and is never run. Production
signature checks and extraction run for real; appliance setup and registration
never run. Failed attempts retain their files because extraction may still run.
.PARAMETER PackagePath
Optional existing AzureMigrateInstaller.zip. The caller's ZIP is never removed.
#>
[CmdletBinding()]
param([string]$PackagePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'This package integration check requires 64-bit Windows PowerShell or PowerShell on Windows.'
}

$packageUrl = 'https://download.microsoft.com/download/f2fae98a-9ff0-45e2-a0cb-e009e1ad4df6/AzureMigrateInstaller.zip'
# Verified against Microsoft's appliance deployment documentation and ZIP bytes.
$expectedSha256 = 'D7CC59E5C16A34155C53CDDFF9710D9F07EC1CE51EA802E9354641A602484C7C'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CES Gateway package ' + [guid]::NewGuid().ToString('N'))
$rootCreated = $false
$completed = $false
$script:gatewayIntegrationLaunchCount = 0
$script:gatewayIntegrationPackageDirectory = $null
$previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol

# Guard the only native process launch allowed by this integration check. This
# forwards quiet extraction to the real cmdlet and rejects installation commands.
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$WorkingDirectory, [string]$ArgumentList, [switch]$PassThru)
    $expectedWrapper = Join-Path $script:gatewayIntegrationPackageDirectory 'MicrosoftAzureGatewayService.exe'
    if ($FilePath -ne $expectedWrapper -or $WorkingDirectory -ne $script:gatewayIntegrationPackageDirectory -or -not $PassThru) {
        throw 'The package check permits only the verified Gateway extractor in its isolated package directory.'
    }
    if ($ArgumentList -cnotmatch '^/q /x:"([^"]+)"$') {
        throw 'The package check permits /q /x extraction only; appliance installation is prohibited.'
    }
    $stage = $Matches[1]
    if ((Split-Path -Path $stage -Parent) -ne $script:gatewayIntegrationPackageDirectory -or
        (Split-Path -Path $stage -Leaf) -notmatch '^GatewayPayload-[0-9a-f]{32}$') {
        throw 'The package check requires extraction into a fresh helper-owned staging directory.'
    }
    $script:gatewayIntegrationLaunchCount++
    Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -WorkingDirectory $WorkingDirectory `
        -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop
    $rootCreated = $true
    Write-Host 'Gateway integration check: extraction only; no appliance installation or registration.'
    if ($PackagePath) {
        $packageItem = Get-Item -LiteralPath $PackagePath -ErrorAction Stop
        if ($packageItem.PSIsContainer -or $packageItem.PSProvider.Name -ne 'FileSystem') {
            throw 'PackagePath must identify an existing ZIP file on disk.'
        }
        $zipPath = $packageItem.FullName
    } else {
        $zipPath = Join-Path $testRoot 'AzureMigrateInstaller.zip'
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host 'Downloading the pinned Microsoft appliance ZIP (300-second download limit).'
        $previousProgressPreference = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $packageUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        } finally { $ProgressPreference = $previousProgressPreference }
    }
    $actualSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualSha256 -ne $expectedSha256) {
        throw "Appliance ZIP SHA256 mismatch. Expected $expectedSha256; received $actualSha256. Reverify Microsoft's published package before changing the pin."
    }
    Write-Host "Verified appliance ZIP SHA256: $actualSha256"

    $packageDirectory = Join-Path $testRoot 'Extracted Gateway package'
    $script:gatewayIntegrationPackageDirectory = (New-Item -ItemType Directory -Path $packageDirectory -ErrorAction Stop).FullName
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($name in @('AzureMigrateInstaller.ps1', 'MicrosoftAzureGatewayService.exe')) {
            # Select exact root entries and construct destination names ourselves;
            # never expand the ZIP's other installers or arbitrary entry paths.
            $entries = @($archive.Entries | Where-Object { $_.FullName -ceq $name })
            if ($entries.Count -ne 1) { throw "The verified package must contain exactly one root entry named $name." }
            $destination = Join-Path $script:gatewayIntegrationPackageDirectory $name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $destination, $false)
        }
    } finally { $archive.Dispose() }

    $helperPath = Join-Path $PSScriptRoot '../scripts/Expand-LabApplianceGateway.ps1'
    $tokens = $null
    $parseErrors = $null
    $helperAst = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Cannot test a Gateway helper with PowerShell parse errors.' }
    foreach ($functionName in @('Assert-LabGatewaySignature', 'Expand-LabGatewayPayload')) {
        $definitions = @($helperAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true))
        if ($definitions.Count -ne 1) { throw "Expected one $functionName function in the Gateway helper." }
        # Load only production signature validation and extraction. Top-level VM
        # checks and AzureMigrateInstaller.ps1 are never executed by this test.
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $result = @(Expand-LabGatewayPayload -Directory $script:gatewayIntegrationPackageDirectory -TimeoutSeconds 600)
    if ($result.Count -ne 1 -or $result[0].Status -ne 'PayloadReady' -or
        $result[0].InstallerDirectory -ne $script:gatewayIntegrationPackageDirectory -or
        $result[0].GatewaySetup -ne (Join-Path $script:gatewayIntegrationPackageDirectory 'GATEWAYSETUPINSTALLER.EXE')) {
        throw 'The real Microsoft Gateway extraction did not return the expected PayloadReady result.'
    }
    foreach ($name in @(
        'GATEWAYSETUPINSTALLER.EXE', 'MICROSOFTAZUREGATEWAYSERVICE.MSI',
        'VCREDIST_X64_2012.EXE', 'VCREDIST_X64_2013.EXE', 'VCREDIST_X64_V14.EXE'
    )) {
        $payloadPath = Join-Path $script:gatewayIntegrationPackageDirectory $name
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf) -or (Get-Item -LiteralPath $payloadPath).Length -le 0) {
            throw "The real extraction did not prepare a nonempty $name."
        }
        Write-Host "Prepared payload from the verified Microsoft wrapper: $name; SHA256 $((Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash)"
    }
    if ($script:gatewayIntegrationLaunchCount -ne 1) { throw 'Expected exactly one Gateway extraction process.' }
    if (@(Get-ChildItem -LiteralPath $script:gatewayIntegrationPackageDirectory -Directory -Filter 'GatewayPayload-*').Count -ne 0) {
        throw 'The successful extraction did not remove its staging directory.'
    }
    $completed = $true
} catch {
    if ($rootCreated) {
        Write-Warning "Package check failed. Retained files: $testRoot. If extraction started, its process may still be running; inspect it before retrying or removing files."
    }
    throw
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    if ($completed -and $rootCreated) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
}
Write-Host 'PASS real Microsoft Gateway package: verified wrapper extraction completed. No appliance installer, service installation, or Azure operation was run.'
