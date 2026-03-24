<#
.SYNOPSIS
    Step 2: Deploy the Azure Migrate appliance and discover VMs.

.DESCRIPTION
    This script deploys the Azure Migrate appliance on the Hyper-V host,
    initiates discovery of the 4 on-premises VMs, and creates an assessment.

    IMPORTANT: Some steps require waiting for discovery to complete.
    The script will pause and prompt you to continue when manual steps
    are needed.

    What this script does:
    1. Retrieves the Hyper-V host connection info
    2. Generates an Azure Migrate appliance registration key
    3. Downloads and deploys the Azure Migrate appliance VHD on the Hyper-V host
    4. Guides you through the appliance configuration (manual browser step)
    5. Waits for discovery to complete and displays discovered servers
    6. Creates a migration assessment
    7. Displays assessment results (readiness, sizing, cost)

    Prerequisites:
    - Step 1 (migrate-step1-setup-project.ps1) must be completed
    - The Hyper-V host (HyperVHost) must be running
    - You need RDP or browser access to complete appliance configuration

.PARAMETER SourceResourceGroup
    The on-premises simulation resource group. Default: nazli-onprem

.PARAMETER TargetResourceGroup
    The target cloud resource group. Default: nazli-oncloud

.PARAMETER Location
    Azure region. Default: eastus

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project (from Step 1). Default: MigrateProject-Workshop

.PARAMETER HyperVHostVMName
    Name of the Hyper-V host Azure VM. Default: HyperVHost

.PARAMETER ApplianceVMName
    Name for the Azure Migrate appliance VM inside Hyper-V. Default: AzMigrateAppliance

.EXAMPLE
    .\migrate-step2-discover-assess.ps1

.EXAMPLE
    .\migrate-step2-discover-assess.ps1 -SourceResourceGroup "my-onprem" -MigrateProjectName "MyProject"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroup = "nazli-onprem",

    [Parameter(Mandatory = $false)]
    [string]$TargetResourceGroup = "nazli-oncloud",

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$MigrateProjectName = "MigrateProject-Workshop",

    [Parameter(Mandatory = $false)]
    [string]$HyperVHostVMName = "HyperVHost",

    [Parameter(Mandatory = $false)]
    [string]$ApplianceVMName = "AzMigrateAppliance"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
# Helper Functions
# ================================================================

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""
}

function Write-StepHeader {
    param([int]$Step, [string]$Title)
    Write-Host ""
    Write-Host "--- Step $Step`: $Title ---" -ForegroundColor Green
    Write-Host ""
}

function Write-ManualAction {
    param([string]$Title, [string[]]$Instructions)
    Write-Host ""
    Write-Host ("*" * 70) -ForegroundColor Red
    Write-Host "  MANUAL ACTION REQUIRED: $Title" -ForegroundColor Red
    Write-Host ("*" * 70) -ForegroundColor Red
    foreach ($instruction in $Instructions) {
        Write-Host "  $instruction" -ForegroundColor White
    }
    Write-Host ("*" * 70) -ForegroundColor Red
    Write-Host ""
}

function Write-NextSteps {
    param([string[]]$Steps)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host "  WHAT TO DO NEXT" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta
    foreach ($s in $Steps) {
        Write-Host "  -> $s" -ForegroundColor White
    }
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host ""
}

# ================================================================
Write-Section "Step 2: Discover & Assess On-Premises VMs"
# ================================================================

# ================================================================
# PRE-FLIGHT: Verify Prerequisites
# ================================================================

Write-StepHeader -Step 0 -Title "Pre-flight: Verify Prerequisites"

# Check Azure authentication
try {
    $context = Get-AzContext
    if (-not $context) { throw "Not logged in." }
    Write-Log "Authenticated as: $($context.Account.Id)"
} catch {
    throw "Azure authentication required. Run Connect-AzAccount first."
}

# Verify source resource group and Hyper-V host exist
$sourceRg = Get-AzResourceGroup -Name $SourceResourceGroup -ErrorAction SilentlyContinue
if (-not $sourceRg) {
    throw "Source resource group '$SourceResourceGroup' not found. Run deploy-lab.ps1 first."
}

# Verify target resource group exists (created in Step 1)
$targetRg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue
if (-not $targetRg) {
    throw "Target resource group '$TargetResourceGroup' not found. Run migrate-step1-setup-project.ps1 first."
}

