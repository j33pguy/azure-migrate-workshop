<#
.SYNOPSIS
Capture or compare the complete sample-table data inside a SQL workload VM.
.DESCRIPTION
Run in Windows PowerShell inside the source, test or migrated SQL VM.
Uses Windows authentication to .\SQLEXPRESS and reads ContosoApp only.
Checks database integrity and every defined column of Customers and Orders,
including timestamps. Stop writers before capturing the cutover baseline.
This is sample-data validation, not a backup or a general database/schema diff.
.PARAMETER Capture
Write a new baseline file. Existing files are never overwritten.
.PARAMETER BaselinePath
For capture, a new JSON path. For comparison, the copied source baseline.
.EXAMPLE
.\Test-LabSqlData.ps1 -Capture -BaselinePath C:\LabEvidence\source-precutover.baseline.json
.EXAMPLE
.\Test-LabSqlData.ps1 -BaselinePath C:\LabEvidence\source-precutover.baseline.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [switch]$Capture
)

function Get-LabSqlColumns {
    return [ordered]@{
        Customers = @('CustomerID','FirstName','LastName','Email','City','CreatedDate')
        Orders = @('OrderID','CustomerID','ProductName','Quantity','UnitPrice','OrderDate')
    }
}

function ConvertFrom-LabSqlJson {
    param([Parameter(Mandatory)][string]$Json)
    # PowerShell 7.5+ otherwise turns ISO timestamp strings into DateTime values.
    # Windows PowerShell 5.1 has no DateKind parameter and preserves these strings.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Json -DateKind String
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { throw 'Use Windows PowerShell 5.1 or PowerShell 7.5+ to preserve baseline timestamp strings.' }
    return ConvertFrom-Json -InputObject $Json
}

function ConvertTo-LabSqlValue {
    param([AllowNull()]$Value)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value -or $Value -is [DBNull]) { return $null }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-ddTHH:mm:ss.fff', $culture) }
    if ($Value -is [System.IFormattable]) { return $Value.ToString($null, $culture) }
    return [string]$Value
}

function Assert-LabSqlSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    foreach ($property in @('SchemaVersion','Database','Tables')) {
        if ($Snapshot.PSObject.Properties.Name -cnotcontains $property) { throw 'Missing SQL baseline header. Use a file produced by this script.' }
    }
    if ($Snapshot.SchemaVersion -ne 1 -or $Snapshot.Database -cne 'ContosoApp' -or $null -eq $Snapshot.Tables) {
        throw 'Unsupported SQL baseline format or database.'
    }
    $columns = Get-LabSqlColumns
    if (@($Snapshot.Tables.PSObject.Properties).Count -ne $columns.Count) { throw 'Unexpected SQL baseline tables.' }
    foreach ($table in $columns.Keys) {
        if ($Snapshot.Tables.PSObject.Properties.Name -cnotcontains $table -or $Snapshot.Tables.$table -isnot [array]) {
            throw "Missing baseline row array for $table."
        }
        $keys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($row in $Snapshot.Tables.$table) {
            if ($null -eq $row -or @($row.PSObject.Properties).Count -ne $columns[$table].Count) { throw "Invalid baseline columns for $table." }
            foreach ($column in $columns[$table]) {
                if ($row.PSObject.Properties.Name -cnotcontains $column) { throw "Missing baseline column $table.$column." }
                if ($null -ne $row.$column -and $row.$column -isnot [string]) { throw "Invalid baseline value for $table.$column." }
            }
            $key = $row.($columns[$table][0])
            $parsedKey = 0
            if (-not [int]::TryParse($key, [ref]$parsedKey) -or -not $keys.Add([string]$parsedKey)) {
                throw "Invalid or duplicate primary key in $table baseline."
            }
        }
    }
}

