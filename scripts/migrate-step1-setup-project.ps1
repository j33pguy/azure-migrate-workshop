<#
.SYNOPSIS
Prepare dedicated target/test networks for the Hyper-V workshop.
.DESCRIPTION
Creates a target resource group, two unpeered VNets, and a NAT gateway/public
IP per VNet for explicit outbound access. Does not create an Azure Migrate
project: complete project creation in Module 1 so geography/tool initialization
come from the supported portal workflow. New target resource group only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SourceResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,60}$')][string]$TargetResourceGroup,
    [string]$Location = 'eastus'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$null = Assert-LabContext $SubscriptionId
$null = Assert-LabResourceGroup $SourceResourceGroup
if ($SourceResourceGroup -eq $TargetResourceGroup) { throw 'Source and target groups must be different.' }
if (Get-LabResourceGroup -Name $TargetResourceGroup -AllowMissing) { throw 'Use a new target resource group. Existing networks will not be overwritten.' }
$tags = @{ Workshop = 'TD-SYNNEX-CES-HyperV'; Team = 'Cloud Enablement Services'; Purpose = 'Training' }
New-AzResourceGroup -Name $TargetResourceGroup -Location $Location -Tag $tags | Out-Null
foreach ($network in @(@{Name='target';Prefix='10.1'},@{Name='test';Prefix='10.2'})) {
    $name = "$TargetResourceGroup-$($network.Name)"
    $pip = New-AzPublicIpAddress -Name "$name-egress" -ResourceGroupName $TargetResourceGroup -Location $Location -AllocationMethod Static -Sku Standard
    $nat = New-AzNatGateway -Name "$name-nat" -ResourceGroupName $TargetResourceGroup -Location $Location -Sku Standard -PublicIpAddress $pip -IdleTimeoutInMinutes 10
    # No public inbound management. Validate with Azure VM Run Command, or add
    # an instructor-approved Bastion deployment for interactive private access.
    $nsg = New-AzNetworkSecurityGroup -Name "$name-nsg" -ResourceGroupName $TargetResourceGroup -Location $Location
    $subnet = New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix "$($network.Prefix).0.0/24" -InputObject $nat -NetworkSecurityGroup $nsg -DefaultOutboundAccess $false
    $vnet = New-AzVirtualNetwork -Name "$name-vnet" -ResourceGroupName $TargetResourceGroup -Location $Location -AddressPrefix "$($network.Prefix).0.0/16" -Subnet $subnet
    Write-Host "$($network.Name) VNet: $($vnet.Name) / default"
}
Write-Host 'Target/test networks created with explicit egress. They have no peering to each other or the source.'
Write-Host 'Create the Azure Migrate project in the source resource group using docs/Module-1-Discovery.md.'
