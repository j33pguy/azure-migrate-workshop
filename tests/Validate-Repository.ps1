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
# Public Azure response fixtures; no module import, sign-in or service calls.
function New-HostSkuFixture {
    param([string]$Name='Standard_D16s_v5')
    $values=@{vCPUs='16';vCPUsAvailable='16';MemoryGB='64';CpuArchitectureType='x64';HyperVGenerations='V1,V2';PremiumIO='True';AcceleratedNetworkingEnabled='True'}
    [pscustomobject]@{Name=$Name;ResourceType='virtualMachines';Locations=@('eastus');Restrictions=@();Family='standardDSv5Family';
        Capabilities=@($values.GetEnumerator() | ForEach-Object { [pscustomobject]@{Name=$_.Key;Value=$_.Value} })}
}
function Get-AzComputeResourceSku {
    param($Location,$ErrorAction)
    $script:hostSkuLookupLocation=$Location
    if ($hostLookupFailure) { throw 'Simulated Azure lookup failure.' }
    $hostSkus
}
function Get-AzVMUsage { param($Location,$ErrorAction) $hostUsage }
function Reset-HostFixtures {
    $script:hostLookupFailure=$false
    $script:hostSkus=@((New-HostSkuFixture), (New-HostSkuFixture 'Standard_E8s_v5'))
    $script:hostUsage=@(
        [pscustomobject]@{Name=[pscustomobject]@{Value='standardDSv5Family'};Limit=32;CurrentValue=16},
        [pscustomobject]@{Name=[pscustomobject]@{Value='cores'};Limit=64;CurrentValue=16})
}
Check 'Host validation uses the selected SKU and region without a fixed size list' {
    Reset-HostFixtures
    $selected=Get-LabHostSku -VMSize Standard_D16s_v5 -Location eastus
    if ($selected.Name -ne 'Standard_D16s_v5' -or $selected.Cores -ne 16 -or $selected.MemoryGB -ne 64 -or
        -not $selected.AcceleratedNetworking -or $hostSkuLookupLocation -ne 'eastus') { throw 'Wrong host profile selected.' }
    $script:hostSkus[0].Name='Standard_E32s_v5'
    if ((Get-LabHostSku -VMSize Standard_E32s_v5 -Location eastus).Name -ne 'Standard_E32s_v5') { throw 'Alternative size blocked.' }
}
Check 'Host validation refuses missing, duplicate and region-restricted SKUs' {
    Reset-HostFixtures
    Should-Throw { Get-LabHostSku Standard_Unknown99 eastus }
    Should-Throw { Get-LabHostSku Standard_D16s_v5 westus2 }
    $script:hostSkus+=New-HostSkuFixture
    Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
    Reset-HostFixtures
    $script:hostSkus[0].Restrictions=@([pscustomobject]@{Type='Location'})
    Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
    Reset-HostFixtures; $script:hostLookupFailure=$true
    Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
}
Check 'Host validation rejects insufficient or incompatible CPU RAM architecture and storage' {
    foreach ($case in @(@('vCPUs','0'),@('vCPUs','unknown'),@('vCPUsAvailable','4'),@('vCPUsAvailable','unknown'),
        @('MemoryGB','32'),@('MemoryGB','unknown'),@('CpuArchitectureType','Arm64'),@('HyperVGenerations','V1'),@('PremiumIO','False'))) {
        Reset-HostFixtures
        ($script:hostSkus[0].Capabilities | Where-Object Name -EQ $case[0]).Value=$case[1]
        Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
    }
    Reset-HostFixtures
    $script:hostSkus[0].Capabilities=@($script:hostSkus[0].Capabilities | Where-Object Name -NE 'MemoryGB')
    Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
}
Check 'Host quotas require both family and regional records with sufficient headroom' {
    foreach ($index in @(0,1)) {
        Reset-HostFixtures; $script:hostUsage[$index].Limit=31
        Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
        Reset-HostFixtures; $script:hostUsage=@($script:hostUsage[$index])
        Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
    }
    Reset-HostFixtures; $script:hostUsage[0].Limit=$null
    Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
    Reset-HostFixtures; $script:hostUsage=@($script:hostUsage[0],$script:hostUsage[0])
    Should-Throw { Get-LabHostSku Standard_D16s_v5 eastus }
}
function Get-AzContext { param($ErrorAction) [pscustomobject]@{Subscription=[pscustomobject]@{Id='fixture-sub'}} }
function Get-AzVMImage { throw 'SDK image lookup attempted: simulated unsupported API 2026-04-01.' }
function Invoke-ImageCatalogFixture {
    param($Path,$Method)
    $windowsImageCalls.Add($Path)
    if ($Method -ne 'GET' -or $Path -notmatch '^/subscriptions/fixture-sub/providers/Microsoft.Compute/locations/eastus/publishers/MicrosoftWindowsServer/artifacttypes/vmimage/offers/windowsserver2022/skus/(2022-datacenter(?:-smalldisk)?-g2)/versions(?:/([0-9.]+))?\?api-version=2025-04-01$') {
        throw 'Unexpected image catalog request or unsupported API version.'
    }
    $sku=$Matches[1]; $version=$Matches[2]
    if ($imageMode -eq 'failure') { throw 'Simulated image access failure.' }
    if ($imageMode -eq 'empty') { return [pscustomobject]@{StatusCode=200;Content=''} }
    if ($imageMode -eq 'malformed') { return [pscustomobject]@{StatusCode=200;Content='<html>proxy error</html>'} }
    if ($imageMode -eq 'unsupported-api') { return [pscustomobject]@{StatusCode=400;Content='{"error":{"code":"NoRegisteredProviderFound"}}'} }
    if ($imageMode -eq 'forbidden') { return [pscustomobject]@{StatusCode=403;Content='{"error":{"code":"AuthorizationFailed"}}'} }
    if (-not $version) {
        $body=@(@{name='20348.1.9'},@{name='20348.1.10'})
        if ($imageMode -eq 'missing' -and $sku -match 'smalldisk') { $body=@() }
        if ($imageMode -eq 'invalid-version') { $body=@(@{name='latest'}) }
        if ($imageMode -eq 'missing-version') { $body=@(@{id='/no-name'}) }
    } else {
        $body=@{id=($Path -split '\?')[0];properties=@{hyperVGeneration='V2';architecture='x64';osDiskImage=@{operatingSystem='Windows'}}}
        switch ($imageMode) {
            'wrong-id' { $body.id='/subscriptions/another-sub/wrong-image' }
            'gen1' { $body.properties.hyperVGeneration='V1' }
            'arm' { $body.properties.architecture='Arm64' }
            'linux' { $body.properties.osDiskImage.operatingSystem='Linux' }
            'missing-properties' { $body.Remove('properties') }
        }
    }
    [pscustomobject]@{StatusCode=200;Content=(ConvertTo-Json -InputObject $body -Depth 8 -Compress)}
}
function Invoke-AzRestMethod { param($Path,$Method,$ErrorAction) Invoke-ImageCatalogFixture $Path $Method }
function New-AzDiskConfig {
    param($Location,$CreateOption,$HyperVGeneration,$OsType,$ImageReference,$ErrorAction)
    [pscustomobject]@{Location=$Location;CreateOption=$CreateOption;HyperVGeneration=$HyperVGeneration;OsType=$OsType;ImageReference=$ImageReference;SecurityProfile=$null}
}
function Set-AzDiskSecurityProfile {
    param($Disk,$SecurityType,$ErrorAction)
    if ($SecurityType -ne 'Standard') { throw 'The guest export disk must explicitly select Standard security.' }
    if ($diskMode -eq 'ignored') { return $Disk }
    $Disk.SecurityProfile=[pscustomobject]@{SecurityType=$SecurityType}
    return $Disk
}
Check 'Windows host and guest images use the current offer and exact newest versions' {
    $script:imageMode='good'; $script:windowsImageCalls=[Collections.Generic.List[string]]::new()
    $images=Get-LabWindowsImages eastus
    if ($images.Host.Version -ne '20348.1.10' -or $images.Guest.Version -ne '20348.1.10' -or
        $images.Host.Sku -ne '2022-datacenter-g2' -or $images.Guest.Sku -ne '2022-datacenter-smalldisk-g2' -or
        $windowsImageCalls.Count -ne 4) { throw 'Wrong image selection.' }
}
Check 'Unavailable incompatible malformed or unverified Windows images stop preflight' {
    foreach ($mode in @('missing','failure','gen1','arm','linux','wrong-id','missing-properties','invalid-version','missing-version','empty','malformed','forbidden')) {
        $script:imageMode=$mode; $script:windowsImageCalls=[Collections.Generic.List[string]]::new()
        Should-Throw { Get-LabWindowsImages eastus }
    }
}
Check 'Catalog errors preserve the Azure code and never fall back to the SDK image API' {
    $script:imageMode='unsupported-api'; $script:windowsImageCalls=[Collections.Generic.List[string]]::new()
    $message=''
    try { $null=Get-LabWindowsImages eastus } catch { $message=$_.Exception.Message }
    if ($message -notlike '*NoRegisteredProviderFound*API 2025-04-01*' -or $windowsImageCalls.Count -ne 1) { throw 'API failure was hidden or retried through an unsupported SDK default.' }
}
Check 'Temporary guest disk retains Standard security and the exact validated image' {
    $script:diskMode='good'; $script:imageMode='good'; $script:windowsImageCalls=[Collections.Generic.List[string]]::new()
    $images=Get-LabWindowsImages eastus
    $disk=New-LabWindowsGuestDiskConfig eastus $images.Guest.Id
    if ($disk.SecurityProfile.SecurityType -ne 'Standard' -or $disk.ImageReference.Id -cne $images.Guest.Id -or
        $disk.HyperVGeneration -ne 'V2' -or $disk.OsType -ne 'Windows' -or $disk.CreateOption -ne 'FromImage') { throw 'Export disk configuration is incompatible with the Hyper-V guests.' }
    $script:diskMode='ignored'
    Should-Throw { New-LabWindowsGuestDiskConfig eastus $images.Guest.Id }
}
Check 'Direct deployment rejects invalid host image API or disk security before creating resources' {
    function Import-Module { param($Name,$ErrorAction) if ($Name -notlike 'Az.*') { throw 'Unexpected module import.' } }
    function Get-AzContext { param($ErrorAction) [pscustomobject]@{Subscription=[pscustomobject]@{Id='fixture-sub'}} }
    function Invoke-AzRestMethod {
        param($Path,$Method,$ErrorAction)
        if ($Path -match '/resourcegroups/') { return [pscustomobject]@{StatusCode=404;Content='{"error":{"code":"ResourceGroupNotFound"}}'} }
        Invoke-ImageCatalogFixture $Path $Method
    }
    function Set-AzVMRunCommand { param($ProtectedParameter) throw 'Unexpected Run Command.' }
    function Get-AzVMRunCommand { throw 'Unexpected Run Command lookup.' }
    function New-AzResourceGroup { $script:resourceCreateCalls++; throw 'Unexpected resource creation.' }
    $script:resourceCreateCalls=0
    $password=ConvertTo-SecureString 'Fixture-Only-Password123!' -AsPlainText -Force
    foreach ($case in @('host','image','api','security')) {
        Reset-HostFixtures; $script:imageMode='good'; $script:diskMode='good'; $script:windowsImageCalls=[Collections.Generic.List[string]]::new()
        if ($case -eq 'host') { ($script:hostSkus[0].Capabilities | Where-Object Name -EQ 'MemoryGB').Value='32' }
        if ($case -eq 'image') { $script:imageMode='missing' }
        if ($case -eq 'api') { $script:imageMode='unsupported-api' }
        if ($case -eq 'security') { $script:diskMode='ignored' }
        $message=''
        try {
            & "$root/scripts/deploy-lab.ps1" -SubscriptionId fixture-sub -ResourceGroupName source-test -Location eastus `
                -AdminUsername labadmin -AdminPassword $password -AdminSourceCidr '203.0.113.42/32' -VMSize Standard_D16s_v5
        } catch { $message=$_.Exception.Message }
        $expected=switch ($case) {
            'host' { 'at least 8 enabled vCPUs and 64 GiB' }
            'image' { 'No Windows image versions found' }
            'api' { 'NoRegisteredProviderFound' }
            'security' { 'did not retain Standard security' }
        }
        if ($message -notlike "*$expected*" -or $script:resourceCreateCalls) { throw "Deployment did not stop at the expected $case gate: $message" }
    }
}
# Load pure helpers from the real host payload without executing its setup body.
$tokens=$null; $errors=$null
$hostAst=[System.Management.Automation.Language.Parser]::ParseFile("$root/scripts/host/configure-host.ps1",[ref]$tokens,[ref]$errors)
foreach ($name in @('Expand-LabTextTemplate','Assert-LabSourceWorkloads')) {
    $definition=$hostAst.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
Check 'RDP source accepts one IPv4 /32 and rejects wildcard, CIDR /0 and invalid input' {
    Assert-LabAdminSource '203.0.113.14/32'
    foreach ($bad in @('*','0.0.0.0/0','10.0.0.0/24','999.1.1.1/32','::1/32','0.0.0.0/32','10.0.0.1',
        '8.8.2056/32','134744072/32','010.010.010.010/32','0x08.0x08.0x08.0x08/32',' 8.8.8.8/32')) {
        Should-Throw { Assert-LabAdminSource $bad }
    }
}
Check 'Workload checks require four distinct literal VM names' {
    Assert-LabWorkloadNames @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')
    foreach ($names in @(
        @('OnPrem-Web','onprem-web','OnPrem-Linux-Web','OnPrem-Linux-App'),
        @('OnPrem-*','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App'),
        @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web',' OnPrem-Linux-App'),
        @('OnPrem-Web','OnPrem-SQL'))) { Should-Throw { Assert-LabWorkloadNames $names } }
}
Check 'Incomplete deployment checkout fails before importing Azure modules' {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $null=New-Item -ItemType Directory -Path "$temp/host" -Force
    Copy-Item "$root/scripts/deploy-lab.ps1","$root/scripts/common.ps1" $temp
    $script:cesImports=0
    function Import-Module { $script:cesImports++; throw 'An Azure module import was reached.' }
    try {
        foreach ($content in @($null,'','param( broken syntax')) {
            if ($null -ne $content) { [IO.File]::WriteAllText("$temp/host/configure-host.ps1",$content) }
            Should-Throw { & "$temp/deploy-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -AdminUsername labadmin `
                -AdminPassword (ConvertTo-SecureString 'Sample-Test123!' -AsPlainText -Force) -AdminSourceCidr '203.0.113.14/32' }
        }
        if ($script:cesImports -ne 0) { throw 'Deployment advanced past a missing, empty or invalid host script.' }
    } finally { Remove-Item $temp -Recurse -Force }
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
$global:cesLookupCalls=0
$global:cesRestMode='present'
$global:cesAfterDeleteMode='missing'
$global:cesDeletedNames=@()
function Invoke-AzRestMethod {
    [CmdletBinding()]
    param($Path,$Method)
    $global:cesLookupCalls++
    if ($Method -ne 'GET' -or $Path -notmatch '^/subscriptions/test-sub/resourcegroups/([^?]+)\?api-version=2021-04-01$') {
        throw 'Unexpected API operation reached the local mock.'
    }
    $name=[uri]::UnescapeDataString($Matches[1])
    $mode=if ($global:cesDeletedNames -contains $name) { $global:cesAfterDeleteMode } else { $global:cesRestMode }
    switch ($mode) {
        'transport' { throw 'Synthetic network failure'; }
        'empty' { return $null }
        'malformed' { return [pscustomobject]@{StatusCode=404;Content='<html>Proxy failure</html>'} }
        'present' {
            $body=@{name=$name;id="/subscriptions/test-sub/resourceGroups/$name";tags=@{Workshop=$global:cesMockTag}}
            return [pscustomobject]@{StatusCode=200;Content=(ConvertTo-Json $body -Compress)}
        }
        'wrongIdentity' {
            $body=@{name=$name;id="/subscriptions/another-sub/resourceGroups/$name";tags=@{Workshop=$global:cesMockTag}}
            return [pscustomobject]@{StatusCode=200;Content=(ConvertTo-Json $body -Compress)}
        }
        'missing' { $status=404; $code='ResourceGroupNotFound' }
        'subscriptionMissing' { $status=404; $code='SubscriptionNotFound' }
        'unauthorized' { $status=401; $code='InvalidAuthenticationToken' }
        'forbidden' { $status=403; $code='AuthorizationFailed' }
        'throttled' { $status=429; $code='TooManyRequests' }
        'serverError' { $status=500; $code='InternalServerError' }
        default { throw 'Unexpected mock response mode.' }
    }
    return [pscustomobject]@{StatusCode=$status;Content=(ConvertTo-Json @{error=@{code=$code}} -Compress)}
}
$global:cesMockResources=@()
$global:cesLateVaultGroup=''
function Get-AzResource {
    param($ResourceGroupName)
    if ($ResourceGroupName -eq $global:cesLateVaultGroup) {
        [pscustomobject]@{Name='late-vault';ResourceType='Microsoft.RecoveryServices/vaults';ResourceGroupName=$ResourceGroupName}
    } else { $global:cesMockResources }
}
$global:cesMockLocks=@()
function Get-AzResourceLock { param($ResourceGroupName) $global:cesMockLocks }
$global:cesDeleteCalls=0
$global:cesAllowMockDelete=$false
function Remove-AzResourceGroup {
    param($Name,[switch]$Force)
    $global:cesDeleteCalls++
    if (-not $global:cesAllowMockDelete) { throw 'Unexpected deletion reached mock.' }
    $global:cesDeletedNames += $Name
}
Check 'Resource-group absence requires the specific ARM 404 code; other failures stop' {
    try {
        $global:cesRestMode='missing'
        if ($null -ne (Get-LabResourceGroup test-rg -AllowMissing)) { throw 'Expected a verified absent group.' }
        Should-Throw { Get-LabResourceGroup test-rg }
        foreach ($mode in @('subscriptionMissing','unauthorized','forbidden','throttled','serverError','transport','malformed','empty','wrongIdentity')) {
            $global:cesRestMode=$mode
            Should-Throw { Get-LabResourceGroup test-rg -AllowMissing }
        }
        $global:cesRestMode='present'
        if ((Get-LabResourceGroup 'test-(rg)').ResourceGroupName -ne 'test-(rg)') { throw 'Exact group name was not preserved.' }
    } finally { $global:cesRestMode='present' }
}
Check 'Wildcard and invalid cleanup names are rejected before any Azure lookup' {
    $callsBefore=$global:cesLookupCalls
    foreach ($name in @('*','test-*','test-?g','test-[rg]',' test-rg','/subscriptions/test-sub/resourceGroups/test-rg','test-rg.')) {
        Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg,$name -WhatIf }
    }
    if ($global:cesLookupCalls -ne $callsBefore) { throw 'An invalid name reached Azure lookup.' }
}
Check 'Subscription mismatch blocks cleanup' {
    Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId wrong-sub -ResourceGroupName test-rg -WhatIf }
}
Check 'Untagged resource group blocks cleanup' {
    $global:cesMockTag='another-project'
    Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -WhatIf }
    $global:cesMockTag='TD-SYNNEX-CES-HyperV'
}
Check 'Vault blocks cleanup' {
    foreach ($type in @('Microsoft.RecoveryServices/vaults','Microsoft.DataProtection/backupVaults')) {
        $global:cesMockResources=@([pscustomobject]@{Name='vault';ResourceType=$type;ResourceGroupName='test-rg'})
        Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -WhatIf }
    }
    $global:cesMockResources=@()
}
Check 'A vault in the second group or a resource lock blocks every deletion' {
    try {
        $global:cesLateVaultGroup='second-rg'
        Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName first-rg,second-rg -Confirm:$false }
        $global:cesLateVaultGroup=''
        $global:cesMockLocks=@([pscustomobject]@{Name='keep-lab'})
        Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -Confirm:$false }
        if ($global:cesDeleteCalls -ne 0) { throw 'A deletion was reached before all groups were cleared.' }
    } finally { $global:cesLateVaultGroup=''; $global:cesMockLocks=@() }
}
Check 'WhatIf performs zero resource deletion calls' {
    & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -WhatIf
    if ($global:cesDeleteCalls -ne 0) { throw 'A deletion was attempted.' }
}
Check 'Cleanup completion requires verified absence and does not hide post-delete lookup failure' {
    try {
        $global:cesAllowMockDelete=$true
        foreach ($mode in @('forbidden','transport','missing','present')) {
            $global:cesDeletedNames=@()
            $global:cesDeleteCalls=0
            $global:cesAfterDeleteMode=$mode
            if ($mode -eq 'missing') {
                & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -Confirm:$false
            } else {
                Should-Throw { & "$root/scripts/cleanup-lab.ps1" -SubscriptionId test-sub -ResourceGroupName test-rg -Confirm:$false }
            }
            if ($global:cesDeleteCalls -ne 1) { throw 'Expected exactly one simulated deletion attempt.' }
        }
    } finally {
        $global:cesAllowMockDelete=$false; $global:cesDeletedNames=@(); $global:cesDeleteCalls=0; $global:cesAfterDeleteMode='missing'
    }
}
if ($failures.Count) { $failures | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }
Write-Host "$count local checks passed. Azure/Hyper-V execution has not been tested."
