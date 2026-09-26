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

$packageRoot = $projectRoot
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    # SwiftPM 6.4 checks out Apple-only pins even with the conditional Windows manifest.
    # Mirror the actual manifest and portable sources without moving the authoritative Apple lock.
    $packageRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build/windows-core'))
    $workspacePrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $packageRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Windows test package must remain inside this workspace.'
    }
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'Package.swift') -Destination (Join-Path $packageRoot 'Package.swift') -Force
    foreach ($relativeSource in @('Sources/LedgerCore', 'Tests/LedgerCoreTests')) {
        $targetSource = [IO.Path]::GetFullPath((Join-Path $packageRoot $relativeSource))
        if (-not $targetSource.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Source mirror path escaped the Windows test package.'
        }
        New-Item -ItemType Directory -Path $targetSource -Force | Out-Null
        # Remove only the old mirrored source files, so renamed tests cannot run by accident.
        Get-ChildItem -LiteralPath $targetSource -Recurse -File -Filter '*.swift' | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName
        }
        $originalSource = Join-Path $projectRoot $relativeSource
        Get-ChildItem -LiteralPath $originalSource -Recurse -File -Filter '*.swift' | ForEach-Object {
            $relativeFile = [IO.Path]::GetRelativePath($originalSource, $_.FullName)
            $targetFile = Join-Path $targetSource $relativeFile
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetFile) -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force
        }
    }
    Write-Host "Windows core tests use an exact source mirror at $packageRoot; the Apple dependency lock stays in place."
}

Push-Location -LiteralPath $packageRoot
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
