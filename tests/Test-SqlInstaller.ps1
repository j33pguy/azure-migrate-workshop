# Local installer validation tests. -VerifyDownload also reads Microsoft's public
# downloads on Windows, verifies their metadata/signature, and never runs the EXE.
[CmdletBinding()]
param([switch]$VerifyDownload)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sqlChecks = 0
$tokens = $null
$parseErrors = $null
$hostPath = Join-Path $PSScriptRoot '../scripts/host/configure-host.ps1'
$hostAst = [System.Management.Automation.Language.Parser]::ParseFile($hostPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Cannot test a host payload with PowerShell parse errors.' }
$validatorDefinitions = @($hostAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LabSqlInstaller'
}, $true))
if ($validatorDefinitions.Count -ne 1) { throw 'Expected one Assert-LabSqlInstaller function in the host payload.' }
# Define only the pure validator; do not run host provisioning or its SQL block.
. ([scriptblock]::Create($validatorDefinitions[0].Extent.Text))

function Test-SqlInstallerCase {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:sqlChecks++
    Write-Host "PASS SQL installer: $Name"
}
function Expect-SqlInstallerFailure {
    param([scriptblock]$Action)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Installer validation accepted a rejected fixture.' }
}
function Get-SqlSourceDownloadUrl {
    param([string]$VariableName)
    $assignments = @($hostAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq $VariableName
    }, $true))
    if ($assignments.Count -ne 1 -or
        $assignments[0].Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $assignments[0].Right.Expression -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
        throw "Expected one literal $VariableName source URL."
    }
    $uri = [uri]$assignments[0].Right.Expression.Value
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com') { throw "$VariableName must be an HTTPS download.microsoft.com URL." }
    $uri.AbsoluteUri
}
function New-SqlVersionFixture {
    param([version]$Version = '16.2607.0.1', [string]$Filename = 'SQL2022-SSEI-Expr.exe')
    [pscustomobject]@{
        FileMajorPart = $Version.Major; FileMinorPart = $Version.Minor
        FileBuildPart = $Version.Build; FilePrivatePart = $Version.Revision
        OriginalFilename = $Filename
    }
}
function New-SqlSignatureFixture {
    param([string]$Status = 'Valid', [string]$Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US')
    [pscustomobject]@{Status = $Status; SignerCertificate = [pscustomobject]@{Subject = $Subject}}
}
function New-SqlManifestFixture {
    param([version]$Version = '16.2607.0.1')
    @"
<Manifest xmlns="http://schemas.datacontract.org/2004/07/InstallerEngine" xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
  <MinInstallerFreeSpaceInMb>0</MinInstallerFreeSpaceInMb>
  <SupportedEngineVersion xmlns:a="http://schemas.datacontract.org/2004/07/System">
    <a:_Build>$($Version.Build)</a:_Build>
    <a:_Major>$($Version.Major)</a:_Major>
    <a:_Minor>$($Version.Minor)</a:_Minor>
    <a:_Revision>$($Version.Revision)</a:_Revision>
  </SupportedEngineVersion>
</Manifest>
"@
}
$validVersion = New-SqlVersionFixture
$validSignature = New-SqlSignatureFixture
$validManifest = New-SqlManifestFixture

Test-SqlInstallerCase 'current supported SQL 2022 installer returns one version result' {
    $result = @(Assert-LabSqlInstaller -VersionInfo $validVersion -Signature $validSignature -ManifestText $validManifest)
    if ($result.Count -ne 1 -or $result[0].Version -ne '16.2607.0.1' -or $result[0].MinimumVersion -ne '16.2607.0.1') {
        throw 'Supported installer did not return its exact detected and minimum versions.'
    }
}
Test-SqlInstallerCase 'engineer-reported expired bootstrapper is rejected' {
    Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo (New-SqlVersionFixture '16.2211.5693.3') -Signature $validSignature -ManifestText $validManifest }
}
Test-SqlInstallerCase 'newer SQL 2022 installer remains supported' {
    $result = Assert-LabSqlInstaller -VersionInfo (New-SqlVersionFixture '16.2608.0.2') -Signature $validSignature -ManifestText $validManifest
    if ($result.Version -ne '16.2608.0.2') { throw 'A newer installer in the same SQL product generation was lost.' }
}
Test-SqlInstallerCase 'wrong SQL product generation and filename cannot silently upgrade the lab' {
    foreach ($fixture in @(
        (New-SqlVersionFixture '17.2607.0.1'),
        (New-SqlVersionFixture '16.2607.0.1' 'SQL2025-SSEI-Expr.exe'),
        (New-SqlVersionFixture '16.2607.0.1' 'SQL2022-SSEI-Dev.exe')
    )) {
        Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $fixture -Signature $validSignature -ManifestText $validManifest }
    }
}
Test-SqlInstallerCase 'invalid and missing signatures are rejected' {
    foreach ($signature in @((New-SqlSignatureFixture 'NotSigned'), (New-SqlSignatureFixture 'HashMismatch'), $null)) {
        Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature $signature -ManifestText $validManifest }
    }
    Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature ([pscustomobject]@{Status = 'Valid'; SignerCertificate = $null}) -ManifestText $validManifest }
}
Test-SqlInstallerCase 'a valid signature must identify the Microsoft organization' {
    foreach ($subject in @(
        'CN=Other Publisher, O=Other Publisher, C=US',
        'CN=Microsoft Corporation, O=Other Publisher, C=US',
        'CN=Other Publisher, O=Microsoft Corporation Spoof, C=US'
    )) {
        Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature (New-SqlSignatureFixture 'Valid' $subject) -ManifestText $validManifest }
    }
}
Test-SqlInstallerCase 'empty malformed and unrelated manifests cannot authorize an installer' {
    foreach ($manifest in @('', '<Manifest>', '<html>Download unavailable</html>', ($validManifest.Replace('http://schemas.datacontract.org/2004/07/InstallerEngine', 'https://example.invalid/manifest')))) {
        Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature $validSignature -ManifestText $manifest }
    }
}
Test-SqlInstallerCase 'DTD and entity declarations are prohibited' {
    $manifest = '<!DOCTYPE Manifest [<!ENTITY fixture "16">]>' + $validManifest.Replace('<a:_Major>16</a:_Major>', '<a:_Major>&fixture;</a:_Major>')
    Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature $validSignature -ManifestText $manifest }
}
Test-SqlInstallerCase 'missing and nonnumeric minimum versions are rejected' {
    foreach ($manifest in @(
        ($validManifest.Replace('<a:_Revision>1</a:_Revision>', '')),
        ($validManifest.Replace('<a:_Minor>2607</a:_Minor>', '<a:_Minor>unknown</a:_Minor>'))
    )) {
        Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature $validSignature -ManifestText $manifest }
    }
}
Test-SqlInstallerCase 'a manifest for a future SQL generation cannot change the lab product' {
    Expect-SqlInstallerFailure { Assert-LabSqlInstaller -VersionInfo $validVersion -Signature $validSignature -ManifestText (New-SqlManifestFixture '17.2607.0.1') }
}
Test-SqlInstallerCase 'download verification reads the actual Microsoft URLs from the host source' {
    $installerUri = [uri](Get-SqlSourceDownloadUrl 'sqlSseiUrl')
    $manifestUri = [uri](Get-SqlSourceDownloadUrl 'sqlBootstrapManifestUrl')
    if ($installerUri.AbsolutePath -notlike '*/SQL2022-SSEI-Expr.exe' -or $manifestUri.AbsolutePath -notlike '*/Manifest_Bootstrap_All.xml') {
        throw 'Installer verification would not use the expected SQL 2022 package and bootstrap manifest.'
    }
}

