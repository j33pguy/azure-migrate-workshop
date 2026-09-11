<#
.SYNOPSIS
Prepare the Gateway payload before running the Azure Migrate appliance installer.
.DESCRIPTION
Run inside MigrateAppl after extracting the complete, verified Microsoft ZIP.
Microsoft's installer currently waits five seconds after starting its Gateway
extractor. This helper waits for the extractor to finish, checks its exit code,
and verifies fresh payload files before placing them beside the installer.
It does not install services, change registration, or run AzureMigrateInstaller.ps1.
.PARAMETER InstallerDirectory
Existing folder containing the extracted AzureMigrateInstaller.ps1 package.
.PARAMETER TimeoutMinutes
Maximum wait for extraction. A timeout preserves the staging directory for review.
.EXAMPLE
.\Expand-LabApplianceGateway.ps1 -InstallerDirectory C:\AzureMigrateInstaller
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerDirectory,
    [ValidateRange(1,30)][int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-LabGatewaySignature {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw "Microsoft signature validation failed: $Path. Obtain the complete verified appliance ZIP; do not bypass this check."
    }
}

function Expand-LabGatewayPayload {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateRange(1,1800)][int]$TimeoutSeconds = 600
    )
    $folder = Get-Item -LiteralPath $Directory -ErrorAction Stop
    if (-not $folder.PSIsContainer -or $folder.PSProvider.Name -ne 'FileSystem') {
        throw 'InstallerDirectory must be an extracted package folder on disk.'
    }
    $directoryPath = $folder.FullName
    foreach ($name in @('AzureMigrateInstaller.ps1', 'MicrosoftAzureGatewayService.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $directoryPath $name) -PathType Leaf)) {
            throw "Missing $name in $directoryPath. Extract the complete Microsoft ZIP before preparing Gateway."
        }
    }
    $packager = Join-Path $directoryPath 'MicrosoftAzureGatewayService.exe'
    Assert-LabGatewaySignature $packager
    $running = @(Get-Process -Name 'MicrosoftAzureGatewayService','GATEWAYSETUPINSTALLER' -ErrorAction SilentlyContinue)
    if ($running.Count) {
        throw 'A Gateway extraction or installation process is still running. Let it finish or inspect it before retrying.'
    }

    # Always validate a fresh extraction, never leftovers from an earlier attempt.
    $staging = Join-Path $directoryPath ('GatewayPayload-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $staging -ErrorAction Stop
    $process = $null
    $processExited = $false
    $completed = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Host 'Extracting Gateway payload; waiting for completion (no services are installed).' -ForegroundColor Cyan
        $process = Start-Process -FilePath $packager -WorkingDirectory $directoryPath `
            -ArgumentList ('/q /x:"{0}"' -f $staging) -PassThru -ErrorAction Stop
        # Keep the native handle alive so Windows PowerShell 5.1 retains ExitCode.
        $null = $process.Handle
        while (-not $process.WaitForExit(1000)) {
            Write-Progress -Id 4710 -Activity 'Prepare Azure Migrate Gateway' -PercentComplete -1 `
                -Status ("Extracting | {0}s elapsed | {1}s limit" -f [int]$clock.Elapsed.TotalSeconds, $TimeoutSeconds)
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Gateway extraction exceeded $TimeoutSeconds seconds. Process $($process.Id) may still be running; inspect it before retrying. Staging: $staging"
            }
        }
        $processExited = $true
        if ($process.ExitCode -ne 0) {
            throw "Gateway extraction failed with exit code $($process.ExitCode). Inspect free disk space, the package, and any Windows Security detection. Staging: $staging"
        }
        $payloadNames = @(
            'GATEWAYSETUPINSTALLER.EXE', 'MICROSOFTAZUREGATEWAYSERVICE.MSI',
            'VCREDIST_X64_2012.EXE', 'VCREDIST_X64_2013.EXE', 'VCREDIST_X64_V14.EXE'
        )
        foreach ($name in $payloadNames) {
            $path = Join-Path $staging $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Gateway extraction exited successfully but did not produce $name. Inspect extraction and Windows Security history. Staging: $staging"
            }
            if ((Get-Item -LiteralPath $path).Length -eq 0) {
                throw "Gateway extraction produced an empty $name. Staging: $staging"
            }
        }
        # Microsoft's inner Gateway bootstrapper is unsigned. Its provenance is
        # the signed outer packager and this fresh extraction, not a bypass of
        # a failed inner signature check. Verify each copy against that output.
        foreach ($name in $payloadNames) {
            $source = Join-Path $staging $name
            $destination = Join-Path $directoryPath $name
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) {
                throw "Gateway payload copy could not be verified: $destination"
            }
        }
        $completed = $true
        Write-Host 'Gateway payload verified and ready. Appliance installation and registration are still pending.' -ForegroundColor Green
        [pscustomobject]@{
            Status = 'PayloadReady'
            InstallerDirectory = $directoryPath
            GatewaySetup = Join-Path $directoryPath 'GATEWAYSETUPINSTALLER.EXE'
        }
    } finally {
        Write-Progress -Id 4710 -Activity 'Prepare Azure Migrate Gateway' -Completed
        if ($null -ne $process) { $process.Dispose() }
        if ($completed -and $processExited) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
        }
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Run this helper in an elevated 64-bit Windows PowerShell window inside MigrateAppl.'
}
if ($env:COMPUTERNAME -ne 'MigrateAppl') { throw 'Run this helper inside MigrateAppl, where the appliance package is extracted.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open Windows PowerShell as administrator inside MigrateAppl.'
    }
} finally { $identity.Dispose() }

Expand-LabGatewayPayload -Directory $InstallerDirectory -TimeoutSeconds ($TimeoutMinutes * 60)
