[CmdletBinding()]
param(
    [ValidateRange(0, 100000)]
    [int[]]$Sizes = @(0, 10000, 100000),
    [ValidateRange(1, 1000)]
    [int]$Samples = 10,
    [ValidateRange(0, 100)]
    [int]$Warmups = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Sizes.Count -eq 0 -or @($Sizes | Select-Object -Unique).Count -ne $Sizes.Count) {
    throw 'Sizes must be a nonempty list of distinct entry counts.'
}
$benchmarkProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$benchmarkWorkspacePrefix = $benchmarkProjectRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$benchmarkRoot = [IO.Path]::GetFullPath((Join-Path $benchmarkProjectRoot 'build/performance'))
if (-not $benchmarkRoot.StartsWith($benchmarkWorkspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Benchmark output must remain inside this workspace.'
}
$benchmarkRunName = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + $PID + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
$benchmarkRunRoot = Join-Path $benchmarkRoot $benchmarkRunName
$benchmarkPackageRoot = Join-Path $benchmarkRunRoot 'package'
$benchmarkCoreTarget = Join-Path $benchmarkPackageRoot 'Sources/LedgerCore'
$benchmarkDriverTarget = Join-Path $benchmarkPackageRoot 'Sources/CoreBaseline'
New-Item -ItemType Directory -Path $benchmarkCoreTarget, $benchmarkDriverTarget -Force | Out-Null

# A new per-run source snapshot avoids deleting files or racing another benchmark process.
# The actual Core sources are copied byte-for-byte; the root Apple Package.resolved is never touched.
$benchmarkSourceRecords = @()
$benchmarkCoreSource = Join-Path $benchmarkProjectRoot 'Sources/LedgerCore'
foreach ($source in (Get-ChildItem -LiteralPath $benchmarkCoreSource -Recurse -File -Filter '*.swift' | Sort-Object FullName)) {
    $relative = [IO.Path]::GetRelativePath($benchmarkCoreSource, $source.FullName)
    $destination = Join-Path $benchmarkCoreTarget $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source.FullName -Destination $destination
    $benchmarkSourceRecords += [ordered]@{
        path = 'Sources/LedgerCore/' + $relative.Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$benchmarkDriverSource = Join-Path $benchmarkProjectRoot 'Benchmarks/CoreBaseline/main.swift'
$benchmarkDriverFile = Join-Path $benchmarkDriverTarget 'main.swift'
Copy-Item -LiteralPath $benchmarkDriverSource -Destination $benchmarkDriverFile
$benchmarkSourceRecords += [ordered]@{
    path = 'Benchmarks/CoreBaseline/main.swift'
    sha256 = (Get-FileHash -LiteralPath $benchmarkDriverFile -Algorithm SHA256).Hash.ToLowerInvariant()
}
$benchmarkManifest = @'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LedgerCoreBaseline",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "CoreBaseline", targets: ["CoreBaseline"])],
    targets: [.target(name: "LedgerCore"), .executableTarget(name: "CoreBaseline", dependencies: ["LedgerCore"])],
    swiftLanguageModes: [.v6]
)
'@
$benchmarkManifestFile = Join-Path $benchmarkPackageRoot 'Package.swift'
[IO.File]::WriteAllText($benchmarkManifestFile, $benchmarkManifest, [Text.UTF8Encoding]::new($false))
$benchmarkSourceRecords += [ordered]@{
    path = 'Package.swift (generated baseline manifest)'
    sha256 = (Get-FileHash -LiteralPath $benchmarkManifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
}
$benchmarkSourceRecords = @($benchmarkSourceRecords | Sort-Object { $_.path })
$benchmarkDigestText = ($benchmarkSourceRecords | ForEach-Object { $_.path + "`t" + $_.sha256 }) -join "`n"
$benchmarkDigestBytes = [Text.Encoding]::UTF8.GetBytes($benchmarkDigestText + "`n")
$benchmarkHasher = [Security.Cryptography.SHA256]::Create()
try { $benchmarkSourceDigest = [Convert]::ToHexString($benchmarkHasher.ComputeHash($benchmarkDigestBytes)).ToLowerInvariant() }
finally { $benchmarkHasher.Dispose() }

$benchmarkSwift = Get-Command swift -ErrorAction Stop
$benchmarkSwiftVersion = (& $benchmarkSwift.Source --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Swift could not report its version.' }
$benchmarkHead = (& git -C $benchmarkProjectRoot rev-parse HEAD 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { $benchmarkHead = 'unavailable' }
$benchmarkCPUModel = 'unavailable'
try {
    $benchmarkCPUName = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
        Select-Object -ExpandProperty Name -Unique) -join '; '
    if (-not [string]::IsNullOrWhiteSpace($benchmarkCPUName)) { $benchmarkCPUModel = $benchmarkCPUName.Trim() }
} catch { } # Optional environment detail must not block measurement.
$benchmarkMetadata = [ordered]@{
    capturedAtUTC = [DateTime]::UtcNow.ToString('o')
    swiftVersion = $benchmarkSwiftVersion
    operatingSystem = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    cpuModel = $benchmarkCPUModel
    logicalProcessorCount = [Environment]::ProcessorCount
    configuration = 'release'
    gitHead = $benchmarkHead
    sourceSnapshotSHA256 = $benchmarkSourceDigest
    sourceDigestMethod = 'SHA256 of UTF8 sorted relative-path TAB lowercase-sha256 LF records; includes exact mirrored Core, benchmark driver and generated package manifest'
    sourceFiles = $benchmarkSourceRecords
    generatedManifestSHA256 = (Get-FileHash -LiteralPath $benchmarkManifestFile -Algorithm SHA256).Hash.ToLowerInvariant()
    scriptSHA256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    dataSource = 'Deterministic synthetic fixture core-mixed-v1; no user database, backup or input read'
    environmentalControls = 'Host background load, thermal state and power mode are not controlled. This is a function baseline, not an acceptance threshold.'
}
$benchmarkMetadataFile = Join-Path $benchmarkRunRoot 'metadata.json'
$benchmarkReportFile = Join-Path $benchmarkRunRoot 'results.json'
[IO.File]::WriteAllText($benchmarkMetadataFile, ($benchmarkMetadata | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Host $benchmarkSwiftVersion
Write-Host "Core Release baseline: $($Sizes -join ', ') entries; $Samples measured samples and $Warmups warmups per operation."
Write-Host "This does not measure SQLite, UI, iPhone or Q01-Q09 acceptance. Results: $benchmarkReportFile"
$benchmarkArguments = @('run', '--package-path', $benchmarkPackageRoot, '--configuration', 'release', 'CoreBaseline',
    '--output', $benchmarkReportFile, '--metadata', $benchmarkMetadataFile, '--sizes', ($Sizes -join ','),
    '--samples', $Samples.ToString(), '--warmups', $Warmups.ToString())
& $benchmarkSwift.Source @benchmarkArguments 2>&1 | Tee-Object -FilePath (Join-Path $benchmarkRunRoot 'run.log')
if ($LASTEXITCODE -ne 0) { throw "Core benchmark failed (exit $LASTEXITCODE); retain this run directory for diagnostics: $benchmarkRunRoot" }
Write-Host "Completed. Raw samples and summaries: $benchmarkReportFile"
