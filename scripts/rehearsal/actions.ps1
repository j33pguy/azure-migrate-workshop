# Azure adapters for the rehearsal. No action executes merely by dot-sourcing.
Set-StrictMode -Version Latest

function Initialize-RehearsalAzure {
    param($Config,[switch]$Interactive)
    foreach ($module in @('Az.Accounts','Az.Resources','Az.Network','Az.Compute')) { Import-Module $module -ErrorAction Stop }
    $context=Get-AzContext -ErrorAction Stop
    if ($Interactive -and (-not $context -or $context.Subscription.Id -ne $Config.SubscriptionId -or $context.Tenant.Id -ne $Config.TenantId)) {
        Connect-AzAccount -Tenant $Config.TenantId -Subscription $Config.SubscriptionId -ErrorAction Stop | Out-Null
    }
    $context=Assert-LabContext $Config.SubscriptionId
    if ($context.Tenant.Id -ne $Config.TenantId) { throw 'Azure tenant does not match the rehearsal configuration.' }
}

function Invoke-RehearsalLocalChecks {
    param([string]$Root)
    $executable=(Get-Process -Id $PID).Path
    & $executable -NoProfile -File (Join-Path $Root 'tests/Validate-Repository.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Local PowerShell validation failed.' }
    & $executable -NoProfile -File (Join-Path $Root 'tests/Test-Rehearsal.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Rehearsal orchestration regression tests failed.' }
}

function Test-RehearsalAzurePrerequisites {
    param($Config)
    foreach ($name in @($Config.SourceResourceGroup,$Config.TargetResourceGroup)) {
        if (Get-LabResourceGroup -Name $name -AllowMissing) { throw "Rehearsal needs two new dedicated groups; '$name' already exists." }
    }
    foreach ($command in @('Set-AzVMRunCommand','Get-AzVMRunCommand')) { $null=Get-Command $command -ErrorAction Stop }
    if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Update Az.Compute to a version supporting protected managed Run Command parameters.' }
    foreach ($provider in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage','Microsoft.Migrate','Microsoft.OffAzure','Microsoft.RecoveryServices','Microsoft.KeyVault')) {
        $records=@(Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop)
        if (-not $records.Count -or @($records | Where-Object RegistrationState -NE 'Registered').Count) { throw "Provider $provider is not registered. Resolve registration separately before provisioning." }
    }
    $hostSku=Get-LabHostSku -VMSize $Config.VMSize -Location $Config.Location
    $images=Get-LabWindowsImages -Location $Config.Location
    $null=New-LabWindowsGuestDiskConfig -Location $Config.Location -ImageId $images.Guest.Id
    Write-Host "Selected host $($hostSku.Name): $($hostSku.Cores) enabled vCPUs, $($hostSku.MemoryGB) GiB RAM. SKU, quota and Windows image checks passed."
    Write-Host 'Confirm nested virtualization support for this series in Microsoft documentation at the environment checkpoint. Target/test capacity, policy, licensing and download access also require instructor verification.'
}

function Get-RehearsalVMMap {
    param($State,[ValidateSet('test','final')][string]$Phase)
    $gate=if ($Phase -eq 'test') { 'test-migration' } else { 'cutover' }
    $map=(Get-RehearsalEvidence $State $gate).VMNames
    Assert-LabWorkloadNames @($map.WindowsWebVM,$map.SqlVM,$map.LinuxWebVM,$map.LinuxAppVM)
    return @{WindowsWebVM=$map.WindowsWebVM;SqlVM=$map.SqlVM;LinuxWebVM=$map.LinuxWebVM;LinuxAppVM=$map.LinuxAppVM}
}

function Get-RehearsalVM {
    param($Config,[string]$Name)
    $matches=@(Get-AzVM -ResourceGroupName $Config.TargetResourceGroup -Name $Name -ErrorAction Stop)
    $expected="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.TargetResourceGroup)/providers/Microsoft.Compute/virtualMachines/$Name"
    if ($matches.Count -ne 1 -or $matches[0].Name -ne $Name -or $matches[0].Id -ne $expected) { throw 'Azure returned an unexpected VM identity.' }
    return $matches[0]
}