if ($VerifyDownload) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '-VerifyDownload requires Windows Authenticode verification.' }
    $installerUrl = Get-SqlSourceDownloadUrl 'sqlSseiUrl'
    $manifestUrl = Get-SqlSourceDownloadUrl 'sqlBootstrapManifestUrl'
    $downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ces-sql-installer-' + [guid]::NewGuid())
    $directoryCreated = $false
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        $null = New-Item -ItemType Directory -Path $downloadDirectory -ErrorAction Stop
        $directoryCreated = $true
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $installerPath = Join-Path $downloadDirectory 'SQL2022-SSEI-Expr.exe'
        $manifestPath = Join-Path $downloadDirectory 'Manifest_Bootstrap_All.xml'
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        Invoke-WebRequest -Uri $manifestUrl -OutFile $manifestPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        Test-SqlInstallerCase 'fresh Microsoft download has a valid signature and supported SQL 2022 version' {
            $result = Assert-LabSqlInstaller -VersionInfo (Get-Item -LiteralPath $installerPath).VersionInfo -Signature (Get-AuthenticodeSignature -LiteralPath $installerPath) -ManifestText (Get-Content -LiteralPath $manifestPath -Raw)
            $hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
            Write-Host "Verified SQL installer $($result.Version); minimum $($result.MinimumVersion); SHA256 $hash. The installer was not executed."
        }
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
        if ($directoryCreated) { Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction Stop }
    }
}
Write-Host "SQL installer checks passed: $sqlChecks. No installer or Azure operation was executed."
