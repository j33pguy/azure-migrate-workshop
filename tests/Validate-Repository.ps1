# Local-only validation. Does not import Az modules, authenticate or deploy.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()
$count = 0
function Check {
    param([string]$Name,[scriptblock]$Test)
    try { & $Test; $script:count++; Write-Host "PASS $Name" }
    catch { $failures.Add("$Name`: $($_.Exception.Message)") }
}
function Should-Throw {
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected a terminating error.' }
}
Check 'PowerShell parses every script, including the host payload' {
    foreach ($file in Get-ChildItem $root -Recurse -Filter *.ps1 | Where-Object FullName -NotMatch '/\.git/') {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "$($file.Name): $($errors[0].Message) at $($errors[0].Extent.StartLineNumber)" }
    }
}
Check 'PowerShell examples in all learner guides parse' {
    $files = @(Get-Item "$root/README.md") + @(Get-ChildItem "$root/docs" -Filter *.md)
    foreach ($file in $files) {
        foreach ($match in [regex]::Matches((Get-Content $file.FullName -Raw),'(?ms)^```powershell\s*\n(.*?)^```')) {
            $tokens=$null; $errors=$null
            $null=[System.Management.Automation.Language.Parser]::ParseInput($match.Groups[1].Value,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "$($file.Name): $($errors[0].Message)" }
        }
    }
}
. "$root/scripts/common.ps1"
# Load pure helpers from the real host payload without executing its setup body.
$tokens=$null; $errors=$null
$hostAst=[System.Management.Automation.Language.Parser]::ParseFile("$root/scripts/host/configure-host.ps1",[ref]$tokens,[ref]$errors)
foreach ($name in @('Expand-LabTextTemplate','Assert-LabSourceWorkloads')) {
    $definition=$hostAst.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
Check 'RDP source accepts one IPv4 /32 and rejects wildcard, CIDR /0 and invalid input' {
    Assert-LabAdminSource '203.0.113.14/32'
    foreach ($bad in @('*','0.0.0.0/0','10.0.0.0/24','999.1.1.1/32','::1/32','0.0.0.0/32','10.0.0.1')) {
        Should-Throw { Assert-LabAdminSource $bad }
    }
}
Check 'Remote command requires stdout success marker and no stderr' {
    $good = [pscustomobject]@{Value=@([pscustomobject]@{Code='ComponentStatus/StdOut/succeeded';Message='WORKLOAD_VALIDATED'},[pscustomobject]@{Code='ComponentStatus/StdErr/succeeded';Message=''})}
    $null = Assert-LabRunResult $good WORKLOAD_VALIDATED
    $good.Value[0].Message = 'Setup started'
    Should-Throw { Assert-LabRunResult $good WORKLOAD_VALIDATED }
    $good.Value[0].Message = 'WORKLOAD_VALIDATED'
    $good.Value[1].Message = 'database failed'
    Should-Throw { Assert-LabRunResult $good WORKLOAD_VALIDATED }
    $good.Value[1].Message = ''
    foreach ($misleading in @('NOT_WORKLOAD_VALIDATED','WORKLOAD_VALIDATED_FAILED','Expected WORKLOAD_VALIDATED but failed','workload_validated')) {
        $good.Value[0].Message = $misleading
        Should-Throw { Assert-LabRunResult $good WORKLOAD_VALIDATED }
    }
    $good.Value[0].Message = 'WORKLOAD_VALIDATED'
    $good.Value[0].Code = 'ComponentStatus/StdOut/failed'
    Should-Throw { Assert-LabRunResult $good WORKLOAD_VALIDATED }
}
Check 'Managed command requires execution success, zero exit and workload evidence' {
    Assert-LabManagedRunResult ([pscustomobject]@{ExecutionState='Succeeded';ExitCode=0;Output='LAB_WORKLOADS_READY'})
    foreach ($bad in @(
        [pscustomobject]@{ExecutionState='Failed';ExitCode=1;Output='LAB_WORKLOADS_READY'},
        [pscustomobject]@{ExecutionState='Succeeded';ExitCode=1;Output='LAB_WORKLOADS_READY'},
        [pscustomobject]@{ExecutionState='Succeeded';ExitCode=0;Output='Provisioning accepted'},
        [pscustomobject]@{ExecutionState='Succeeded';ExitCode=0;Output='NOT_LAB_WORKLOADS_READY'},
        [pscustomobject]@{ExecutionState='Running';ExitCode=$null;Output=''})) { Should-Throw { Assert-LabManagedRunResult $bad } }
}
Check 'Windows password substitution preserves XML-sensitive and regex replacement characters' {
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile("$root/scripts/host/configure-host.ps1",[ref]$tokens,[ref]$errors)
    $literal=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('<?xml')},$true)[0].Value
    foreach ($password in @('Ab&<test>"quote''$1`{}: xyz123','Simple-Complex!234','Ab12__VMNAME____PASSWORD__!')) {
        $value=Expand-LabTextTemplate $literal @{'__VMNAME__'='OnPrem-Web';'__PASSWORD__'=[System.Security.SecurityElement]::Escape($password)}
        $xml=[xml]$value
        $ns=[System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        if ($xml.SelectSingleNode('//u:AdministratorPassword/u:Value',$ns).InnerText -cne $password) { throw 'Password changed during XML serialization.' }
    }
}
Check 'Template replacement preserves token-like passwords and rejects missing template values' {
    $password='Ab12__USER____RUNYAML____PASSWORD__$1!'
    $rendered=Expand-LabTextTemplate 'password: __PASSWORD__; user: __USER__' @{'__PASSWORD__'=$password;'__USER__'='labadmin'}
    if ($rendered -cne "password: $password; user: labadmin") { throw 'Inserted password was interpreted as template content.' }
    Should-Throw { Expand-LabTextTemplate '__UNKNOWN__' @{} }
}
Check 'Source readiness rejects a default IIS page, an unhealthy API and a closed SQL port' {
    $script:cesIisContent='TD SYNNEX'
    $script:cesApiStatus='healthy'
    $script:cesSqlReady=$true
    function Invoke-WebRequest {
        param($Uri,[switch]$UseBasicParsing,$TimeoutSec)
        [pscustomobject]@{StatusCode=200;Content=$(if ($Uri -eq 'http://192.168.0.10') {$script:cesIisContent} else {'TD SYNNEX'})}
    }
    function Invoke-RestMethod { param($Uri,$TimeoutSec) [pscustomobject]@{status=$script:cesApiStatus;server='OnPrem-Linux-App'} }
    function Test-NetConnection { param($ComputerName,$Port,$InformationLevel,$WarningAction) $script:cesSqlReady }
    Assert-LabSourceWorkloads
    $script:cesIisContent='Welcome to IIS'
    Should-Throw { Assert-LabSourceWorkloads }
    $script:cesIisContent='TD SYNNEX'
    $script:cesApiStatus='failed'
    Should-Throw { Assert-LabSourceWorkloads }
    $script:cesApiStatus='healthy'
    $script:cesSqlReady=$false
    Should-Throw { Assert-LabSourceWorkloads }
}
# SQL tests import function definitions only: no SQL connection or file capture.
$sqlAst=[System.Management.Automation.Language.Parser]::ParseFile("$root/scripts/Test-LabSqlData.ps1",[ref]$tokens,[ref]$errors)
foreach ($definition in $sqlAst.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function New-LabSqlFixture {
    return ConvertFrom-LabSqlJson @'
{"SchemaVersion":1,"Database":"ContosoApp","CapturedUtc":"2026-09-08T00:00:00Z","Tables":{
"Customers":[{"CustomerID":"1","FirstName":"Alice","LastName":"Johnson","Email":"alice@example.invalid","City":"Seattle","CreatedDate":"2026-09-08T12:00:00.003"}],
"Orders":[{"OrderID":"1","CustomerID":"1","ProductName":"Sample","Quantity":"2","UnitPrice":"49.99","OrderDate":"2026-09-08T12:00:00.007"}]}}
'@
}
Check 'SQL comparison catches changed values even when row counts match' {
    $expected=New-LabSqlFixture
    Assert-LabSqlDataMatches $expected (New-LabSqlFixture)
    foreach ($change in @(@('Customers','Email'),@('Customers','CreatedDate'),@('Orders','UnitPrice'),@('Orders','OrderDate'))) {
        $actual=New-LabSqlFixture
        $actual.Tables.($change[0])[0].($change[1])='changed'
        Should-Throw { Assert-LabSqlDataMatches $expected $actual }
    }
    $actual=New-LabSqlFixture
    $actual.Tables.Customers[0].FirstName='ALICE'
    Should-Throw { Assert-LabSqlDataMatches $expected $actual }
}
Check 'SQL baseline validates missing columns, duplicate keys and empty row arrays' {
    $expected=New-LabSqlFixture
    $actual=New-LabSqlFixture
    $actual.Tables.Orders[0].PSObject.Properties.Remove('OrderDate')
    Should-Throw { Assert-LabSqlDataMatches $expected $actual }
    $actual=New-LabSqlFixture
    $actual.Tables.Customers=@($actual.Tables.Customers[0],$actual.Tables.Customers[0])
    Should-Throw { Assert-LabSqlSnapshot $actual }
    $actual=New-LabSqlFixture
    $actual.Tables.Orders=@()
    Should-Throw { Assert-LabSqlDataMatches $expected $actual }
    $expected.Tables.Orders=@()
    Assert-LabSqlDataMatches $expected $actual
    $actual.Tables.Orders=$null
    Should-Throw { Assert-LabSqlSnapshot $actual }
}
Check 'SQL serialization preserves null, Unicode, decimal precision and timestamp milliseconds across cultures' {
    $culture=[System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture=[System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        if ((ConvertTo-LabSqlValue ([decimal]49.99)) -cne '49.99') { throw 'Decimal formatting depends on machine locale.' }
        $date=[datetime]::new(2026,9,8,12,0,0,7)
        if ((ConvertTo-LabSqlValue $date) -cne '2026-09-08T12:00:00.007') { throw 'Timestamp precision lost.' }
        if ($null -ne (ConvertTo-LabSqlValue ([DBNull]::Value))) { throw 'SQL NULL was changed.' }
        $expected=New-LabSqlFixture
        $expected.Tables.Customers[0].City=[string][char]0x00e9 + ' $1 <City>'
        $expected.Tables.Customers[0].Email=$null
        $roundTrip=ConvertFrom-LabSqlJson (ConvertTo-Json -InputObject $expected -Depth 8)
        Assert-LabSqlDataMatches $expected $roundTrip
        $roundTrip.Tables.Customers[0].Email=''
        Should-Throw { Assert-LabSqlDataMatches $expected $roundTrip }
    } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture=$culture }
}
Check 'Guest readiness returns one Boolean even when progress is logged' {
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile("$root/scripts/host/configure-host.ps1",[ref]$tokens,[ref]$errors)
    foreach ($name in @('Write-Log','Wait-ForGuestVM')) {
        $definition=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $logFile = Join-Path ([System.IO.Path]::GetTempPath()) 'ces-readiness-unit.log'
    try {
        $result=@(Wait-ForGuestVM -VMName 'NeverStarted' -TimeoutSeconds 0)
        if ($result.Count -ne 1 -or $result[0] -isnot [bool] -or $result[0]) { throw 'Progress output masked a false readiness result.' }
    } finally { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
}
# Mocks: cleanup must never invoke an Azure API in this suite.
function Get-AzContext { [pscustomobject]@{Subscription=[pscustomobject]@{Id='test-sub'}} }
$global:cesMockTag='TD-SYNNEX-CES-HyperV'
function Get-AzResourceGroup { param($Name) [pscustomobject]@{ResourceGroupName=$Name;Tags=@{Workshop=$global:cesMockTag}} }
$global:cesMockResources=@()
function Get-AzResource { param($ResourceGroupName) $global:cesMockResources }
function Get-AzResourceLock { param($ResourceGroupName) @() }
$global:cesDeleteCalls=0
function Remove-AzResourceGroup { param($Name,[switch]$Force) $global:cesDeleteCalls++; throw 'Unexpected deletion reached mock.' }
Check 'Subscription mismatch blocks cleanup' {
    Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId wrong-sub -ResourceGroupName test-rg -WhatIf }
}
Check 'Untagged resource group blocks cleanup' {
    $global:cesMockTag='another-project'
    Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -WhatIf }
    $global:cesMockTag='TD-SYNNEX-CES-HyperV'
}
Check 'Vault blocks cleanup' {
    $global:cesMockResources=@([pscustomobject]@{Name='vault';ResourceType='Microsoft.RecoveryServices/vaults';ResourceGroupName='test-rg'})
    Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -WhatIf }
    $global:cesMockResources=@()
}
Check 'WhatIf performs zero resource deletion calls' {
    & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -WhatIf
    if ($global:cesDeleteCalls -ne 0) { throw 'A deletion was attempted.' }
}
if ($failures.Count) { $failures | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }
Write-Host "$count local checks passed. Azure/Hyper-V execution has not been tested."