function Test-RehearsalNetwork {
    param($Config,$Map,[ValidateSet('test','final')][string]$Phase)
    $null=Assert-LabResourceGroup $Config.TargetResourceGroup
    $network=if ($Phase -eq 'test') { 'test' } else { 'target' }
    $expectedSubnet="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.TargetResourceGroup)/providers/Microsoft.Network/virtualNetworks/$($Config.TargetResourceGroup)-$network-vnet/subnets/default"
    $addresses=@{}
    foreach ($role in @('WindowsWebVM','SqlVM','LinuxWebVM','LinuxAppVM')) {
        $vm=Get-RehearsalVM $Config $Map[$role]
        if (@($vm.NetworkProfile.NetworkInterfaces).Count -ne 1) { throw 'Each lab VM must have exactly one NIC.' }
        $nicId=[string]$vm.NetworkProfile.NetworkInterfaces[0].Id
        $prefix="/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.TargetResourceGroup)/providers/Microsoft.Network/networkInterfaces/"
        if (-not $nicId.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'VM NIC is outside the intended target resource group.' }
        $name=$nicId.Substring($prefix.Length)
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$') { throw 'Unexpected NIC resource name.' }
        $nics=@(Get-AzNetworkInterface -ResourceGroupName $Config.TargetResourceGroup -Name $name -ErrorAction Stop)
        if ($nics.Count -ne 1 -or $nics[0].Id -ne $nicId -or @($nics[0].IpConfigurations).Count -ne 1) { throw 'Unexpected NIC identity or IP configuration.' }
        $ipConfig=$nics[0].IpConfigurations[0]
        if ($ipConfig.Subnet.Id -ne $expectedSubnet -or $null -ne $ipConfig.PublicIpAddress) { throw 'VM is on the wrong subnet or has a public NIC IP.' }
        $address=[string]$ipConfig.PrivateIpAddress
        $parsed=$null
        if ($address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($address,[ref]$parsed)) { throw 'VM has no valid private IPv4 address.' }
        $addresses[$role]=$address
    }
    $ports=@{SqlVM=1433;LinuxWebVM=80;LinuxAppVM=3000}
    $lines=@('$ErrorActionPreference = ''Stop''')
    foreach ($role in @('SqlVM','LinuxWebVM','LinuxAppVM')) {
        $lines += "if (-not (Test-NetConnection -ComputerName '$($addresses[$role])' -Port $($ports[$role]) -InformationLevel Quiet -WarningAction SilentlyContinue)) { throw 'Cross-VM TCP check failed for $role.' }"
    }
    $lines += "Write-Output 'LAB_NETWORK_VALIDATED'"
    $result=Invoke-AzVMRunCommand -ResourceGroupName $Config.TargetResourceGroup -VMName $Map.WindowsWebVM -CommandId RunPowerShellScript -ScriptString ($lines -join "`n") -ErrorAction Stop
    $null=Assert-LabRunResult $result 'LAB_NETWORK_VALIDATED'
    Write-Host 'Expected subnet placement, absence of public NIC IPs and three cross-VM TCP probes passed. DNS and business integrations are separate acceptance checks.'
}

