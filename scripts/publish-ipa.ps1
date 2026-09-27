[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory,
    [string]$DestinationDirectory = 'D:\Data\Ledger-Install'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "SHA-256 mismatch: $Path"
    }
}

function Publish-File([string]$Source, [string]$Target) {
    # Same-directory staging keeps the existing IPA intact if copying fails.
    $temporary = Join-Path (Split-Path -Parent $Target) ('.publish-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        Assert-Hash $temporary (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([IO.File]::Exists($Target)) {
            [IO.File]::Replace($temporary, $Target, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Target)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

$artifacts = (Resolve-Path -LiteralPath $ArtifactsDirectory).Path
$ipa = Join-Path $artifacts 'Ledger-unsigned.ipa'
$checksum = Join-Path $artifacts 'Ledger-unsigned.ipa.sha256'
$metadataPath = Join-Path $artifacts 'build-metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
$line = (Get-Content -LiteralPath $checksum -Raw -Encoding utf8).Trim()
if ($line -notmatch '^([a-fA-F0-9]{64})\s+\*?Ledger-unsigned\.ipa$') {
    throw 'Expected a SHA-256 record for Ledger-unsigned.ipa.'
}
$digest = $Matches[1].ToLowerInvariant()
Assert-Hash $ipa $digest
if ($metadata.status -ne 'package tests and simulator tests passed; unsigned device build produced' -or
    $metadata.architectures -ne 'arm64' -or $metadata.sourceCommit -notmatch '^[a-fA-F0-9]{40}$') {
    throw 'Expected successful arm64 build metadata with an exact source commit.'
}
# PowerShell versions differ in whether ConvertFrom-Json parses ISO dates.
$builtAt = [DateTimeOffset]$metadata.builtAtUTC
$destination = [IO.Path]::GetFullPath($DestinationDirectory)
$historyRoot = Join-Path $destination 'history'
[IO.Directory]::CreateDirectory($historyRoot) | Out-Null
# Other chats may publish concurrently. Reject concurrent publication instead of mixing versions.
$lock = [IO.File]::Open((Join-Path $historyRoot '.publish.lock'), [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $latestIPA = Join-Path $destination 'Ledger-latest.ipa'
    $latestRecord = Join-Path $destination 'latest.json'
    if (Test-Path -LiteralPath $latestRecord -PathType Leaf) {
        $previous = Get-Content -LiteralPath $latestRecord -Raw -Encoding utf8 | ConvertFrom-Json
        if (([DateTimeOffset]$previous.builtAtUTC) -gt $builtAt) {
            throw 'A newer build is already published. The latest IPA has not been replaced.'
        }
    }
    $version = $builtAt.UtcDateTime.ToString('yyyyMMddTHHmmssZ') + '-' + $metadata.sourceCommit.Substring(0, 10)
    $archive = Join-Path $historyRoot $version
    [IO.Directory]::CreateDirectory($archive) | Out-Null
    $archiveIPA = Join-Path $archive 'Ledger-unsigned.ipa'
    if (Test-Path -LiteralPath $archiveIPA -PathType Leaf) {
        Assert-Hash $archiveIPA $digest
    } else {
        Publish-File $ipa $archiveIPA
    }
    Assert-Hash $archiveIPA $digest
    Publish-File $checksum (Join-Path $archive 'Ledger-unsigned.ipa.sha256')
    Publish-File $metadataPath (Join-Path $archive 'build-metadata.json')

    $record = [ordered]@{
        builtAtUTC = $builtAt.ToUniversalTime().ToString('o')
        publishedAtUTC = [DateTimeOffset]::UtcNow.ToString('o')
        sourceCommit = $metadata.sourceCommit
        githubRunID = $metadata.githubRunID
        sha256 = $digest
        bytes = (Get-Item -LiteralPath $archiveIPA).Length
        latestIPA = $latestIPA
        archiveIPA = $archiveIPA
        signing = 'unsigned; sign locally before installation'
        deviceInstallation = $metadata.deviceInstallation
    }
    $encoding = [Text.UTF8Encoding]::new($false)
    $archivedRecord = Join-Path $archive 'installation-package.json'
    [IO.File]::WriteAllText($archivedRecord, ($record | ConvertTo-Json) + "`n", $encoding)
    $instructions = @"
Ledger 真机安装包

每次安装只取此文件夹中的 Ledger-latest.ipa，拖入 Sideloadly 签名安装。
该文件始终代表最近一次成功交付的未签名版本；不要把自己的签名文件保存为此文件名。

构建时间（本机时间）：$($builtAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))
源代码提交：$($metadata.sourceCommit)
GitHub 运行 ID：$($metadata.githubRunID)
SHA-256：$digest
文件大小：$($record.bytes) 字节
历史版本：history\$version

latest.json 保存可核对的版本信息，history 保留以前的版本。
这个文件夹在项目工作区之外，更新安装包不会修改 App 的账本数据。
"@
    $archivedInstructions = Join-Path $archive '安装说明.txt'
    [IO.File]::WriteAllText($archivedInstructions, $instructions, $encoding)

    # Only the IPA replacement is atomic; the version notes are separate files.
    Publish-File $archiveIPA $latestIPA
    Assert-Hash $latestIPA $digest
    Publish-File $archivedRecord $latestRecord
    Publish-File $archivedInstructions (Join-Path $destination '安装说明.txt')
    $record | ConvertTo-Json
} finally {
    $lock.Dispose()
}
