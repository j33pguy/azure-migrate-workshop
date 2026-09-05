<#
.SYNOPSIS
Optional offline cmdlet-parameter validation using installed Az modules.
.DESCRIPTION
Imports cmdlet definitions only. Never authenticates or invokes Azure APIs.
Does not validate argument values, dynamic splats or complete parameter sets.
#>
[CmdletBinding()]
param([string]$ModulePath)
$ErrorActionPreference = 'Stop'
if ($ModulePath) { $env:PSModulePath = $ModulePath + [IO.Path]::PathSeparator + $env:PSModulePath }
Import-Module Az.Compute,Az.Network,Az.Resources -ErrorAction Stop
$root = Split-Path $PSScriptRoot -Parent
$failures = @()
$commands = @{}
foreach ($file in Get-ChildItem "$root/scripts" -Recurse -Filter *.ps1) {
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    foreach ($call in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^[a-z]+-Az'},$true)) {
        $name = $call.GetCommandName()
        try {
            $cmd = Get-Command $name -ErrorAction Stop
            $commands[$name] = $cmd.Source
            foreach ($element in $call.CommandElements) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and -not $cmd.Parameters.ContainsKey($element.ParameterName)) {
                    $failures += "$($file.Name):$($element.Extent.StartLineNumber): $name has no parameter -$($element.ParameterName)"
                }
            }
        } catch { $failures += "$($file.Name): $name was not resolved." }
    }
}
Get-Module Az.Accounts,Az.Compute,Az.Network,Az.Resources | Select-Object Name,Version
if ($failures.Count) { $failures; exit 1 }
Write-Host "PASS: $($commands.Count) Azure cmdlet names and their explicitly named parameters resolve. No Azure APIs were invoked."
