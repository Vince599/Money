[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'debug',
    [string]$Filter = 'LedgerCoreTests'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
$swiftCommand = Get-Command swift -ErrorAction Stop

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'Package.swift'))) {
    throw 'Package.swift is missing. Run this script from the complete Ledger checkout.'
}

Push-Location -LiteralPath $projectRoot
try {
    & $swiftCommand.Source --version
    if ($LASTEXITCODE -ne 0) {
        throw "Swift could not report its version (exit $LASTEXITCODE)."
    }

    $testArguments = @('test', '--configuration', $Configuration)
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $testArguments += @('--filter', $Filter)
    }
    & $swiftCommand.Source @testArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Swift core tests failed (exit $LASTEXITCODE)."
    }
}
finally {
    Pop-Location
}