function Test-RehearsalSql {
    param([string]$Root,$Config,$State,[string]$Directory,$Map,[ValidateSet('test','final')][string]$Phase)
    $gate=if ($Phase -eq 'test') { 'pretest-baseline' } else { 'precutover-baseline' }
    $evidence=Get-RehearsalEvidence $State $gate
    $expected=(Get-FileHash -LiteralPath (Join-Path $Directory $evidence.BaselinePath) -Algorithm SHA256).Hash
    if ($expected -cne $evidence.BaselineSha256 -or $expected -notmatch '^[A-F0-9]{64}$') { throw 'Independent source SQL baseline changed.' }
    $helper=(Get-FileHash -LiteralPath (Join-Path $Root 'scripts/Test-LabSqlData.ps1') -Algorithm SHA256).Hash
    $suffix=if ($Phase -eq 'test') { 'pretest' } else { 'precutover' }
    $script=@'
$ErrorActionPreference = 'Stop'
$baseline = 'C:\LabEvidence\source-__SUFFIX__.baseline.json'
$helper = 'C:\LabTools\Test-LabSqlData.ps1'
if ((Get-FileHash -LiteralPath $baseline -Algorithm SHA256).Hash -cne '__BASELINE__') { throw 'Replicated baseline does not match the independent source record.' }
if ((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash -cne '__HELPER__') { throw 'SQL helper does not match the reviewed checkout.' }
& $helper -BaselinePath $baseline
Write-Output 'SQL_BASELINE_VALIDATED'
'@
    $script=$script.Replace('__SUFFIX__',$suffix).Replace('__BASELINE__',$expected).Replace('__HELPER__',$helper)
    $null=Assert-LabResourceGroup $Config.TargetResourceGroup
    $null=Get-RehearsalVM $Config $Map.SqlVM
    $result=Invoke-AzVMRunCommand -ResourceGroupName $Config.TargetResourceGroup -VMName $Map.SqlVM -CommandId RunPowerShellScript -ScriptString $script -ErrorAction Stop
    $null=Assert-LabRunResult $result 'SQL_DATA_MATCHED'
    $null=Assert-LabRunResult $result 'SQL_BASELINE_VALIDATED'
}

function Invoke-RehearsalCleanup {
    param([string]$Root,$Config,[switch]$Preview)
    # On an explicit retry, a group deleted by an earlier attempt may be absent.
    # Only the exact ARM not-found response is accepted as absence.
    $remaining=@(foreach ($name in @($Config.SourceResourceGroup,$Config.TargetResourceGroup)) {
        if (Get-LabResourceGroup -Name $name -AllowMissing) { $name }
    })
    if ($remaining.Count) {
        if ($Preview) { & (Join-Path $Root 'scripts/cleanup-lab.ps1') -SubscriptionId $Config.SubscriptionId -ResourceGroupName $remaining -WhatIf }
        else { & (Join-Path $Root 'scripts/cleanup-lab.ps1') -SubscriptionId $Config.SubscriptionId -ResourceGroupName $remaining -Confirm:$false }
    }
    if (-not $Preview) {
        foreach ($name in @($Config.SourceResourceGroup,$Config.TargetResourceGroup)) {
            if (Get-LabResourceGroup -Name $name -AllowMissing) { throw 'A lab resource group still exists after cleanup.' }
        }
    }
}

function Invoke-RehearsalAction {
    param([string]$Id,[string]$Root,$Config,$State,[string]$Directory,[SecureString]$AdminPassword,[switch]$Interactive)
    if ($Id -eq 'local-checks') { Invoke-RehearsalLocalChecks $Root; return }
    Initialize-RehearsalAzure $Config -Interactive:$Interactive
    switch ($Id) {
        'azure-preflight' { Test-RehearsalAzurePrerequisites $Config }
        'deploy-source' {
            & (Join-Path $Root 'scripts/deploy-lab.ps1') -SubscriptionId $Config.SubscriptionId -ResourceGroupName $Config.SourceResourceGroup -Location $Config.Location `
                -AdminUsername $Config.AdminUsername -AdminPassword $AdminPassword -AdminSourceCidr $Config.AdminSourceCidr -VMSize $Config.VMSize `
                -HealthPath (Join-Path $Directory 'artifacts/deployment-health.json')
        }
        'target-networks' {
            & (Join-Path $Root 'scripts/migrate-step1-setup-project.ps1') -SubscriptionId $Config.SubscriptionId -SourceResourceGroup $Config.SourceResourceGroup -TargetResourceGroup $Config.TargetResourceGroup -Location $Config.Location `
                -HealthPath (Join-Path $Directory 'artifacts/deployment-health.json')
        }
        { $_ -in @('test-workloads','final-workloads','test-network','final-network','test-sql','final-sql','post-inventory') } {
            $phase=if ($Id.StartsWith('test-')) { 'test' } else { 'final' }
            $map=Get-RehearsalVMMap $State $phase
            if ($Id.EndsWith('-workloads')) {
                & (Join-Path $Root 'scripts/Test-MigratedWorkloads.ps1') -SubscriptionId $Config.SubscriptionId -ResourceGroupName $Config.TargetResourceGroup @map
            } elseif ($Id.EndsWith('-network')) { Test-RehearsalNetwork $Config $map $phase }
            elseif ($Id.EndsWith('-sql')) { Test-RehearsalSql $Root $Config $State $Directory $map $phase }
            else {
                $null=Assert-LabResourceGroup $Config.TargetResourceGroup
                foreach ($name in $map.Values) {
                    $vm=Get-RehearsalVM $Config $name
                    [pscustomobject]@{Name=$vm.Name;Size=$vm.HardwareProfile.VmSize;OS=$vm.StorageProfile.OsDisk.OsType;Location=$vm.Location}
                }
            }
        }
        'test-absence' {
            $null=Assert-LabResourceGroup $Config.TargetResourceGroup
            $map=Get-RehearsalVMMap $State 'test'
            $vms=@(Get-AzVM -ResourceGroupName $Config.TargetResourceGroup -ErrorAction Stop)
            if (@($vms | Where-Object { $_.Name -in @($map.Values) }).Count) { throw 'One or more recorded test VMs still exist.' }
        }
        'source-off' {
            $null=Assert-LabResourceGroup $Config.SourceResourceGroup
            $script=@'
$ErrorActionPreference = 'Stop'
foreach ($name in @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')) {
    $vm = @(Get-VM -Name $name -ErrorAction Stop)
    if ($vm.Count -ne 1 -or $vm[0].Name -ne $name -or $vm[0].State -ne 'Off') { throw 'A source workload is not powered off.' }
}
Write-Output 'SOURCE_WORKLOADS_OFF'
'@
            $result=Invoke-AzVMRunCommand -ResourceGroupName $Config.SourceResourceGroup -VMName HyperVHost -CommandId RunPowerShellScript -ScriptString $script -ErrorAction Stop
            $null=Assert-LabRunResult $result 'SOURCE_WORKLOADS_OFF'
        }
        'cleanup-preview' { Invoke-RehearsalCleanup $Root $Config -Preview }
        'cleanup' { Invoke-RehearsalCleanup $Root $Config }
        default { throw "No automated action exists for stage $Id." }
    }
}
