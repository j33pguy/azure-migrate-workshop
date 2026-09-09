<#
.SYNOPSIS
Deploy the TD SYNNEX Cloud Enablement Services Hyper-V workshop.
.DESCRIPTION
Creates one Standard-security Windows host and provisions five nested VMs
(four workloads plus an appliance OS VM). Module 1 installs/registers the
Azure Migrate appliance. This script creates billable Azure resources.
Use a new dedicated resource group. Existing groups are refused intentionally.
.PARAMETER AdminSourceCidr
Your public IPv4 address as a /32. Required for the host RDP rule.
.PARAMETER AzureOperationTimeoutMinutes
Maximum monitored wait for each Azure host, network or disk creation operation.
.PARAMETER GuestSetupTimeoutMinutes
Azure's execution limit for ConfigureWorkshop; individual installer limits also apply.
.PARAMETER HealthPath
Local JSON status summary, without credentials or raw Run Command output.
.EXAMPLE
$password = Read-Host 'Lab password' -AsSecureString
.\scripts\deploy-lab.ps1 -SubscriptionId $subscriptionId -ResourceGroupName 'rg-ces-source-01' -AdminUsername 'labadmin' -AdminPassword $password -AdminSourceCidr $adminCidr
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,60}$')][string]$ResourceGroupName,
    [string]$Location = 'eastus',
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,18}$')][string]$AdminUsername,
    [Parameter(Mandatory)][SecureString]$AdminPassword,
    [Parameter(Mandatory)][string]$AdminSourceCidr,
    [string]$VMSize = 'Standard_E8s_v5',
    [ValidateRange(15,120)][int]$AzureOperationTimeoutMinutes = 60,
    [ValidateRange(30,240)][int]$GuestSetupTimeoutMinutes = 240,
    [string]$HealthPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$hostScript = Read-LabHostConfiguration "$PSScriptRoot/host/configure-host.ps1"
