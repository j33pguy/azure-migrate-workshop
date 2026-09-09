# Shared checks. Dot-source this file; it never connects to Azure or changes resources.
Set-StrictMode -Version Latest

function Assert-LabContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Subscription -or $context.Subscription.Id -ne $SubscriptionId) {
        throw "Select the intended subscription first: Set-AzContext -SubscriptionId '$SubscriptionId'"
    }
    return $context
}

function Assert-LabResourceGroupName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[\p{L}\p{M}\p{N}_.()-]{1,90}$' -or $Name.EndsWith('.')) {
        throw 'Supply one exact resource group name, without wildcards, whitespace or a resource ID.'
    }
}

function Get-LabResourceGroup {
    param([Parameter(Mandatory)][string]$Name, [switch]$AllowMissing)
    Assert-LabResourceGroupName $Name
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Subscription -or [string]::IsNullOrWhiteSpace($context.Subscription.Id)) {
        throw 'Select the intended Azure subscription before inspecting resource groups.'
    }
    $subscription = [uri]::EscapeDataString($context.Subscription.Id)
    $group = [uri]::EscapeDataString($Name)
    # Get-AzResourceGroup can replace CloudException with a generic missing-group
    # message. Use the documented exact ARM GET to preserve its status and code.
    $response = Invoke-AzRestMethod -Path "/subscriptions/$subscription/resourcegroups/$group`?api-version=2021-04-01" -Method GET -ErrorAction Stop
    if ($null -eq $response -or $null -eq $response.StatusCode -or [string]::IsNullOrWhiteSpace($response.Content)) {
        throw "No verifiable Azure response for group '$Name'. No absence or deletion is assumed."
    }
    $body = ConvertFrom-Json -InputObject $response.Content -ErrorAction Stop
    if ($response.StatusCode -ne 200) {
        $code = ''
        if ($null -ne $body -and $body.PSObject.Properties['error'] -and $null -ne $body.error -and $body.error.PSObject.Properties['code']) {
            $code = [string]$body.error.code
        }
        if ($AllowMissing -and $response.StatusCode -eq 404 -and $code -eq 'ResourceGroupNotFound') { return $null }
        throw "Could not verify group '$Name': HTTP $($response.StatusCode), code '$code'. No absence or deletion is assumed."
    }
    $expectedId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$Name"
    if ($null -eq $body -or $body.name -ne $Name -or
        [uri]::UnescapeDataString($body.id) -ne $expectedId) {
        throw "Azure returned an unexpected resource identity for '$Name'."
    }
    $tags = @{}
    if ($body.PSObject.Properties['tags'] -and $null -ne $body.tags) {
        foreach ($tag in $body.tags.PSObject.Properties) { $tags[$tag.Name] = $tag.Value }
    }
    return [pscustomobject]@{ ResourceGroupName=$body.name; ResourceId=$body.id; Tags=$tags }
}

function Assert-LabResourceGroup {
    param([Parameter(Mandatory)][string]$Name)
    $rg = Get-LabResourceGroup $Name
    if (-not $rg.Tags -or $rg.Tags['Workshop'] -ne 'TD-SYNNEX-CES-HyperV') {
        throw "Resource group '$Name' is not tagged as this workshop. It will not be modified."
    }
    return $rg
}

function Assert-LabAdminSource {
    param([Parameter(Mandatory)][string]$Cidr)
    $ip = $null
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -ne '32' -or
        $parts[0] -notmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' -or
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
        $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parts[0] -eq '0.0.0.0') {
        throw 'AdminSourceCidr must be your current public IPv4 address followed by /32.'
    }
}

function Assert-LabWorkloadNames {
    param([Parameter(Mandatory)][string[]]$Names)
    if ($Names.Count -ne 4) { throw 'Supply the exact names of all four workload VMs.' }
    $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$' -or -not $unique.Add($name)) {
            throw 'Workload VM names must be four distinct exact names, without wildcards or whitespace.'
        }
    }
}

function Assert-LabHostSizeName {
    param([Parameter(Mandatory)][string]$VMSize)
    if ($VMSize -notmatch '^Standard_[a-zA-Z0-9][a-zA-Z0-9_-]{1,80}$') {
        throw 'VMSize must be one exact Azure size name, such as Standard_E8s_v5, without wildcards or whitespace.'
    }
}

