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