. "$PSScriptRoot/health.ps1"
if (-not $HealthPath) { $HealthPath = Join-Path $PSScriptRoot "../.artifacts/deployment-health-$ResourceGroupName.json" }
Assert-LabAdminSource $AdminSourceCidr
Assert-LabHostSizeName $VMSize
foreach ($module in @('Az.Accounts','Az.Resources','Az.Network','Az.Compute')) {
    Import-Module $module -ErrorAction Stop
}
$null = Assert-LabContext $SubscriptionId
foreach ($command in @('Set-AzVMRunCommand','Get-AzVMRunCommand')) { $null = Get-Command $command -ErrorAction Stop }
if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Update Az.Compute; managed Run Command protected parameters are required.' }
if ($AdminUsername -in @('admin','administrator','root','guest','user','test')) { throw 'Choose a non-reserved administrator username, such as labadmin.' }
$credential = [pscredential]::new($AdminUsername,$AdminPassword)
$passwordPlain = $credential.GetNetworkCredential().Password
if ($passwordPlain.Length -lt 12 -or $passwordPlain.Length -gt 72 -or $passwordPlain -match '[\r\n\x00-\x1f]') { throw 'Use a 12-72 character lab password without control characters.' }
$classes = @('[a-z]','[A-Z]','[0-9]','[^a-zA-Z0-9]') | Where-Object { $passwordPlain -cmatch $_ }
if (@($classes).Count -lt 3) { throw 'The password must include at least three character categories: lower, upper, number, symbol.' }
if (Get-LabResourceGroup -Name $ResourceGroupName -AllowMissing) { throw 'Use a new, dedicated source resource group. Deployment is not a post-migration repair command.' }
$hostSku = Get-LabHostSku -VMSize $VMSize -Location $Location
$windowsImages = Get-LabWindowsImages -Location $Location
$guestDiskConfig = New-LabWindowsGuestDiskConfig -Location $Location -ImageId $windowsImages.Guest.Id
Write-Host "Selected host: $($hostSku.Name), $($hostSku.Cores) enabled vCPUs, $($hostSku.MemoryGB) GiB RAM. Confirm this series supports nested virtualization with Standard security before running deployment."
foreach ($provider in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage','Microsoft.Migrate','Microsoft.OffAzure','Microsoft.RecoveryServices','Microsoft.KeyVault')) {
    $state = @(Get-AzResourceProvider -ProviderNamespace $provider)[0].RegistrationState
    if ($state -ne 'Registered') { throw "Register $provider first with Register-AzResourceProvider and wait until Registered." }
}
Write-Host "Creating source lab in subscription $SubscriptionId, region $Location."
Write-LabHealth 'Source deployment' Preparing 0 'Preflight passed. Starting dedicated workshop resource creation.' $HealthPath
$tags = @{ Workshop = 'TD-SYNNEX-CES-HyperV'; Team = 'Cloud Enablement Services'; Purpose = 'Training' }
$vmName = 'HyperVHost'
$diskName = 'WinServerBase-temp'
$runName = 'ConfigureWorkshop'
$diskCreated = $false
$runCreated = $false
$setupPassed = $false
$setupObservation = @{ Terminal = $false }
$deploymentClock = [Diagnostics.Stopwatch]::StartNew()
try {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $tags | Out-Null
    $subnet = New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix '10.0.0.0/24' -DefaultOutboundAccess $false
    $job = New-AzVirtualNetwork -Name "$ResourceGroupName-vnet" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix '10.0.0.0/16' -Subnet $subnet -AsJob
    $vnet = Wait-LabJob $job 'Create source network' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    # The host's attached Standard public IP provides explicit outbound connectivity.
    $job = New-AzPublicIpAddress -Name "$vmName-pip" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard -AsJob
    $pip = Wait-LabJob $job 'Create host public IP' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $rdp = New-AzNetworkSecurityRuleConfig -Name Allow-RDP -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix $AdminSourceCidr -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
    $job = New-AzNetworkSecurityGroup -Name "$vmName-nsg" -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rdp -AsJob
    $nsg = Wait-LabJob $job 'Create host firewall rules' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $job = New-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id -EnableAcceleratedNetworking:$hostSku.AcceleratedNetworking -AsJob
    $nic = Wait-LabJob $job 'Create host network interface' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $vm = New-AzVMConfig -VMName $vmName -VMSize $VMSize -SecurityType Standard
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $windowsImages.Host.Publisher -Offer $windowsImages.Host.Offer -Skus $windowsImages.Host.Sku -Version $windowsImages.Host.Version
    $vm = Set-AzVMOSDisk -VM $vm -Name "$vmName-osdisk" -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB 512
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    $job = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $tags -AsJob
    $null = Wait-LabJob $job 'Create Azure host' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $install = @'
$ErrorActionPreference = 'Stop'
$result = Install-WindowsFeature Hyper-V,DHCP -IncludeManagementTools
if (-not $result.Success) { throw 'Hyper-V installation failed.' }
Write-Output 'HYPERV_INSTALLED'
'@
    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString $install -AsJob
    $result = Wait-LabJob $job 'Install Hyper-V and DHCP' -TimeoutSeconds 1800 -HealthPath $HealthPath
    $null = Assert-LabRunResult $result 'HYPERV_INSTALLED'
    $job = Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -AsJob
    $null = Wait-LabJob $job 'Restart Azure host' -TimeoutSeconds 900 -HealthPath $HealthPath
    $ready = $false
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try {
            $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString "if ((Get-Service vmms).Status -ne 'Running') { throw 'Hyper-V not ready' }; Write-Output 'HYPERV_READY'" -AsJob
            $probe = Wait-LabJob $job 'Check Hyper-V readiness' -TimeoutSeconds 120 -HealthPath $HealthPath
            $null = Assert-LabRunResult $probe 'HYPERV_READY'
            $ready = $true; break
        } catch { Write-Host 'Waiting for the VM agent and Hyper-V service...' }
    }
    if (-not $ready) { throw 'Hyper-V host did not become ready.' }
    $job = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Disk $guestDiskConfig -AsJob
    $null = Wait-LabJob $job 'Create guest image disk' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $diskCreated = $true
    $access = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName -Access Read -DurationInSecond 18000
    $parameters = @(@{ Name = 'AdminUsername'; Value = $AdminUsername })
    $protected = @(@{ Name = 'AdminPassword'; Value = $passwordPlain }, @{ Name = 'WindowsVhdSasUrl'; Value = $access.AccessSAS })
    $runCreated = $true
    $job = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -Location $Location -RunCommandName $runName `
        -SourceScript $hostScript -Parameter $parameters -ProtectedParameter $protected -TimeoutInSecond ($GuestSetupTimeoutMinutes * 60) -AsyncExecution -AsJob
    $null = Wait-LabJob $job 'Submit guest setup' -TimeoutSeconds 900 -HealthPath $HealthPath
    $null = Wait-LabManagedSetup -ReadStatus {
        Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
    } -Observation $setupObservation -TimeoutSeconds (($GuestSetupTimeoutMinutes * 60) + 600) -HealthPath $HealthPath
    $setupPassed = $true
    Write-Host "Workload setup verified. Host public IP: $($pip.IpAddress). Host login: $AdminUsername."
    Write-Host 'Windows guests: Administrator and the supplied lab password. Linux guests: the supplied username/password.'
    Write-Host 'The MigrateAppl OS VM is prepared. Complete appliance installation and registration in docs/Module-1-Discovery.md.'
} catch {
    try {
        $lastHealth = Get-Content -LiteralPath $HealthPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($lastHealth.State -ne 'NeedsReview') {
            Write-LabHealth 'Source deployment' NeedsReview $deploymentClock.Elapsed.TotalSeconds "Deployment stopped after $($lastHealth.Stage). Inspect the terminal and Azure/host diagnostics before retrying." $HealthPath
        }
    } catch { Write-Warning 'Could not update the local health summary. Preserve the terminal error and inspect Azure directly.' }
    throw
} finally {
    $passwordPlain = $null
    $protected = $null
    if ($diskCreated -and (-not $runCreated -or $setupObservation.Terminal)) {
        try {
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName | Out-Null
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Force | Out-Null
        } catch { Write-Warning 'Temporary disk cleanup failed. Revoke its export access and remove WinServerBase-temp in the source resource group.' }
    } elseif ($diskCreated) {
        Write-Warning 'Setup termination is unconfirmed. WinServerBase-temp is retained so a running download is not interrupted. Its export access expires after five hours; revoke access and remove the disk after confirming ConfigureWorkshop has stopped.'
    }
    if ($runCreated -and $setupPassed) {
        try { Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName | Out-Null }
        catch { Write-Warning 'Managed Run Command removal failed. Inspect and remove ConfigureWorkshop from the host when it has stopped.' }
    } elseif ($runCreated) {
        Write-Warning 'ConfigureWorkshop is retained for failure diagnostics. Inspect its instance view and remove it after it has stopped.'
    }
}