function Get-LabHostSku {
    param([Parameter(Mandatory)][string]$VMSize, [Parameter(Mandatory)][string]$Location)
    Assert-LabHostSizeName $VMSize
    $matches = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VMSize })
    if ($matches.Count -ne 1 -or $Location -notin $matches[0].Locations -or
        @($matches[0].Restrictions | Where-Object Type -EQ 'Location').Count) {
        throw "VM size '$VMSize' is not available to this subscription in '$Location'. Choose a size offered in that region or resolve the subscription restriction."
    }
    $sku = $matches[0]
    $capabilities = @{}
    foreach ($capability in $sku.Capabilities) { $capabilities[$capability.Name] = [string]$capability.Value }
    $cores = 0; $availableCores = 0; $memory = [decimal]0
    if (-not [int]::TryParse($capabilities['vCPUs'], [ref]$cores) -or $cores -le 0 -or
        -not [decimal]::TryParse($capabilities['MemoryGB'], [Globalization.NumberStyles]::Number,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$memory)) {
        throw "Cannot verify CPU/RAM metadata for '$VMSize' in '$Location'."
    }
    $availableCores = $cores
    if ($capabilities.ContainsKey('vCPUsAvailable') -and
        -not [int]::TryParse($capabilities['vCPUsAvailable'], [ref]$availableCores)) {
        throw "Cannot verify enabled vCPUs for '$VMSize'."
    }
    if ($availableCores -lt 8 -or $availableCores -gt $cores -or $memory -lt 64) {
        throw "Host size '$VMSize' has $availableCores enabled vCPUs and $memory GiB RAM. This five-VM workshop requires at least 8 enabled vCPUs and 64 GiB RAM."
    }
    if ($capabilities['CpuArchitectureType'] -ne 'x64' -or
        'V2' -notin @($capabilities['HyperVGenerations'] -split ',' | ForEach-Object { $_.Trim() }) -or
        $capabilities['PremiumIO'] -ne 'True') {
        throw "Host size '$VMSize' must report x64, Generation 2 and Premium SSD support for this workshop's Windows image and OS disk."
    }
    if ([string]::IsNullOrWhiteSpace($sku.Family)) { throw "Cannot identify the quota family for '$VMSize'." }
    $usage = @(Get-AzVMUsage -Location $Location -ErrorAction Stop)
    foreach ($name in @($sku.Family, 'cores')) {
        $quota = @($usage | Where-Object { $_.Name.Value -eq $name })
        $limit = [long]0; $used = [long]0
        if ($quota.Count -ne 1 -or
            -not [long]::TryParse([string]$quota[0].Limit, [ref]$limit) -or
            -not [long]::TryParse([string]$quota[0].CurrentValue, [ref]$used) -or $limit -lt 0 -or $used -lt 0) {
            throw "Cannot verify quota '$name' for '$VMSize' in '$Location'."
        }
        if ($limit - $used -lt $cores) {
            throw "Insufficient '$name' quota in '$Location' for '$VMSize': need $cores free vCPUs; $($limit - $used) available. Reserve target/test quota separately."
        }
    }
    # SKU metadata is not a nested-virtualization certification. The instructor
    # verifies the selected series' Microsoft documentation before provisioning.
    return [pscustomobject]@{ Name=$sku.Name; Family=$sku.Family; Cores=$availableCores; MemoryGB=$memory;
        AcceleratedNetworking=($capabilities['AcceleratedNetworkingEnabled'] -eq 'True') }
}

function Get-LabWindowsImages {
    param([Parameter(Mandatory)][string]$Location)
    $images = @{}
    foreach ($role in @('Host','Guest')) {
        $sku = if ($role -eq 'Host') { '2022-datacenter-g2' } else { '2022-datacenter-smalldisk-g2' }
        $offer = 'windowsserver2022'
        $versions = @(Get-AzVMImage -Location $Location -PublisherName MicrosoftWindowsServer -Offer $offer -Skus $sku -ErrorAction Stop)
        if (-not $versions.Count) { throw "No Windows image versions found: MicrosoftWindowsServer:${offer}:${sku} in '$Location'. Verify region, offer and image access before deploying." }
        $version = $versions | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        $details = @(Get-AzVMImage -Location $Location -PublisherName MicrosoftWindowsServer -Offer $offer -Skus $sku -Version $version.Version -ErrorAction Stop)
        if ($details.Count -ne 1 -or $details[0].HyperVGeneration -ne 'V2' -or
            $details[0].Architecture -ne 'x64' -or $details[0].OSDiskImage.OperatingSystem -ne 'Windows' -or
            [string]::IsNullOrWhiteSpace($details[0].Id)) {
            throw "Cannot verify a Windows x64 Gen2 image for ${offer}:${sku}:$($version.Version) in '$Location'."
        }
        $images[$role] = [pscustomobject]@{ Publisher='MicrosoftWindowsServer'; Offer=$offer; Sku=$sku; Version=$version.Version; Id=$details[0].Id }
        Write-Host "Resolved $role image: MicrosoftWindowsServer:${offer}:${sku}:$($version.Version)"
    }
    return [pscustomobject]$images
}

function Read-LabHostConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'The host configuration script is empty. Obtain the complete workshop checkout.' }
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The host configuration script has syntax errors. Obtain the reviewed workshop revision.' }
    return $content
}

function Assert-LabRunResult {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Marker)
    $stdout = @($Result.Value | Where-Object Code -Match 'StdOut' | ForEach-Object Message) -join "`n"
    $stderr = @($Result.Value | Where-Object Code -Match 'StdErr' | ForEach-Object Message) -join "`n"
    $failedStatuses = @($Result.Value | Where-Object { $_.Code -match '/(failed|error)(/|$)' })
    $markerLine = '(?m)^' + [regex]::Escape($Marker) + '\r?$'
    if ($failedStatuses.Count -gt 0 -or $stdout -cnotmatch $markerLine -or -not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "Remote validation did not pass. Review the VM Run Command output. $stderr"
    }
    return $stdout
}

function Assert-LabManagedRunResult {
    param([Parameter(Mandatory)]$InstanceView)
    if ($InstanceView.ExecutionState -ne 'Succeeded' -or $null -eq $InstanceView.ExitCode -or $InstanceView.ExitCode -ne 0 -or
        $InstanceView.Output -cnotmatch '(?m)^LAB_WORKLOADS_READY\r?$') {
        throw 'Guest setup did not pass. Inspect the managed Run Command instance view and C:\AzMigrateLab\setup-log.txt.'
    }
}
