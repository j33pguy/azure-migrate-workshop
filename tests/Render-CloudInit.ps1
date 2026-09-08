# Use the real template renderer and assignment without executing host setup.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/host/configure-host.ps1'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
$definition=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Expand-LabTextTemplate'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$assignment=$ast.Find({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$userData' -and $n.Right.Extent.Text.StartsWith('Expand-LabTextTemplate')},$true)
$results=@(foreach ($case in ([Console]::In.ReadToEnd() | ConvertFrom-Json)) {
    $userData=$case.Template
    $guestUser=$case.User
    $passwordYaml=ConvertTo-Json -InputObject $case.Password -Compress
    $pkgYaml=$case.Packages
    $runYaml=$case.Commands
    . ([scriptblock]::Create($assignment.Extent.Text))
    $userData
})
ConvertTo-Json -InputObject $results -Depth 8 -Compress