# Verify the Hyper-V host VM is running
$hostVM = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -Status -ErrorAction SilentlyContinue
if (-not $hostVM) {
    throw "Hyper-V host VM '$HyperVHostVMName' not found in '$SourceResourceGroup'."
}
$vmStatus = ($hostVM.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
Write-Log "Hyper-V host VM status: $vmStatus"
if ($vmStatus -ne "VM running") {
    Write-Host "WARNING: Hyper-V host is not running. Starting it now..." -ForegroundColor Yellow
    Start-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -ErrorAction Stop
    Write-Log "Hyper-V host started."
}

# Ensure Az.Migrate module is loaded
$migrateModule = Get-Module -ListAvailable -Name Az.Migrate
if (-not $migrateModule) {
    Write-Log "Installing Az.Migrate module..."
    Install-Module -Name Az.Migrate -Force -AllowClobber -Scope CurrentUser
}
Import-Module Az.Migrate -ErrorAction SilentlyContinue

Write-Log "All prerequisites verified."

Read-Host "Press Enter to continue..."

# ================================================================
# STEP 1: Get Hyper-V Host Information
# ================================================================
# We need the Hyper-V host's public IP to:
# 1. Access the Azure Migrate appliance web UI (after deployment)
# 2. Run commands on the host via Invoke-AzVMRunCommand
#
# The public IP was assigned during lab deployment (deploy-lab.ps1).
# The Hyper-V host runs Windows Server 2022 with the Hyper-V role and
# contains 4 nested VMs simulating on-premises workloads.

Write-StepHeader -Step 1 -Title "Get Hyper-V Host Information"

try {
    # Find the public IP associated with the Hyper-V host
    # The PIP name follows the convention set in deploy-lab.ps1
    $pipName = "$HyperVHostVMName-pip"
    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

    Write-Log "Hyper-V Host Details:"
    Write-Host "  VM Name     : $HyperVHostVMName" -ForegroundColor White
    Write-Host "  Public IP   : $($pip.IpAddress)" -ForegroundColor White
    Write-Host "  RDP Access  : mstsc /v:$($pip.IpAddress)" -ForegroundColor White
    Write-Host ""

    # Store the IP for later use
    $hyperVHostIP = $pip.IpAddress

    # List the guest VMs currently running on the Hyper-V host
    # This confirms the on-premises environment is healthy before we start discovery
    Write-Log "Checking guest VMs on the Hyper-V host..."
    $guestVmResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $SourceResourceGroup `
        -VMName $HyperVHostVMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString "Get-VM | Select-Object Name, State, MemoryAssigned, ProcessorCount | Format-Table -AutoSize" `
        -ErrorAction Stop

    Write-Host "  Guest VMs on Hyper-V host:" -ForegroundColor White
    Write-Host $guestVmResult.Value[0].Message -ForegroundColor Gray

} catch {
    throw "Failed to get Hyper-V host information: $_"
}

Read-Host "Press Enter to continue to Step 2..."

# ================================================================
# STEP 2: Generate Appliance Registration Key
# ================================================================
# The Azure Migrate appliance needs a registration key to:
# 1. Authenticate itself with the Azure Migrate project
# 2. Establish a secure channel for sending discovery data
# 3. Associate discovered machines with the correct project
#
# The key is generated from the Azure Migrate project and is valid
# for a limited time. It's embedded in the appliance configuration
# during setup. Without this key, the appliance cannot communicate
# with Azure Migrate.

Write-StepHeader -Step 2 -Title "Generate Appliance Registration Key"

$applianceKeyName = "HyperVKey1"
$applianceKey = $null

try {
    Write-Log "Generating appliance registration key '$applianceKeyName'..."
    Write-Log "This key links the on-premises appliance to your Azure Migrate project."

    # Generate the key via the Az.Migrate cmdlet
    # The key is specific to the Hyper-V scenario (as opposed to VMware or physical)
    $keyResult = New-AzMigrateHyperVSiteApplianceKey `
        -SiteName "${MigrateProjectName}HyperVSite" `
        -ResourceGroupName $SourceResourceGroup `
        -ProjectName $MigrateProjectName `
        -KeyName $applianceKeyName `
        -ErrorAction Stop

    $applianceKey = $keyResult.Key
    Write-Log "Appliance registration key generated successfully."
    Write-Host ""
    Write-Host "  Registration Key (save this -- you'll need it during appliance setup):" -ForegroundColor White
    Write-Host "  $applianceKey" -ForegroundColor Green
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "NOTE: Could not generate key via PowerShell." -ForegroundColor Yellow
    Write-Host "This is normal if the Hyper-V site hasn't been created yet." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "MANUAL ALTERNATIVE -- Generate the key from the Azure portal:" -ForegroundColor Yellow
    Write-Host "  1. Go to: https://portal.azure.com" -ForegroundColor White
    Write-Host "  2. Navigate to: Azure Migrate > $MigrateProjectName" -ForegroundColor White
    Write-Host "  3. Under 'Servers, databases, and web apps', click 'Discover'" -ForegroundColor White
    Write-Host "  4. Select: 'Yes, with Hyper-V' for virtualization type" -ForegroundColor White
    Write-Host "  5. Name the appliance: $ApplianceVMName" -ForegroundColor White
    Write-Host "  6. Click 'Generate key' and copy the key" -ForegroundColor White
    Write-Host ""
    Write-Warning "Error details: $_"
    Write-Host ""
    $applianceKey = Read-Host "Paste the registration key here (or press Enter to skip)"
}

Read-Host "Press Enter to continue to Step 3..."

# ================================================================
# STEP 3: Download and Deploy Azure Migrate Appliance
# ================================================================
# The Azure Migrate appliance is a lightweight VM that runs on your
# Hyper-V host. It performs:
# - Agentless discovery of VMs (no agent installation needed on guests)
# - Performance data collection (CPU, memory, disk, network)
# - Dependency analysis (optional, agent-based)
# - Software inventory (installed applications, roles, features)
#
# The appliance is provided as a VHD that Microsoft publishes. We:
# 1. Download the VHD to the Hyper-V host
# 2. Create a Hyper-V VM from the VHD
# 3. Connect it to the internal switch (so it can discover guest VMs)
#    AND give it external connectivity (so it can communicate with Azure)
#
# Why TWO network connections?
# - Internal (intSwitch): The appliance must be on the same network as
#   the VMs it discovers (192.168.0.0/24). This is how it finds and
#   communicates with guest VMs via WMI/WinRM/SSH.
# - External: The appliance needs internet access to:
#   a) Register with Azure Migrate using the registration key
#   b) Upload discovery data to the Azure Migrate service
#   c) Download updates and configuration from Azure

Write-StepHeader -Step 3 -Title "Download and Deploy Azure Migrate Appliance"

Write-Log "This step deploys the Azure Migrate appliance VHD on the Hyper-V host."
Write-Log "This may take 15-30 minutes depending on download speed."
Write-Host ""

try {
    # The Azure Migrate appliance VHD URL for Hyper-V
    # This is the official Microsoft download link for the appliance
    $applianceVhdUrl = "https://aka.ms/migrate/appliance/hyperv"

    # Step 3a: Download the appliance VHD to the Hyper-V host
    # We use Invoke-AzVMRunCommand to run commands directly on the host VM.
    # This is equivalent to RDP-ing in and running commands manually.
    Write-Log "Step 3a: Downloading Azure Migrate appliance VHD to Hyper-V host..."
    Write-Log "This downloads a ~12GB compressed file. Please be patient."

    $downloadScript = @"
`$ErrorActionPreference = 'Stop'

# Create directory for the appliance
`$appDir = 'C:\AzMigrateAppliance'
if (-not (Test-Path `$appDir)) { New-Item -ItemType Directory -Path `$appDir -Force | Out-Null }

# Download the appliance ZIP file
# The URL redirects to a ZIP containing the VHD
`$zipPath = "`$appDir\AzMigrateAppliance.zip"
if (-not (Test-Path `$zipPath)) {
    Write-Output "Downloading Azure Migrate appliance from $applianceVhdUrl..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # Use BITS for reliable large file downloads (supports resume on failure)
    Start-BitsTransfer -Source '$applianceVhdUrl' -Destination `$zipPath -ErrorAction Stop
    Write-Output "Download complete: `$zipPath"
} else {
    Write-Output "Appliance ZIP already exists at `$zipPath"
}

# Extract the VHD from the ZIP
`$vhdDir = "`$appDir\VHD"
if (-not (Test-Path `$vhdDir)) {
    Write-Output "Extracting VHD from ZIP file..."
    Expand-Archive -Path `$zipPath -DestinationPath `$vhdDir -Force
    Write-Output "Extraction complete."
} else {
    Write-Output "VHD directory already exists."
}

# Find the VHD/VHDX file
`$vhdFile = Get-ChildItem -Path `$vhdDir -Recurse -Include *.vhdx,*.vhd | Select-Object -First 1
if (`$vhdFile) {
    Write-Output "VHD file found: `$(`$vhdFile.FullName)"
    Write-Output "VHD size: `$([math]::Round(`$vhdFile.Length / 1GB, 2)) GB"
} else {
    throw "No VHD/VHDX file found in extracted archive."
}
"@

    $downloadResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $SourceResourceGroup `
        -VMName $HyperVHostVMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString $downloadScript `
        -ErrorAction Stop

    Write-Host $downloadResult.Value[0].Message -ForegroundColor Gray
    if ($downloadResult.Value[1].Message) {
        Write-Host $downloadResult.Value[1].Message -ForegroundColor Yellow
    }

} catch {
    Write-Host ""
    Write-Host "WARNING: Automated download may have timed out or failed." -ForegroundColor Yellow
    Write-Host "This is common for large file downloads via Invoke-AzVMRunCommand." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "MANUAL ALTERNATIVE:" -ForegroundColor Yellow
    Write-Host "  1. RDP to the Hyper-V host: mstsc /v:$hyperVHostIP" -ForegroundColor White
    Write-Host "  2. Open a browser and download: $applianceVhdUrl" -ForegroundColor White
    Write-Host "  3. Extract the ZIP to C:\AzMigrateAppliance\VHD\" -ForegroundColor White
    Write-Host ""
    Write-Warning "Error: $_"
}

Read-Host "Press Enter once the VHD is downloaded and extracted..."

# Step 3b: Create the Hyper-V VM from the appliance VHD
Write-Log "Step 3b: Creating Hyper-V VM '$ApplianceVMName' from the appliance VHD..."

try {
    $createVmScript = @"
`$ErrorActionPreference = 'Stop'

`$vmName = '$ApplianceVMName'
`$appDir = 'C:\AzMigrateAppliance'
`$vmDir  = "`$appDir\VM"

# Check if the VM already exists
`$existingVM = Get-VM -Name `$vmName -ErrorAction SilentlyContinue
if (`$existingVM) {
    Write-Output "VM '`$vmName' already exists (State: `$(`$existingVM.State))."
    if (`$existingVM.State -ne 'Running') {
        Start-VM -Name `$vmName
        Write-Output "VM started."
    }
    # Get IP address
    Start-Sleep -Seconds 10
    `$vmIp = (Get-VMNetworkAdapter -VMName `$vmName | Select-Object -ExpandProperty IPAddresses | Where-Object { `$_ -match '^\d+\.\d+' }) -join ', '
    Write-Output "VM IP addresses: `$vmIp"
    return
}

# Find the extracted VHD file
`$vhdFile = Get-ChildItem -Path "`$appDir\VHD" -Recurse -Include *.vhdx,*.vhd | Select-Object -First 1
if (-not `$vhdFile) { throw "No VHD file found in `$appDir\VHD" }

# Copy VHD to the VM directory to avoid modifying the original
if (-not (Test-Path `$vmDir)) { New-Item -ItemType Directory -Path `$vmDir -Force | Out-Null }
`$targetVhd = "`$vmDir\`$vmName.vhdx"

if (-not (Test-Path `$targetVhd)) {
    Write-Output "Copying VHD to `$targetVhd..."
    Copy-Item -Path `$vhdFile.FullName -Destination `$targetVhd -Force
    Write-Output "VHD copied."
}

# Create the VM with sufficient resources for the appliance
# The appliance needs at least 8GB RAM and 4 vCPUs for smooth operation
Write-Output "Creating VM '`$vmName'..."
New-VM -Name `$vmName ``
    -MemoryStartupBytes 8GB ``
    -VHDPath `$targetVhd ``
    -Generation 2 ``
    -Path `$vmDir ``
    -ErrorAction Stop | Out-Null

# Configure VM settings
Set-VM -Name `$vmName ``
    -ProcessorCount 4 ``
    -DynamicMemory ``
    -MemoryMinimumBytes 4GB ``
    -MemoryMaximumBytes 8GB ``
    -ErrorAction Stop

# Connect to the internal switch (intSwitch) for guest VM discovery
# This puts the appliance on the same 192.168.0.0/24 network as the guest VMs
Write-Output "Connecting VM to internal switch 'intSwitch'..."
Get-VMNetworkAdapter -VMName `$vmName | Connect-VMNetworkAdapter -SwitchName "intSwitch" -ErrorAction Stop

# Add a second NIC connected to the external/default switch for internet access
# The appliance needs internet to register with Azure Migrate and upload data
Write-Output "Adding external network adapter for internet connectivity..."
`$extSwitch = Get-VMSwitch | Where-Object { `$_.SwitchType -eq 'External' } | Select-Object -First 1
if (`$extSwitch) {
    Add-VMNetworkAdapter -VMName `$vmName -SwitchName `$extSwitch.Name -ErrorAction Stop
    Write-Output "Connected to external switch: `$(`$extSwitch.Name)"
} else {
    # Fall back to Default Switch if no external switch exists
    `$defaultSwitch = Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue
    if (`$defaultSwitch) {
        Add-VMNetworkAdapter -VMName `$vmName -SwitchName "Default Switch" -ErrorAction Stop
        Write-Output "Connected to Default Switch for internet access."
    } else {
        Write-Output "WARNING: No external/default switch found. The appliance may not have internet access."
        Write-Output "You will need to manually configure networking after the VM starts."
    }
}

# Disable Secure Boot to allow the appliance VHD to boot
# (The Microsoft-signed appliance VHD may not be compatible with Secure Boot in nested Hyper-V)
Set-VMFirmware -VMName `$vmName -EnableSecureBoot Off -ErrorAction SilentlyContinue

# Start the VM
Write-Output "Starting VM '`$vmName'..."
Start-VM -Name `$vmName -ErrorAction Stop
Write-Output "VM started. Waiting for boot..."

# Wait for the VM to get an IP address
Start-Sleep -Seconds 30
`$vmIp = (Get-VMNetworkAdapter -VMName `$vmName | Select-Object -ExpandProperty IPAddresses | Where-Object { `$_ -match '^\d+\.\d+' }) -join ', '
Write-Output "VM '`$vmName' is running."
Write-Output "VM IP addresses: `$vmIp"
"@

    $createResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $SourceResourceGroup `
        -VMName $HyperVHostVMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString $createVmScript `
        -ErrorAction Stop

    Write-Host $createResult.Value[0].Message -ForegroundColor Gray
    if ($createResult.Value[1].Message) {
        Write-Host $createResult.Value[1].Message -ForegroundColor Yellow
    }

} catch {
    Write-Host ""
    Write-Host "WARNING: Automated VM creation may have failed." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "MANUAL ALTERNATIVE (via RDP to Hyper-V host):" -ForegroundColor Yellow
    Write-Host "  1. RDP to: mstsc /v:$hyperVHostIP" -ForegroundColor White
    Write-Host "  2. Open Hyper-V Manager" -ForegroundColor White
    Write-Host "  3. Click 'Import Virtual Machine' or create a new VM from the VHD" -ForegroundColor White
    Write-Host "  4. Assign 8GB RAM, 4 vCPUs" -ForegroundColor White
    Write-Host "  5. Connect NIC 1 to 'intSwitch' (for discovery)" -ForegroundColor White
    Write-Host "  6. Connect NIC 2 to external/Default Switch (for internet)" -ForegroundColor White
    Write-Host "  7. Start the VM" -ForegroundColor White
    Write-Host ""
    Write-Warning "Error: $_"
}

Read-Host "Press Enter once the appliance VM is running..."

# ================================================================
# STEP 4: Configure the Azure Migrate Appliance (Manual Browser Step)
# ================================================================
# The Azure Migrate appliance has a web-based configuration portal
# that runs on port 44368. You access it from a browser on the
# Hyper-V host (via RDP) to complete the initial setup.
#
# Why is this a manual step?
# The appliance configuration wizard handles:
# - Accepting license terms
# - Setting up auto-updates
# - Registering with Azure (using the key from Step 2)
# - Configuring Hyper-V host credentials for discovery
# - Starting the discovery process
#
# These steps involve interactive web forms with authentication flows
# that cannot be easily automated via PowerShell.

Write-StepHeader -Step 4 -Title "Configure Azure Migrate Appliance (Manual Step)"

# Get the appliance IP from the Hyper-V host
try {
    $ipResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $SourceResourceGroup `
        -VMName $HyperVHostVMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString "Get-VMNetworkAdapter -VMName '$ApplianceVMName' | Select-Object -ExpandProperty IPAddresses" `
        -ErrorAction Stop

    $applianceIPs = $ipResult.Value[0].Message.Trim()
    Write-Log "Appliance VM IP addresses: $applianceIPs"
} catch {
    $applianceIPs = "(could not determine -- check Hyper-V Manager)"
    Write-Warning "Could not retrieve appliance IP: $_"
}

Write-ManualAction -Title "Configure the appliance via browser" -Instructions @(
    ""
    "1. RDP into the Hyper-V host:"
    "   mstsc /v:$hyperVHostIP"
    ""
    "2. Open a browser on the Hyper-V host and navigate to:"
    "   https://<appliance-ip>:44368"
    "   `(Appliance IPs detected: $applianceIPs`)"
    ""
    "3. In the appliance configuration wizard, complete these steps:"
    ""
    "   a) Accept license terms and read the privacy statement"
    ""
    "   b) Set up prerequisites:"
    "      - The wizard checks internet connectivity, time sync, and updates"
    "      - Allow auto-updates if prompted"
    ""
    "   c) Register with Azure Migrate:"
    "      - Paste the registration key from Step 2:"
    "        $applianceKey"
    "      - Log in with your Azure credentials when prompted"
    ""
    "   d) Add Hyper-V host credentials:"
    "      - Click 'Add credentials'"
    "      - Type: Hyper-V host / Cluster"
    "      - Friendly name: HyperVHostCreds"
    "      - Username: (the admin username you used in deploy-lab.ps1)"
    "      - Password: (the admin password you used in deploy-lab.ps1)"
    ""
    "   e) Add the Hyper-V host for discovery:"
    "      - Click 'Add discovery source'"
    "      - Select 'Hyper-V host / Cluster'"
    "      - IP address: 192.168.0.1 (the host's internal IP)"
    "        OR use the host's actual hostname"
    "      - Select the credentials you just added"
    "      - Click 'Validate' and wait for success"
    ""
    "   f) Start discovery:"
    "      - Click 'Start discovery'"
    "      - Discovery takes 5-15 minutes for 4 VMs"
    ""
    "4. Wait for the discovery to show all 4 VMs in the portal:"
    "   - OnPrem-Web"
    "   - OnPrem-SQL"
    "   - OnPrem-Linux-Web"
    "   - OnPrem-Linux-App"
    ""
)

Read-Host "Press Enter AFTER you have completed the appliance configuration and discovery has started..."

# ================================================================
# STEP 5: Wait for Discovery and List Discovered Servers
# ================================================================
# After starting discovery from the appliance web UI, the appliance
# begins collecting information about VMs on the Hyper-V host:
# - VM names, IPs, OS details
# - CPU, memory, disk configuration
# - Running processes and network connections (if dependency analysis is enabled)
#
# Discovery data is uploaded to Azure Migrate every few minutes.
# We poll the Azure Migrate service to check when all 4 VMs appear.
#
# In production migrations with hundreds of VMs, discovery can take
# hours. For our 4-VM lab, it typically completes in 5-15 minutes.

Write-StepHeader -Step 5 -Title "Wait for Discovery to Complete"

$expectedVMs = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App")
$discoveryComplete = $false
$maxAttempts = 30  # Poll for up to 15 minutes (30 x 30 seconds)
$attempt = 0

Write-Log "Polling Azure Migrate for discovered servers..."
Write-Log "Looking for $($expectedVMs.Count) VMs: $($expectedVMs -join ', ')"
Write-Log "This may take 5-15 minutes. Polling every 30 seconds."
Write-Host ""

while (-not $discoveryComplete -and $attempt -lt $maxAttempts) {
    $attempt++
    try {
        # Query Azure Migrate for discovered servers
        # The discovered servers are stored in the Hyper-V site associated
        # with the Azure Migrate project
        $discoveredServers = Get-AzMigrateDiscoveredServer `
            -ProjectName $MigrateProjectName `
            -ResourceGroupName $SourceResourceGroup `
            -ErrorAction Stop

        $discoveredCount = 0
        if ($discoveredServers) {
            $discoveredCount = @($discoveredServers).Count
        }

        Write-Log "  Attempt $attempt/$maxAttempts -- Discovered $discoveredCount server`(s`) so far..."

        if ($discoveredCount -ge $expectedVMs.Count) {
            $discoveryComplete = $true
            Write-Log "All expected VMs discovered!"
        } else {
            Start-Sleep -Seconds 30
        }
    } catch {
        Write-Log "  Attempt $attempt -- Waiting for discovery data... `($($_.Exception.Message)`)"
        Start-Sleep -Seconds 30
    }
}

if ($discoveryComplete) {
    Write-Host ""
    Write-Host "  Discovered Servers:" -ForegroundColor White
    Write-Host "  ==================" -ForegroundColor White

    foreach ($server in $discoveredServers) {
        $osType = if ($server.OperatingSystemDetailOSType) { $server.OperatingSystemDetailOSType } else { "Unknown" }
        $osName = if ($server.OperatingSystemDetailOSName) { $server.OperatingSystemDetailOSName } else { "Unknown" }
        $cores  = if ($server.NumberOfProcessorCore) { $server.NumberOfProcessorCore } else { "?" }
        $memMB  = if ($server.AllocatedMemoryInMb) { $server.AllocatedMemoryInMb } else { "?" }

        Write-Host "  Name    : $($server.DisplayName)" -ForegroundColor Green
        Write-Host "  OS      : $osName `($osType`)" -ForegroundColor Gray
        Write-Host "  Cores   : $cores" -ForegroundColor Gray
        Write-Host "  Memory  : ${memMB} MB" -ForegroundColor Gray
        Write-Host "  ---" -ForegroundColor Gray
    }
} else {
    Write-Host ""
    Write-Host "Discovery has not completed yet." -ForegroundColor Yellow
    Write-Host "This is normal -- you can check progress in the Azure portal:" -ForegroundColor Yellow
    Write-Host "  Azure Migrate > $MigrateProjectName > Discovered servers" -ForegroundColor White
    Write-Host ""
    Write-Host "You can re-run this script later, or continue and create the assessment" -ForegroundColor Yellow
    Write-Host "manually in the portal once discovery completes." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to continue anyway..."
}

Read-Host "Press Enter to continue to Step 6..."

# ================================================================
# STEP 6: Create Migration Assessment
# ================================================================
# An assessment evaluates your discovered VMs and provides:
# - **Azure readiness**: Can this VM run in Azure as-is, or are there
#   compatibility issues (unsupported OS, boot type, disk config)?
# - **VM sizing**: Recommended Azure VM size based on current CPU/memory
#   utilization (right-sizing to avoid over-provisioning)
# - **Cost estimation**: Monthly cost estimate for running the VMs in Azure
#   including compute, storage, and networking costs
# - **Risk identification**: Potential migration blockers or warnings
#
# Assessments use the performance data collected by the appliance. For
# the most accurate sizing, let the appliance collect data for at least
# 24 hours. For this workshop, we use "as on-premises" sizing which
# maps VMs 1:1 to equivalent Azure VM sizes.

Write-StepHeader -Step 6 -Title "Create Migration Assessment"

$assessmentName = "Workshop-Assessment"

try {
    Write-Log "Creating assessment '$assessmentName'..."
    Write-Log "Assessment type: Azure VM (IaaS) -- for lift-and-shift migration"

    # The assessment needs a group of servers to evaluate.
    # We create a group containing all discovered VMs.
    $groupName = "AllServers-Group"

    # Attempt to create assessment via REST API since the PowerShell cmdlet
    # may not be available in all Az.Migrate module versions
    $subscriptionId = $context.Subscription.Id
    $apiVersion = "2023-03-15"

    # Build the assessment group with all discovered machines
    if ($discoveredServers) {
        $machineIds = @()
        foreach ($server in $discoveredServers) {
            if ($server.Id) {
                $machineIds += $server.Id
            }
        }

        Write-Log "Creating server group '$groupName' with $($machineIds.Count) machines..."

        # Create the group via REST API
        $groupUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Migrate/assessmentProjects/$MigrateProjectName/groups/${groupName}?api-version=$apiVersion"

        $groupBody = @{
            properties = @{
                machines = $machineIds
            }
        } | ConvertTo-Json -Depth 5

        try {
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            }
            $groupResponse = Invoke-RestMethod -Uri $groupUri -Method Put -Body $groupBody -Headers $headers -ErrorAction Stop
            Write-Log "Server group '$groupName' created."
        } catch {
            Write-Warning "Could not create group via REST API: $_"
        }

        # Create the assessment
        Write-Log "Creating assessment '$assessmentName'..."

        $assessmentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Migrate/assessmentProjects/$MigrateProjectName/groups/$groupName/assessments/${assessmentName}?api-version=$apiVersion"

        $assessmentBody = @{
            properties = @{
                # "AsOnPremises" uses the current VM sizes to find equivalent Azure sizes
                # "PerformanceBased" would use actual utilization data for right-sizing
                sizingCriterion     = "AsOnPremises"
                azureLocation       = $Location
                currency            = "USD"
                # Reserved instances can reduce costs by 30-72% for 1-3 year commitments
                reservedInstance    = "None"
                azureOfferCode      = "MS-AZR-0003P"  # Pay-As-You-Go
                azureHybridUseBenefit = "No"
            }
        } | ConvertTo-Json -Depth 5

        try {
            $assessmentResponse = Invoke-RestMethod -Uri $assessmentUri -Method Put -Body $assessmentBody -Headers $headers -ErrorAction Stop
            Write-Log "Assessment '$assessmentName' created successfully."
        } catch {
            Write-Warning "Could not create assessment via REST API: $_"
        }
    }

} catch {
    Write-Host ""
    Write-Host "NOTE: Assessment creation requires discovered servers." -ForegroundColor Yellow
    Write-Host "If discovery hasn't completed, create the assessment manually:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "MANUAL ALTERNATIVE:" -ForegroundColor Yellow
    Write-Host "  1. Go to Azure portal > Azure Migrate > $MigrateProjectName" -ForegroundColor White
    Write-Host "  2. Under 'Assessment tools', click 'Assess' > 'Azure VM'" -ForegroundColor White
    Write-Host "  3. Assessment settings:" -ForegroundColor White
    Write-Host "     - Target location: $Location" -ForegroundColor White
    Write-Host "     - Sizing criterion: As on-premises" -ForegroundColor White
    Write-Host "     - VM series: Include all" -ForegroundColor White
    Write-Host "     - Pricing: Pay-As-You-Go" -ForegroundColor White
    Write-Host "  4. Select all 4 discovered servers" -ForegroundColor White
    Write-Host "  5. Create the assessment and wait for it to complete" -ForegroundColor White
    Write-Host ""
    Write-Warning "Error details: $_"
}

Read-Host "Press Enter to continue to Step 7..."

# ================================================================
# STEP 7: Display Assessment Results
# ================================================================
# The assessment takes a few minutes to compute. Once complete, it
# provides detailed information about each VM's readiness for Azure.
# This is critical decision-making data for a real migration:
# - Are there any blockers? (e.g., unsupported OS, incompatible boot type)
# - What Azure VM size should each VM use?
# - What will it cost monthly?

Write-StepHeader -Step 7 -Title "Display Assessment Results"

try {
    Write-Log "Retrieving assessment results..."
    Write-Log "(Assessment computation may take 2-5 minutes after creation)"

    # Poll for assessment status
    $assessmentReady = $false
    $assessAttempts = 0
    $maxAssessAttempts = 10

    while (-not $assessmentReady -and $assessAttempts -lt $maxAssessAttempts) {
        $assessAttempts++
        try {
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            }

            $assessResultUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Migrate/assessmentProjects/$MigrateProjectName/groups/$groupName/assessments/${assessmentName}/assessedMachines?api-version=$apiVersion"

            $assessedMachines = Invoke-RestMethod -Uri $assessResultUri -Method Get -Headers $headers -ErrorAction Stop

            if ($assessedMachines.value -and $assessedMachines.value.Count -gt 0) {
                $assessmentReady = $true

                Write-Host ""
                Write-Host "  Assessment Results: $assessmentName" -ForegroundColor White
                Write-Host "  ========================================" -ForegroundColor White
                Write-Host ""

                foreach ($machine in $assessedMachines.value) {
                    $props = $machine.properties
                    $readiness = if ($props.suitability) { $props.suitability } else { "Unknown" }
                    $readinessColor = if ($readiness -eq "Suitable") { "Green" } elseif ($readiness -eq "ConditionallySuitable") { "Yellow" } else { "Red" }

                    Write-Host "  VM: $($props.displayName)" -ForegroundColor White
                    Write-Host "    Readiness       : $readiness" -ForegroundColor $readinessColor
                    Write-Host "    Recommended Size: $($props.recommendedSize)" -ForegroundColor Gray
                    Write-Host "    Monthly Cost    : `$$($props.monthlyComputeCostForRecommendedSize) `(compute`)" -ForegroundColor Gray
                    Write-Host "    OS              : $($props.operatingSystemName)" -ForegroundColor Gray
                    Write-Host "    Boot Type       : $($props.bootType)" -ForegroundColor Gray
                    Write-Host ""
                }
            } else {
                Write-Log "  Attempt $assessAttempts/$maxAssessAttempts -- Assessment still computing..."
                Start-Sleep -Seconds 30
            }
        } catch {
            Write-Log "  Attempt $assessAttempts -- Waiting for assessment results..."
            Start-Sleep -Seconds 30
        }
    }

    if (-not $assessmentReady) {
        Write-Host ""
        Write-Host "Assessment results are not yet available." -ForegroundColor Yellow
        Write-Host "Check results in the Azure portal:" -ForegroundColor Yellow
        Write-Host "  Azure Migrate > $MigrateProjectName > Assessments > $assessmentName" -ForegroundColor White
    }

} catch {
    Write-Host ""
    Write-Host "Could not retrieve assessment results programmatically." -ForegroundColor Yellow
    Write-Host "Check results in the Azure portal:" -ForegroundColor Yellow
    Write-Host "  Azure Migrate > $MigrateProjectName > Assessments" -ForegroundColor White
    Write-Warning "Error: $_"
}

# ================================================================
# SUMMARY & NEXT STEPS
# ================================================================

Write-Section "STEP 2 COMPLETE -- Summary"

Write-Host "  What was accomplished:" -ForegroundColor White
Write-Host "  [+] Hyper-V host connection verified" -ForegroundColor Green
Write-Host "  [+] Azure Migrate appliance registration key generated" -ForegroundColor Green
Write-Host "  [+] Azure Migrate appliance deployed on Hyper-V host" -ForegroundColor Green
Write-Host "  [+] Appliance configured and discovery initiated" -ForegroundColor Green
Write-Host "  [+] Discovered servers listed" -ForegroundColor Green
Write-Host "  [+] Migration assessment created" -ForegroundColor Green
Write-Host ""
Write-Host "  VMs Discovered:" -ForegroundColor White
Write-Host "  - OnPrem-Web       (192.168.0.10) -- Windows + IIS" -ForegroundColor Cyan
Write-Host "  - OnPrem-SQL       (192.168.0.11) -- Windows + SQL Server 2022 Express" -ForegroundColor Cyan
Write-Host "  - OnPrem-Linux-Web (192.168.0.12) -- Ubuntu 22.04 + Nginx" -ForegroundColor Cyan
Write-Host "  - OnPrem-Linux-App (192.168.0.13) -- Ubuntu 22.04 + Node.js" -ForegroundColor Cyan

Write-NextSteps @(
    "Review the assessment results in the Azure portal"
    "Note any readiness issues or warnings for each VM"
    "Run Step 3: .\migrate-step3-replicate.ps1"
    "Step 3 will enable replication for all 4 VMs and begin migration"
)

Write-Log "Step 2 finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
