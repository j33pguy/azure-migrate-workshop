# Runs as SYSTEM on the Windows Hyper-V host through managed Run Command.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdminUsername,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$WindowsVhdSasUrl,
    [string]$WorkshopTitle = 'TD SYNNEX - Cloud Enablement Services'
)
try {
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------- Logging ----------
$labRoot = "C:\AzMigrateLab"
$logFile = "$labRoot\setup-log.txt"
New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
if (Test-Path "$labRoot\setup-complete.json") {
    throw 'This host has already been provisioned. Use validation, not deployment, after migration starts.'
}
# This directory contains unattended setup material; limit it to local administrators and SYSTEM.
& icacls.exe $labRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict setup directory permissions.' }

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
}

function Expand-LabTextTemplate {
    param([string]$Template, [System.Collections.IDictionary]$Values)
    # Replace only tokens present in the template. Never interpret inserted
    # passwords as more template tokens, PowerShell, or regex replacements.
    return [regex]::Replace($Template, '__[A-Z][A-Z0-9_]*__', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if (-not $Values.Contains($match.Value)) { throw "Missing template value: $($match.Value)" }
        return [string]$Values[$match.Value]
    })
}

function Assert-LabSourceWorkloads {
    foreach ($address in @('http://192.168.0.10','http://192.168.0.12')) {
        $page = Invoke-WebRequest $address -UseBasicParsing -TimeoutSec 10
        if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'TD SYNNEX') {
            throw "Workshop sample site missing at $address."
        }
    }
    $api = Invoke-RestMethod 'http://192.168.0.13:3000/api/health' -TimeoutSec 10
    if ($api.status -ne 'healthy' -or $api.server -ne 'OnPrem-Linux-App') { throw 'Node API unhealthy or wrong application.' }
    if (-not (Test-NetConnection 192.168.0.11 -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw 'SQL TCP listener unavailable.'
    }
}

$vhdPath       = "$labRoot\VHDs"
$intSwitchName = "intSwitch"
$natName       = "LabNAT"
$natPrefix     = "192.168.0.0/24"
$hostIp        = "192.168.0.1"
$guestAdminPwd = $AdminPassword
$guestUser = $AdminUsername
$windowsVhdSasUrl = $WindowsVhdSasUrl

New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null

# =============================================================
# PHASE 1 — Virtual networking
# =============================================================
Write-Log "PHASE 1: Configuring virtual networking..."

$existingSwitch = Get-VMSwitch -Name $intSwitchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    Write-Log "Virtual switch '$intSwitchName' already exists."
} else {
    New-VMSwitch -SwitchType Internal -Name $intSwitchName -ErrorAction Stop | Out-Null
    Write-Log "Created internal switch '$intSwitchName'."
}

$adapter = Get-NetAdapter -Name "vEthernet ($intSwitchName)" -ErrorAction Stop
if ($adapter) {
    $existingIp = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $hostIp }
    if (-not $existingIp) {
        New-NetIPAddress -IPAddress $hostIp -PrefixLength 24 -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Out-Null
        Write-Log "Assigned $hostIp to host adapter."
    } else {
        Write-Log "Host adapter already has IP $hostIp."
    }
} else {
    throw "Could not find adapter for switch '$intSwitchName'."
}

$existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
if ($existingNat) {
    Write-Log "NAT '$natName' already exists."
} else {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $natPrefix -ErrorAction Stop | Out-Null
    Write-Log "Created NAT '$natName' with prefix $natPrefix."
}

