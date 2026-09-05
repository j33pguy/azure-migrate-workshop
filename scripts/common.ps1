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

function Assert-LabResourceGroup {
    param([Parameter(Mandatory)][string]$Name)
    $rg = Get-AzResourceGroup -Name $Name -ErrorAction Stop
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
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
        $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parts[0] -eq '0.0.0.0') {
        throw 'AdminSourceCidr must be your current public IPv4 address followed by /32.'
    }
}

function Assert-LabRunResult {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Marker)
    $stdout = @($Result.Value | Where-Object Code -Match 'StdOut' | ForEach-Object Message) -join "`n"
    $stderr = @($Result.Value | Where-Object Code -Match 'StdErr' | ForEach-Object Message) -join "`n"
    if ($stdout -notmatch [regex]::Escape($Marker) -or -not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "Remote validation did not pass. Review the VM Run Command output. $stderr"
    }
    return $stdout
}

function Assert-LabManagedRunResult {
    param([Parameter(Mandatory)]$InstanceView)
    if ($InstanceView.ExecutionState -ne 'Succeeded' -or $null -eq $InstanceView.ExitCode -or $InstanceView.ExitCode -ne 0 -or
        $InstanceView.Output -notmatch 'LAB_WORKLOADS_READY') {
        throw 'Guest setup did not pass. Inspect the managed Run Command instance view and C:\AzMigrateLab\setup-log.txt.'
    }
}
