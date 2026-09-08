<#
.SYNOPSIS
Validate explicitly named migrated/test VMs from inside each VM.
.DESCRIPTION
Runs local service, HTTP and SQL checks using the Azure VM agent. This works
without a route from your workstation to the VM's private IP. Supply actual
Azure VM names: test names must be copied from the portal. Throws on any
missing VM, agent failure, service failure, bad HTTP content or SQL error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WindowsWebVM,
    [Parameter(Mandatory)][string]$SqlVM,
    [Parameter(Mandatory)][string]$LinuxWebVM,
    [Parameter(Mandatory)][string]$LinuxAppVM
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$null = Assert-LabContext $SubscriptionId
$null = Assert-LabResourceGroup $ResourceGroupName
$webCheck = @'
$ErrorActionPreference = 'Stop'
if ((Get-Service W3SVC).Status -ne 'Running') { throw 'IIS service is not running.' }
$page = Invoke-WebRequest http://localhost -UseBasicParsing -TimeoutSec 15
if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'TD SYNNEX') { throw 'IIS sample site did not pass.' }
Write-Output 'WORKLOAD_VALIDATED'
'@
$sqlCheck = @'
$ErrorActionPreference = 'Stop'
if ((Get-Service 'MSSQL$SQLEXPRESS').Status -ne 'Running') { throw 'SQL service is not running.' }
$connection = New-Object System.Data.SqlClient.SqlConnection 'Server=.\SQLEXPRESS;Database=ContosoApp;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15'
try {
    $connection.Open()
    $cmd = $connection.CreateCommand()
    $cmd.CommandTimeout = 120
    $cmd.CommandText = "DBCC CHECKDB (N'ContosoApp') WITH NO_INFOMSGS;"
    $null = $cmd.ExecuteNonQuery()
    $cmd.CommandText = 'SELECT COUNT(*) FROM dbo.Customers'
    if ([int]$cmd.ExecuteScalar() -lt 5) { throw 'Expected at least five sample Customers.' }
    $cmd.CommandText = 'SELECT COUNT(*) FROM dbo.Orders'
    if ([int]$cmd.ExecuteScalar() -lt 5) { throw 'Expected at least five sample Orders.' }
    Write-Output 'WORKLOAD_VALIDATED'
} finally { $connection.Dispose() }
'@
$linuxWebCheck = @'
set -eu
systemctl is-active --quiet nginx
page=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 20 http://127.0.0.1/)
printf '%s\n' "$page" | grep -q 'TD SYNNEX'
printf '%s\n' WORKLOAD_VALIDATED
'@
$linuxAppCheck = @'
set -eu
systemctl is-active --quiet contoso-app
response=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 20 http://127.0.0.1:3000/api/health)
printf '%s\n' "$response" | python3 -c 'import json,sys; data=json.load(sys.stdin); sys.exit(0 if data.get("status") == "healthy" and data.get("server") == "OnPrem-Linux-App" else 1)'
printf '%s\n' WORKLOAD_VALIDATED
'@
$checks = @(
    @{VM=$WindowsWebVM;OS='Windows';Command='RunPowerShellScript';Script=$webCheck},
    @{VM=$SqlVM;OS='Windows';Command='RunPowerShellScript';Script=$sqlCheck},
    @{VM=$LinuxWebVM;OS='Linux';Command='RunShellScript';Script=$linuxWebCheck},
    @{VM=$LinuxAppVM;OS='Linux';Command='RunShellScript';Script=$linuxAppCheck}
)
$failures = @()
foreach ($check in $checks) {
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $check.VM -ErrorAction Stop
        if ([string]$vm.StorageProfile.OsDisk.OsType -ne $check.OS) { throw 'Unexpected operating system.' }
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $check.VM -CommandId $check.Command -ScriptString $check.Script -ErrorAction Stop
        $null = Assert-LabRunResult $result 'WORKLOAD_VALIDATED'
        Write-Host "PASS: $($check.VM)"
    } catch {
        $failures += $check.VM
        Write-Warning "$($check.VM): $($_.Exception.Message)"
    }
}
if ($failures.Count) { throw "Workload validation failed: $($failures -join ', ')." }
Write-Host 'All four local workload smoke tests passed. Compare SQL baseline data and complete the network/application checks in Modules 2 and 3.'