function ConvertTo-LabSqlCanonicalTable {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Table)
    $columns = (Get-LabSqlColumns)[$Table]
    $rows = @(
        foreach ($row in ($Snapshot.Tables.$Table | Sort-Object { [int]$_.($columns[0]) })) {
            $ordered = [ordered]@{}
            foreach ($column in $columns) { $ordered[$column] = $row.$column }
            [pscustomobject]$ordered
        }
    )
    return ConvertTo-Json -InputObject $rows -Depth 6 -Compress
}

function Assert-LabSqlDataMatches {
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual)
    Assert-LabSqlSnapshot $Expected
    Assert-LabSqlSnapshot $Actual
    foreach ($table in (Get-LabSqlColumns).Keys) {
        $expectedJson = ConvertTo-LabSqlCanonicalTable $Expected $table
        $actualJson = ConvertTo-LabSqlCanonicalTable $Actual $table
        if (-not [string]::Equals($expectedJson, $actualJson, [System.StringComparison]::Ordinal)) {
            throw "$table data differs from the source baseline (expected $(@($Expected.Tables.$table).Count) rows, found $(@($Actual.Tables.$table).Count)). Stop acceptance and investigate; row values are not printed."
        }
    }
}

function Get-LabSqlSnapshot {
    param([Parameter(Mandatory)]$Connection)
    $tables = [ordered]@{}
    $columns = Get-LabSqlColumns
    # A single transaction provides a consistent view of both small sample tables.
    # Writers must still be stopped before the final baseline and remain stopped.
    $transaction = $Connection.BeginTransaction([System.Data.IsolationLevel]::Serializable)
    try {
        foreach ($table in $columns.Keys) {
            $command = $Connection.CreateCommand()
            $reader = $null
            try {
                $command.Transaction = $transaction
                $command.CommandTimeout = 120
                $projection = ($columns[$table] | ForEach-Object { "[$_]" }) -join ','
                $command.CommandText = "SELECT $projection FROM dbo.[$table] ORDER BY [$($columns[$table][0])];"
                $reader = $command.ExecuteReader()
                $rows = [System.Collections.Generic.List[object]]::new()
                while ($reader.Read()) {
                    $row = [ordered]@{}
                    foreach ($column in $columns[$table]) { $row[$column] = ConvertTo-LabSqlValue $reader[$column] }
                    $rows.Add([pscustomobject]$row)
                }
                $tables[$table] = $rows.ToArray()
            } finally {
                if ($null -ne $reader) { $reader.Dispose() }
                $command.Dispose()
            }
        }
        $transaction.Commit()
    } finally { $transaction.Dispose() }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Database = 'ContosoApp'
        CapturedUtc = [datetime]::UtcNow.ToString('o')
        Tables = [pscustomobject]$tables
    }
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run this script inside the Windows SQL workload VM.' }
$fullPath = [System.IO.Path]::GetFullPath($BaselinePath)
if ($Capture) {
    if (Test-Path -LiteralPath $fullPath) { throw 'The baseline already exists. Choose a new filename; preserve the earlier evidence.' }
} else {
    $expected = ConvertFrom-LabSqlJson (Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop)
    Assert-LabSqlSnapshot $expected
}
$connection = New-Object System.Data.SqlClient.SqlConnection 'Server=.\SQLEXPRESS;Database=ContosoApp;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connection Timeout=15'
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    try {
        $command.CommandTimeout = 120
        $command.CommandText = "DBCC CHECKDB (N'ContosoApp') WITH NO_INFOMSGS;"
        $null = $command.ExecuteNonQuery()
    } finally { $command.Dispose() }
    $actual = Get-LabSqlSnapshot $connection
} finally { $connection.Dispose() }
Assert-LabSqlSnapshot $actual
if ($Capture) {
    $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($fullPath)) -Force
    # CreateNew also prevents overwriting if another process created it meanwhile.
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $actual -Depth 8))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Write-Output "Source baseline captured: $fullPath. Keep it outside Git and copy this exact file to the SQL VM being validated."
} else {
    Assert-LabSqlDataMatches -Expected $expected -Actual $actual
    Write-Output 'SQL_DATA_MATCHED'
}