# The internal NAT has no DHCP service of its own. Provide DHCP on intSwitch
# so guest OS NICs already use DHCP when copied into an Azure VNet.
Add-DhcpServerSecurityGroup -ErrorAction Stop
foreach ($binding in Get-DhcpServerv4Binding) {
    Set-DhcpServerv4Binding -InterfaceAlias $binding.InterfaceAlias -BindingState ($binding.InterfaceAlias -eq "vEthernet ($intSwitchName)")
}
if (-not (Get-DhcpServerv4Scope -ScopeId 192.168.0.0 -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name Workshop -StartRange 192.168.0.10 -EndRange 192.168.0.200 -SubnetMask 255.255.255.0 -State Active | Out-Null
}
Set-DhcpServerv4OptionValue -ScopeId 192.168.0.0 -Router 192.168.0.1 -DnsServer 1.1.1.1,8.8.8.8
Restart-Service DHCPServer
function Set-LabReservation {
    param([string]$VMName,[string]$IPAddress)
    $mac = '00155D0000' + ([int]($IPAddress.Split('.')[-1])).ToString('X2')
    Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $mac
    if (-not (Get-DhcpServerv4Reservation -ScopeId 192.168.0.0 | Where-Object IPAddress -EQ $IPAddress)) {
        Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress $IPAddress -ClientId ($mac -replace '(..)(?!$)', '$1-') -Name $VMName | Out-Null
    }
}

# =============================================================
# PHASE 2 — Download OS images
# =============================================================
Write-Log "PHASE 2: Downloading OS images..."

# Install Windows ADK Deployment Tools (provides oscdimg.exe for cloud-init ISO creation)
$oscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
if (-not (Test-Path $oscdimgPath)) {
    Write-Log "Installing Windows ADK Deployment Tools (for oscdimg)..."
    $adkInstaller = "$labRoot\adksetup.exe"
    $adkUrl = "https://go.microsoft.com/fwlink/?linkid=2243390"
    Invoke-WebRequest -Uri $adkUrl -OutFile $adkInstaller -UseBasicParsing -ErrorAction Stop
    $signature = Get-AuthenticodeSignature $adkInstaller
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'ADK signature validation failed.' }
    $process = Start-Process -FilePath $adkInstaller -ArgumentList "/quiet /norestart /features OptionId.DeploymentTools" -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -notin @(0,3010) -or -not (Test-Path $oscdimgPath)) { throw 'ADK Deployment Tools installation failed.' }
    Write-Log "Windows ADK Deployment Tools installed."
} else {
    Write-Log "Windows ADK Deployment Tools already installed."
}

$ubuntuCloudUrl = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
$ubuntuQcow2    = "$vhdPath\Ubuntu2204-cloudimg.img"
$ubuntuBaseVhd  = "$vhdPath\Ubuntu2204-Base.vhdx"

$windowsBaseVhd = "$vhdPath\WindowsServer2022-Base.vhdx"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Install qemu-img (needed for image conversion) --
$qemuImg = "C:\Program Files\qemu\qemu-img.exe"
if (-not (Test-Path $qemuImg)) {
    $qemuImg = (Get-ChildItem "C:\ProgramData\chocolatey" -Recurse -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
}
if (-not $qemuImg -or -not (Test-Path $qemuImg)) {
    Write-Log "Installing qemu-img via Chocolatey..."
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
    choco install qemu --no-progress -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "QEMU installation failed." }
    $qemuImg = (Get-ChildItem "C:\Program Files\qemu" -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
    if (-not $qemuImg) {
        $qemuImg = (Get-ChildItem "C:\ProgramData\chocolatey" -Recurse -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
    }
    if (-not $qemuImg) { throw "qemu-img.exe not found after installation." }
}
Write-Log "qemu-img available at: $qemuImg"

# -- Ubuntu cloud image (download QCOW2, convert to VHDX via qemu-img) --
if (-not (Test-Path $ubuntuBaseVhd)) {
    # Download Ubuntu QCOW2 cloud image
    if (Test-Path $ubuntuQcow2) { Remove-Item $ubuntuQcow2 -Force }
    if (-not (Test-Path $ubuntuQcow2)) {
        Write-Log "Downloading Ubuntu 22.04 cloud image (QCOW2 format, ~600MB)..."
        try {
            Start-BitsTransfer -Source $ubuntuCloudUrl -Destination $ubuntuQcow2 -ErrorAction Stop
        } catch {
            Write-Log "BITS transfer failed, falling back to Invoke-WebRequest..."
            Invoke-WebRequest -Uri $ubuntuCloudUrl -OutFile $ubuntuQcow2 -UseBasicParsing -ErrorAction Stop
        }
        $hashPath = "$vhdPath\SHA256SUMS"
        Invoke-WebRequest -Uri 'https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS' -OutFile $hashPath -UseBasicParsing
        $hashLine = Get-Content $hashPath | Where-Object { $_ -match ' [ *]?jammy-server-cloudimg-amd64.img$' }
        if (@($hashLine).Count -ne 1) { throw 'Cannot identify Ubuntu image checksum; retry if the current image changed.' }
        $expectedHash = ($hashLine -split '\s+')[0]
        if ((Get-FileHash $ubuntuQcow2 -Algorithm SHA256).Hash -ne $expectedHash) { Remove-Item $ubuntuQcow2 -Force; throw 'Ubuntu image checksum mismatch.' }
        Write-Log "Ubuntu cloud image downloaded and SHA256 verified."
    }

    # Convert QCOW2 to VHDX using qemu-img
    Write-Log "Converting Ubuntu QCOW2 to VHDX (this may take a few minutes)..."
    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic "$ubuntuQcow2" "$ubuntuBaseVhd" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "qemu-img conversion failed with exit code $LASTEXITCODE"
    }
    # Remove sparse file attribute (required by Hyper-V for differencing disks)
    fsutil sparse setflag "$ubuntuBaseVhd" 0
    Write-Log "Ubuntu base VHDX created."

    # Cleanup downloaded QCOW2
    Remove-Item -Path $ubuntuQcow2 -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "Ubuntu base VHDX already exists."
}

# -- Windows Server 2022 base VHDX (downloaded from Azure marketplace managed disk via SAS) --
if (-not (Test-Path $windowsBaseVhd)) {
    if ([string]::IsNullOrWhiteSpace($windowsVhdSasUrl)) {
        throw "Windows VHD SAS URL not provided. Cannot create Windows guest VMs."
    }

    $windowsVhdTemp = "$vhdPath\WindowsServer2022-temp.vhd"
    if (Test-Path $windowsVhdTemp) { Remove-Item $windowsVhdTemp -Force }
    if (-not (Test-Path $windowsVhdTemp)) {
        Remove-Item -Path $windowsVhdTemp -Force -ErrorAction SilentlyContinue
        Write-Log "Downloading Windows Server 2022 VHD from Azure marketplace disk (intra-Azure, fast)..."
        # Install azcopy for reliable large file downloads
        $azcopy = (Get-ChildItem "$labRoot\azcopy" -Recurse -Filter "azcopy.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
        if (-not $azcopy) {
            Write-Log "Installing azcopy..."
            Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile "$labRoot\azcopy.zip" -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path "$labRoot\azcopy.zip" -DestinationPath "$labRoot\azcopy" -Force
            $azcopy = (Get-ChildItem "$labRoot\azcopy" -Recurse -Filter "azcopy.exe" | Select-Object -First 1) | Select-Object -ExpandProperty FullName
            Write-Log "azcopy installed at: $azcopy"
        }
            & $azcopy copy $windowsVhdSasUrl $windowsVhdTemp --check-md5 NoCheck --log-level NONE --output-level quiet
        if ($LASTEXITCODE -ne 0) { Remove-Item $windowsVhdTemp -Force -ErrorAction SilentlyContinue; throw 'Windows disk download failed.' }
        if (-not (Test-Path $windowsVhdTemp) -or (Get-Item $windowsVhdTemp).Length -lt 1GB) {
            throw "azcopy download failed or file is too small."
        }
        Write-Log "Windows Server VHD downloaded ($([math]::Round((Get-Item $windowsVhdTemp).Length/1GB, 1)) GB)."
    }

    Convert-VHD -Path $windowsVhdTemp -DestinationPath $windowsBaseVhd -VHDType Dynamic -ErrorAction Stop
    Write-Log 'Windows Server base VHDX created.'

    # Cleanup temp VHD
    Remove-Item -Path $windowsVhdTemp -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "Windows Server base VHDX already exists."
}

# =============================================================
# PHASE 3 — Create guest VMs
# =============================================================
Write-Log "PHASE 3: Creating guest VMs..."

# --- Helper: Create-WindowsGuestVM ---
function Create-WindowsGuestVM {
    param(
        [string]$VMName, [string]$IPAddress,
        [int]$MemoryMB = 4096, [int]$CPUs = 2, [int]$DiskGB = 40
    )

    $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existingVM) { throw "VM $VMName already exists. Use a fresh lab; do not replay guest provisioning." }

    Write-Log "Creating Windows VM '$VMName'..."

    $vmVhdPath = "$vhdPath\$VMName.vhdx"
    if (-not (Test-Path $vmVhdPath)) {
        Convert-VHD -Path $windowsBaseVhd -DestinationPath $vmVhdPath -VHDType Dynamic -ErrorAction Stop
        Resize-VHD -Path $vmVhdPath -SizeBytes ($DiskGB * 1GB)
    }

    # Generate unattend.xml
    $unattendDir = "$labRoot\Unattend\$VMName"
    New-Item -ItemType Directory -Path $unattendDir -Force | Out-Null

    $unattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>__VMNAME__</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>__PASSWORD__</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
'@
    $unattendXml = Expand-LabTextTemplate $unattendXml @{
        '__VMNAME__' = $VMName
        '__PASSWORD__' = [System.Security.SecurityElement]::Escape($guestAdminPwd)
    }
    $null = [xml]$unattendXml
    $unattendXml | Out-File -FilePath "$unattendDir\unattend.xml" -Encoding UTF8 -Force

    $vmDir = "$labRoot\VMs\$VMName"
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    New-VM -Name $VMName -MemoryStartupBytes ($MemoryMB * 1MB) -VHDPath $vmVhdPath `
        -SwitchName $intSwitchName -Path $vmDir -Generation 2 -ErrorAction Stop | Out-Null
    Set-LabReservation -VMName $VMName -IPAddress $IPAddress
    Set-VMProcessor -VMName $VMName -Count $CPUs -ErrorAction Stop
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction Stop
    Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
    # Inject unattend.xml into the independent guest VHD.
    try {
        $mountResult = Mount-VHD -Path $vmVhdPath -Passthru -ErrorAction Stop
        $partitions = @($mountResult | Get-Disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' })
        foreach ($partition in $partitions) {
            if (-not $partition.DriveLetter) { $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop }
        }
        $dl = @($mountResult | Get-Disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } | Select-Object -ExpandProperty DriveLetter)
        if ($dl.Count -ne 1) { throw 'Expected exactly one Windows partition.' }
        $dl = $dl[0]
        if ($dl -and (Test-Path "${dl}:\Windows")) {
            $pantherDir = "${dl}:\Windows\Panther"
            New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
            Copy-Item -Path "$unattendDir\unattend.xml" -Destination "$pantherDir\unattend.xml" -Force
            Write-Log "Injected unattend.xml into VHD for '$VMName'."
        } else {
            throw "Windows directory not found for $VMName."
        }
    } catch {
        throw "Failed to inject unattend.xml for $VMName."
    } finally {
        Dismount-VHD -Path $vmVhdPath -ErrorAction SilentlyContinue
    }

    Write-Log "VM '$VMName' created ($CPUs vCPUs, ${MemoryMB}MB RAM, IP $IPAddress)."
}

# --- Helper: Create-LinuxGuestVM ---
function Create-LinuxGuestVM {
    param(
        [string]$VMName, [string]$IPAddress,
        [int]$MemoryMB = 2048, [int]$CPUs = 2,
        [string[]]$ExtraPackages = @(),
        [string]$ExtraRunCmdYaml = ""
    )

    $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existingVM) { throw "VM $VMName already exists. Use a fresh lab; do not replay guest provisioning." }

    Write-Log "Creating Linux VM '$VMName'..."

    $vmVhdPath = "$vhdPath\$VMName.vhdx"
    if (-not (Test-Path $vmVhdPath)) {
        Convert-VHD -Path $ubuntuBaseVhd -DestinationPath $vmVhdPath -VHDType Dynamic -ErrorAction Stop
    }

    # Resize the standalone disk so cloud-init has room
    Resize-VHD -Path $vmVhdPath -SizeBytes 30GB -ErrorAction Stop

    # Cloud-init files
    $cloudInitDir = "$labRoot\CloudInit\$VMName"
    New-Item -ItemType Directory -Path $cloudInitDir -Force | Out-Null

    $metaData = "instance-id: $VMName`nlocal-hostname: $VMName"
    [System.IO.File]::WriteAllText("$cloudInitDir\meta-data", $metaData, [System.Text.UTF8Encoding]::new($false))

    $macAddress = '00155D0000' + ([int]($IPAddress.Split('.')[-1])).ToString('X2')
    $macColon = ($macAddress -replace '(..)(?!$)', '$1:').ToLowerInvariant()
    $networkConfig = @'
version: 2
ethernets:
  labnic:
    match:
      macaddress: "__MAC__"
    set-name: eth0
    dhcp4: true
    dhcp-identifier: mac
'@
    $networkConfig = Expand-LabTextTemplate $networkConfig @{ '__MAC__' = $macColon }
    [System.IO.File]::WriteAllText("$cloudInitDir\network-config", $networkConfig, [System.Text.UTF8Encoding]::new($false))

    $basePackages = @("openssh-server", "curl", "wget", "net-tools", "walinuxagent")
    $allPackages  = $basePackages + $ExtraPackages
    $pkgYaml = ($allPackages | ForEach-Object { "  - $_" }) -join "`n"

    $networkPrepare = @'
  - |
    cat > /etc/netplan/50-cloud-init.yaml << 'NETPLAN'
    network:
      version: 2
      ethernets:
        primary:
          match:
            name: "e*"
          dhcp4: true
          dhcp-identifier: mac
    NETPLAN
  - chmod 600 /etc/netplan/50-cloud-init.yaml
  - |
    echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  - netplan generate
'@
    $baseRun = @("  - systemctl enable ssh", "  - systemctl start ssh", "  - systemctl enable walinuxagent", "  - systemctl start walinuxagent")
    $runYaml = ($baseRun -join "`n") + "`n" + $networkPrepare
    if ($ExtraRunCmdYaml) { $runYaml += "`n$ExtraRunCmdYaml" }

    $userData = @'
#cloud-config
password: __PASSWORD__
chpasswd:
  expire: false
ssh_pwauth: true
users:
  - name: __USER__
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: __PASSWORD__
packages:
__PKGYAML__
runcmd:
__RUNYAML__
'@
    $passwordYaml = ConvertTo-Json -InputObject $guestAdminPwd -Compress
    $userData = Expand-LabTextTemplate $userData @{
        '__PASSWORD__' = $passwordYaml
        '__USER__' = $guestUser
        '__PKGYAML__' = $pkgYaml
        '__RUNYAML__' = $runYaml
    }
    [System.IO.File]::WriteAllText("$cloudInitDir\user-data", $userData, [System.Text.UTF8Encoding]::new($false))

    # Create cloud-init ISO
    $ciIsoPath = "$vhdPath\$VMName-cidata.iso"
    $oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"

    $isoCreated = $false
    if (Test-Path $oscdimg) {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        & $oscdimg -j2 -lcidata "$cloudInitDir" "$ciIsoPath" 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
        if ($LASTEXITCODE -eq 0 -and (Test-Path $ciIsoPath)) { $isoCreated = $true }
    }

    if (-not $isoCreated) { throw "Cloud-init ISO creation failed for $VMName. No guest was created." }

    $vmDir = "$labRoot\VMs\$VMName"
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    New-VM -Name $VMName -MemoryStartupBytes ($MemoryMB * 1MB) -VHDPath $vmVhdPath `
        -SwitchName $intSwitchName -Path $vmDir -Generation 2 -ErrorAction Stop | Out-Null
    Set-VMProcessor -VMName $VMName -Count $CPUs -ErrorAction Stop
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction Stop
    Set-LabReservation -VMName $VMName -IPAddress $IPAddress
    Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    if ($ciIsoPath -and (Test-Path $ciIsoPath)) {
        Add-VMDvdDrive -VMName $VMName -Path $ciIsoPath -ErrorAction Stop
        Write-Log "Attached cloud-init ISO to '$VMName'."
    }

    Write-Log "VM '$VMName' created ($CPUs vCPUs, ${MemoryMB}MB RAM, IP $IPAddress)."
}

# --- Define cloud-init runcmd YAML for Linux workloads ---

# Nginx web server setup (packages directive installs nginx before runcmd runs)
$nginxRunCmdYaml = @'
  - systemctl enable nginx
  - systemctl start nginx
  - |
    cat > /var/www/html/index.html << 'HTMLEOF'
    <!DOCTYPE html>
    <html>
    <head>
        <title>TD SYNNEX - Cloud Enablement Services</title>
        <style>
            body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #1a1a2e; color: #eee; }
            .container { max-width: 800px; margin: 0 auto; background: #16213e; padding: 40px; border-radius: 8px; }
            h1 { color: #e94560; }
            .info { background: #0f3460; padding: 15px; border-radius: 4px; margin: 20px 0; }
            .status { color: #4ecca3; font-weight: bold; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>TD SYNNEX | Linux Web</h1><p>Cloud Enablement Services</p>
            <p class="status">&#x2705; Nginx is running</p>
            <div class="info">
                <h3>Environment Details</h3>
                <ul>
                    <li><strong>Server:</strong> OnPrem-Linux-Web</li>
                    <li><strong>Platform:</strong> Ubuntu 22.04 + Nginx</li>
                    <li><strong>IP Address:</strong> 192.168.0.12</li>
                    <li><strong>Status:</strong> On-Premises (Pre-Migration)</li>
                </ul>
            </div>
            <p>This is a sample Linux-hosted website for the Azure Migrate Workshop.</p>
        </div>
    </body>
    </html>
    HTMLEOF
'@

# Node.js + Express.js app setup
$nodeJsRunCmdYaml = @'
  - apt-get update -y
  - curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/nodesource_setup.sh
  - bash /tmp/nodesource_setup.sh
  - DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  - mkdir -p /opt/contoso-app
  - |
    cat > /opt/contoso-app/package.json << 'PKGJSON'
    {
      "name": "contoso-app",
      "version": "1.0.0",
      "description": "Contoso sample Node.js application for Azure Migrate Workshop",
      "main": "server.js",
      "scripts": { "start": "node server.js" },
      "dependencies": { "express": "5.2.1" }
    }
    PKGJSON
  - |
    cat > /opt/contoso-app/server.js << 'SERVERJS'
    const express = require('express');
    const os = require('os');
    const app = express();
    const PORT = 3000;

    app.get('/', (req, res) => {
      res.send(`
        <!DOCTYPE html>
        <html>
        <head>
          <title>TD SYNNEX - Cloud Enablement Services</title>
          <style>
            body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #0d1117; color: #c9d1d9; }
            .container { max-width: 800px; margin: 0 auto; background: #161b22; padding: 40px; border-radius: 8px; border: 1px solid #30363d; }
            h1 { color: #58a6ff; }
            pre { background: #0d1117; padding: 15px; border-radius: 4px; overflow-x: auto; }
            .status { color: #3fb950; font-weight: bold; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>TD SYNNEX | Application Server</h1><p>Cloud Enablement Services</p>
            <p class="status">&#x2705; Node.js API is running</p>
            <h3>System Info</h3>
            <pre>${JSON.stringify({
              hostname: os.hostname(),
              platform: os.platform(),
              arch: os.arch(),
              uptime: Math.floor(os.uptime()) + 's',
              memory: Math.floor(os.totalmem() / 1024 / 1024) + 'MB',
              nodeVersion: process.version
            }, null, 2)}</pre>
            <h3>API Endpoints</h3>
            <ul>
              <li><a href="/api/health" style="color:#58a6ff">/api/health</a> - Health check</li>
              <li><a href="/api/info" style="color:#58a6ff">/api/info</a> - System information</li>
            </ul>
          </div>
        </body>
        </html>
      `);
    });

    app.get('/api/health', (req, res) => {
      res.json({ status: 'healthy', timestamp: new Date().toISOString(), server: 'OnPrem-Linux-App' });
    });

    app.get('/api/info', (req, res) => {
      res.json({
        hostname: os.hostname(),
        platform: os.platform(),
        arch: os.arch(),
        uptime: os.uptime(),
        memory: { total: os.totalmem(), free: os.freemem() },
        cpus: os.cpus().length,
        nodeVersion: process.version,
        environment: 'on-premises'
      });
    });

    app.listen(PORT, '0.0.0.0', () => {
      console.log(`Contoso App Server running on port ${PORT}`);
    });
    SERVERJS
  - cd /opt/contoso-app && npm install --omit=dev
  - |
    cat > /etc/systemd/system/contoso-app.service << 'SVCFILE'
    [Unit]
    Description=Contoso Node.js Application
    After=network.target

    [Service]
    Type=simple
    User=contosoapp
    NoNewPrivileges=true
    WorkingDirectory=/opt/contoso-app
    ExecStart=/usr/bin/node server.js
    Restart=on-failure
    RestartSec=10
    Environment=NODE_ENV=production

    [Install]
    WantedBy=multi-user.target
    SVCFILE
  - useradd --system --no-create-home --shell /usr/sbin/nologin contosoapp
  - chown -R contosoapp:contosoapp /opt/contoso-app
  - systemctl daemon-reload
  - systemctl enable contoso-app
  - systemctl start contoso-app
'@

# --- Create VMs ---
Create-WindowsGuestVM -VMName "OnPrem-Web" -IPAddress "192.168.0.10" -MemoryMB 4096 -CPUs 2
Create-WindowsGuestVM -VMName "OnPrem-SQL" -IPAddress "192.168.0.11" -MemoryMB 4096 -CPUs 2
Create-WindowsGuestVM -VMName "MigrateAppl" -IPAddress "192.168.0.20" -MemoryMB 16384 -CPUs 8 -DiskGB 100
Create-LinuxGuestVM   -VMName "OnPrem-Linux-Web" -IPAddress "192.168.0.12" -MemoryMB 2048 -CPUs 2 -ExtraPackages @("nginx") -ExtraRunCmdYaml $nginxRunCmdYaml
Create-LinuxGuestVM   -VMName "OnPrem-Linux-App" -IPAddress "192.168.0.13" -MemoryMB 2048 -CPUs 2 -ExtraRunCmdYaml $nodeJsRunCmdYaml

# =============================================================
# PHASE 4 — Start VMs and wait for boot
# =============================================================
Write-Log "PHASE 4: Starting guest VMs..."

$allVMs = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App", "MigrateAppl")
foreach ($vm in $allVMs) {
    $v = Get-VM -Name $vm -ErrorAction SilentlyContinue
    if ($v -and $v.State -ne "Running") {
        Start-VM -Name $vm -ErrorAction Stop
        Write-Log "Started VM '$vm'."
    } elseif ($v) {
        Write-Log "VM '$vm' is already running."
    } else {
        Write-Log "WARNING: VM '$vm' not found."
    }
}

Write-Log "Waiting 180 seconds for VMs to boot and complete first-boot setup..."
Start-Sleep -Seconds 180

# --- Wait helper ---
function Wait-ForGuestVM {
    param([string]$VMName, [int]$TimeoutSeconds = 900)
    Write-Log "Waiting for '$VMName' heartbeat..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $hb = Get-VMIntegrationService -VMName $VMName -Name "Heartbeat" -ErrorAction SilentlyContinue
        if ($hb -and $hb.PrimaryStatusDescription -eq "OK") {
            if ($VMName -notlike '*Linux*') {
                try { $null = Invoke-Command -VMName $VMName -Credential $winCred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop }
                catch { Start-Sleep -Seconds 10; continue }
            }
            Write-Log "'$VMName' is responding."
            return $true
        }
        Start-Sleep -Seconds 10
    }
    Write-Log "WARNING: Timed out waiting for '$VMName'."
    return $false
}

# =============================================================
# PHASE 5 — Install workloads
# =============================================================
Write-Log "PHASE 5: Installing workloads..."

$winCred = New-Object System.Management.Automation.PSCredential(
    "Administrator",
    (ConvertTo-SecureString $guestAdminPwd -AsPlainText -Force)
)

# Expand the Windows OS partitions and enable private management after first boot.
foreach ($name in @('OnPrem-Web','OnPrem-SQL','MigrateAppl')) {
    if (-not (Wait-ForGuestVM -VMName $name)) { throw "Guest setup did not finish: $name" }
    Invoke-Command -VMName $name -Credential $winCred -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $size = Get-PartitionSupportedSize -DriveLetter C
        if ((Get-Partition -DriveLetter C).Size -lt $size.SizeMax) { Resize-Partition -DriveLetter C -Size $size.SizeMax }
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    }
}
# ---- OnPrem-Web: IIS + ASP.NET + sample site ----
Write-Log "--- Configuring OnPrem-Web (192.168.0.10) ---"
try {
    if (-not (Wait-ForGuestVM -VMName "OnPrem-Web")) { throw "Windows web guest not ready." }

    Invoke-Command -VMName "OnPrem-Web" -Credential $winCred -ScriptBlock {
        $ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

        if (-not (Get-WindowsFeature Web-Server).Installed) {
            Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop | Out-Null
        }
        if (-not (Get-WindowsFeature Web-Asp-Net45).Installed) {
            Install-WindowsFeature -Name Web-Asp-Net45 -ErrorAction Stop | Out-Null
        }

        # Enable RDP for private lab validation; network access remains restricted.
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        $sitePath = "C:\inetpub\wwwroot"
        @'
<!DOCTYPE html>
<html>
<head>
    <title>TD SYNNEX - Cloud Enablement Services</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #f0f0f0; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; }
        .info { background: #e8f4fd; padding: 15px; border-radius: 4px; margin: 20px 0; }
        .status { color: #107c10; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <h1>TD SYNNEX | Windows Web</h1><p>Cloud Enablement Services</p>
        <p class="status">&#x2705; Application is running</p>
        <div class="info">
            <h3>Environment Details</h3>
            <ul>
                <li><strong>Server:</strong> OnPrem-Web</li>
                <li><strong>Platform:</strong> Windows Server 2022 + IIS</li>
                <li><strong>IP Address:</strong> 192.168.0.10</li>
                <li><strong>Sample:</strong> Standalone static site (no database connection)</li>
                <li><strong>Status:</strong> On-Premises (Pre-Migration)</li>
            </ul>
        </div>
        <p>This is a sample on-premises web application for the Azure Migrate Workshop.</p>
    </div>
</body>
</html>
'@ | Out-File -FilePath "$sitePath\index.html" -Encoding UTF8 -Force
        Write-Output "IIS and sample website deployed on OnPrem-Web."
    } -ErrorAction Stop

    Write-Log "OnPrem-Web configured successfully."
} catch {
    throw "OnPrem-Web workload setup failed: $_"
}

# ---- OnPrem-SQL: SQL Server 2022 Express + ContosoApp DB ----
Write-Log "--- Configuring OnPrem-SQL (192.168.0.11) ---"
try {
    if (-not (Wait-ForGuestVM -VMName "OnPrem-SQL")) { throw "SQL guest not ready." }

    Invoke-Command -VMName "OnPrem-SQL" -Credential $winCred -ScriptBlock {
        $ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

        $sqlSseiUrl = "https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe"
        $sqlSsei = "C:\Temp\SQL2022-SSEI-Expr.exe"
        $sqlMediaPath = "C:\Temp\SqlExpress"

        New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
        New-Item -ItemType Directory -Path $sqlMediaPath -Force | Out-Null

        $sqlService = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
        if (-not $sqlService) {
            Write-Output "Downloading SQL Server 2022 Express installer..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $sqlSseiUrl -OutFile $sqlSsei -UseBasicParsing -ErrorAction Stop

            $signature = Get-AuthenticodeSignature $sqlSsei
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'SQL installer signature is invalid.' }
            $install = Start-Process -FilePath $sqlSsei -ArgumentList '/ACTION=Install /QUIET /IACCEPTSQLSERVERLICENSETERMS' -Wait -PassThru
            if ($install.ExitCode -notin @(0,3010)) { throw "SQL Express installer failed: $($install.ExitCode)" }
            if (-not (Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue)) { throw 'SQLEXPRESS service not found after installation.' }
        } else {
            Write-Output "SQL Server Express is already installed."
        }

        $instanceId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
        $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
        Set-ItemProperty $tcpPath -Name Enabled -Value 1
        Set-ItemProperty "$tcpPath\IPAll" -Name TcpDynamicPorts -Value ''
        Set-ItemProperty "$tcpPath\IPAll" -Name TcpPort -Value '1433'
        Restart-Service 'MSSQL$SQLEXPRESS'
        if (-not (Get-NetFirewallRule -Name LabSql -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name LabSql -DisplayName 'Lab SQL from private networks' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -RemoteAddress 192.168.0.0/24,10.1.0.0/16,10.2.0.0/16 | Out-Null
        }
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        # Create sample database using PowerShell SqlServer module
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name SqlServer -Force -AllowClobber -ErrorAction Stop

            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance ".\SQLEXPRESS" -Query "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'ContosoApp') CREATE DATABASE ContosoApp;" -ErrorAction Stop

            $createTables = "USE ContosoApp; IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Customers') BEGIN CREATE TABLE Customers (CustomerID INT PRIMARY KEY IDENTITY(1,1), FirstName NVARCHAR(50), LastName NVARCHAR(50), Email NVARCHAR(100), City NVARCHAR(50), CreatedDate DATETIME DEFAULT GETDATE()); INSERT INTO Customers (FirstName, LastName, Email, City) VALUES ('Alice','Johnson','alice@contoso.com','Seattle'),('Bob','Smith','bob@contoso.com','Portland'),('Carol','Williams','carol@contoso.com','San Francisco'),('Dave','Brown','dave@contoso.com','Los Angeles'),('Eve','Davis','eve@contoso.com','Denver'); END; IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders') BEGIN CREATE TABLE Orders (OrderID INT PRIMARY KEY IDENTITY(1,1), CustomerID INT FOREIGN KEY REFERENCES Customers(CustomerID), ProductName NVARCHAR(100), Quantity INT, UnitPrice DECIMAL(10,2), OrderDate DATETIME DEFAULT GETDATE()); INSERT INTO Orders (CustomerID, ProductName, Quantity, UnitPrice) VALUES (1,'Azure Certification Guide',2,49.99),(2,'Cloud Architecture Poster',1,19.99),(3,'DevOps Handbook',3,39.99),(1,'Kubernetes Stickers',10,4.99),(4,'Serverless Cookbook',1,34.99); END;"
            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance ".\SQLEXPRESS" -Query $createTables -ErrorAction Stop
            # Permit the Azure VM agent's SYSTEM identity to validate only this lab database.
            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance ".\SQLEXPRESS" -Query "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS; USE ContosoApp; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'NT AUTHORITY\SYSTEM') CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM]; ALTER ROLE db_owner ADD MEMBER [NT AUTHORITY\SYSTEM];" -ErrorAction Stop
            Write-Output "Sample database 'ContosoApp' created with Customers and Orders tables."
        } catch {
            throw "Could not create sample database: $_"
        }
    } -ErrorAction Stop

    Write-Log "OnPrem-SQL configured successfully."
} catch {
    throw "OnPrem-SQL workload setup failed: $_"
}

# Workload success must be observed, not inferred from VM heartbeat.
$deadline = (Get-Date).AddMinutes(20)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    try {
        Assert-LabSourceWorkloads
        $healthy = $true
        break
    } catch { Start-Sleep -Seconds 20 }
}
if (-not $healthy) { throw 'Workload readiness timed out. Check guest services and cloud-init logs; setup is incomplete.' }
# Delete Windows setup password material after successful first boot.
foreach ($name in @('OnPrem-Web','OnPrem-SQL','MigrateAppl')) {
    Invoke-Command -VMName $name -Credential $winCred -ScriptBlock {
        Remove-Item 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
        Remove-Item 'C:\Windows\Panther\Unattend\unattend.xml' -Force -ErrorAction SilentlyContinue
    }
}
Remove-Item "$labRoot\Unattend" -Recurse -Force -ErrorAction SilentlyContinue
# Detach the cloud-init seed to keep it out of migration disk selection.
foreach ($name in @('OnPrem-Linux-Web','OnPrem-Linux-App')) {
    Get-VMDvdDrive -VMName $name | Set-VMDvdDrive -Path $null
    Remove-Item "$vhdPath\$name-cidata.iso" -Force -ErrorAction SilentlyContinue
}
Remove-Item "$labRoot\CloudInit" -Recurse -Force -ErrorAction SilentlyContinue
# cloud-init retains a root-only copy of user-data within Linux; credentials are lab-only.
@{ CompletedUtc = (Get-Date).ToUniversalTime().ToString('o'); VMs = $allVMs; Workshop = $WorkshopTitle } |
    ConvertTo-Json | Set-Content "$labRoot\setup-complete.json" -Encoding UTF8
Write-Output 'LAB_WORKLOADS_READY'

} catch {
    Write-Error ('Host setup failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
